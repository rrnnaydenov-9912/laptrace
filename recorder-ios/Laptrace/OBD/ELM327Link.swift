import CoreBluetooth
import Foundation
import Observation

/// Talks to a Bluetooth LE ELM327 OBD reader. Line based: write a command plus CR, collect the
/// reply until the adapter prints its ">" prompt.
///
/// Read-only by construction: `send` refuses anything that isn't an adapter AT command or an OBD
/// service 01 / 09 query, so nothing here can clear codes or write to the car.
@Observable
final class ELM327Link: NSObject {
    enum State: Equatable {
        case idle, bluetoothOff, unauthorized, scanning, connecting, ready
        case failed(String)
    }

    struct Found: Identifiable {
        let id: UUID
        let name: String
        var rssi: Int
        let peripheral: CBPeripheral
        /// Names cheap readers commonly advertise; used only to sort them to the top.
        var looksLikeOBD: Bool {
            let n = name.uppercased()
            return ["OBD", "ELM", "LINK", "VEEPEAK", "KONNWEI", "CAR"].contains { n.contains($0) }
        }
    }

    enum LinkError: LocalizedError {
        case notReady, busy, timeout(String), refused(String), disconnected
        var errorDescription: String? {
            switch self {
            case .notReady: "The reader isn't connected."
            case .busy: "The reader is still answering the previous command."
            case .timeout(let c): "The reader didn't answer \(c) in time."
            case .refused(let c): "Blocked \(c): only read commands are allowed."
            case .disconnected: "The reader disconnected."
            }
        }
    }

    /// One reader connection for the whole app: the Car tab's probe and the live track feed share it.
    static let shared = ELM327Link()

    private(set) var state: State = .idle
    private(set) var found: [Found] = []
    private(set) var deviceName: String?
    /// Which BLE service/characteristics carry the serial link, for the probe log.
    private(set) var channel = ""

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var writeChar: CBCharacteristic?
    @ObservationIgnored private var notifyChar: CBCharacteristic?
    @ObservationIgnored private var pendingServices = 0
    @ObservationIgnored private var buffer = ""
    @ObservationIgnored private var waiter: CheckedContinuation<String, Error>?
    @ObservationIgnored private var waiterID = 0
    @ObservationIgnored private var connectWaiter: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var streamLine: ((String) -> Void)?
    @ObservationIgnored private var streamEnded: (() -> Void)?

    // MARK: Read-only guard

    /// AT commands only configure the adapter itself; a few of them persist settings in the
    /// adapter or make it transmit on its own, so those are blocked too.
    static func isReadOnly(_ command: String) -> Bool {
        let c = command.uppercased().replacingOccurrences(of: " ", with: "")
        guard !c.isEmpty else { return false }
        if c.hasPrefix("AT") {
            let blocked = ["ATPP", "ATSD", "ATWM", "ATBRD", "ATBRT", "ATMT", "ATMR"]
            return !blocked.contains { c.hasPrefix($0) }
        }
        guard c.allSatisfy(\.isHexDigit) else { return false }
        return c.hasPrefix("01") || c.hasPrefix("09")
    }

    // MARK: Scanning and connecting

    func scan() {
        found = []
        if central == nil {
            // Creating the manager is what triggers the Bluetooth permission prompt.
            central = CBCentralManager(delegate: self, queue: .main)
            state = .scanning
            return
        }
        startScanIfPowered()
    }

    func stopScan() {
        central?.stopScan()
        if state == .scanning { state = .idle }
    }

    private func startScanIfPowered() {
        guard let central else { return }
        switch central.state {
        case .poweredOn:
            state = .scanning
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .unauthorized: state = .unauthorized
        case .poweredOff: state = .bluetoothOff
        default: break
        }
    }

    func connect(_ device: Found) async throws {
        guard let central else { throw LinkError.notReady }
        central.stopScan()
        disconnect()
        state = .connecting
        deviceName = device.name
        peripheral = device.peripheral
        device.peripheral.delegate = self
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connectWaiter = c
            central.connect(device.peripheral)
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self, self.connectWaiter != nil else { return }
                self.finishConnect(.failure(LinkError.timeout("the connection")))
                self.disconnect()
            }
        }
    }

    func disconnect() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        failWaiter(LinkError.disconnected)
        if state == .ready || state == .connecting { state = .idle }
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        guard let c = connectWaiter else { return }
        connectWaiter = nil
        switch result {
        case .success:
            state = .ready
            c.resume()
        case .failure(let e):
            state = .failed(e.localizedDescription)
            c.resume(throwing: e)
        }
    }

    // MARK: Commands

    /// Sends one command and returns the reply lines (echo, "SEARCHING..." and the prompt removed).
    func send(_ command: String, timeout: Double = 3) async throws -> [String] {
        guard Self.isReadOnly(command) else { throw LinkError.refused(command) }
        let raw = try await exchange(command + "\r", timeout: timeout, label: command)
        return Self.lines(raw, echo: command)
    }

    /// Starts a command that streams lines without a prompt (ATMA). `onLine` gets each complete
    /// line; `onEnded` fires if the adapter stops by itself (e.g. BUFFER FULL).
    func startStream(_ command: String, onLine: @escaping (String) -> Void, onEnded: @escaping () -> Void) throws {
        guard Self.isReadOnly(command) else { throw LinkError.refused(command) }
        guard waiter == nil, streamLine == nil else { throw LinkError.busy }
        buffer = ""
        streamLine = onLine
        streamEnded = onEnded
        try write(command + "\r")
    }

    /// Any character stops a streaming command; waits for the prompt so the next command is clean.
    func stopStream() async {
        guard streamLine != nil else { return }
        streamLine = nil
        streamEnded = nil
        buffer = ""
        _ = try? await exchange("\r", timeout: 2, label: "stop")
    }

    private func exchange(_ text: String, timeout: Double, label: String) async throws -> String {
        guard state == .ready else { throw LinkError.notReady }
        guard waiter == nil, streamLine == nil else { throw LinkError.busy }
        buffer = ""
        waiterID += 1
        let id = waiterID
        return try await withCheckedThrowingContinuation { c in
            waiter = c
            do { try write(text) } catch { failWaiter(error); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.waiterID == id, self.waiter != nil else { return }
                self.failWaiter(LinkError.timeout(label))
            }
        }
    }

    private func write(_ text: String) throws {
        guard let peripheral, let writeChar else { throw LinkError.notReady }
        let type: CBCharacteristicWriteType = writeChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let data = Data(text.utf8)
        let chunk = max(20, peripheral.maximumWriteValueLength(for: type))
        var i = 0
        while i < data.count {
            peripheral.writeValue(data.subdata(in: i..<min(i + chunk, data.count)), for: writeChar, type: type)
            i += chunk
        }
    }

    private func failWaiter(_ error: Error) {
        guard let c = waiter else { return }
        waiter = nil
        c.resume(throwing: error)
    }

    private func received(_ data: Data) {
        let text = String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
        buffer += text
        if let onLine = streamLine {
            if let prompt = buffer.firstIndex(of: ">") {
                buffer.removeSubrange(prompt...)
                for l in Self.lines(buffer, echo: nil) { onLine(l) }
                buffer = ""
                let ended = streamEnded
                streamLine = nil
                streamEnded = nil
                ended?()
                return
            }
            // Emit complete lines, keep the partial tail.
            while let r = buffer.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
                let line = buffer[..<r].trimmingCharacters(in: .whitespaces)
                buffer.removeSubrange(...r)
                if !line.isEmpty { onLine(line) }
            }
            return
        }
        guard let prompt = buffer.firstIndex(of: ">"), let c = waiter else { return }
        let reply = String(buffer[..<prompt])
        buffer = ""
        waiter = nil
        c.resume(returning: reply)
    }

    static func lines(_ raw: String, echo: String?) -> [String] {
        raw.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != echo && !$0.hasPrefix("SEARCHING") }
    }
}

// MARK: - CoreBluetooth

extension ELM327Link: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: if state == .scanning || state == .idle || state == .bluetoothOff { startScanIfPowered() }
        case .unauthorized: state = .unauthorized
        case .poweredOff: state = .bluetoothOff; disconnect()
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name, !name.isEmpty else { return }
        if let i = found.firstIndex(where: { $0.id == peripheral.identifier }) {
            found[i].rssi = RSSI.intValue
        } else {
            found.append(Found(id: peripheral.identifier, name: name, rssi: RSSI.intValue, peripheral: peripheral))
        }
        found.sort { ($0.looksLikeOBD ? 1 : 0, $0.rssi) > ($1.looksLikeOBD ? 1 : 0, $1.rssi) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishConnect(.failure(error ?? LinkError.disconnected))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        self.peripheral = nil
        writeChar = nil
        notifyChar = nil
        finishConnect(.failure(LinkError.disconnected))
        failWaiter(LinkError.disconnected)
        streamLine = nil
        streamEnded = nil
        state = .failed(LinkError.disconnected.localizedDescription)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        pendingServices = services.count
        if services.isEmpty { finishConnect(.failure(LinkError.notReady)) }
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingServices -= 1
        guard pendingServices <= 0 else { return }
        guard let (notify, write) = Self.pickChannel(peripheral.services ?? []) else {
            finishConnect(.failure(LinkError.timeout("a serial channel (this doesn't look like an OBD reader)")))
            return
        }
        notifyChar = notify
        writeChar = write
        channel = "service \(notify.service?.uuid.uuidString ?? "?") · notify \(notify.uuid.uuidString) · write \(write.uuid.uuidString)"
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic == notifyChar else { return }
        if let error { finishConnect(.failure(error)) } else { finishConnect(.success(())) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic == notifyChar, let data = characteristic.value else { return }
        received(data)
    }

    /// BLE ELM327 clones put the serial link in a vendor service (FFE0, FFF0, 18F0, …). Prefer a
    /// characteristic that both notifies and accepts writes; otherwise pair them within one service.
    static func pickChannel(_ services: [CBService]) -> (CBCharacteristic, CBCharacteristic)? {
        let standard: Set<String> = ["1800", "1801", "180A", "180F"]
        let preferred = ["FFE0", "FFF0", "18F0"]
        let candidates = services
            .filter { !standard.contains($0.uuid.uuidString) }
            .sorted { (preferred.firstIndex(of: $0.uuid.uuidString) ?? 99) < (preferred.firstIndex(of: $1.uuid.uuidString) ?? 99) }
        func canWrite(_ c: CBCharacteristic) -> Bool { c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) }
        func canNotify(_ c: CBCharacteristic) -> Bool { c.properties.contains(.notify) || c.properties.contains(.indicate) }
        for s in candidates {
            let chars = s.characteristics ?? []
            if let both = chars.first(where: { canWrite($0) && canNotify($0) }) { return (both, both) }
            if let n = chars.first(where: canNotify), let w = chars.first(where: canWrite) { return (n, w) }
        }
        return nil
    }
}

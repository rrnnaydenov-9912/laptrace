import Foundation
import Observation

/// Live car feed for the track screen: polls RPM, speed, throttle, pedal and load as fast as the
/// reader answers, and the temperatures every few seconds. While a session is recording, every
/// poll is written to the session's obd.csv.
///
/// Read-only like everything else on the link: only service 01 queries and adapter AT commands.
@Observable
final class OBDLive {
    static let shared = OBDLive()

    let link = ELM327Link.shared
    private(set) var running = false
    private(set) var values: [UInt8: Double] = [:]
    private(set) var hz: Double = 0
    private(set) var lastUpdate: Date?
    private(set) var problem: String?
    private(set) var readerName: String?

    /// Fresh enough to show as live numbers.
    var isLive: Bool { running && (lastUpdate.map { Date().timeIntervalSince($0) < 2 } ?? false) }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var fastMode = FastMode.multiCounted
    @ObservationIgnored private var slowCombined = true
    @ObservationIgnored private var singleIndex = 0
    @ObservationIgnored private var slowIndex = 0

    private enum FastMode { case multiCounted, multi, single }
    static let fastPIDs: [UInt8] = [0x0C, 0x0D, 0x11, 0x49, 0x04]
    static let slowPIDs: [UInt8] = [0x05, 0x5C, 0x0F]
    private static let rememberKey = "obdReaderID"

    // MARK: Connect

    /// Finds the reader (the last one used, else the first that looks like OBD), connects and starts.
    func autoConnect() async {
        problem = nil
        if link.state != .ready {
            link.scan()
            let remembered = UserDefaults.standard.string(forKey: Self.rememberKey).flatMap(UUID.init)
            var pick: ELM327Link.Found?
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(200))
                if let r = remembered, let d = link.found.first(where: { $0.id == r }) { pick = d; break }
                if remembered == nil, let d = link.found.first(where: \.looksLikeOBD) { pick = d; break }
            }
            if pick == nil { pick = link.found.first(where: \.looksLikeOBD) }
            guard let pick else {
                link.stopScan()
                problem = link.state == .bluetoothOff ? "Bluetooth is off." : "No OBD reader found. Is it plugged in with the ignition on?"
                return
            }
            await connect(pick)
            guard link.state == .ready else { return }
        }
        await start()
    }

    func connect(_ device: ELM327Link.Found) async {
        do {
            try await link.connect(device)
            UserDefaults.standard.set(device.id.uuidString, forKey: Self.rememberKey)
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: Poll

    func start() async {
        guard !running, link.state == .ready else { return }
        running = true
        problem = nil
        readerName = link.deviceName
        values = [:]
        fastMode = .multiCounted
        slowCombined = true
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() async {
        running = false
        await loop?.value
        loop = nil
        hz = 0
    }

    private func run() async {
        for c in ["ATE0", "ATL0", "ATS0", "ATH0", "ATCAF1"] { _ = try? await link.send(c) }
        // First query wakes the car link; it can take several seconds while the protocol is found.
        if (try? await link.send("0100", timeout: 15)) == nil {
            problem = "The car didn't answer. Start the engine and try again."
            running = false
            return
        }
        var lastSlow = Date.distantPast
        var failures = 0
        var stamps: [Date] = []
        while running && link.state == .ready {
            do {
                var got = try await pollFast()
                if Date().timeIntervalSince(lastSlow) > 3 {
                    got.merge(try await pollSlow()) { $1 }
                    lastSlow = Date()
                }
                failures = 0
                let now = Date()
                guard !got.isEmpty else { continue }
                values.merge(got) { $1 }
                lastUpdate = now
                stamps.append(now)
                stamps.removeAll { now.timeIntervalSince($0) > 2 }
                hz = Double(stamps.count) / 2
                Recorder.shared.record(OBDSample(t: now.timeIntervalSince1970, pids: got))
            } catch ELM327Link.LinkError.busy {
                try? await Task.sleep(for: .milliseconds(50))
            } catch {
                failures += 1
                if failures >= 5 {
                    problem = "The reader stopped answering."
                    break
                }
            }
        }
        if link.state != .ready && problem == nil { problem = "The reader disconnected." }
        running = false
        hz = 0
    }

    private func decode(_ lines: [String]) -> [UInt8: Double] {
        var out: [UInt8: Double] = [:]
        for (pid, bytes) in OBDDecode.mode01(lines) {
            if let v = OBDDecode.value(pid: pid, bytes) { out[pid] = v }
        }
        return out
    }

    private static func command(_ pids: [UInt8]) -> String {
        "01" + pids.map { String(format: "%02X", $0) }.joined()
    }

    /// Several PIDs per request is far faster on CAN. The trailing count tells the reader how many
    /// answers to wait for; some clones don't understand it, so fall back step by step.
    private func pollFast() async throws -> [UInt8: Double] {
        switch fastMode {
        case .multiCounted, .multi:
            let cmd = Self.command(Self.fastPIDs) + (fastMode == .multiCounted ? "1" : "")
            let got = decode(try await link.send(cmd, timeout: 1.5))
            if got.count < 2 { fastMode = fastMode == .multiCounted ? .multi : .single }
            return got
        case .single:
            let pid = Self.fastPIDs[singleIndex % 2 == 0 ? 0 : 1 + (singleIndex / 2) % (Self.fastPIDs.count - 1)]
            singleIndex += 1
            return decode(try await link.send(Self.command([pid]), timeout: 1.5))
        }
    }

    private func pollSlow() async throws -> [UInt8: Double] {
        if slowCombined {
            let got = decode(try await link.send(Self.command(Self.slowPIDs), timeout: 1.5))
            if got.isEmpty { slowCombined = false }
            return got
        }
        let pid = Self.slowPIDs[slowIndex % Self.slowPIDs.count]
        slowIndex += 1
        return decode((try? await link.send(Self.command([pid]), timeout: 1.5)) ?? [])
    }
}

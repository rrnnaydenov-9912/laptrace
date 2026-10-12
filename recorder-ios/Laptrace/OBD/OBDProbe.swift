import Foundation
import Observation

/// One-off check of what a cheap ELM327 can see on this car: adapter, protocol, supported PIDs,
/// how many readings per second we get, and whether steering / brake show up as passive CAN
/// traffic. Everything is written to a text log the user can share.
@Observable
final class OBDProbe {
    struct Step: Identifiable {
        enum Status { case running, ok, warn, failed }
        let id: String
        let title: String
        var detail: String
        var status: Status
    }

    /// What the driver should do during each passive listening window.
    struct ListenPhase {
        let key: String, title: String, instruction: String, seconds: Int
    }

    static let listenPhases = [
        ListenPhase(key: "quiet", title: "Hands off", instruction: "Don't touch the wheel or pedals.", seconds: 10),
        ListenPhase(key: "steer", title: "Steering", instruction: "Turn the wheel slowly to full left, then full right, then back to centre.", seconds: 20),
        ListenPhase(key: "brake", title: "Brake", instruction: "Press the brake pedal firmly three times.", seconds: 15),
        ListenPhase(key: "throttle", title: "Throttle", instruction: "Blip the throttle twice. Stay in neutral.", seconds: 15),
    ]

    /// PIDs the lap coach would use, in the order they matter.
    static let wishlist: [UInt8] = [0x0C, 0x0D, 0x11, 0x49, 0x04, 0x0B, 0x05, 0x0F, 0x5C]

    let link = ELM327Link.shared
    private(set) var steps: [Step] = []
    private(set) var running = false
    private(set) var listening: (phase: ListenPhase, secondsLeft: Int, frames: Int)?
    private(set) var live: [UInt8: Double] = [:]
    private(set) var logURL: URL?
    private(set) var findings: [String] = []

    @ObservationIgnored private var log: [String] = []
    @ObservationIgnored private var started = Date()

    // MARK: Run

    func run() async {
        guard !running else { return }
        await OBDLive.shared.stop() // the probe needs the reader to itself
        running = true
        steps = []
        findings = []
        live = [:]
        logURL = nil
        log = []
        started = Date()
        note("Laptrace OBD probe · \(started.formatted(.iso8601))")
        note("Reader: \(link.deviceName ?? "?") · \(link.channel)")

        do {
            try await adapter()
            try await carLink()
            let supported = await supportedPIDs()
            await ecus()
            await rates(supported: supported)
            await temperatures()
            await listen()
        } catch {
            note("ABORTED: \(error.localizedDescription)")
            if let i = steps.indices.last, steps[i].status == .running {
                steps[i].status = .failed
                steps[i].detail = error.localizedDescription
            }
        }
        await restoreDefaults()
        saveLog()
        running = false
    }

    private func adapter() async throws {
        begin("adapter", "Reader")
        _ = try await cmd("ATZ", timeout: 5)
        for c in ["ATE0", "ATL0", "ATS0", "ATH0", "ATCAF1", "ATSP0"] { _ = try await cmd(c) }
        let version = try await cmd("ATI").first ?? "?"
        let volts = (try? await cmd("ATRV").first) ?? "?"
        finish("adapter", "\(version) · battery \(volts)", .ok)
    }

    private func carLink() async throws {
        begin("car", "Car connection")
        let reply = try await cmd("0100", timeout: 15)
        guard reply.contains(where: { $0.replacingOccurrences(of: " ", with: "").contains("4100") }) else {
            finish("car", "The car didn't answer (\(reply.joined(separator: " "))). Start the engine and run the probe again.", .failed)
            throw ELM327Link.LinkError.timeout("0100")
        }
        let proto = (try? await cmd("ATDP").first) ?? "?"
        let isCAN = proto.contains("15765")
        finish("car", proto, isCAN ? .ok : .warn)
        if !isCAN { findings.append("Not on CAN (\(proto)): multi-PID requests and passive listening won't work.") }
    }

    private func supportedPIDs() async -> Set<UInt8> {
        begin("pids", "Supported data")
        var all = Set<UInt8>()
        var base: UInt8 = 0x00
        while true {
            guard let reply = try? await cmd(String(format: "01%02X", base), timeout: 4) else { break }
            let s = OBDDecode.supported(reply, base: base)
            all.formUnion(s)
            guard base < 0x60, s.contains(base + 0x20) else { break }
            base += 0x20
        }
        let sorted = all.sorted()
        note("Supported PIDs: " + sorted.map { String(format: "%02X", $0) }.joined(separator: " "))
        let have = Self.wishlist.filter(all.contains).compactMap { OBDDecode.pidName[$0] }
        let missing = Self.wishlist.filter { !all.contains($0) }.compactMap { OBDDecode.pidName[$0] }
        var detail = "\(all.count) PIDs. Has \(have.joined(separator: ", "))."
        if !missing.isEmpty { detail += " Missing \(missing.joined(separator: ", "))." }
        finish("pids", detail, all.contains(0x0C) && all.contains(0x11) ? .ok : .warn)
        return all
    }

    private func ecus() async {
        _ = try? await cmd("ATH1")
        let reply = (try? await cmd("0100", timeout: 4)) ?? []
        _ = try? await cmd("ATH0")
        let headers = Set(reply.compactMap { l -> String? in
            let s = l.replacingOccurrences(of: " ", with: "")
            guard s.count > 6, s.allSatisfy(\.isHexDigit) else { return nil }
            return String(s.prefix(s.hasPrefix("18") ? 8 : 3))
        })
        note("ECUs answering 0100: \(headers.sorted().joined(separator: " "))")
    }

    /// Readings per second for one PID per request, several per request, and several with the
    /// "expect one reply" suffix that stops clones waiting out their timeout.
    private func rates(supported: Set<UInt8>) async {
        begin("rate", "Readings per second")
        let fast = [0x0C, 0x0D, 0x11, 0x49, 0x04, 0x0B].filter { supported.contains(UInt8($0)) }.prefix(6)
        let multi = "01" + fast.map { String(format: "%02X", $0) }.joined()
        let variants: [(String, String)] = [
            ("single", "010C"),
            ("multi", multi),
            ("multi+1", multi + "1"),
        ]
        var results: [String] = []
        var best: (label: String, hz: Double, pids: Int) = ("", 0, 0)
        for (label, request) in variants where request.count > 2 {
            var ok = 0, pids = 0
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 5 {
                guard let reply = try? await cmd(request, timeout: 2, quiet: true) else { break }
                let values = OBDDecode.mode01(reply)
                if !values.isEmpty { ok += 1; pids = max(pids, values.count) }
                for (pid, d) in values { live[pid] = OBDDecode.value(pid: pid, d) }
            }
            let hz = Double(ok) / Date().timeIntervalSince(t0)
            results.append(String(format: "%@ %.1f Hz × %d", label, hz, pids))
            note(String(format: "Rate %@ (%@): %.1f replies/s, %d PIDs per reply", label, request, hz, pids))
            if hz * Double(pids) > best.hz * Double(best.pids) { best = (label, hz, pids) }
        }
        let status: Step.Status = best.hz >= 5 ? .ok : .warn
        finish("rate", results.joined(separator: " · "), status)
        findings.append(String(format: "Best: %@ at %.1f Hz with %d values per reading.", best.label, best.hz, best.pids))
    }

    /// Coolant and oil temperature. Asked for even when the bitmap doesn't list them, since
    /// some ECUs answer PIDs they don't advertise.
    private func temperatures() async {
        begin("temps", "Coolant and oil temperature")
        var parts: [String] = [], missing: [String] = []
        for (pid, name) in [(UInt8(0x05), "coolant"), (UInt8(0x5C), "oil")] {
            let reply = (try? await cmd(String(format: "01%02X", pid), timeout: 2)) ?? []
            if let d = OBDDecode.mode01(reply)[pid], let v = OBDDecode.value(pid: pid, d) {
                live[pid] = v
                parts.append(String(format: "%@ %.0f °C", name.capitalized, v))
            } else {
                missing.append(name)
            }
        }
        var detail = parts.joined(separator: " · ")
        if !missing.isEmpty {
            if !detail.isEmpty { detail += ". " }
            detail += "No \(missing.joined(separator: " or ")) temperature over standard OBD."
        }
        finish("temps", detail, missing.isEmpty ? .ok : .warn)
        if missing.contains("oil") {
            findings.append("Oil temperature isn't a standard reading on this car; it would need the engine ECU's own request.")
        }
    }

    /// Passive CAN listen in four timed windows so the log shows which bytes move with which action.
    private func listen() async {
        begin("listen", "Listening for steering and brake")
        for c in ["ATH1", "ATS1", "ATCAF0"] { _ = try? await cmd(c) }
        var captured: [String: [OBDDecode.Frame]] = [:]
        var overflows = 0
        let t0 = Date()

        for phase in Self.listenPhases {
            note("--- \(phase.key): \(phase.instruction)")
            var frames: [OBDDecode.Frame] = []
            var stopped = false
            listening = (phase, phase.seconds, 0)
            let end = Date().addingTimeInterval(Double(phase.seconds))

            func start() {
                try? link.startStream("ATMA", onLine: { [weak self] line in
                    guard let self else { return }
                    let t = Date().timeIntervalSince(t0)
                    self.log.append(String(format: "%8.3f %@", t, line))
                    if line.contains("BUFFER FULL") { overflows += 1 }
                    if let f = OBDDecode.frame(line, t: t) {
                        frames.append(f)
                        self.listening?.frames = frames.count
                    }
                }, onEnded: { stopped = true })
            }
            start()
            while Date() < end {
                try? await Task.sleep(for: .milliseconds(250))
                listening?.secondsLeft = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
                if stopped { stopped = false; start() } // cheap readers overflow and drop back to the prompt
            }
            await link.stopStream()
            captured[phase.key] = frames
            note("--- \(phase.key): \(frames.count) frames, \(Set(frames.map(\.id)).count) IDs")
        }
        listening = nil

        let total = captured.values.reduce(0) { $0 + $1.count }
        let seconds = Double(Self.listenPhases.reduce(0) { $0 + $1.seconds })
        guard total > 0 else {
            finish("listen", "No traffic on the diagnostic port. The car probably keeps its internal network behind a gateway, so steering and brake need another route.", .warn)
            findings.append("Passive listening saw nothing.")
            return
        }

        var lines = [String(format: "%d frames (%.0f/s), %d IDs", total, Double(total) / seconds,
                            Set(captured.values.flatMap { $0.map(\.id) }).count)]
        if overflows > 0 { lines.append("reader overflowed \(overflows)×") }
        let quiet = captured["quiet"] ?? []
        for key in ["steer", "brake", "throttle"] {
            let c = OBDDecode.candidates(quiet: quiet, active: captured[key] ?? [])
            let text = c.isEmpty ? "nothing obvious" : c.map { "\($0.id) byte \($0.byte)" }.joined(separator: ", ")
            note("Candidates \(key): " + c.map { "\($0.id)[\($0.byte)] \($0.quiet)→\($0.active) values" }.joined(separator: "; "))
            findings.append("\(key.capitalized): \(text)")
        }
        finish("listen", lines.joined(separator: " · "), .ok)
    }

    private func restoreDefaults() async {
        await link.stopStream()
        for c in ["ATCAF1", "ATS0", "ATH0"] { _ = try? await cmd(c) }
    }

    // MARK: Helpers

    private func cmd(_ c: String, timeout: Double = 3, quiet: Bool = false) async throws -> [String] {
        do {
            let r = try await link.send(c, timeout: timeout)
            if !quiet { note("> \(c)  →  \(r.joined(separator: " | "))") }
            return r
        } catch {
            note("> \(c)  →  ERROR \(error.localizedDescription)")
            throw error
        }
    }

    private func note(_ s: String) { log.append(s) }

    private func begin(_ id: String, _ title: String) {
        steps.append(Step(id: id, title: title, detail: "", status: .running))
    }

    private func finish(_ id: String, _ detail: String, _ status: Step.Status) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].detail = detail
        steps[i].status = status
        note("[\(status)] \(steps[i].title): \(detail)")
    }

    private func saveLog() {
        log.append("")
        log.append("Findings:")
        log.append(contentsOf: findings.map { "- " + $0 })
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Probes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        let url = dir.appendingPathComponent("obd-probe-\(f.string(from: started)).txt")
        do {
            try log.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            logURL = url
        } catch {
            findings.append("Couldn't save the log: \(error.localizedDescription)")
        }
    }
}

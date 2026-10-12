import Foundation

/// Pure decoding helpers for ELM327 replies and passive CAN captures, kept free of Bluetooth so
/// they can be unit tested.
enum OBDDecode {
    /// Data bytes per service 01 PID, for the PIDs the probe asks about.
    static let pidLength: [UInt8: Int] = [
        0x04: 1, 0x05: 1, 0x0B: 1, 0x0C: 2, 0x0D: 1, 0x0F: 1, 0x10: 2, 0x11: 1,
        0x33: 1, 0x45: 1, 0x46: 1, 0x49: 1, 0x4A: 1, 0x5C: 1,
    ]

    static let pidName: [UInt8: String] = [
        0x04: "engine load", 0x05: "coolant", 0x0B: "boost (MAP)", 0x0C: "RPM", 0x0D: "speed",
        0x0F: "intake air", 0x10: "air flow", 0x11: "throttle", 0x33: "baro", 0x45: "relative throttle",
        0x46: "ambient", 0x49: "pedal D", 0x4A: "pedal E", 0x5C: "oil temp",
    ]

    /// Joins a (possibly multi-frame) reply into one hex string. With headers and spaces off, a
    /// multi-frame CAN reply looks like "00C", "0:410C1AF80D", "1:2A114D0000…".
    static func payloadHex(_ lines: [String]) -> String {
        var out = ""
        for l in lines {
            var s = l.replacingOccurrences(of: " ", with: "").uppercased()
            if let colon = s.firstIndex(of: ":") { s = String(s[s.index(after: colon)...]) }
            else if s.count == 3, s.allSatisfy(\.isHexDigit), lines.count > 1 { continue } // byte count line
            guard s.allSatisfy(\.isHexDigit) else { continue }
            out += s
        }
        return out
    }

    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), i < hex.endIndex {
            if let b = UInt8(hex[i..<j], radix: 16) { out.append(b) }
            i = j
        }
        return out
    }

    /// Parses a service 01 reply (one or many PIDs) into PID → data bytes. Stops at the first PID
    /// it doesn't know the length of.
    static func mode01(_ lines: [String]) -> [UInt8: [UInt8]] {
        let b = bytes(payloadHex(lines))
        var out: [UInt8: [UInt8]] = [:]
        guard let start = b.firstIndex(of: 0x41) else { return out }
        var i = start + 1
        while i < b.count {
            let pid = b[i]
            guard let n = pidLength[pid], i + n < b.count else { break }
            out[pid] = Array(b[(i + 1)...(i + n)])
            i += n + 1
        }
        return out
    }

    /// Standard scaling for the PIDs the live readout shows.
    static func value(pid: UInt8, _ d: [UInt8]) -> Double? {
        guard let a = d.first.map(Double.init) else { return nil }
        let b = d.count > 1 ? Double(d[1]) : 0
        switch pid {
        case 0x0C: return (a * 256 + b) / 4
        case 0x0D, 0x0B, 0x33: return a
        case 0x05, 0x0F, 0x46, 0x5C: return a - 40
        case 0x04, 0x11, 0x45, 0x49, 0x4A: return a * 100 / 255
        case 0x10: return (a * 256 + b) / 100
        default: return nil
        }
    }

    /// Supported-PID bitmaps: every "41 xx AABBCCDD" in the reply (several ECUs may answer).
    static func supported(_ lines: [String], base: UInt8) -> Set<UInt8> {
        var out = Set<UInt8>()
        for l in lines {
            let b = bytes(payloadHex([l]))
            guard let i = b.firstIndex(of: 0x41), i + 5 < b.count, b[i + 1] == base else { continue }
            for k in 0..<32 where b[i + 2 + k / 8] & (0x80 >> UInt8(k % 8)) != 0 {
                out.insert(base + UInt8(k + 1))
            }
        }
        return out
    }

    // MARK: Passive CAN

    struct Frame { let t: Double; let id: String; let data: [UInt8] }

    /// A monitor line with headers and spaces on: "1A3 00 7F 12 …" (11-bit) or "18DAF110 …".
    static func frame(_ line: String, t: Double) -> Frame? {
        let parts = line.split(separator: " ")
        guard let id = parts.first, id.count == 3 || id.count == 8, id.allSatisfy(\.isHexDigit) else { return nil }
        var data: [UInt8] = []
        for p in parts.dropFirst() {
            guard p.count == 2, let b = UInt8(p, radix: 16) else { return nil }
            data.append(b)
        }
        return Frame(t: t, id: String(id), data: data)
    }

    struct Candidate: Equatable { let id: String; let byte: Int; let quiet: Int; let active: Int }

    /// Bytes that sit still while nothing is touched but move during an action are the likely
    /// carriers of that action (steering angle, brake pressure, pedal). Ranked by how much
    /// livelier the byte gets.
    static func candidates(quiet: [Frame], active: [Frame], limit: Int = 4) -> [Candidate] {
        func distinct(_ frames: [Frame]) -> [String: [Int: Set<UInt8>]] {
            var m: [String: [Int: Set<UInt8>]] = [:]
            for f in frames {
                for (i, b) in f.data.enumerated() { m[f.id, default: [:]][i, default: []].insert(b) }
            }
            return m
        }
        let q = distinct(quiet), a = distinct(active)
        var out: [Candidate] = []
        for (id, bytes) in a {
            for (i, values) in bytes {
                let still = q[id]?[i]?.count ?? 0
                guard still > 0, still <= 3, values.count >= 6 else { continue }
                out.append(Candidate(id: id, byte: i, quiet: still, active: values.count))
            }
        }
        return Array(out.sorted { ($0.active - $0.quiet, $1.id) > ($1.active - $1.quiet, $0.id) }.prefix(limit))
    }
}

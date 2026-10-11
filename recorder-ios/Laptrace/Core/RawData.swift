import Foundation

/// One GPS fix as delivered by CoreLocation. Negative speed/course = invalid.
struct GPSFix: Equatable {
    var t: Double          // Unix seconds
    var lat: Double
    var lon: Double
    var alt: Double        // metres
    var hAcc: Double       // horizontal accuracy, metres
    var speed: Double      // m/s
    var course: Double     // degrees, 0 = north
    var latLon: LatLon { LatLon(lat: lat, lon: lon) }

    var csvLine: String {
        String(format: "%.3f,%.8f,%.8f,%.2f,%.2f,%.3f,%.2f\n", t, lat, lon, alt, hAcc, speed, course)
    }

    init(t: Double, lat: Double, lon: Double, alt: Double, hAcc: Double, speed: Double, course: Double) {
        self.t = t; self.lat = lat; self.lon = lon; self.alt = alt; self.hAcc = hAcc; self.speed = speed; self.course = course
    }

    init?(csvLine line: Substring) {
        let f = line.split(separator: ",").compactMap { Double($0) }
        guard f.count == 7 else { return nil }
        self.init(t: f[0], lat: f[1], lon: f[2], alt: f[3], hAcc: f[4], speed: f[5], course: f[6])
    }
}

/// One CoreMotion device-motion sample, all in the phone's own axes.
struct MotionSample {
    var t: Double        // Unix seconds
    var accel: Vec3      // user acceleration, g (gravity removed)
    var gravity: Vec3    // gravity direction, g
    var rotation: Vec3   // rotation rate, rad/s

    static let byteCount = 8 + 9 * 4

    func append(to data: inout Data) {
        var t = self.t.bitPattern.littleEndian
        withUnsafeBytes(of: &t) { data.append(contentsOf: $0) }
        for v in [accel.x, accel.y, accel.z, gravity.x, gravity.y, gravity.z, rotation.x, rotation.y, rotation.z] {
            var b = Float(v).bitPattern.littleEndian
            withUnsafeBytes(of: &b) { data.append(contentsOf: $0) }
        }
    }

    static func decodeAll(_ data: Data) -> [MotionSample] {
        let n = data.count / byteCount
        var out: [MotionSample] = []
        out.reserveCapacity(n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let base = i * byteCount
                let t = Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: base, as: UInt64.self)))
                var f = [Double](repeating: 0, count: 9)
                for k in 0..<9 {
                    f[k] = Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + 8 + k * 4, as: UInt32.self))))
                }
                out.append(MotionSample(t: t, accel: Vec3(x: f[0], y: f[1], z: f[2]),
                                        gravity: Vec3(x: f[3], y: f[4], z: f[5]),
                                        rotation: Vec3(x: f[6], y: f[7], z: f[8])))
            }
        }
        return out
    }
}

/// Buffered append-only file writer, safe to call from any thread.
final class AppendWriter {
    private let handle: FileHandle
    private let queue: DispatchQueue
    private var buffer = Data()
    private let flushThreshold: Int

    init(url: URL, flushThreshold: Int = 32_768) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        queue = DispatchQueue(label: "writer.\(url.lastPathComponent)")
        self.flushThreshold = flushThreshold
    }

    func append(_ data: Data) {
        queue.async {
            self.buffer.append(data)
            if self.buffer.count >= self.flushThreshold { self.flushLocked() }
        }
    }

    func flush() { queue.sync { flushLocked() } }

    func close() {
        queue.sync {
            flushLocked()
            try? handle.close()
        }
    }

    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        handle.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

enum RawFiles {
    static func readFixes(_ url: URL) -> [GPSFix] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap(GPSFix.init(csvLine:))
    }

    static func readMotion(_ url: URL) -> [MotionSample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return MotionSample.decodeAll(data)
    }
}

import Foundation

/// Live longitudinal and lateral g. The phone sits in the car at an unknown angle, so its horizontal
/// acceleration is fitted against GPS-derived g (the same fit the exporter runs after the session)
/// and, once the two agree, read from the 50 Hz IMU instead of waiting a second for the next fix.
/// Pure value type so it can be unit tested and replayed; the recorder feeds it motion and fixes.
struct LiveG {
    struct Reading: Equatable {
        var long: Double    // g, + = accelerating
        var lat: Double     // g, + = turning right
        var fromIMU: Bool   // false while still on 1 Hz GPS
    }

    /// IMU averaging window for the live reading, seconds.
    static let window = 0.25
    /// Correlation with GPS g an axis needs before we trust the IMU on it.
    static let minR = 0.5
    /// GPS intervals kept for the fit (about ten minutes at 1 Hz), so a phone that shifts recovers.
    static let maxPairs = 600

    private struct Sample { var t: Double; var h: Vec3; var up: Vec3 }
    private struct Pair { var h: Vec3; var up: Vec3; var long: Double; var lat: Double }

    private var buffer: [Sample] = []
    private var pairs: [Pair] = []
    private var lastFix: GPSFix?
    private var fwd: Vec3?
    private var side: Vec3?
    private var gps: (long: Double, lat: Double)?
    private(set) var rLong = 0.0
    private(set) var rLat = 0.0

    var calibrated: Bool { rLong > Self.minR || rLat > Self.minR }

    mutating func reset() { self = LiveG() }

    mutating func add(_ m: MotionSample) {
        let up = (m.gravity * -1).normalized
        buffer.append(Sample(t: m.t, h: m.accel - up * m.accel.dot(up), up: up))
        if let first = buffer.first, m.t - first.t > 3 {
            buffer.removeFirst(buffer.firstIndex { m.t - $0.t <= 3 } ?? 0)
        }
    }

    mutating func add(_ fix: GPSFix) {
        defer { lastFix = fix }
        guard let a = lastFix, let g = Self.gpsG(a, fix) else { return }
        gps = g
        guard a.speed > 5, fix.speed > 5 else { return }
        let inside = buffer.filter { $0.t >= a.t && $0.t < fix.t }
        guard inside.count >= 5 else { return }
        let n = Double(inside.count)
        pairs.append(Pair(h: inside.reduce(Vec3.zero) { $0 + $1.h } * (1 / n),
                          up: inside.reduce(Vec3.zero) { $0 + $1.up } * (1 / n), long: g.long, lat: g.lat))
        if pairs.count > Self.maxPairs { pairs.removeFirst(pairs.count - Self.maxPairs) }
        calibrate()
    }

    /// The best current estimate: IMU on each axis that has calibrated, GPS on the rest.
    var reading: Reading? {
        let recent = buffer.reversed().prefix { (buffer.last?.t ?? 0) - $0.t <= Self.window }
        var long = gps?.long, lat = gps?.lat, fromIMU = false
        if !recent.isEmpty, let fwd, let side {
            let h = recent.reduce(Vec3.zero) { $0 + $1.h } * (1 / Double(recent.count))
            if rLong > Self.minR { long = h.dot(fwd); fromIMU = true }
            if rLat > Self.minR { lat = h.dot(side); fromIMU = true }
        }
        guard let long, let lat else { return nil }
        return Reading(long: long, lat: lat, fromIMU: fromIMU)
    }

    /// g between two consecutive fixes: speed change for longitudinal, speed × yaw rate for lateral.
    static func gpsG(_ a: GPSFix, _ b: GPSFix) -> (long: Double, lat: Double)? {
        let dt = b.t - a.t
        guard dt > 0.2, dt <= 2.5, a.speed >= 0, b.speed >= 0 else { return nil }
        let long = (b.speed - a.speed) / dt / 9.80665
        var lat = 0.0
        if a.course >= 0, b.course >= 0, a.speed > 3, b.speed > 3 {
            let yaw = angleDelta(a.course, b.course) * .pi / 180 / dt
            lat = (a.speed + b.speed) / 2 * yaw / 9.80665
        }
        return (long, lat)
    }

    private mutating func calibrate() {
        guard pairs.count >= 15 else { return }
        var F = Vec3.zero, L = Vec3.zero, U = Vec3.zero
        for p in pairs { F = F + p.h * p.long; L = L + p.h * p.lat; U = U + p.up }
        let upAxis = U.normalized
        let f = (F - upAxis * F.dot(upAxis)).normalized
        var s = upAxis.cross(f).normalized
        if L.dot(s) < 0 { s = s * -1 }
        guard f.length > 0.5, s.length > 0.5 else { return }
        fwd = f; side = s
        rLong = correlation(pairs.map { $0.h.dot(f) }, pairs.map(\.long))
        rLat = correlation(pairs.map { $0.h.dot(s) }, pairs.map(\.lat))
    }
}

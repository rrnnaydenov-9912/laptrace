import Foundation
@testable import LaptraceLogger

/// Synthetic session: a car lapping a circle clockwise at varying speed, with a
/// phone mounted at an arbitrary tilt/yaw. Used to check that the exporter
/// recovers laps and car-frame g-forces from 1 Hz GPS + 50 Hz IMU.
struct SyntheticSession {
    var center = LatLon(lat: 42.3155, lon: 23.5385)
    var radius = 120.0
    var laps = 4
    var t0 = 1_760_000_000.0
    /// Phone orientation: yaw then pitch then roll (degrees), applied car→phone.
    var mount = (yaw: 37.0, pitch: -25.0, roll: 12.0)

    /// Lap speed profile (m/s) as a function of angle around the circle.
    func speed(_ theta: Double) -> Double { 22 + 6 * sin(2 * theta) }

    var track: Track {
        // Start/finish across the circle at its northernmost point; travel is clockwise → east (90°).
        let proj = LocalProjection(origin: center)
        let p = proj.unproject(Vec2(x: 0, y: radius))
        let sf = Gate.perpendicular(id: "sf", label: "Start / Finish", through: p, travelBearing: 90)
        return Track(id: "synthetic", name: "Synthetic ring", country: nil, center: center, radiusMeters: 2000, gates: [sf])
    }

    struct Truth { var t: Double; var long: Double; var lat: Double }

    func generate() -> (fixes: [GPSFix], motion: [MotionSample], truth: [Truth], lapTimes: [Double]) {
        let proj = LocalProjection(origin: center)
        let dt = 0.001
        // Start just before the line (theta measured clockwise from north).
        var theta = -0.4, t = t0, lapTimes: [Double] = [], lastLap: Double? = nil
        var fixes: [GPSFix] = [], motion: [MotionSample] = [], truth: [Truth] = []
        var nextFix = t0, nextMotion = t0
        let R = rotation()
        var prevV = speed(theta)
        let end = 2 * .pi * Double(laps) + 0.6
        var lapCount = 0
        while theta < end {
            let v = speed(theta)
            let long = (v - prevV) / dt / 9.80665
            prevV = v
            let lat = v * v / radius / 9.80665   // clockwise = right turn = positive
            if t >= nextMotion {
                // Car frame: x forward, y right, z up. Phone sees R * (car vector).
                let carAcc = Vec3(x: long, y: lat, z: 0)
                let carGrav = Vec3(x: 0, y: 0, z: -1)
                motion.append(MotionSample(t: t, accel: R(carAcc), gravity: R(carGrav), rotation: .zero))
                truth.append(Truth(t: t, long: long, lat: lat))
                nextMotion += 0.02
            }
            if t >= nextFix {
                let pos = Vec2(x: radius * sin(theta), y: radius * cos(theta))
                let course = normalizeDegrees(theta * 180 / .pi + 90)
                let ll = proj.unproject(pos)
                fixes.append(GPSFix(t: t, lat: ll.lat, lon: ll.lon, alt: 600, hAcc: 4, speed: v, course: course))
                nextFix += 1
            }
            let newTheta = theta + v / radius * dt
            // Lap boundary when crossing theta = 2πk.
            let k = (newTheta / (2 * .pi)).rounded(.down)
            if k > (theta / (2 * .pi)).rounded(.down) {
                if let lastLap { lapTimes.append(t - lastLap) }
                lastLap = t
                lapCount += 1
            }
            theta = newTheta
            t += dt
        }
        return (fixes, motion, truth, lapTimes)
    }

    private func rotation() -> (Vec3) -> Vec3 {
        let (y, p, r) = (mount.yaw * .pi / 180, mount.pitch * .pi / 180, mount.roll * .pi / 180)
        return { v in
            // yaw about z
            var a = Vec3(x: v.x * cos(y) - v.y * sin(y), y: v.x * sin(y) + v.y * cos(y), z: v.z)
            // pitch about y
            a = Vec3(x: a.x * cos(p) + a.z * sin(p), y: a.y, z: -a.x * sin(p) + a.z * cos(p))
            // roll about x
            a = Vec3(x: a.x, y: a.y * cos(r) - a.z * sin(r), z: a.y * sin(r) + a.z * cos(r))
            return a
        }
    }
}

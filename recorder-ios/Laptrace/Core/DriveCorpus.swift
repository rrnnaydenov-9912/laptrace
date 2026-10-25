import Foundation

/// One drive reduced to the numbers we compare across drives.
struct DriveStats: Equatable {
    var id: String
    /// Metres driven after the drive start gate passed.
    var distance: Double
    /// Seconds spent above 2 m/s.
    var movingTime: Double
    /// Mean speed while moving (above 2 m/s), in km/h.
    var avgKmh: Double
    var p95Kmh: Double
    /// 95th percentile of forward acceleration, in g.
    var accelG: Double
    /// 95th percentile of deceleration, in g, as a positive number.
    var brakeG: Double
    /// RMS rate of change of longitudinal g, in g/s. Lower is smoother.
    var jerk: Double
    var harshBrakes: Int
    var harshAccels: Int

    var harshBrakesPer10km: Double { distance > 0 ? Double(harshBrakes) / (distance / 10_000) : 0 }
}

/// Typical values over a set of earlier drives (medians after outliers are dropped).
struct DriveBaseline: Equatable {
    var count: Int
    var brakeG: Double
    var accelG: Double
    var avgKmh: Double
    var harshBrakesPer10km: Double
    /// Jerk of each drive in the baseline, oldest first.
    var recentJerks: [Double]
}

/// Treats every recorded drive as a reference corpus: stats per drive, a baseline over recent drives
/// with outliers dropped, and advice that compares one drive against that baseline.
enum DriveCorpus {
    static let g = 9.80665
    static let minDistance = 500.0
    static let minBaselineDrives = 3
    static let harshBrakeG = 0.35
    static let harshAccelG = 0.30

    /// Stats for one drive from its raw fixes, or nil when it is too short or too sparse to judge.
    /// Bad fixes, gaps and GPS jumps are skipped; nothing counts until the drive start gate passes.
    static func stats(id: String, fixes raw: [GPSFix]) -> DriveStats? {
        var fixes: [GPSFix] = []
        for f in raw.filter({ $0.hAcc > 0 && $0.hAcc <= 30 }).sorted(by: { $0.t < $1.t })
        where fixes.last.map({ f.t > $0.t }) ?? true { fixes.append(f) }

        var gate = DriveStartGate()
        guard let start = fixes.firstIndex(where: { gate.add($0) }) else { return nil }
        let drive = fixes[start...]

        var distance = 0.0, moving = 0.0, movingDist = 0.0
        var speeds: [Double] = []
        var accels: [Double] = []           // g, every usable sample
        var jerks: [Double] = []            // g/s between contiguous accel samples
        var lastAccel: (t: Double, a: Double)?
        var harshB = 0, harshA = 0
        var inBrake = false, inAccel = false
        var prev: GPSFix?, prevV: Double?

        for f in drive {
            defer { prev = f }
            guard let p = prev else { continue }
            let dt = f.t - p.t
            guard dt > 0 else { continue }
            if dt > 5 { prevV = nil; lastAccel = nil; continue }    // gap: don't bridge it
            let step = haversineMeters(p.latLon, f.latLon)
            let v = f.speed >= 0 ? f.speed : step / dt
            guard v < 70, step / dt < 70 else { prevV = nil; lastAccel = nil; continue }   // jump
            distance += step
            speeds.append(v)
            if v > 2 { moving += dt; movingDist += v * dt }
            defer { prevV = v }
            guard let pv = prevV, dt <= 2, max(v, pv) > 2 else { lastAccel = nil; continue }
            let a = (v - pv) / dt / g
            guard abs(a) <= 1.2 else { lastAccel = nil; continue }
            accels.append(a)
            if let la = lastAccel { jerks.append((a - la.a) / (f.t - la.t)) }
            lastAccel = (f.t, a)
            if a < -harshBrakeG { if !inBrake { harshB += 1 }; inBrake = true } else if a > -harshBrakeG / 2 { inBrake = false }
            if a > harshAccelG { if !inAccel { harshA += 1 }; inAccel = true } else if a < harshAccelG / 2 { inAccel = false }
        }

        guard distance >= minDistance, accels.count >= 30, moving > 0 else { return nil }
        let rms = jerks.isEmpty ? 0 : (jerks.map { $0 * $0 }.reduce(0, +) / Double(jerks.count)).squareRoot()
        return DriveStats(id: id, distance: distance, movingTime: moving,
                          avgKmh: movingDist / moving * 3.6,
                          p95Kmh: percentile(speeds, 0.95) * 3.6,
                          accelG: percentile(accels.filter { $0 > 0 }, 0.95),
                          brakeG: percentile(accels.filter { $0 < 0 }.map { -$0 }, 0.95),
                          jerk: rms, harshBrakes: harshB, harshAccels: harshA)
    }

    /// The drives a baseline is built from: the last `n` in `history` (oldest first) with at least a
    /// minute of moving time, minus outliers (over 3 scaled MADs from the median on braking,
    /// acceleration or average speed).
    static func baselineDrives(from history: [DriveStats], last n: Int = 10) -> [DriveStats] {
        var recent = Array(history.filter { $0.movingTime >= 60 }.suffix(n))
        for key in [\DriveStats.brakeG, \.accelG, \.avgKmh] {
            let values = recent.map { $0[keyPath: key] }
            let med = median(values)
            let mad = median(values.map { abs($0 - med) }) * 1.4826
            if mad > 0 { recent.removeAll { abs($0[keyPath: key] - med) > 3 * mad } }
        }
        return recent
    }

    /// Baseline over `baselineDrives`. Nil with fewer than 3 drives left.
    static func baseline(from history: [DriveStats], last n: Int = 10) -> DriveBaseline? {
        let recent = baselineDrives(from: history, last: n)
        guard recent.count >= minBaselineDrives else { return nil }
        return DriveBaseline(count: recent.count,
                             brakeG: median(recent.map(\.brakeG)),
                             accelG: median(recent.map(\.accelG)),
                             avgKmh: median(recent.map(\.avgKmh)),
                             harshBrakesPer10km: median(recent.map(\.harshBrakesPer10km)),
                             recentJerks: recent.map(\.jerk))
    }

    /// Plain-language comparisons of `drive` against the baseline built from `history`.
    static func insights(for drive: DriveStats, history: [DriveStats]) -> [String] {
        guard let b = baseline(from: history) else {
            let n = baselineDrives(from: history).count
            return ["Not enough drives yet for a baseline (\(n) of \(minBaselineDrives))"]
        }
        var out = [compare("Braking", drive.brakeG, b.brakeG), compare("Acceleration", drive.accelG, b.accelG)]

        let smootherThan = b.recentJerks.filter { drive.jerk < $0 }.count
        let n = b.recentJerks.count
        out.append(smootherThan == n ? "Smoother than all of your last \(n) drives"
                   : smootherThan == 0 ? "Less smooth than all of your last \(n) drives"
                   : "Smoother than \(smootherThan) of your last \(n) drives")

        out.append(String(format: "Average %.0f km/h vs your usual %.0f km/h", drive.avgKmh, b.avgKmh))
        if drive.harshBrakes == 0 && b.harshBrakesPer10km == 0 {
            out.append(String(format: "No harsh braking (over %.2f g), in line with your usual", harshBrakeG))
        } else {
            out.append(String(format: "%.1f harsh brakes per 10 km vs your usual %.1f",
                              drive.harshBrakesPer10km, b.harshBrakesPer10km))
        }
        return out
    }

    private static func compare(_ what: String, _ value: Double, _ usual: Double) -> String {
        let diff = value - usual
        guard abs(diff) >= max(0.02, 0.1 * usual) else { return String(format: "%@ in line with your usual (%.2f g)", what, usual) }
        return String(format: "%@ %.2f g %@ than your usual (%.2f g)", what, abs(diff), diff > 0 ? "harder" : "softer", usual)
    }

    static func median(_ xs: [Double]) -> Double { percentile(xs, 0.5) }

    /// Linear-interpolated percentile; 0 for an empty array.
    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let pos = p * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }
}

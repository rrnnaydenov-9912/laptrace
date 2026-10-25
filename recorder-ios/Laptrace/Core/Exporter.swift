import Foundation

/// Turns a raw recording (≈1 Hz GPS + ≈50 Hz motion) into the shared CSV
/// contract (see shared/CSV-FORMAT.md):
/// - positions on a fixed-rate grid, Hermite-interpolated between fixes using
///   the GPS velocity, so curves stay curved;
/// - g-forces rotated into the car's axes by learning the phone mount from the
///   session itself (correlating motion with GPS speed and heading changes);
/// - lap labels from start/finish crossings on the interpolated path.
struct Exporter {
    struct Options {
        var rateHz: Double = 10
        var maxAccuracy: Double = 30      // drop fixes worse than this (m)
        var maxGap: Double = 3            // no rows inside GPS gaps longer than this (s)
        var gWindow: Double = 0.15        // ± seconds averaged per g-force row
        var device: String = "iPhone"
        var extraMeta: [(key: String, value: String)] = []   // optional Driver / Vehicle / Notes / Video Start UTC
        var obdSource: String?            // the OBD reader, when car data was recorded
    }

    /// A car-data column: CSV header, where it lives on a sample, and how far apart two readings
    /// may be and still be blended (fast channels) or held (slowly polled temperatures).
    struct OBDColumn {
        let header: String
        let key: KeyPath<OBDSample, Double?>
        let maxGap: Double
        let hold: Double
        let decimals: Int
    }

    static let obdColumns: [OBDColumn] = [
        OBDColumn(header: "RPM", key: \.rpm, maxGap: 1.5, hold: 0.5, decimals: 0),
        OBDColumn(header: "Throttle (%)", key: \.throttle, maxGap: 1.5, hold: 0.5, decimals: 1),
        OBDColumn(header: "Pedal (%)", key: \.pedal, maxGap: 1.5, hold: 0.5, decimals: 1),
        OBDColumn(header: "Engine Load (%)", key: \.load, maxGap: 1.5, hold: 0.5, decimals: 1),
        OBDColumn(header: "OBD Speed (km/h)", key: \.speed, maxGap: 1.5, hold: 0.5, decimals: 0),
        OBDColumn(header: "Coolant (°C)", key: \.coolant, maxGap: 20, hold: 15, decimals: 0),
        OBDColumn(header: "Oil (°C)", key: \.oil, maxGap: 20, hold: 15, decimals: 0),
        OBDColumn(header: "Intake (°C)", key: \.intake, maxGap: 20, hold: 15, decimals: 0),
    ]

    struct Calibration {
        var calibrated: Bool
        var intervals: Int
        var longitudinalCorrelation: Double
        var lateralCorrelation: Double
        var source: String {
            calibrated
                ? String(format: "Phone IMU auto-aligned (r long %.2f / lat %.2f)", longitudinalCorrelation, lateralCorrelation)
                : "Derived from GPS speed and heading"
        }
    }

    struct Summary {
        var rows: Int
        var duration: Double
        var laps: [CompletedLap]
        var calibration: Calibration
        var track: Track?
        var best: CompletedLap? { laps.min(by: { $0.duration < $1.duration }) }
    }

    struct Row {
        var t: Double
        var p: LatLon
        var alt: Double
        var speed: Double     // m/s
        var heading: Double
        var long: Double
        var lat: Double
        var vert: Double?
        var acc: Double
        var fix: Bool
        var lap: Int = 0
        var obd: [Double?] = []   // one entry per used OBD column
    }

    var options = Options()

    // MARK: - Public

    func export(fixes rawFixes: [GPSFix], motion: [MotionSample], track: Track?, obd: [OBDSample] = []) -> (csv: String, summary: Summary)? {
        let fixes = clean(rawFixes)
        guard fixes.count >= 2 else { return nil }
        let proj = LocalProjection(origin: fixes[0].latLon)
        var rows = interpolate(fixes, proj: proj)
        guard rows.count >= 2 else { return nil }
        let cal = applyGForces(&rows, fixes: fixes, motion: motion)
        let laps = labelLaps(&rows, track: track)
        let columns = applyOBD(&rows, obd)
        let summary = Summary(rows: rows.count, duration: rows.last!.t - rows.first!.t, laps: laps, calibration: cal, track: track)
        return (render(rows, summary: summary, obdColumns: columns), summary)
    }

    /// Interpolated laps (local metres) for the debrief; no g-force work.
    func coachLaps(fixes rawFixes: [GPSFix], track: Track?) -> [Coach.Lap] {
        let fixes = clean(rawFixes)
        guard fixes.count >= 2 else { return [] }
        let proj = LocalProjection(origin: fixes[0].latLon)
        var rows = interpolate(fixes, proj: proj)
        let laps = labelLaps(&rows, track: track)
        let groups = Dictionary(grouping: rows.filter { $0.lap > 0 }, by: \.lap)
        return groups.keys.sorted().compactMap { n in
            guard let r = groups[n], r.count >= 2 else { return nil }
            let pts = r.map { proj.project($0.p) }
            let duration = n <= laps.count ? laps[n - 1].duration : r.last!.t - r.first!.t
            return Coach.Lap(number: n, duration: duration, t: r.map(\.t), x: pts.map(\.x), y: pts.map(\.y), speed: r.map(\.speed))
        }
    }

    /// One lap's 10 Hz channels for the telemetry overlay and the GG diagram (studio-web LapData).
    struct LapChannels {
        var number: Int
        var duration: Double
        var s: [Double]        // metres from the start line
        var speed: [Double]    // m/s
        var long: [Double]     // g, + = accelerating
        var lat: [Double]      // g, + = turning right
        var pedal: [Double?]   // %, accelerator pedal, else throttle plate; nil without car data
        var t: [Double] = []
        var rpm: [Double?] = []
        var coolant: [Double?] = []
        var oil: [Double?] = []
        var intake: [Double?] = []
    }

    /// Laps with g-forces (phone IMU when it calibrates, else GPS) and the car's pedal.
    func lapChannels(fixes rawFixes: [GPSFix], motion: [MotionSample], obd: [OBDSample], track: Track?) -> (laps: [LapChannels], imu: Bool) {
        let fixes = clean(rawFixes)
        guard fixes.count >= 2 else { return ([], false) }
        let proj = LocalProjection(origin: fixes[0].latLon)
        var rows = interpolate(fixes, proj: proj)
        let cal = applyGForces(&rows, fixes: fixes, motion: motion)
        let laps = labelLaps(&rows, track: track)
        let columns = applyOBD(&rows, obd)
        func col(_ header: String) -> Int? { columns.firstIndex { $0.header == header } }
        let pedalCol = col("Pedal (%)"), throttleCol = col("Throttle (%)")
        let rpmCol = col("RPM"), coolantCol = col("Coolant (°C)"), oilCol = col("Oil (°C)"), intakeCol = col("Intake (°C)")
        func values(_ r: [Row], _ c: Int?) -> [Double?] { r.map { row in c.flatMap { row.obd[$0] } } }
        let groups = Dictionary(grouping: rows.filter { $0.lap > 0 }, by: \.lap)
        let out = groups.keys.sorted().compactMap { n -> LapChannels? in
            guard let r = groups[n], r.count >= 2 else { return nil }
            let pts = r.map { proj.project($0.p) }
            var s = [0.0]
            for i in 1..<pts.count { s.append(s[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
            let pedal = r.map { row in (pedalCol.flatMap { row.obd[$0] }) ?? throttleCol.flatMap { row.obd[$0] } }
            let duration = n <= laps.count ? laps[n - 1].duration : r.last!.t - r.first!.t
            return LapChannels(number: n, duration: duration, s: s, speed: r.map(\.speed),
                               long: r.map(\.long), lat: r.map(\.lat), pedal: pedal, t: r.map(\.t),
                               rpm: values(r, rpmCol), coolant: values(r, coolantCol), oil: values(r, oilCol),
                               intake: values(r, intakeCol))
        }
        return (out, cal.calibrated)
    }

    // MARK: - Fix cleaning

    func clean(_ input: [GPSFix]) -> [GPSFix] {
        var out: [GPSFix] = []
        for f in input.sorted(by: { $0.t < $1.t }) {
            guard f.hAcc > 0, f.hAcc <= options.maxAccuracy,
                  abs(f.lat) <= 90, abs(f.lon) <= 180, !(f.lat == 0 && f.lon == 0) else { continue }
            if let prev = out.last {
                let dt = f.t - prev.t
                guard dt > 0.05 else { continue }
                // Reject teleports: faster than 120 m/s between fixes.
                if haversineMeters(prev.latLon, f.latLon) / dt > 120 { continue }
            }
            out.append(f)
        }
        return out
    }

    // MARK: - Path interpolation

    private func velocity(_ fixes: [GPSFix], _ pos: [Vec2], _ i: Int) -> Vec2 {
        let f = fixes[i]
        if f.speed >= 0, f.course >= 0, f.speed > 1 { return Vec2.fromBearing(f.course) * f.speed }
        let a = max(0, i - 1), b = min(fixes.count - 1, i + 1)
        let dt = fixes[b].t - fixes[a].t
        return dt > 0 ? (pos[b] - pos[a]) * (1 / dt) : Vec2(x: 0, y: 0)
    }

    func interpolate(_ fixes: [GPSFix], proj: LocalProjection) -> [Row] {
        let pos = fixes.map { proj.project($0.latLon) }
        let vel = fixes.indices.map { velocity(fixes, pos, $0) }
        let step = 1 / options.rateHz
        var t = (fixes[0].t * options.rateHz).rounded(.up) / options.rateHz
        var i = 0
        var rows: [Row] = []
        rows.reserveCapacity(Int((fixes.last!.t - t) * options.rateHz) + 1)
        var lastHeading = fixes[0].course >= 0 ? fixes[0].course : 0
        while t <= fixes.last!.t + 1e-9 {
            while i + 1 < fixes.count - 1 && fixes[i + 1].t <= t { i += 1 }
            let a = fixes[i], b = fixes[min(i + 1, fixes.count - 1)]
            let dt = b.t - a.t
            let nearA = abs(t - a.t) < step / 2, nearB = abs(t - b.t) < step / 2
            if dt > options.maxGap && !nearA && !nearB {
                t = ((t + step) * options.rateHz).rounded() / options.rateHz
                continue
            }
            let s = dt > 0 ? min(max((t - a.t) / dt, 0), 1) : 0
            let s2 = s * s, s3 = s2 * s
            let p0 = pos[i], p1 = pos[min(i + 1, pos.count - 1)]
            let v0 = vel[i] * dt, v1 = vel[min(i + 1, vel.count - 1)] * dt
            let p = p0 * (2 * s3 - 3 * s2 + 1) + v0 * (s3 - 2 * s2 + s) + p1 * (-2 * s3 + 3 * s2) + v1 * (s3 - s2)
            var dp = Vec2(x: 0, y: 0)
            if dt > 0 {
                dp = (p0 * (6 * s2 - 6 * s) + v0 * (3 * s2 - 4 * s + 1) + p1 * (-6 * s2 + 6 * s) + v1 * (3 * s2 - 2 * s)) * (1 / dt)
            }
            let speed: Double = (a.speed >= 0 && b.speed >= 0) ? a.speed + (b.speed - a.speed) * s : dp.length
            if dp.length > 0.5 { lastHeading = dp.bearing }
            rows.append(Row(t: t, p: proj.unproject(p), alt: a.alt + (b.alt - a.alt) * s,
                            speed: max(0, speed), heading: lastHeading, long: 0, lat: 0, vert: nil,
                            acc: nearB ? b.hAcc : a.hAcc + (b.hAcc - a.hAcc) * s, fix: nearA || nearB))
            t = ((t + step) * options.rateHz).rounded() / options.rateHz
        }
        return rows
    }

    // MARK: - G-forces

    /// GPS-only estimate per fix interval: (mid time, long g, lat g).
    private func gpsAccelerations(_ fixes: [GPSFix]) -> [(t: Double, long: Double, lat: Double, dt: Double, a: GPSFix, b: GPSFix)] {
        var out: [(Double, Double, Double, Double, GPSFix, GPSFix)] = []
        for j in 0..<(fixes.count - 1) {
            let a = fixes[j], b = fixes[j + 1], dt = b.t - a.t
            guard dt > 0.2, dt <= 2.5, a.speed >= 0, b.speed >= 0 else { continue }
            let long = (b.speed - a.speed) / dt / 9.80665
            var lat = 0.0
            if a.course >= 0, b.course >= 0, a.speed > 3, b.speed > 3 {
                let yaw = angleDelta(a.course, b.course) * .pi / 180 / dt   // + = turning right
                lat = (a.speed + b.speed) / 2 * yaw / 9.80665
            }
            out.append(((a.t + b.t) / 2, long, lat, dt, a, b))
        }
        return out.map { (t: $0.0, long: $0.1, lat: $0.2, dt: $0.3, a: $0.4, b: $0.5) }
    }

    func applyGForces(_ rows: inout [Row], fixes: [GPSFix], motion: [MotionSample]) -> Calibration {
        let gps = gpsAccelerations(fixes)
        // GPS fallback, linearly interpolated at row times.
        var k = 0
        for r in rows.indices {
            guard !gps.isEmpty else { break }
            while k + 1 < gps.count && gps[k + 1].t <= rows[r].t { k += 1 }
            let a = gps[k], b = gps[min(k + 1, gps.count - 1)]
            let s = b.t > a.t ? min(max((rows[r].t - a.t) / (b.t - a.t), 0), 1) : 0
            rows[r].long = a.long + (b.long - a.long) * s
            rows[r].lat = a.lat + (b.lat - a.lat) * s
        }

        let ms = motion.sorted { $0.t < $1.t }
        guard ms.count > 100 else {
            return Calibration(calibrated: false, intervals: 0, longitudinalCorrelation: 0, lateralCorrelation: 0)
        }
        // Horizontal (gravity-removed, gravity-orthogonal) acceleration per sample.
        let up = ms.map { ($0.gravity * -1).normalized }
        let horiz = ms.indices.map { i -> Vec3 in let a = ms[i].accel; return a - up[i] * a.dot(up[i]) }
        let vert = ms.indices.map { ms[$0].accel.dot(up[$0]) }
        let times = ms.map(\.t)

        func range(_ t0: Double, _ t1: Double) -> Range<Int> {
            lowerBound(times, t0)..<lowerBound(times, t1)
        }

        // Learn forward and lateral axes in the phone frame.
        var F = Vec3.zero, L = Vec3.zero, U = Vec3.zero
        var samples: [(h: Vec3, long: Double, lat: Double)] = []
        for g in gps where g.a.speed > 5 && g.b.speed > 5 {
            let r = range(g.a.t, g.b.t)
            guard r.count >= 5 else { continue }
            var h = Vec3.zero, u = Vec3.zero
            for i in r { h = h + horiz[i]; u = u + up[i] }
            h = h * (1 / Double(r.count))
            F = F + h * g.long
            L = L + h * g.lat
            U = U + u
            samples.append((h, g.long, g.lat))
        }
        guard samples.count >= 15 else {
            return Calibration(calibrated: false, intervals: samples.count, longitudinalCorrelation: 0, lateralCorrelation: 0)
        }
        let upAxis = U.normalized
        let fwd = (F - upAxis * F.dot(upAxis)).normalized
        var side = upAxis.cross(fwd).normalized
        if L.dot(side) < 0 { side = side * -1 }

        let rLong = correlation(samples.map { $0.h.dot(fwd) }, samples.map(\.long))
        let rLat = correlation(samples.map { $0.h.dot(side) }, samples.map(\.lat))
        // Require the learned axes to actually explain the GPS signal.
        guard rLong > 0.5 || rLat > 0.5 else {
            return Calibration(calibrated: false, intervals: samples.count, longitudinalCorrelation: rLong, lateralCorrelation: rLat)
        }

        for r in rows.indices {
            let rr = range(rows[r].t - options.gWindow, rows[r].t + options.gWindow)
            guard rr.count >= 2 else { continue }   // keep GPS fallback
            var h = Vec3.zero, v = 0.0
            for i in rr { h = h + horiz[i]; v += vert[i] }
            let n = Double(rr.count)
            h = h * (1 / n)
            if rLong > 0.5 { rows[r].long = h.dot(fwd) }
            if rLat > 0.5 { rows[r].lat = h.dot(side) }
            rows[r].vert = 1 + v / n
        }
        return Calibration(calibrated: true, intervals: samples.count, longitudinalCorrelation: rLong, lateralCorrelation: rLat)
    }

    // MARK: - Laps

    func labelLaps(_ rows: inout [Row], track: Track?) -> [CompletedLap] {
        guard let track, track.startFinish != nil else { return [] }
        let timer = LapTimer()
        timer.setTrack(track)
        var boundaries: [Int] = []
        for (idx, r) in rows.enumerated() {
            for e in timer.ingest(TimedPoint(t: r.t, p: r.p)) {
                if case .lapStarted = e { boundaries.append(idx) }
            }
        }
        guard boundaries.count >= 2 else { return [] }
        for (n, start) in boundaries.dropLast().enumerated() {
            for idx in start..<boundaries[n + 1] { rows[idx].lap = n + 1 }
        }
        return timer.laps
    }

    // MARK: - Car data

    /// Puts car readings on the row grid. Returns the columns that got at least one value; each
    /// row's `obd` then lines up with them. Cells with no reading close enough stay nil.
    func applyOBD(_ rows: inout [Row], _ samples: [OBDSample]) -> [OBDColumn] {
        let sorted = samples.sorted { $0.t < $1.t }
        var used: [OBDColumn] = []
        var values: [[Double?]] = []
        for col in Self.obdColumns {
            let pts = sorted.compactMap { s in s[keyPath: col.key].map { (t: s.t, v: $0) } }
            guard !pts.isEmpty else { continue }
            let ts = pts.map(\.t)
            let column = rows.map { Self.sample(pts, ts, at: $0.t, maxGap: col.maxGap, hold: col.hold) }
            guard column.contains(where: { $0 != nil }) else { continue }
            used.append(col)
            values.append(column)
        }
        for i in rows.indices { rows[i].obd = values.map { $0[i] } }
        return used
    }

    /// Linear blend between the readings either side of `t` when they are close enough together,
    /// else the nearest reading if it is within `hold` seconds.
    static func sample(_ pts: [(t: Double, v: Double)], _ ts: [Double], at t: Double, maxGap: Double, hold: Double) -> Double? {
        let j = lowerBound(ts, t)
        let next = j < pts.count ? pts[j] : nil
        let prev = j > 0 ? pts[j - 1] : nil
        if let a = prev, let b = next, b.t - a.t <= maxGap {
            let span = b.t - a.t
            return span > 0 ? a.v + (b.v - a.v) * (t - a.t) / span : b.v
        }
        let near = [prev, next].compactMap { $0 }.min { abs($0.t - t) < abs($1.t - t) }
        if let near, abs(near.t - t) <= hold { return near.v }
        return nil
    }

    // MARK: - CSV

    func render(_ rows: [Row], summary: Summary, obdColumns: [OBDColumn] = []) -> String {
        let hasLaps = !summary.laps.isEmpty
        let hasVert = rows.contains { $0.vert != nil }
        let iso = ISO8601DateFormatter()
        func meta(_ k: String, _ v: String) -> String { "\(k),\(v.replacingOccurrences(of: ",", with: " "))\n" }
        var s = ""
        s.reserveCapacity(rows.count * 110 + 512)
        s += meta("Format", "Laptrace Logger CSV")
        s += meta("Date UTC", iso.string(from: Date(timeIntervalSince1970: rows[0].t)))
        s += meta("Track", summary.track?.name ?? "Unknown")
        s += meta("Device", options.device)
        s += meta("GPS Source", "Phone GPS ~1 Hz interpolated to \(Int(options.rateHz)) Hz")
        s += meta("G-Force Source", summary.calibration.source)
        s += meta("Lateral Sign", "positive = right turn")
        if !obdColumns.isEmpty { s += meta("OBD Source", options.obdSource ?? "OBD reader") }
        if let best = summary.best { s += meta("Best Lap", String(format: "Lap %d %.3f s", best.number, best.duration)) }
        for (k, v) in options.extraMeta where !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s += "\(k),\(Exporter.quoted(v))\n"
        }
        s += "\n"
        var header = ["Time"]
        if hasLaps { header.append("Lap") }
        header += ["Latitude", "Longitude", "Altitude (m)", "Speed (km/h)", "Heading (deg)", "Longitudinal (g)", "Lateral (g)"]
        if hasVert { header.append("Vertical (g)") }
        header += ["GPS Accuracy (m)", "GPS Fix"]
        header += obdColumns.map(\.header)
        s += header.joined(separator: ",") + "\n"
        for r in rows {
            var line = fmt(r.t, 2)
            if hasLaps { line += ",\(r.lap)" }
            line += "," + fmt(r.p.lat, 7) + "," + fmt(r.p.lon, 7) + "," + fmt(r.alt, 1) + "," + fmt(r.speed * 3.6, 2)
            line += "," + fmt(r.heading, 1) + "," + fmt(r.long, 3) + "," + fmt(r.lat, 3)
            if hasVert { line += "," + fmt(r.vert ?? 1, 3) }
            line += "," + fmt(r.acc, 1) + "," + (r.fix ? "1" : "0")
            for (k, col) in obdColumns.enumerated() {
                line += "," + (k < r.obd.count ? r.obd[k].map { fmt($0, col.decimals) } ?? "" : "")
            }
            line += "\n"
            s += line
        }
        return s
    }
}

extension Exporter {
    /// A metadata value as one quoted CSV field: inner quotes doubled, line breaks folded to spaces.
    static func quoted(_ v: String) -> String {
        let oneLine = v.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return "\"" + oneLine.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

// MARK: - Helpers

func fmt(_ v: Double, _ decimals: Int) -> String {
    String(format: "%.\(decimals)f", v.isFinite ? v : 0)
}

func lowerBound(_ a: [Double], _ x: Double) -> Int {
    var lo = 0, hi = a.count
    while lo < hi { let m = (lo + hi) / 2; if a[m] < x { lo = m + 1 } else { hi = m } }
    return lo
}

func correlation(_ x: [Double], _ y: [Double]) -> Double {
    let n = Double(x.count)
    guard n > 2 else { return 0 }
    let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
    var sxy = 0.0, sxx = 0.0, syy = 0.0
    for i in x.indices {
        let dx = x[i] - mx, dy = y[i] - my
        sxy += dx * dy; sxx += dx * dx; syy += dy * dy
    }
    return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
}

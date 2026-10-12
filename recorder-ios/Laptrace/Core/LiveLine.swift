import Foundation

/// Live comparison of the lap in progress with the best lap so far: the two lines for the map,
/// speed against the best lap at the same spot, and a coaching cue for the next corner.
/// Pure value type so it can be unit tested; the recorder feeds it fixes and lap events.
struct LiveLine {
    enum Pedal: Equatable { case throttle, brake, coast }

    struct Point: Equatable {
        var t: Double
        var x: Double
        var y: Double
        var v: Double        // m/s
        var pedal: Pedal
    }

    struct CornerRef: Equatable {
        var number: Int
        var start: Double    // metres from the line, on the best lap
        var end: Double
        var x: Double        // apex, for the map label
        var y: Double
        var best: Coach.Measure
        var last: Coach.Measure?
    }

    struct Now: Equatable {
        var s: Double            // metres into the best lap
        var bestKmh: Double      // best lap's speed at this spot
        var deltaKmh: Double     // now minus best
        var deltaSeconds: Double? = nil   // elapsed this lap minus best lap's elapsed at the same spot (+ = slower)
        var predicted: Double? = nil      // best lap time + running delta
    }

    struct BrakeMarker: Equatable { var corner: Int; var s: Double; var x: Double; var y: Double }

    /// Longitudinal deceleration (g) beyond which we call it braking.
    static let brakeG = 0.15
    /// Throttle / pedal (%) above which we call it accelerating.
    static let throttleOn = 5.0

    private(set) var proj: LocalProjection?
    private(set) var current: [Point] = []
    private(set) var best: [Point] = []
    private(set) var corners: [CornerRef] = []
    private(set) var now: Now?
    private(set) var accelG: Double = 0

    private(set) var bestDuration: Double?
    /// Brake markers from the best lap, for the map.
    private(set) var brakeMarkers: [BrakeMarker] = []

    private var bestGrid: Coach.Grid?
    private var lastS: Double?
    private var lapStartT: Double?
    private var bestStartT: Double?   // the best lap's own line-crossing time, on its grid's clock
    private var lastT: Double?
    private var warned: Set<Int> = []
    private var pendingAlert: Int?

    /// Metres before the best lap's brake point at which to warn the driver.
    static let brakeLead = 50.0

    mutating func reset() { self = LiveLine() }

    /// One GPS fix. `pedal` is the OBD accelerator (or throttle) reading in %, when connected.
    mutating func add(_ fix: GPSFix, pedal: Double?) {
        if proj == nil { proj = LocalProjection(origin: fix.latLon) }
        guard let proj, fix.speed >= 0 else { return }
        let p = proj.project(fix.latLon)
        if let prev = current.last, fix.t > prev.t {
            let a = (fix.speed - prev.v) / (fix.t - prev.t) / 9.81
            accelG = accelG * 0.6 + a * 0.4
        }
        current.append(Point(t: fix.t, x: p.x, y: p.y, v: fix.speed, pedal: Self.pedal(accelG: accelG, pedal: pedal)))
        if current.count > 6_000 { current.removeFirst(1_000) }   // out-lap safety net
        lastT = fix.t
        let prevS = lastS
        now = locate(p, speed: fix.speed, t: fix.t)
        if let s = now?.s, let prevS, s >= prevS {
            for m in brakeMarkers where !warned.contains(m.corner) {
                let at = m.s - Self.brakeLead
                if prevS < at && s >= at { warned.insert(m.corner); pendingAlert = m.corner }
            }
        }
    }

    /// The corner whose brake warning point we just passed, once per corner per lap.
    mutating func takeBrakeAlert() -> Int? {
        defer { pendingAlert = nil }
        return pendingAlert
    }

    /// Where the best lap was at this point of the current lap, for the ghost dot on the map.
    var ghost: Vec2? {
        guard let g = bestGrid, let t0 = lapStartT, let t = lastT, let b0 = bestStartT,
              let first = g.t.first, let end = g.t.last else { return nil }
        let e = t - t0 + b0
        guard e >= first, e <= end else { return nil }
        let i = min(max(lowerBound(g.t, e), 1), g.t.count - 1)
        let f = min(max((e - g.t[i - 1]) / max(g.t[i] - g.t[i - 1], 1e-9), 0), 1)
        return Vec2(x: g.x[i - 1] + (g.x[i] - g.x[i - 1]) * f, y: g.y[i - 1] + (g.y[i] - g.y[i - 1]) * f)
    }

    static func pedal(accelG: Double, pedal: Double?) -> Pedal {
        if let pedal, pedal > throttleOn { return .throttle }
        if accelG < -brakeG { return .brake }
        if pedal == nil && accelG > 0.05 { return .throttle }
        return .coast
    }

    /// `at` is the interpolated line-crossing time from the lap timer, when known.
    mutating func lapStarted(at t: Double? = nil) {
        current = current.suffix(1)
        lapStartT = t ?? current.last?.t
        lastS = bestGrid == nil ? nil : 0   // just crossed the line: search the start of the lap first
        warned = []
        pendingAlert = nil
    }

    /// Call when a lap finishes, before `lapStarted` for the next one.
    mutating func lapCompleted(number: Int, duration: Double, isBest: Bool) {
        guard current.count > 20 else { return }
        let lap = Coach.Lap(number: number, duration: duration, t: current.map(\.t), x: current.map(\.x),
                            y: current.map(\.y), speed: current.map(\.v))
        if isBest || bestGrid == nil {
            best = current
            bestDuration = duration
            let g = Coach.resample(lap)
            bestStartT = min(lapStartT ?? g.t.first ?? 0, g.t.first ?? 0)
            setBest(g)
        } else if let ref = bestGrid, let length = ref.s.last {
            let g = Coach.aligned(Coach.resample(lap), to: length)
            let zones = Coach.cornerZones(corners.map { Coach.Corner(start: $0.start, end: $0.end, angle: 0) }, length: length)
            for i in corners.indices {
                let c = Coach.Corner(start: corners[i].start, end: corners[i].end, angle: 0)
                corners[i].last = Coach.measure(g, corner: c, zone: zones[i])
            }
        }
    }

    private mutating func setBest(_ g: Coach.Grid) {
        bestGrid = g
        let found = Coach.detectCorners(g)
        let zones = Coach.cornerZones(found, length: g.s.last ?? 0)
        corners = found.enumerated().map { i, c in
            let m = Coach.measure(g, corner: c, zone: zones[i])
            let k = min(max(lowerBound(g.s, m.minAt), 0), g.s.count - 1)
            return CornerRef(number: i + 1, start: c.start, end: c.end, x: g.x[k], y: g.y[k], best: m, last: nil)
        }
        brakeMarkers = corners.compactMap { c in
            guard let b = c.best.brake else { return nil }
            let k = min(max(lowerBound(g.s, b), 0), g.s.count - 1)
            return BrakeMarker(corner: c.number, s: b, x: g.x[k], y: g.y[k])
        }
    }

    /// Where we are on the best lap. Searches near the last match so close-together sections of
    /// track (a hairpin's two legs) don't get confused.
    private mutating func locate(_ p: Vec2, speed: Double, t: Double) -> Now? {
        guard let g = bestGrid, !g.s.isEmpty else { return nil }
        var lo = 0, hi = g.s.count - 1
        if let s = lastS {
            lo = max(0, lowerBound(g.s, s - 30)); hi = min(g.s.count - 1, lowerBound(g.s, s + 150))
        }
        var k = lo, d = Double.infinity
        for i in lo...hi {
            let dd = hypot(g.x[i] - p.x, g.y[i] - p.y)
            if dd < d { d = dd; k = i }
        }
        guard d < 40 else { lastS = nil; return nil }   // off the reference line (pit lane, spin)
        lastS = g.s[k]
        var now = Now(s: g.s[k], bestKmh: g.v[k] * 3.6, deltaKmh: (speed - g.v[k]) * 3.6)
        // Past the end of the best lap's grid means we just crossed the line and the lap hasn't reset yet.
        if let t0 = lapStartT, let b0 = bestStartT, t >= t0, k < g.s.count - 1 {
            let delta = (t - t0) - (g.t[k] - b0)
            now.deltaSeconds = delta
            if let bestDuration { now.predicted = bestDuration + delta }
        }
        return now
    }

    /// The corner ahead (or the one we're in) and how far away its turn-in is.
    var nextCorner: (corner: CornerRef, metres: Double)? {
        guard let s = now?.s, let length = bestGrid?.s.last else { return nil }
        if let c = corners.first(where: { s <= $0.end }) { return (c, max(0, c.start - s)) }
        if let c = corners.first { return (c, length - s + c.start) }   // wraps past the line
        return nil
    }

    /// One short instruction for the next corner, from the best lap and how the last lap compared.
    var cue: String? {
        guard let (c, metres) = nextCorner, metres < 300 else { return nil }
        let b = c.best
        let minKmh = Int((b.min * 3.6).rounded())
        if let l = c.last {
            if let bb = b.brake, let lb = l.brake, bb - lb > 5 {
                return "T\(c.number): brake \(Int((bb - lb).rounded())) m later, like your best"
            }
            let lost = (b.min - l.min) * 3.6
            if lost > 2 { return "T\(c.number): carry \(minKmh) km/h at the apex (last \(Int((l.min * 3.6).rounded())))" }
            let exitLost = (b.exit - l.exit) * 3.6
            if exitLost > 2 { return "T\(c.number): throttle earlier, exit at \(Int((b.exit * 3.6).rounded())) km/h" }
            return "T\(c.number): repeat it, min \(minKmh) km/h"
        }
        if let bb = b.brake { return "T\(c.number): brake \(Int(max(0, c.start - bb).rounded())) m before turn-in, min \(minKmh) km/h" }
        return "T\(c.number): min \(minKmh) km/h"
    }
}

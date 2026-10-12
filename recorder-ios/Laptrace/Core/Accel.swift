import Foundation

/// One GPS reading for acceleration timing. `obdKmh` is the car's own speed when a reader is connected.
struct AccelSample: Equatable {
    var t: Double
    var v: Double           // m/s
    var alt: Double         // metres
    var hAcc: Double        // metres
    var vAcc: Double = -1   // metres; negative when the phone has no altitude
    var obdKmh: Double? = nil
}

/// A finished timed run, e.g. 0–100 km/h.
struct AccelRun: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case zeroTo60mph = "0–60 mph"
        case zeroTo100 = "0–100 km/h"
        case hundredTo200 = "100–200 km/h"
        case quarterMile = "¼ mile"
        case brake60to0 = "60–0 mph"
    }

    var id = UUID()
    var kind: Kind
    /// Seconds. Standing starts have the 1 ft rollout taken off, as at a drag strip.
    var time: Double
    /// Standing starts only: the time from the first movement.
    var timeNoRollout: Double?
    var distance: Double
    /// ¼ mile: speed at the line, km/h.
    var trapKmh: Double?
    /// Rise over run, %, positive uphill. Nil when the phone gave no altitude.
    var slopePct: Double?
    /// The time on a level road: uphill makes it shorter, downhill longer.
    var levelTime: Double?
    var worstHAcc: Double
    var issues: [String]
    var at: Double

    var valid: Bool { issues.isEmpty }

    static func == (a: AccelRun, b: AccelRun) -> Bool { a.id == b.id }
}

/// Acceleration and braking timer on phone GPS. Arms when the car stops, starts by itself
/// on launch, and reports every standard run the launch covered. Pure value type for tests.
struct AccelMeter {
    enum Phase: Equatable { case moving, ready, running }

    static let rollout = 0.3048            // 1 ft
    static let quarterMile = 402.336
    static let mph60 = 60 * 1.609344 / 3.6 // m/s
    static let kmh100 = 100 / 3.6
    static let kmh200 = 200 / 3.6
    static let stopped = 1 / 3.6           // below 1 km/h counts as standing
    static let maxSlopePct = 1.0
    static let maxHAcc = 10.0
    static let maxGap = 1.5
    static let g = 9.81

    private(set) var phase: Phase = .moving
    private(set) var runs: [AccelRun] = []
    /// Start of the run in progress, for the live clock.
    private(set) var runStart: Double?
    private(set) var runDistance: Double = 0
    /// OBD speed against GPS speed: mean of obd/gps − 1, as a percentage. Positive means the car reads high.
    var speedoErrorPct: Double? { speedPairs >= 10 ? (ratioSum / Double(speedPairs) - 1) * 100 : nil }
    private(set) var speedPairs = 0

    private var ratioSum = 0.0
    private var seg: [AccelSample] = []
    private var peak = 0.0
    private var brake: [AccelSample] = []
    private var last: AccelSample?

    mutating func reset() { self = AccelMeter() }

    /// Feed one sample; returns the runs it completed.
    @discardableResult
    mutating func add(_ s: AccelSample) -> [AccelRun] {
        defer { last = s }
        var done: [AccelRun] = []
        guard s.v >= 0 else { return done }

        if let k = s.obdKmh, s.v * 3.6 > 20, s.hAcc > 0, s.hAcc <= Self.maxHAcc {
            ratioSum += k / (s.v * 3.6); speedPairs += 1
        }

        done += trackBraking(s)

        switch phase {
        case .moving:
            if s.v < Self.stopped { phase = .ready }
        case .ready:
            if s.v >= Self.stopped, let prev = last {
                phase = .running
                seg = [prev, s]
                peak = s.v
                runStart = prev.t
                runDistance = 0
            }
        case .running:
            seg.append(s)
            peak = max(peak, s.v)
            runDistance = Self.distance(Self.profile(seg))
            let finished = s.v < peak - 10 / 3.6 || s.v < Self.stopped
                || (peak >= Self.kmh200 && runDistance > Self.quarterMile + 50)
                || s.t - (runStart ?? s.t) > 60
            if finished {
                done += Self.launchRuns(seg)
                runs += done.filter { $0.kind != .brake60to0 }
                seg = []
                runStart = nil
                phase = s.v < Self.stopped ? .ready : .moving
            }
        }
        if let b = done.first(where: { $0.kind == .brake60to0 }) { runs.append(b) }
        return done
    }

    // MARK: - Braking 60–0 mph

    private mutating func trackBraking(_ s: AccelSample) -> [AccelRun] {
        guard let prev = last else { return [] }
        if brake.isEmpty {
            if prev.v >= Self.mph60 && s.v < Self.mph60 { brake = [prev, s] }
            return []
        }
        brake.append(s)
        if s.v > Self.mph60 + 5 / 3.6 || s.v > brake[brake.count - 2].v + 3 / 3.6 { brake = []; return [] }   // let off, not a stop
        guard s.v < Self.stopped else { return [] }
        defer { brake = [] }
        guard let run = Self.brakingRun(brake) else { return [] }
        return [run]
    }

    static func brakingRun(_ b: [AccelSample]) -> AccelRun? {
        guard b.count >= 3 else { return nil }
        // Braking usually starts between two readings, so take the crossing from the first full braking interval.
        var t0 = crossing(b[0], b[1], Self.mph60)
        let dec = (b[1].v - b[2].v) / max(b[2].t - b[1].t, 1e-6)
        if dec > 0.5 { t0 = max(b[0].t, b[1].t - (Self.mph60 - b[1].v) / dec) }
        // The last reading is clamped at zero; stop time comes from the deceleration just before it.
        let p = b[b.count - 2], pp = b[b.count - 3]
        let a = (pp.v - p.v) / max(p.t - pp.t, 1e-6)
        let tStop = a > 0.5 ? min(p.t + p.v / a, b[b.count - 1].t) : b[b.count - 1].t
        var pts: [(t: Double, v: Double)] = [(t0, Self.mph60)]
        pts += b[1..<(b.count - 1)].map { ($0.t, $0.v) }
        pts.append((tStop, 0))
        let d = distance(pts)
        var issues = quality(b)
        let slope = slopePct(b.first!, b.last!, distance: d)
        if let s = slope, abs(s) > maxSlopePct { issues.append(String(format: "Slope %.1f%% (limit %.0f%%)", s, maxSlopePct)) }
        return AccelRun(kind: .brake60to0, time: tStop - t0, timeNoRollout: nil, distance: d, trapKmh: nil,
                        slopePct: slope, levelTime: nil, worstHAcc: b.map(\.hAcc).max() ?? 0, issues: issues, at: t0)
    }

    // MARK: - Standing starts

    /// Speed against time from launch: the first point is (launch, 0).
    static func profile(_ seg: [AccelSample]) -> [(t: Double, v: Double)] {
        guard seg.count >= 2 else { return [] }
        let first = seg[1]
        var launch = seg[0].t
        // Back-extrapolate the launch from the first two moving readings (constant acceleration).
        if seg.count >= 3 {
            let a = (seg[2].v - first.v) / max(seg[2].t - first.t, 1e-6)
            if a > 0.1 { launch = max(seg[0].t, first.t - first.v / a) }
        }
        return [(launch, 0)] + seg[1...].map { ($0.t, $0.v) }
    }

    static func launchRuns(_ seg: [AccelSample]) -> [AccelRun] {
        let pts = profile(seg)
        guard pts.count >= 3, let launch = pts.first?.t else { return [] }
        let tRoll = time(atDistance: rollout, pts) ?? launch
        let worst = seg.dropFirst().map(\.hAcc).max() ?? 0
        let baseIssues = quality(Array(seg.dropFirst()))
        var out: [AccelRun] = []

        func make(_ kind: AccelRun.Kind, from t0: Double, to t1: Double, v0: Double, v1: Double, noRollout: Double?, trap: Double? = nil) {
            let d0 = distance(pts, upTo: t0), d1 = distance(pts, upTo: t1)
            let a0 = altitude(at: t0, seg), a1 = altitude(at: t1, seg)
            var slope: Double?
            if let a0, let a1, d1 - d0 > 1 { slope = (a1 - a0) / (d1 - d0) * 100 }
            var issues = baseIssues
            if let s = slope, abs(s) > maxSlopePct { issues.append(String(format: "Slope %.1f%% (limit %.0f%%)", s, maxSlopePct)) }
            let t = t1 - t0
            var level: Double?
            if let s = slope, t > 0 {
                // Gravity along the slope adds or removes g·sin(θ) of acceleration.
                if kind == .quarterMile {
                    let a = 2 * (d1 - d0) / (t * t) + g * s / 100
                    if a > 0 { level = (2 * (d1 - d0) / a).squareRoot() }
                } else {
                    let a = (v1 - v0) / t + g * s / 100
                    if a > 0 { level = (v1 - v0) / a }
                }
            }
            out.append(AccelRun(kind: kind, time: t, timeNoRollout: noRollout, distance: d1 - d0, trapKmh: trap,
                                slopePct: slope, levelTime: level, worstHAcc: worst, issues: issues, at: launch))
        }

        if let t = time(atSpeed: mph60, pts) { make(.zeroTo60mph, from: tRoll, to: t, v0: 0, v1: mph60, noRollout: t - launch) }
        if let t = time(atSpeed: kmh100, pts) { make(.zeroTo100, from: tRoll, to: t, v0: 0, v1: kmh100, noRollout: t - launch) }
        if let a = time(atSpeed: kmh100, pts), let b = time(atSpeed: kmh200, pts) {
            make(.hundredTo200, from: a, to: b, v0: kmh100, v1: kmh200, noRollout: nil)
        }
        if let t = time(atDistance: rollout + quarterMile, pts) {
            make(.quarterMile, from: tRoll, to: t, v0: 0, v1: speed(at: t, pts), noRollout: nil, trap: speed(at: t, pts) * 3.6)
        }
        return out
    }

    // MARK: - Checks

    static func quality(_ s: [AccelSample]) -> [String] {
        var issues: [String] = []
        let worst = s.map(\.hAcc).max() ?? 0
        if worst > maxHAcc || worst <= 0 { issues.append(String(format: "GPS accuracy ±%.0f m (limit %.0f m)", worst, maxHAcc)) }
        let gap = zip(s, s.dropFirst()).map { $1.t - $0.t }.max() ?? 0
        if gap > maxGap { issues.append(String(format: "GPS gap of %.1f s", gap)) }
        return issues
    }

    static func slopePct(_ a: AccelSample, _ b: AccelSample, distance d: Double) -> Double? {
        guard a.vAcc >= 0, b.vAcc >= 0, d > 1 else { return nil }
        return (b.alt - a.alt) / d * 100
    }

    static func altitude(at t: Double, _ seg: [AccelSample]) -> Double? {
        guard !seg.contains(where: { $0.vAcc < 0 }), let i = seg.firstIndex(where: { $0.t >= t }) else { return nil }
        guard i > 0 else { return seg[0].alt }
        let a = seg[i - 1], b = seg[i]
        let f = (t - a.t) / max(b.t - a.t, 1e-9)
        return a.alt + (b.alt - a.alt) * f
    }

    // MARK: - Piecewise-linear speed helpers

    static func crossing(_ a: AccelSample, _ b: AccelSample, _ v: Double) -> Double {
        a.t + (b.t - a.t) * (a.v - v) / max(a.v - b.v, 1e-9)
    }

    static func time(atSpeed v: Double, _ p: [(t: Double, v: Double)]) -> Double? {
        for (a, b) in zip(p, p.dropFirst()) where a.v < v && b.v >= v {
            return a.t + (b.t - a.t) * (v - a.v) / max(b.v - a.v, 1e-9)
        }
        return nil
    }

    static func speed(at t: Double, _ p: [(t: Double, v: Double)]) -> Double {
        for (a, b) in zip(p, p.dropFirst()) where t >= a.t && t <= b.t {
            return a.v + (b.v - a.v) * (t - a.t) / max(b.t - a.t, 1e-9)
        }
        return p.last?.v ?? 0
    }

    static func distance(_ p: [(t: Double, v: Double)], upTo t: Double = .infinity) -> Double {
        var d = 0.0
        for (a, b) in zip(p, p.dropFirst()) {
            guard t > a.t else { break }
            let end = min(t, b.t)
            let vEnd = a.v + (b.v - a.v) * (end - a.t) / max(b.t - a.t, 1e-9)
            d += (a.v + vEnd) / 2 * (end - a.t)
        }
        return d
    }

    /// Solves within the segment for the exact moment the distance is reached (speed linear in time).
    static func time(atDistance target: Double, _ p: [(t: Double, v: Double)]) -> Double? {
        var d = 0.0
        for (a, b) in zip(p, p.dropFirst()) {
            let dt = b.t - a.t
            let seg = (a.v + b.v) / 2 * dt
            if d + seg >= target, dt > 0 {
                let need = target - d, acc = (b.v - a.v) / dt
                if abs(acc) < 1e-9 { return a.t + need / max(a.v, 1e-9) }
                let x = (-a.v + (a.v * a.v + 2 * acc * need).squareRoot()) / acc
                return a.t + x
            }
            d += seg
        }
        return nil
    }
}

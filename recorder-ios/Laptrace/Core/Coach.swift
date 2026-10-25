import Foundation

/// Post-session debrief: lap statistics plus one rule-based coaching goal.
/// Works on plain arrays (local metres, m/s) so it can be unit-tested.
/// Ported from studio-web corners.ts / coach.ts.
enum Coach {
    struct Lap {
        var number: Int
        var duration: Double
        var t: [Double]
        var x: [Double]
        var y: [Double]
        var speed: [Double]     // m/s
    }

    struct Stats: Equatable, Codable {
        var timedLaps: Int
        var bestLap: Double
        var bestLapNumber: Int
        var lapSD: Double
        var bestToMedian: Double
        var bestThreeAverage: Double?
    }

    struct CornerStats: Equatable, Codable {
        var number: Int
        var entryKmh: Double
        var minKmh: Double
        var exitKmh: Double
        var brakeAt: Double?    // metres from the start line
        var lossVsBest: Double  // seconds; average of the other laps
    }

    enum GoalKind: String, Codable { case consistency, braking, cornerSpeed, exit }

    struct Goal: Equatable, Codable {
        var kind: GoalKind
        var title: String
        var text: String
        var corner: Int?
    }

    struct Debrief: Equatable {
        var stats: Stats
        var corners: [CornerStats]
        var goal: Goal
        var factsJSON: String
    }

    static let gridStep = 1.0
    static let minCurvature = 1.0 / 200
    static let minCornerAngle = 20.0
    static let mergeGap = 25.0

    // MARK: - Debrief

    static func debrief(_ laps: [Lap], trackName: String? = nil) -> Debrief? {
        let timed = timedLaps(laps)
        guard let ref = timed.min(by: { $0.duration < $1.duration }) else { return nil }
        let stats = sessionStats(timed, best: ref)

        let refGrid = resample(ref)
        let others = timed.filter { $0.number != ref.number }.map { projected(resample($0), onto: refGrid) }
        let corners = detectCorners(refGrid)
        let zones = cornerZones(corners, length: refGrid.s.last ?? 0)

        var cornerStats: [CornerStats] = []
        var compare: [(ref: Measure, avg: Measure?)] = []
        for (i, c) in corners.enumerated() {
            let r = measure(refGrid, corner: c, zone: zones[i])
            let ms = others.map { measure($0, corner: c, zone: zones[i]) }
            let avg = average(ms)
            compare.append((r, avg))
            cornerStats.append(CornerStats(number: i + 1, entryKmh: r.entry * 3.6, minKmh: r.min * 3.6, exitKmh: r.exit * 3.6,
                                           brakeAt: r.brake, lossVsBest: avg.map { $0.time - r.time } ?? 0))
        }

        let goal = pickGoal(stats: stats, compare: compare)
        let facts = Facts(track: trackName, timedLaps: stats.timedLaps, bestLap: Fmt.lap(stats.bestLap),
                          bestLapNumber: stats.bestLapNumber, lapSpreadSeconds: fmt(stats.lapSD, 2),
                          bestToMedianSeconds: fmt(stats.bestToMedian, 2),
                          bestThreeLapAverage: stats.bestThreeAverage.map { Fmt.lap($0) },
                          goalTitle: goal.title, goalText: goal.text)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let json = (try? enc.encode(facts)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return Debrief(stats: stats, corners: cornerStats, goal: goal, factsJSON: json)
    }

    struct Facts: Codable {
        var track: String?
        var timedLaps: Int
        var bestLap: String
        var bestLapNumber: Int
        var lapSpreadSeconds: String
        var bestToMedianSeconds: String
        var bestThreeLapAverage: String?
        var goalTitle: String
        var goalText: String
    }

    /// Complete laps that look like real timed laps (no pit stops or spins: within 1.5× the median).
    static func timedLaps(_ laps: [Lap]) -> [Lap] {
        let ok = laps.filter { $0.duration > 0 && $0.t.count >= 2 }
        guard let med = median(ok.map(\.duration)) else { return [] }
        return ok.filter { $0.duration <= med * 1.5 }
    }

    static func sessionStats(_ timed: [Lap], best: Lap) -> Stats {
        let d = timed.map(\.duration)
        let byNumber = timed.sorted { $0.number < $1.number }
        var best3: Double?
        if byNumber.count >= 3 {
            for i in 0...(byNumber.count - 3) {
                let w = byNumber[i..<(i + 3)]
                guard w.last!.number - w.first!.number == 2 else { continue }
                let avg = w.map(\.duration).reduce(0, +) / 3
                best3 = min(best3 ?? .infinity, avg)
            }
        }
        return Stats(timedLaps: timed.count, bestLap: best.duration, bestLapNumber: best.number,
                     lapSD: stdDev(d), bestToMedian: (median(d) ?? best.duration) - best.duration, bestThreeAverage: best3)
    }

    // MARK: - Resampling

    struct Grid { var s: [Double]; var t: [Double]; var x: [Double]; var y: [Double]; var v: [Double] }

    /// Resample a lap onto a 1 m distance grid.
    static func resample(_ lap: Lap) -> Grid {
        var d = [0.0]
        for i in 1..<lap.x.count { d.append(d[i - 1] + hypot(lap.x[i] - lap.x[i - 1], lap.y[i] - lap.y[i - 1])) }
        let total = d.last ?? 0
        var g = Grid(s: [], t: [], x: [], y: [], v: [])
        var j = 0, s = 0.0
        while s <= total {
            while j < d.count - 2 && d[j + 1] < s { j += 1 }
            let span = d[j + 1] - d[j]
            let f = span > 0 ? (s - d[j]) / span : 0
            func lerp(_ a: [Double]) -> Double { a[j] + (a[j + 1] - a[j]) * f }
            g.s.append(s); g.t.append(lerp(lap.t)); g.x.append(lerp(lap.x)); g.y.append(lerp(lap.y)); g.v.append(lerp(lap.speed))
            s += gridStep
        }
        return g
    }

    /// Stretch a lap's grid onto the reference length so distances line up.
    static func aligned(_ g: Grid, to length: Double) -> Grid {
        guard let own = g.s.last, own > 0, length > 0 else { return g }
        let k = length / own
        var out = g
        out.s = g.s.map { $0 * k }
        return out
    }

    /// Express a lap on the reference lap's distance grid by projecting each point onto the reference
    /// path (studio-web alignToReference). Laps of slightly different length then line up by track
    /// position instead of drifting tens of metres by mid-lap. Past the lap's own coverage it holds its end values.
    static func projected(_ g: Grid, onto ref: Grid) -> Grid {
        let n = g.s.count, m = ref.s.count
        guard n > 1, m > 1 else { return g }
        var sRef = [Double](repeating: 0, count: n)
        var k = 0, prev = 0.0
        for i in 0..<n {
            var best = (seg: k, f: 0.0, d2: Double.infinity)
            func scan(_ r: Range<Int>) {
                for j in r {
                    let p = segment(g.x[i], g.y[i], ref, j)
                    if p.d2 < best.d2 { best = (j, p.f, p.d2) }
                }
            }
            let hi = i == 0 ? Swift.max(2, m / 10) : Swift.min(m - 1, k + 60)
            scan((i == 0 ? 0 : Swift.max(0, k - 20))..<Swift.min(hi, m - 1))
            // Lost the line (GPS error or a different route): look further ahead.
            if best.d2 > 30 * 30 && i > 0 { scan(Swift.min(hi, m - 1)..<Swift.min(m - 1, k + 400)) }
            let s = ref.s[best.seg] + best.f * (ref.s[best.seg + 1] - ref.s[best.seg])
            sRef[i] = i == 0 ? s : Swift.max(prev, s)
            prev = sRef[i]
            k = best.seg
        }
        if sRef[0] < 15 { sRef[0] = 0 }   // the lap starts on the reference start line
        var out = Grid(s: ref.s, t: [], x: [], y: [], v: [])
        var j = 0
        for s in ref.s {
            while j < n - 2 && sRef[j + 1] < s { j += 1 }
            let span = sRef[j + 1] - sRef[j]
            let f = span > 0 ? Swift.min(1, Swift.max(0, (s - sRef[j]) / span)) : 0
            func lerp(_ a: [Double]) -> Double { a[j] + (a[j + 1] - a[j]) * f }
            out.t.append(lerp(g.t)); out.x.append(lerp(g.x)); out.y.append(lerp(g.y)); out.v.append(lerp(g.v))
        }
        return out
    }

    /// Closest point to (px, py) on the reference segment j → j+1: fraction along it and squared distance.
    private static func segment(_ px: Double, _ py: Double, _ r: Grid, _ j: Int) -> (f: Double, d2: Double) {
        let dx = r.x[j + 1] - r.x[j], dy = r.y[j + 1] - r.y[j]
        let l2 = dx * dx + dy * dy
        let f = l2 > 0 ? Swift.min(1, Swift.max(0, ((px - r.x[j]) * dx + (py - r.y[j]) * dy) / l2)) : 0
        let qx = r.x[j] + f * dx - px, qy = r.y[j] + f * dy - py
        return (f, qx * qx + qy * qy)
    }

    private static func index(_ g: Grid, at s: Double) -> Int {
        min(max(lowerBound(g.s, s), 0), g.s.count - 1)
    }

    private static func time(_ g: Grid, at s: Double) -> Double {
        let i = index(g, at: s)
        guard i > 0 else { return g.t[0] }
        let f = (s - g.s[i - 1]) / max(g.s[i] - g.s[i - 1], 1e-9)
        return g.t[i - 1] + (g.t[i] - g.t[i - 1]) * min(max(f, 0), 1)
    }

    // MARK: - Corners

    struct Corner: Equatable { var start: Double; var end: Double; var angle: Double }

    static func detectCorners(_ g: Grid) -> [Corner] {
        let n = g.s.count
        guard n > 20 else { return [] }
        let w = 8
        var h = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(i - w, 0), b = min(i + w, n - 1)
            h[i] = atan2(g.x[b] - g.x[a], g.y[b] - g.y[a])
        }
        var k = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            var dh = h[i + 1] - h[i - 1]
            while dh > .pi { dh -= 2 * .pi }
            while dh < -.pi { dh += 2 * .pi }
            k[i] = dh / max(g.s[i + 1] - g.s[i - 1], 1e-9)
        }
        let half = 7
        var ks = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(i - half, 0), b = min(i + half, n - 1)
            ks[i] = k[a...b].reduce(0, +) / Double(b - a + 1)
        }
        // Runs of same-direction curvature; a run only absorbs the next one if it turns the same way,
        // so a left-right sequence stays two corners instead of cancelling out (studio-web corners.ts).
        var runs: [(a: Int, b: Int, sign: Int)] = []
        for i in 0..<n {
            let sign = ks[i] > minCurvature ? 1 : (ks[i] < -minCurvature ? -1 : 0)
            guard sign != 0 else { continue }
            if let last = runs.last, last.sign == sign, g.s[i] - g.s[last.b] <= mergeGap { runs[runs.count - 1].b = i }
            else { runs.append((i, i, sign)) }
        }
        return runs.compactMap { a, b, _ in
            let angle = abs(ks[a...b].reduce(0, +) * gridStep) * 180 / .pi
            guard angle >= minCornerAngle, g.s[b] - g.s[a] >= 10 else { return nil }
            return Corner(start: g.s[a], end: g.s[b], angle: angle)
        }
    }

    /// Each corner owns the track from the midpoint after the previous corner to the midpoint before the next.
    static func cornerZones(_ corners: [Corner], length: Double) -> [(Double, Double)] {
        corners.indices.map { i in
            let a = i == 0 ? 0 : (corners[i - 1].end + corners[i].start) / 2
            let b = i == corners.count - 1 ? length : (corners[i].end + corners[i + 1].start) / 2
            return (a, b)
        }
    }

    struct Measure: Equatable {
        var entry: Double; var min: Double; var minAt: Double; var exit: Double; var brake: Double?; var time: Double
        /// Where speed starts rising again after the minimum (throttle pick-up), metres.
        var throttle: Double? = nil
    }

    static func measure(_ g: Grid, corner c: Corner, zone: (Double, Double)) -> Measure {
        let lo = index(g, at: Swift.max(zone.0, c.start - 20)), hi = index(g, at: Swift.min(zone.1, c.end + 10))
        var m = lo
        for i in lo...Swift.max(lo, hi) where g.v[i] < g.v[m] { m = i }
        let z0 = index(g, at: zone.0)
        var p = Swift.min(z0, m)
        for i in Swift.min(z0, m)...m where g.v[i] > g.v[p] { p = i }   // speed peak before the minimum = where braking starts
        let brake = (g.v[p] - g.v[m]) * 3.6 > 5 ? g.s[p] : nil
        let z1 = index(g, at: zone.1)
        let pickUp = (m...max(m, z1)).first { g.v[$0] > g.v[m] + 2 / 3.6 }.map { g.s[$0] }   // +2 km/h, as studio-web
        return Measure(entry: g.v[index(g, at: c.start)], min: g.v[m], minAt: g.s[m], exit: g.v[index(g, at: c.end)],
                       brake: brake, time: time(g, at: zone.1) - time(g, at: zone.0), throttle: pickUp)
    }

    static func average(_ ms: [Measure]) -> Measure? {
        guard !ms.isEmpty else { return nil }
        let n = Double(ms.count)
        let brakes = ms.compactMap(\.brake)
        return Measure(entry: ms.map(\.entry).reduce(0, +) / n, min: ms.map(\.min).reduce(0, +) / n,
                       minAt: ms.map(\.minAt).reduce(0, +) / n, exit: ms.map(\.exit).reduce(0, +) / n,
                       brake: brakes.isEmpty ? nil : brakes.reduce(0, +) / Double(brakes.count),
                       time: ms.map(\.time).reduce(0, +) / n)
    }

    // MARK: - Skill ladder

    static func pickGoal(stats: Stats, compare: [(ref: Measure, avg: Measure?)]) -> Goal {
        if stats.lapSD > 1.2 {
            return Goal(kind: .consistency, title: "Be consistent first",
                        text: "Your lap times varied by \(fmt(stats.lapSD, 1)) s. Repeat the line from your best lap (lap \(stats.bestLapNumber), \(Fmt.lap(stats.bestLap))) and aim for laps within ±0.6 s of each other before chasing speed.",
                        corner: nil)
        }
        let withAvg = compare.enumerated().compactMap { i, c in c.avg.map { (i + 1, c.ref, $0) } }

        let braking = withAvg.compactMap { n, r, a -> (Int, Double, Double)? in
            guard let rb = r.brake, let ab = a.brake, rb - ab > 5, a.time - r.time > 0 else { return nil }
            return (n, rb - ab, a.time - r.time)
        }.max { $0.2 < $1.2 }
        if let (n, metres, loss) = braking {
            return Goal(kind: .braking, title: "Brake later into corner \(n)",
                        text: "Corner \(n): on your best lap you started braking \(fmt(metres, 0)) m later than your average and lost \(fmt(loss, 2)) s less there. Pick a fixed braking marker and move it a little closer each lap.",
                        corner: n)
        }

        let speed = withAvg.map { n, r, a in (n, r.min * 3.6, a.min * 3.6) }.max { ($0.1 - $0.2) < ($1.1 - $1.2) }
        if let (n, best, avg) = speed, best - avg > 2 {
            return Goal(kind: .cornerSpeed, title: "Carry more speed through corner \(n)",
                        text: "Corner \(n): your best lap carried \(fmt(best, 0)) km/h at the slowest point; your average was \(fmt(avg, 0)) km/h. Brake a little less and roll more speed to the apex.",
                        corner: n)
        }

        if let (n, r, a) = withAvg.max(by: { ($0.1.exit - $0.2.exit) < ($1.1.exit - $1.2.exit) }) {
            return Goal(kind: .exit, title: "Get on the throttle earlier out of corner \(n)",
                        text: "Corner \(n): your best lap left the corner at \(fmt(r.exit * 3.6, 0)) km/h; your average was \(fmt(a.exit * 3.6, 0)) km/h. Once the car points down the next straight, squeeze the throttle smoothly and early.",
                        corner: n)
        }
        if let r = compare.first?.ref {
            return Goal(kind: .exit, title: "Get on the throttle earlier out of corner 1",
                        text: "Corner 1: your best lap left the corner at \(fmt(r.exit * 3.6, 0)) km/h. Drive a few more laps so there is something to compare; meanwhile squeeze the throttle smoothly as soon as the car points down the straight.",
                        corner: 1)
        }
        return Goal(kind: .exit, title: "Smooth, early throttle",
                    text: "Your best lap was \(Fmt.lap(stats.bestLap)). Focus on squeezing the throttle smoothly as soon as the car points down each straight.",
                    corner: nil)
    }

    // MARK: - Grounding check for generated text

    static func numbers(in text: String) -> [Double] {
        let re = try! NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#)
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { Double(ns.substring(with: $0.range)) }
    }

    /// True when every number in `text` also appears in `facts`.
    static func numbersAreGrounded(_ text: String, facts: String) -> Bool {
        let allowed = Set(numbers(in: facts))
        return numbers(in: text).allSatisfy { allowed.contains($0) }
    }

    // MARK: - Helpers

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted(), m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    static func stdDev(_ v: [Double]) -> Double {
        guard v.count >= 2 else { return 0 }
        let mean = v.reduce(0, +) / Double(v.count)
        return sqrt(v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count - 1))
    }
}

// MARK: - Opportunities (studio-web insights.ts)

extension Coach {
    enum Cause { case braking, minSpeed, throttle, exit, unclear }

    /// What the reference lap could gain in one corner by matching the lap that was quickest through it.
    struct Opportunity: Identifiable {
        var corner: Int
        var gain: Double            // s
        var fromLap: Int
        var cause: Cause
        var refValue: Double?       // metres for braking/throttle, km/h for speeds
        var fastValue: Double?
        var id: Int { corner }
    }

    /// Main reason `slow` lost time to `fast`. 10 m of brake/throttle point weighs as much as 2 km/h of speed.
    static func cause(slow: Measure, fast: Measure) -> (Cause, Double?, Double?) {
        var cands: [(Cause, Double, Double, Double)] = []
        if let s = slow.brake, let f = fast.brake, f - s >= 5 { cands.append((.braking, (f - s) / 10, s, f)) }
        let dMin = (fast.min - slow.min) * 3.6
        if dMin >= 2 { cands.append((.minSpeed, dMin / 2, slow.min * 3.6, fast.min * 3.6)) }
        if let s = slow.throttle, let f = fast.throttle, s - f >= 5 { cands.append((.throttle, (s - f) / 10, s, f)) }
        let dExit = (fast.exit - slow.exit) * 3.6
        if dExit >= 2 { cands.append((.exit, dExit / 2 * 0.8, slow.exit * 3.6, fast.exit * 3.6)) }
        guard let top = cands.max(by: { $0.1 < $1.1 }) else { return (.unclear, nil, nil) }
        return (top.0, top.2, top.3)
    }

    /// Per corner, the quickest other lap through the corner zone against the reference lap. Biggest gain first.
    static func opportunities(refLap: Int, corners: [(number: Int, laps: [Int: Measure])], minGain: Double = 0.05) -> [Opportunity] {
        corners.compactMap { c in
            guard let r = c.laps[refLap],
                  let fast = c.laps.filter({ $0.key != refLap }).min(by: { $0.value.time < $1.value.time }) else { return nil }
            let gain = r.time - fast.value.time
            guard gain >= minGain else { return nil }
            let why = cause(slow: r, fast: fast.value)
            return Opportunity(corner: c.number, gain: gain, fromLap: fast.key, cause: why.0, refValue: why.1, fastValue: why.2)
        }
        .sorted { $0.gain > $1.gain }
    }
}

// MARK: - Car data (studio-web car.ts)

/// Revs at the shift, time flat out, time with neither pedal, engine temperatures, and how lap
/// time moved as the engine heated up over the stint. Read-only service 01 data only.
enum CarAnalysis {
    static let throttleOn = 5.0
    static let fullThrottle = 90.0
    static let limits = (coolant: 105.0, oil: 130.0, intake: 55.0)

    struct LapStats {
        var number: Int
        var time: Double
        var maxRpm: Double?
        var shiftRpm: Double?       // median of detected upshifts
        var shifts: Int
        var fullThrottlePct: Double?
        var coastSeconds: Double?
        var coolantMax: Double?
        var oilMax: Double?
        var intakeMax: Double?
        var hasCarData: Bool { maxRpm != nil || fullThrottlePct != nil || coolantMax != nil || oilMax != nil }
    }

    struct Advice: Hashable { var text: String; var warn: Bool }

    struct Stint {
        var rows: [LapStats]
        var secPer10C: Double?      // least-squares slope of lap time against the hottest temperature
        var channel: String?        // "oil" or "coolant"
        var verdict: String? {
            guard let s = secPer10C, let name = channel else { return nil }
            if abs(s) < 0.1 { return "Lap times held steady as the \(name) warmed up." }
            return s > 0
                ? String(format: "Laps got about %.2f s slower for every 10 °C of %@. Heat may be costing power or grip; try a cool-down lap mid-stint.", s, name)
                : String(format: "Laps got about %.2f s quicker for every 10 °C of %@, so the car and tyres were still coming in.", -s, name)
        }
    }

    /// Upshifts: a revs peak followed within a second by a drop of more than 1000 rpm while the car keeps its speed.
    static func shifts(_ l: Exporter.LapChannels) -> [Double] {
        var out: [Double] = []
        var i = 1
        while i < l.rpm.count - 1 {
            guard let r = l.rpm[i], r >= 2500, (l.rpm[i - 1].map { r >= $0 } ?? true) else { i += 1; continue }
            var shifted = -1
            var j = i + 1
            while j < l.rpm.count && l.t[j] - l.t[i] <= 1 {
                if let rj = l.rpm[j] {
                    if rj > r { break }
                    if r - rj > 1000 && l.speed[j] >= l.speed[i] - 3 / 3.6 { shifted = j; break }
                }
                j += 1
            }
            if shifted > 0 { out.append(r); i = shifted + 1 } else { i += 1 }
        }
        return out
    }

    /// The session's closed-to-open pedal range. Cars rarely report 0–100: a throttle plate typically
    /// idles near 15% and opens to about 85%, so fixed 5%/90% thresholds would never trigger.
    static func pedalRange(_ laps: [Exporter.LapChannels]) -> (lo: Double, hi: Double)? {
        let v = laps.flatMap { $0.pedal.compactMap { $0 } }.sorted()
        guard v.count >= 20, let hi = v.last else { return nil }
        let lo = v[v.count / 50]   // 2nd percentile: idle, ignoring the odd glitch
        return hi - lo >= 20 ? (lo, hi) : nil
    }

    /// `range` rescales the pedal to 0–100% of what this car showed in the session (see pedalRange).
    static func stats(_ l: Exporter.LapChannels, range: (lo: Double, hi: Double)? = nil) -> LapStats {
        var full = 0.0, coast = 0.0, known = 0.0
        for i in 1..<max(l.t.count, 1) {
            let dt = l.t[i] - l.t[i - 1]
            guard dt > 0, dt < 2, let raw = l.pedal[i] else { continue }
            let p = range.map { (raw - $0.lo) / ($0.hi - $0.lo) * 100 } ?? raw
            known += dt
            if p >= fullThrottle { full += dt } else if p <= throttleOn && l.long[i] > -0.15 { coast += dt }
        }
        let enough = known > l.duration * 0.5
        let sh = shifts(l)
        return LapStats(number: l.number, time: l.duration, maxRpm: l.rpm.compactMap { $0 }.max(),
                        shiftRpm: Coach.median(sh), shifts: sh.count,
                        fullThrottlePct: enough ? full / known * 100 : nil,
                        coastSeconds: enough ? coast * (l.duration / known) : nil,
                        coolantMax: l.coolant.compactMap { $0 }.max(), oilMax: l.oil.compactMap { $0 }.max(),
                        intakeMax: l.intake.compactMap { $0 }.max())
    }

    /// Plain guidance from the best lap against the others.
    static func advice(ref: LapStats, laps: [LapStats]) -> [Advice] {
        let others = laps.filter { $0.number != ref.number }
        let all = laps + [ref]
        var out: [Advice] = []
        func r100(_ v: Double) -> Int { Int((v / 100).rounded()) * 100 }

        let sessionMax = all.compactMap(\.maxRpm).max()
        if let shift = ref.shiftRpm ?? Coach.median(laps.compactMap(\.shiftRpm)), let top = sessionMax {
            out.append(Advice(text: top - shift > 700
                ? "You usually change up at about \(r100(shift)) rpm but the engine reached \(r100(top)) rpm this session. On the straights, hold each gear a little longer before changing up."
                : "Your upshifts sit around \(r100(shift)) rpm, close to the highest revs you used. Keep them there.", warn: false))
        }
        let typFull = Coach.median(others.compactMap(\.fullThrottlePct))
        if let f = ref.fullThrottlePct {
            if let t = typFull, f - t >= 3 {
                out.append(Advice(text: "Your best lap was flat out \(Int(f.rounded()))% of the time, against \(Int(t.rounded()))% on a typical lap. Commit to full throttle sooner on corner exits.", warn: false))
            } else {
                out.append(Advice(text: "Flat out for \(Int(f.rounded()))% of your best lap.", warn: false))
            }
        }
        if let c = Coach.median(others.compactMap(\.coastSeconds)) ?? ref.coastSeconds, c >= 1.5 {
            out.append(Advice(text: String(format: "About %.1f s per lap with neither pedal pressed. Aim to go straight from the brake to a little throttle through the corner.", c), warn: false))
        }
        let oil = all.compactMap(\.oilMax).max(), coolant = all.compactMap(\.coolantMax).max(), intake = all.compactMap(\.intakeMax).max()
        var temps = false
        if let o = oil, o >= limits.oil {
            out.append(Advice(text: "Oil reached \(Int(o.rounded())) °C. Do a slow cool-down lap before it climbs further, and check the oil level after the session.", warn: true)); temps = true
        }
        if let c = coolant, c >= limits.coolant {
            out.append(Advice(text: "Coolant reached \(Int(c.rounded())) °C. Back off for a lap and let it settle.", warn: true)); temps = true
        }
        if let i = intake, i >= limits.intake {
            out.append(Advice(text: "Intake air reached \(Int(i.rounded())) °C. Hot intake air costs power, so expect slower straights later in a stint.", warn: false)); temps = true
        }
        if !temps && (oil != nil || coolant != nil) {
            let parts = [coolant.map { "coolant \(Int($0.rounded())) °C" }, oil.map { "oil \(Int($0.rounded())) °C" }].compactMap { $0 }
            out.append(Advice(text: "Temperatures stayed in range: \(parts.joined(separator: ", ")) at most.", warn: false))
        }
        return out
    }

    /// Lap time against the hottest oil (else coolant) of each lap, in driving order.
    static func stint(_ laps: [LapStats]) -> Stint? {
        let rows = laps.sorted { $0.number < $1.number }
        guard rows.count >= 2, rows.contains(where: { $0.oilMax != nil || $0.coolantMax != nil }) else { return nil }
        func fit(_ pick: (LapStats) -> Double?) -> Double? {
            let pts = rows.compactMap { r in pick(r).map { ($0, r.time) } }
            guard pts.count >= 4, let lo = pts.map(\.0).min(), let hi = pts.map(\.0).max(), hi - lo >= 5 else { return nil }
            let n = Double(pts.count)
            let mx = pts.map(\.0).reduce(0, +) / n, my = pts.map(\.1).reduce(0, +) / n
            let sxx = pts.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }
            guard sxx > 0 else { return nil }
            return pts.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx * 10
        }
        if let s = fit(\.oilMax) { return Stint(rows: rows, secPer10C: s, channel: "oil") }
        let c = fit(\.coolantMax)
        return Stint(rows: rows, secPer10C: c, channel: c == nil ? nil : "coolant")
    }
}

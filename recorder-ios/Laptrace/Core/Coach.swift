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
        let others = timed.filter { $0.number != ref.number }.map { aligned(resample($0), to: refGrid.s.last ?? 0) }
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
        var runs: [(Int, Int)] = []
        var i = 0
        while i < n {
            guard abs(ks[i]) > minCurvature else { i += 1; continue }
            var j = i
            while j + 1 < n && abs(ks[j + 1]) > minCurvature { j += 1 }
            if let last = runs.last, g.s[i] - g.s[last.1] < mergeGap { runs[runs.count - 1].1 = j } else { runs.append((i, j)) }
            i = j + 1
        }
        return runs.compactMap { a, b in
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

    struct Measure: Equatable { var entry: Double; var min: Double; var minAt: Double; var exit: Double; var brake: Double?; var time: Double }

    static func measure(_ g: Grid, corner c: Corner, zone: (Double, Double)) -> Measure {
        let lo = index(g, at: c.start - 20), hi = index(g, at: c.end + 10)
        var m = lo
        for i in lo...max(lo, hi) where g.v[i] < g.v[m] { m = i }
        let z0 = index(g, at: zone.0)
        var p = min(z0, m)
        for i in min(z0, m)...m where g.v[i] >= g.v[p] { p = i }   // last peak = where braking starts
        let brake = (g.v[p] - g.v[m]) * 3.6 > 5 ? g.s[p] : nil
        return Measure(entry: g.v[index(g, at: c.start)], min: g.v[m], minAt: g.s[m], exit: g.v[index(g, at: c.end)],
                       brake: brake, time: time(g, at: zone.1) - time(g, at: zone.0))
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

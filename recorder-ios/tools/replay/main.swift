import Foundation

// Replays a recorded session (or the synthetic one) through the same Core code the recorder runs live,
// and reports how well lap timing, the predictive gap and the g-force calibration hold up.
//
//   B=$(mktemp -d)
//   { echo 'import Foundation'; sed -n '/^enum Fmt/,/^}/p' Laptrace/LaptraceApp.swift; } > $B/Fmt.swift
//   grep -v '@testable' Tests/Synthetic.swift > $B/Synthetic.swift
//   swiftc -O Laptrace/Core/*.swift Laptrace/Recording/DriveStartGate.swift $B/Fmt.swift $B/Synthetic.swift tools/replay/main.swift -o replay
//   ./replay --synthetic
//   ./replay <session folder> [--track <id>] [--tracks Laptrace/Resources/tracks.json]

struct Args {
    var folder: URL?
    var synthetic = false
    var trackId: String?
    var tracksFile = URL(fileURLWithPath: "Laptrace/Resources/tracks.json")

    init() {
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--synthetic": synthetic = true
            case "--track": trackId = it.next()
            case "--tracks": if let p = it.next() { tracksFile = URL(fileURLWithPath: p) }
            default: folder = URL(fileURLWithPath: a)
            }
        }
    }
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}

struct Tracks: Decodable { let tracks: [Track] }

let args = Args()
var fixes: [GPSFix] = [], motion: [MotionSample] = [], obd: [OBDSample] = []
var track: Track?
var truthLaps: [Double] = []

if args.synthetic {
    let s = SyntheticSession()
    let g = s.generate()
    fixes = g.fixes; motion = g.motion; truthLaps = g.lapTimes; track = s.track
} else if let folder = args.folder {
    fixes = RawFiles.readFixes(folder.appendingPathComponent("gps.csv"))
    motion = RawFiles.readMotion(folder.appendingPathComponent("motion.bin"))
    obd = RawFiles.readOBD(folder.appendingPathComponent("obd.csv"))
    var id = args.trackId
    if id == nil, let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
       let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        id = meta["trackId"] as? String
    }
    if let id, let data = try? Data(contentsOf: args.tracksFile),
       let file = try? JSONDecoder().decode(Tracks.self, from: data) {
        track = file.tracks.first { $0.id == id }
    }
} else {
    print("usage: replay --synthetic | <session folder> [--track id]"); exit(1)
}

print("== Input")
print("fixes \(fixes.count) · motion \(motion.count) · obd \(obd.count) · track \(track?.name ?? "none")")

// GPS rate
let dts = zip(fixes.dropFirst(), fixes).map { $0.t - $1.t }.filter { $0 > 0 }
if !dts.isEmpty {
    print("GPS dt p10/p50/p90/max: \(fmt(percentile(dts, 0.1), 3)) / \(fmt(percentile(dts, 0.5), 3)) / \(fmt(percentile(dts, 0.9), 3)) / \(fmt(dts.max()!, 3)) s → \(fmt(1 / percentile(dts, 0.5), 1)) Hz")
    let hAcc = fixes.map(\.hAcc).filter { $0 > 0 }
    print("hAcc p50/p90: \(fmt(percentile(hAcc, 0.5), 1)) / \(fmt(percentile(hAcc, 0.9), 1)) m")
}
let mdts = zip(motion.dropFirst(), motion).map { $0.t - $1.t }.filter { $0 > 0 }
if !mdts.isEmpty { print("IMU rate: \(fmt(1 / percentile(mdts, 0.5), 1)) Hz") }

// Live path, mirroring Recorder.handle(fix)
let timer = LapTimer()
timer.setTrack(track)
var line = LiveLine()
var laps: [CompletedLap] = []
// (lap number, elapsed in lap, predicted lap time) for every fix with a prediction
var predictions: [(lap: Int, elapsed: Double, predicted: Double)] = []
// Reference lap time each lap was predicted against
var references: [Int: Double] = [:]
var currentLap: Int?
for fix in fixes {
    guard fix.hAcc > 0, fix.hAcc <= 30 else { continue }
    line.add(fix, pedal: nil)
    if let lap = currentLap, let p = line.now?.predicted, let start = timer.currentLapStart {
        if ProcessInfo.processInfo.environment["DEBUG_JUMPS"] != nil, let last = predictions.last, last.lap == lap, abs(p - last.predicted) > 1 {
            print("jump lap \(lap) t \(fmt(fix.t - start, 1)) s \(fmt(line.now?.s ?? -1, 0)) v \(fmt(fix.speed, 1)) pred \(fmt(last.predicted, 2))→\(fmt(p, 2))")
        }
        predictions.append((lap, fix.t - start, p))
        if references[lap] == nil { references[lap] = line.bestDuration }
    }
    for e in timer.ingest(TimedPoint(t: fix.t, p: fix.latLon)) {
        switch e {
        case .lapStarted(let t):
            line.lapStarted(at: t)
            currentLap = timer.currentLapNumber
        case .lapCompleted(let lap):
            line.lapCompleted(number: lap.number, duration: lap.duration)
            laps.append(lap)
        case .split: break
        }
    }
}

print("\n== Laps (live LapTimer)")
for (i, lap) in laps.enumerated() {
    var row = "lap \(lap.number): \(fmt(lap.duration, 3)) s"
    if i < truthLaps.count { row += "  truth \(fmt(truthLaps[i], 3))  err \(fmt((lap.duration - truthLaps[i]) * 1000, 0)) ms" }
    let splits = lap.splits.sorted { $0.value < $1.value }.map { "\($0.key) \(fmt($0.value, 2))" }.joined(separator: " · ")
    if !splits.isEmpty { row += "  [\(splits)]" }
    print(row)
}
if laps.isEmpty { print("no laps") }

print("\n== Predicted lap vs actual (per fix, laps that had a reference)")
let lostTimeThreshold = 2.0
var cleanErrs: [Double] = [], lostLaps: [Int] = []
for lap in laps {
    let ps = predictions.filter { $0.lap == lap.number }
    guard !ps.isEmpty else { continue }
    let errs = ps.map { abs($0.predicted - lap.duration) }
    let firstHalf = ps.filter { $0.elapsed < lap.duration / 2 }.map { abs($0.predicted - lap.duration) }
    let jumps = zip(ps.dropFirst(), ps).map { abs($0.predicted - $1.predicted) }
    var row = "lap \(lap.number): n \(ps.count) · |err| p50 \(fmt(percentile(errs, 0.5), 2)) p90 \(fmt(percentile(errs, 0.9), 2)) s · first half p50 \(fmt(percentile(firstHalf, 0.5), 2)) s · fix-to-fix jump p90 \(fmt(percentile(jumps, 0.9), 2)) max \(fmt(jumps.max() ?? 0, 2)) s"
    // Time lost against the reference can only show up in the prediction after it is lost, so a lap
    // that drops well off the reference is flagged rather than scored as predictor error.
    if let ref = references[lap.number] {
        let lost = lap.duration - ref
        row += " · vs ref \(lost >= 0 ? "+" : "")\(fmt(lost, 2)) s"
        if lost > lostTimeThreshold { row += "  LOST TIME"; lostLaps.append(lap.number) } else { cleanErrs += errs }
    }
    print(row)
}
if !cleanErrs.isEmpty || !lostLaps.isEmpty {
    print("clean laps (under \(fmt(lostTimeThreshold, 0)) s lost to ref): |err| p50 \(fmt(percentile(cleanErrs, 0.5), 2)) p90 \(fmt(percentile(cleanErrs, 0.9), 2)) s (n \(cleanErrs.count)) · lost-time laps: \(lostLaps.isEmpty ? "none" : lostLaps.map(String.init).joined(separator: ", "))")
}

print("\n== Live g (LiveG, motion fed up to each fix)")
var liveG = LiveG()
var mi = 0
var calibratedAt: Double?
var gErrs: [Double] = []
var truth: [SyntheticSession.Truth] = []
if args.synthetic { truth = SyntheticSession().generate().truth }
var ti = 0
for fix in fixes {
    while mi < motion.count, motion[mi].t <= fix.t { liveG.add(motion[mi]); mi += 1 }
    liveG.add(fix)
    if calibratedAt == nil, liveG.calibrated { calibratedAt = fix.t - fixes[0].t }
    guard !truth.isEmpty, let r = liveG.reading, r.fromIMU else { continue }
    while ti + 1 < truth.count, truth[ti + 1].t <= fix.t { ti += 1 }
    gErrs.append(max(abs(r.long - truth[ti].long), abs(r.lat - truth[ti].lat)))
}
print("calibrated after \(calibratedAt.map { fmt($0, 0) + " s" } ?? "never") · r long \(fmt(liveG.rLong, 2)) lat \(fmt(liveG.rLat, 2))")
if !gErrs.isEmpty { print("|err| vs truth p50 \(fmt(percentile(gErrs, 0.5), 3)) p90 \(fmt(percentile(gErrs, 0.9), 3)) g (n \(gErrs.count))") }

print("\n== Export (post-session)")
if let (_, summary) = Exporter().export(fixes: fixes, motion: motion, track: track, obd: obd) {
    let c = summary.calibration
    print("rows \(summary.rows) · laps \(summary.laps.count) · \(c.source) · intervals \(c.intervals) · r long \(fmt(c.longitudinalCorrelation, 2)) lat \(fmt(c.lateralCorrelation, 2))")
} else {
    print("export failed")
}

import Foundation

/// Timed position used for crossing detection.
struct TimedPoint {
    var t: Double
    var p: LatLon
}

struct GateCrossing {
    var gate: Gate
    var t: Double
}

/// Finds directed gate crossings along a path. Gates are lengthened by
/// `tolerance` metres on both ends because 1 Hz phone GPS cuts chords.
struct GateDetector {
    let gates: [Gate]
    let tolerance: Double

    init(gates: [Gate], tolerance: Double = 12) {
        self.gates = gates
        self.tolerance = tolerance
    }

    func crossings(from a: TimedPoint, to b: TimedPoint) -> [GateCrossing] {
        guard b.t > a.t else { return [] }
        var out: [GateCrossing] = []
        for gate in gates {
            let proj = LocalProjection(origin: gate.start)
            var g0 = proj.project(gate.start), g1 = proj.project(gate.end)
            let dir = g1 - g0, len = dir.length
            guard len > 0 else { continue }
            let ext = dir * (tolerance / len)
            g0 = g0 - ext; g1 = g1 + ext
            let p0 = proj.project(a.p), p1 = proj.project(b.p)
            let travel = p1 - p0
            guard travel.length > 0.01,
                  abs(angleDelta(gate.travelBearing, travel.bearing)) < 90,
                  let f = segmentIntersection(p0, p1, g0, g1) else { continue }
            out.append(GateCrossing(gate: gate, t: a.t + f * (b.t - a.t)))
        }
        return out.sorted { $0.t < $1.t }
    }
}

struct CompletedLap: Codable, Hashable, Identifiable {
    var number: Int
    var start: Double
    var end: Double
    /// Elapsed seconds from lap start at each split gate, in gate order.
    var splits: [String: Double]
    var id: Int { number }
    var duration: Double { end - start }
}

/// Live lap timing from GPS fixes.
final class LapTimer {
    private(set) var track: Track?
    private var detector: GateDetector?
    private var last: TimedPoint?
    private(set) var currentLapStart: Double?
    private(set) var currentSplits: [String: Double] = [:]
    private(set) var laps: [CompletedLap] = []
    /// Lap number in progress (1-based) or nil before the first crossing.
    var currentLapNumber: Int? { currentLapStart == nil ? nil : laps.count + 1 }
    var best: CompletedLap? { laps.min(by: { $0.duration < $1.duration }) }
    /// Minimum plausible lap; filters gate jitter when parked near the line.
    var minimumLapSeconds: Double = 20

    /// Events emitted by `ingest`.
    enum Event {
        case lapStarted(at: Double)
        case lapCompleted(CompletedLap)
        case split(gate: Gate, elapsed: Double, deltaToBest: Double?)
    }

    func setTrack(_ track: Track?) {
        self.track = track
        detector = track.map { GateDetector(gates: $0.gates) }
    }

    func reset() {
        last = nil; currentLapStart = nil; currentSplits = [:]; laps = []
    }

    @discardableResult
    func ingest(_ point: TimedPoint) -> [Event] {
        defer { last = point }
        guard let prev = last, let detector else { return [] }
        var events: [Event] = []
        for c in detector.crossings(from: prev, to: point) {
            if c.gate.isStartFinish {
                if let start = currentLapStart {
                    guard c.t - start >= minimumLapSeconds else { continue }
                    let lap = CompletedLap(number: laps.count + 1, start: start, end: c.t, splits: currentSplits)
                    laps.append(lap)
                    events.append(.lapCompleted(lap))
                }
                currentLapStart = c.t
                currentSplits = [:]
                events.append(.lapStarted(at: c.t))
            } else if let start = currentLapStart, currentSplits[c.gate.id] == nil {
                let elapsed = c.t - start
                currentSplits[c.gate.id] = elapsed
                let delta = best?.splits[c.gate.id].map { elapsed - $0 }
                events.append(.split(gate: c.gate, elapsed: elapsed, deltaToBest: delta))
            }
        }
        return events
    }
}

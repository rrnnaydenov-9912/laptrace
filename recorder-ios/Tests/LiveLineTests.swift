import XCTest
@testable import LaptraceLogger

final class LiveLineTests: XCTestCase {
    /// Drives the synthetic ring through the lap timer exactly like the recorder does.
    private func run(_ synth: SyntheticSession, _ fixes: [GPSFix], pedal: Double? = nil) -> (LiveLine, [Double?]) {
        let timer = LapTimer()
        timer.setTrack(synth.track)
        var line = LiveLine(), best: Double = .infinity, deltas: [Double?] = []
        for f in fixes {
            line.add(f, pedal: pedal)
            for e in timer.ingest(TimedPoint(t: f.t, p: f.latLon)) {
                switch e {
                case .lapStarted: line.lapStarted()
                case .lapCompleted(let lap):
                    line.lapCompleted(number: lap.number, duration: lap.duration, isBest: lap.duration < best)
                    best = min(best, lap.duration)
                case .split: break
                }
            }
            deltas.append(line.now?.deltaKmh)
        }
        return (line, deltas)
    }

    func testSameLapAgainMatchesBestSpeed() {
        var synth = SyntheticSession()
        synth.laps = 4
        let (line, deltas) = run(synth, synth.generate().fixes)
        XCTAssertFalse(line.best.isEmpty, "best lap kept after the first full lap")
        let late = deltas.suffix(15).compactMap { $0 }
        XCTAssertGreaterThan(late.count, 10, "position found on the best lap")
        // Identical laps: speed at the same spot matches within a few km/h (1 Hz GPS, 1 m grid).
        XCTAssertLessThan(late.map(abs).max() ?? 99, 6)
    }

    func testCurrentLapResetsAtTheLine() {
        let synth = SyntheticSession()
        let fixes = synth.generate().fixes
        let (line, _) = run(synth, fixes)
        XCTAssertLessThan(line.current.count, fixes.count / 2)
    }

    func testPedalClassification() {
        XCTAssertEqual(LiveLine.pedal(accelG: -0.5, pedal: 0), .brake)
        XCTAssertEqual(LiveLine.pedal(accelG: -0.5, pedal: 40), .throttle)   // pedal wins: heel-and-toe, drag
        XCTAssertEqual(LiveLine.pedal(accelG: -0.05, pedal: 0), .coast)
        XCTAssertEqual(LiveLine.pedal(accelG: 0.2, pedal: nil), .throttle)   // no OBD: speeding up
        XCTAssertEqual(LiveLine.pedal(accelG: 0.0, pedal: nil), .coast)
    }

    func testBrakingFromGPSDeceleration() {
        var line = LiveLine()
        for i in 0..<5 {   // 40 → 8 m/s, still braking at the end
            let v = 40.0 - Double(i) * 8   // 8 m/s per second ≈ 0.8 g
            line.add(GPSFix(t: Double(i), lat: 42 + Double(i) * 1e-4, lon: 23, alt: 0, hAcc: 3, speed: max(v, 0), course: 0), pedal: 0)
        }
        XCTAssertEqual(line.current.last?.pedal, .brake)
        XCTAssertLessThan(line.accelG, -0.5)
    }
}

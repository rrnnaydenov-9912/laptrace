import XCTest
@testable import LaptraceLogger

final class AccelTests: XCTestCase {
    /// 1 Hz readings of a car that stands still, launches at `launch` with constant acceleration, then lifts.
    private func pull(accel a: Double = 4, launch: Double = 10.37, top: Double = 60, grade: Double = 0,
                      hAcc: Double = 3, obdScale: Double? = nil) -> [AccelSample] {
        var out: [AccelSample] = []
        var liftT: Double?
        for i in 0..<60 {
            let t = Double(i)
            var v = max(0, (t - launch) * a), d = v * v / (2 * a)
            if v > top {
                let tl = launch + top / a
                liftT = liftT ?? tl
                v = max(0, top - (t - tl) * 3)
                d = top * top / (2 * a) + (top + v) / 2 * (t - tl)
            }
            out.append(AccelSample(t: t, v: v, alt: 500 + d * grade, hAcc: hAcc, vAcc: 3,
                                   obdKmh: obdScale.map { v * 3.6 * $0 }))
        }
        return out
    }

    private func runs(_ samples: [AccelSample]) -> (AccelMeter, [AccelRun]) {
        var m = AccelMeter(), all: [AccelRun] = []
        for s in samples { all += m.add(s) }
        return (m, all)
    }

    private func run(_ k: AccelRun.Kind, _ all: [AccelRun]) throws -> AccelRun {
        try XCTUnwrap(all.first { $0.kind == k }, "\(k.rawValue) recorded")
    }

    func testStandingStartTimesWithRollout() throws {
        let (_, all) = runs(pull())
        let rollout = (2 * AccelMeter.rollout / 4).squareRoot()
        let z100 = try run(.zeroTo100, all)
        XCTAssertEqual(z100.timeNoRollout!, (100 / 3.6) / 4, accuracy: 0.01)
        XCTAssertEqual(z100.time, (100 / 3.6) / 4 - rollout, accuracy: 0.01)
        XCTAssertEqual(try run(.zeroTo60mph, all).timeNoRollout!, AccelMeter.mph60 / 4, accuracy: 0.01)
        XCTAssertEqual(try run(.hundredTo200, all).time, (100 / 3.6) / 4, accuracy: 0.01)
        let q = try run(.quarterMile, all)
        let tq = (2 * (AccelMeter.quarterMile + AccelMeter.rollout) / 4).squareRoot()
        XCTAssertEqual(q.time, tq - rollout, accuracy: 0.02)
        XCTAssertEqual(q.trapKmh!, tq * 4 * 3.6, accuracy: 0.5)
        XCTAssertTrue(z100.valid)
        XCTAssertEqual(z100.slopePct!, 0, accuracy: 0.01)
    }

    func testStartsOnlyFromAStop() {
        let rolling = pull().filter { $0.v > 5 }
        XCTAssertTrue(runs(rolling).1.isEmpty, "a rolling start is not a 0–100")
    }

    func testUphillIsFlaggedAndCorrected() throws {
        let (_, all) = runs(pull(grade: 0.02))
        let z = try run(.zeroTo100, all)
        XCTAssertEqual(z.slopePct!, 2, accuracy: 0.1)
        XCTAssertFalse(z.valid)
        XCTAssertLessThan(z.levelTime!, z.time, "uphill: quicker on the level")
    }

    func testPoorGPSIsFlagged() throws {
        let z = try run(.zeroTo100, runs(pull(hAcc: 15)).1)
        XCTAssertFalse(z.valid)
        XCTAssertTrue(z.issues.contains { $0.contains("accuracy") })
    }

    func testBrakingSixtyToZero() throws {
        // Cruise at 30 m/s, brake at 8 m/s² from t = 5.4.
        let s = (0..<15).map { i -> AccelSample in
            let t = Double(i)
            let v = t < 5.4 ? 30 : max(0, 30 - (t - 5.4) * 8)
            return AccelSample(t: t, v: v, alt: 500, hAcc: 3, vAcc: 3)
        }
        let b = try run(.brake60to0, runs(s).1)
        XCTAssertEqual(b.time, AccelMeter.mph60 / 8, accuracy: 0.05)
        XCTAssertEqual(b.distance, AccelMeter.mph60 * AccelMeter.mph60 / 16, accuracy: 1.5)
    }

    func testSpeedoCheck() {
        let (m, _) = runs(pull(obdScale: 1.04))
        XCTAssertEqual(m.speedoErrorPct ?? 0, 4, accuracy: 0.1)
    }
}

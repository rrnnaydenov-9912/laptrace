import XCTest
@testable import LaptraceLogger

final class LiveGTests: XCTestCase {
    /// Feeds the synthetic session in time order and checks the live reading against true car-frame g.
    func testLiveGCalibratesAndTracksTruth() {
        let data = SyntheticSession().generate()
        var g = LiveG()
        var mi = 0
        var errs: [Double] = []
        var ti = 0
        for fix in data.fixes {
            while mi < data.motion.count, data.motion[mi].t <= fix.t { g.add(data.motion[mi]); mi += 1 }
            g.add(fix)
            guard g.calibrated, let r = g.reading, r.fromIMU else { continue }
            while ti + 1 < data.truth.count, data.truth[ti + 1].t <= fix.t { ti += 1 }
            let truth = data.truth[ti]
            errs.append(max(abs(r.long - truth.long), abs(r.lat - truth.lat)))
        }
        XCTAssertTrue(g.calibrated)
        XCTAssertGreaterThan(g.rLong, 0.9)
        XCTAssertGreaterThan(g.rLat, 0.9)
        XCTAssertGreaterThan(errs.count, 100)
        XCTAssertLessThan(errs.sorted()[errs.count / 2], 0.05)
    }

    func testFallsBackToGPSBeforeCalibration() {
        let data = SyntheticSession().generate()
        var g = LiveG()
        var mi = 0
        for fix in data.fixes.prefix(5) {
            while mi < data.motion.count, data.motion[mi].t <= fix.t { g.add(data.motion[mi]); mi += 1 }
            g.add(fix)
        }
        XCTAssertFalse(g.calibrated)
        XCTAssertEqual(g.reading?.fromIMU, false)
    }
}

import XCTest
@testable import LaptraceLogger

final class ExporterTests: XCTestCase {
    func testSyntheticRingRecoversLapsAndGForces() throws {
        let synth = SyntheticSession()
        let data = synth.generate()
        let result = try XCTUnwrap(Exporter().export(fixes: data.fixes, motion: data.motion, track: synth.track))

        // Laps: same count as truth, each within 0.25 s.
        XCTAssertEqual(result.summary.laps.count, data.lapTimes.count)
        for (lap, truth) in zip(result.summary.laps, data.lapTimes) {
            XCTAssertEqual(lap.duration, truth, accuracy: 0.25)
        }

        // IMU calibration should lock on and keep the sign: right-hand ring → positive lateral.
        XCTAssertTrue(result.summary.calibration.calibrated)
        XCTAssertGreaterThan(result.summary.calibration.lateralCorrelation, 0.8)

        let rows = result.csv.split(separator: "\n").drop { !$0.hasPrefix("Time,") }
        let header = rows.first!.split(separator: ",").map(String.init)
        let latIdx = try XCTUnwrap(header.firstIndex(of: "Lateral (g)"))
        let lats = rows.dropFirst().compactMap { Double($0.split(separator: ",")[latIdx]) }
        let mean = lats.reduce(0, +) / Double(lats.count)
        XCTAssertGreaterThan(mean, 0.2)
    }

    func testGateCrossingDirection() {
        let gate = Gate.perpendicular(id: "sf", label: "SF", through: LatLon(lat: 42, lon: 23), travelBearing: 90)
        let det = GateDetector(gates: [gate])
        let proj = LocalProjection(origin: LatLon(lat: 42, lon: 23))
        let west = TimedPoint(t: 0, p: proj.unproject(Vec2(x: -10, y: 0)))
        let east = TimedPoint(t: 1, p: proj.unproject(Vec2(x: 10, y: 0)))
        XCTAssertEqual(det.crossings(from: west, to: east).first?.t ?? -1, 0.5, accuracy: 0.01)
        XCTAssertTrue(det.crossings(from: east, to: west).isEmpty)
    }

    func testMotionRoundTrip() {
        let s = MotionSample(t: 1_760_000_000.123456, accel: Vec3(x: 0.1, y: -0.2, z: 0.3),
                             gravity: Vec3(x: 0, y: 0, z: -1), rotation: Vec3(x: 1, y: 2, z: 3))
        var d = Data()
        s.append(to: &d)
        let back = MotionSample.decodeAll(d)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].t, s.t)
        XCTAssertEqual(back[0].accel.y, -0.2, accuracy: 1e-6)
    }
}

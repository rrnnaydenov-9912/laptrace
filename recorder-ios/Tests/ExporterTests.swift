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

final class OBDExportTests: XCTestCase {
    func testOBDSampleRoundTrip() {
        let s = OBDSample(t: 1_760_000_000.25, pids: [0x0C: 6200, 0x05: 92, 0x49: 100])
        let back = OBDSample(csvLine: Substring(s.csvLine.trimmingCharacters(in: .newlines)))
        XCTAssertEqual(back?.rpm, 6200)
        XCTAssertEqual(back?.coolant, 92)
        XCTAssertEqual(back?.pedal, 100)
        XCTAssertNil(back?.oil, "missing PIDs stay empty, not zero")
    }

    func testOBDColumnsOnlyWhenRecorded() throws {
        let synth = SyntheticSession()
        let data = synth.generate()
        let plain = try XCTUnwrap(Exporter().export(fixes: data.fixes, motion: data.motion, track: synth.track))
        XCTAssertFalse(plain.csv.contains("RPM"))

        let t0 = data.fixes[0].t
        let obd = (0..<200).map { i in OBDSample(t: t0 + Double(i) * 0.25, pids: [0x0C: 3000 + Double(i) * 10, 0x05: 90]) }
        let csv = try XCTUnwrap(Exporter().export(fixes: data.fixes, motion: data.motion, track: synth.track, obd: obd)).csv
        let rows = csv.split(separator: "\n").drop { !$0.hasPrefix("Time,") }
        let header = rows.first!.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let rpm = try XCTUnwrap(header.firstIndex(of: "RPM"))
        let oil = header.firstIndex { $0.hasPrefix("Oil") }
        XCTAssertNil(oil, "oil never reported → no oil column")
        let values = rows.dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false) }
        let firstRPM = values.compactMap { Double($0[rpm]) }
        XCTAssertFalse(firstRPM.isEmpty)
        XCTAssertTrue(firstRPM.allSatisfy { (3000...5000).contains($0) })
        // After the OBD log ends (50 s in) the cells go empty instead of holding stale values.
        XCTAssertTrue(values.suffix(20).allSatisfy { $0[rpm].isEmpty })
    }
}

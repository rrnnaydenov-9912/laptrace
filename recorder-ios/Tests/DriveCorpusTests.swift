import XCTest
@testable import LaptraceLogger

final class DriveCorpusTests: XCTestCase {
    private let metresPerDegLat = 111_195.0

    /// Speed profile in m/s at 1 Hz: pull away to 10 m/s and hold 15 s, accelerate at `accel` g to
    /// `cruise`, hold it `hold` s, then brake at `brake` g to a stop.
    private func speeds(accel: Double = 0.2, brake: Double = 0.2, cruise: Double = 25, hold: Int = 30) -> [Double] {
        var v: [Double] = [0, 2, 4, 6, 8, 10] + Array(repeating: 10, count: 15)
        while v.last! < cruise { v.append(min(cruise, v.last! + accel * DriveCorpus.g)) }
        v += Array(repeating: cruise, count: hold)
        while v.last! > 0 { v.append(max(0, v.last! - brake * DriveCorpus.g)) }
        return v
    }

    /// 1 Hz fixes driving north along `speeds`, positions integrated from the speeds.
    private func fixes(_ speeds: [Double], t0: Double = 0) -> [GPSFix] {
        var y = 0.0, prev = speeds.first ?? 0
        return speeds.enumerated().map { i, v in
            y += (prev + v) / 2
            prev = v
            return GPSFix(t: t0 + Double(i), lat: 42.7 + y / metresPerDegLat, lon: 23.3, alt: 550,
                          hAcc: 5, speed: v, course: 0)
        }
    }

    /// Stats for an earlier drive, built directly.
    private func stats(_ id: String, brake: Double = 0.2, accel: Double = 0.2, kmh: Double = 50, jerk: Double = 0.05,
                       harshBrakes: Int = 0, km: Double = 10, moving: Double = 600) -> DriveStats {
        DriveStats(id: id, distance: km * 1000, movingTime: moving, avgKmh: kmh, p95Kmh: kmh * 1.5,
                   accelG: accel, brakeG: brake, jerk: jerk, harshBrakes: harshBrakes, harshAccels: 0)
    }

    private func history(_ count: Int = 5) -> [DriveStats] { (0..<count).map { stats("d\($0)") } }

    // MARK: stats

    func testRecoversBrakingAndAcceleration() throws {
        let s = try XCTUnwrap(DriveCorpus.stats(id: "a", fixes: fixes(speeds())))
        XCTAssertEqual(s.brakeG, 0.2, accuracy: 0.01)
        XCTAssertEqual(s.accelG, 0.2, accuracy: 0.01)
        XCTAssertEqual(s.harshBrakes, 0)
        XCTAssertGreaterThan(s.distance, DriveCorpus.minDistance)
    }

    func testParkedPrefixIsDroppedByTheGate() throws {
        // A minute parked with the position hopping 3 m back and forth would add ~180 m if it counted.
        let parked = (0..<60).map { i in
            GPSFix(t: Double(i), lat: 42.7 + (i.isMultiple(of: 2) ? 0 : 3) / metresPerDegLat, lon: 23.3,
                   alt: 550, hAcc: 5, speed: 0, course: -1)
        }
        let alone = try XCTUnwrap(DriveCorpus.stats(id: "a", fixes: fixes(speeds())))
        let withParked = try XCTUnwrap(DriveCorpus.stats(id: "b", fixes: parked + fixes(speeds(), t0: 60)))
        XCTAssertEqual(withParked.distance, alone.distance, accuracy: 1)
    }

    func testParkedOnlyIsNotADrive() {
        let parked = (0..<600).map { i in
            GPSFix(t: Double(i), lat: 42.7 + (i.isMultiple(of: 2) ? 0 : 3) / metresPerDegLat, lon: 23.3,
                   alt: 550, hAcc: 5, speed: 0, course: -1)
        }
        XCTAssertNil(DriveCorpus.stats(id: "a", fixes: parked))
    }

    func testDriveUnder500MetresIsNil() {
        // Up to 54 km/h for a few seconds: about 250 m after the gate.
        XCTAssertNil(DriveCorpus.stats(id: "a", fixes: fixes(speeds(cruise: 15, hold: 5))))
    }

    func testHarshBrakeCountedOnce() throws {
        // One stop at 0.45 g spans several samples over the 0.35 g threshold but is one event.
        let s = try XCTUnwrap(DriveCorpus.stats(id: "a", fixes: fixes(speeds(brake: 0.45))))
        XCTAssertEqual(s.harshBrakes, 1)
        XCTAssertEqual(s.brakeG, 0.45, accuracy: 0.01)
    }

    // MARK: baseline

    func testOutlierIsDroppedFromBaseline() throws {
        let brakes = [0.18, 0.19, 0.2, 0.2, 0.2, 0.21, 0.22, 0.19, 0.21, 0.6]
        let b = try XCTUnwrap(DriveCorpus.baseline(from: brakes.enumerated().map { stats("d\($0)", brake: $1) }))
        XCTAssertEqual(b.count, 9)
        XCTAssertEqual(b.brakeG, 0.2, accuracy: 0.001)
    }

    func testBaselineUsesLast10DrivesWithAMinuteMoving() {
        // d13 moved for only 30 s, so the last 10 that count are d4…d12 and d14.
        let all = (0..<15).map { stats("d\($0)", moving: $0 == 13 ? 30 : 600) }
        XCTAssertEqual(DriveCorpus.baselineDrives(from: all).map(\.id),
                       ["d4", "d5", "d6", "d7", "d8", "d9", "d10", "d11", "d12", "d14"])
    }

    // MARK: insights

    func testFewerThan3DrivesIsNotEnough() {
        XCTAssertEqual(DriveCorpus.insights(for: stats("x"), history: history(2)),
                       ["Not enough drives yet for a baseline (2 of 3)"])
    }

    func testOutlierLeavingTooFewDrivesIsNotEnough() {
        let h = [stats("d0", brake: 0.19), stats("d1", brake: 0.2), stats("d2", brake: 0.6)]
        XCTAssertEqual(DriveCorpus.insights(for: stats("x"), history: h),
                       ["Not enough drives yet for a baseline (2 of 3)"])
    }

    func testInsightsAgainstBaseline() {
        XCTAssertEqual(DriveCorpus.insights(for: stats("x", brake: 0.4, accel: 0.21, kmh: 60, jerk: 0.03), history: history()), [
            "Braking 0.20 g harder than your usual (0.20 g)",
            "Acceleration in line with your usual (0.20 g)",
            "Smoother than all of your last 5 drives",
            "Average 60 km/h vs your usual 50 km/h",
            "No harsh braking (over 0.35 g), in line with your usual",
        ])
    }

    func testSofterBraking() {
        XCTAssertEqual(DriveCorpus.insights(for: stats("x", brake: 0.1), history: history()).first,
                       "Braking 0.10 g softer than your usual (0.20 g)")
    }

    func testSmoothnessAgainstRecentDrives() {
        let h = [0.05, 0.06, 0.07, 0.08, 0.09].enumerated().map { stats("d\($0)", jerk: $1) }
        XCTAssertEqual(DriveCorpus.insights(for: stats("x", jerk: 0.2), history: h)[2],
                       "Less smooth than all of your last 5 drives")
        XCTAssertEqual(DriveCorpus.insights(for: stats("x", jerk: 0.065), history: h)[2],
                       "Smoother than 3 of your last 5 drives")
    }

    func testHarshBrakeRate() {
        // 2 harsh brakes over 10 km against a history with none.
        XCTAssertEqual(DriveCorpus.insights(for: stats("x", harshBrakes: 2), history: history()).last,
                       "2.0 harsh brakes per 10 km vs your usual 0.0")
    }

    // MARK: percentile

    func testPercentileAndMedian() {
        XCTAssertEqual(DriveCorpus.percentile([], 0.5), 0)
        XCTAssertEqual(DriveCorpus.median([3, 1, 2]), 2)
        XCTAssertEqual(DriveCorpus.median([1, 2, 3, 4]), 2.5)
        XCTAssertEqual(DriveCorpus.percentile([0, 10], 0.95), 9.5, accuracy: 1e-9)
    }
}

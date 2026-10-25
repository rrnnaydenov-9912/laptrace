import XCTest
@testable import LaptraceLogger

final class DriveStartGateTests: XCTestCase {
    private let metresPerDegLat = 111_195.0

    /// 1 Hz fixes driving north at `kmh`, `count` fixes long. `speed` overrides the reported speed.
    private func drive(kmh: Double, count: Int, reported: Double? = nil, hAcc: Double = 5) -> [GPSFix] {
        let v = kmh / 3.6
        return (0..<count).map { i in
            GPSFix(t: Double(i), lat: 42.7 + Double(i) * v / metresPerDegLat, lon: 23.3, alt: 550,
                   hAcc: hAcc, speed: reported ?? v, course: 0)
        }
    }

    private func feed(_ fixes: [GPSFix]) -> DriveStartGate {
        var g = DriveStartGate()
        for f in fixes { g.add(f) }
        return g
    }

    func testBelow100MetresDoesNotStart() {
        // 30 km/h for 10 s ≈ 75 m.
        let g = feed(drive(kmh: 30, count: 10))
        XCTAssertFalse(g.passed)
        XCTAssertLessThan(g.distance, 100)
    }

    func testAtOrBelow10KmhDoesNotStart() {
        // 10 km/h for 2 minutes covers 330 m but never goes faster than 10 km/h.
        XCTAssertFalse(feed(drive(kmh: 10, count: 120)).passed)
        XCTAssertFalse(feed(drive(kmh: 8, count: 200)).passed)
    }

    func testDistanceAndSpeedBothPassingStarts() {
        let fixes = drive(kmh: 50, count: 30)   // 13.9 m/s
        var g = DriveStartGate(), firstPass: Int?
        for (i, f) in fixes.enumerated() where g.add(f) && firstPass == nil { firstPass = i }
        XCTAssertTrue(g.passed)
        // 7 steps reach 97 m, 8 steps 111 m: the 9th fix is the first past 100 m.
        XCTAssertEqual(firstPass, 8)
        XCTAssertGreaterThanOrEqual(g.distance, 100)
    }

    func testStaysPassedWhenTheCarStops() {
        var g = feed(drive(kmh: 36, count: 30))
        XCTAssertTrue(g.add(GPSFix(t: 100, lat: 42.71, lon: 23.3, alt: 550, hAcc: 5, speed: 0, course: 0)))
    }

    func testCrawlThenSpeedUpStartsOnceFastEnough() {
        // 300 m at 9 km/h never starts; the first fix above 10 km/h after that does.
        let slow = drive(kmh: 9, count: 120)
        var g = feed(slow)
        XCTAssertFalse(g.passed)
        let last = slow.last!
        XCTAssertTrue(g.add(GPSFix(t: last.t + 1, lat: last.lat + 5 / metresPerDegLat, lon: 23.3, alt: 550,
                                   hAcc: 5, speed: 20 / 3.6, course: 0)))
    }

    func testParkedGPSJitterNeverStarts() {
        // Ten minutes parked: position wanders ±5 m, reported speed 0–1 m/s (≤ 3.6 km/h).
        var rng = SystemRandomNumberGenerator()
        let fixes = (0..<600).map { i in
            GPSFix(t: Double(i),
                   lat: 42.7 + Double.random(in: -5...5, using: &rng) / metresPerDegLat,
                   lon: 23.3 + Double.random(in: -5...5, using: &rng) / (metresPerDegLat * cos(42.7 * .pi / 180)),
                   alt: 550, hAcc: Double.random(in: 4...25, using: &rng),
                   speed: Double.random(in: 0...1, using: &rng), course: -1)
        }
        let g = feed(fixes)
        XCTAssertFalse(g.passed)
        XCTAssertLessThan(g.distance, 20)
    }

    func testParkedJitterWithoutReportedSpeedNeverStarts() {
        // Speed invalid (-1): a 4 m hop every second implies 14 km/h, but the car never leaves its spot.
        let fixes = (0..<600).map { i in
            GPSFix(t: Double(i), lat: 42.7 + (i.isMultiple(of: 2) ? 2 : -2) / metresPerDegLat, lon: 23.3,
                   alt: 550, hAcc: 10, speed: -1, course: -1)
        }
        XCTAssertFalse(feed(fixes).passed)
    }

    func testInaccurateFixesAreIgnored() {
        XCTAssertFalse(feed(drive(kmh: 50, count: 60, hAcc: 45)).passed)
        XCTAssertFalse(feed(drive(kmh: 50, count: 60, hAcc: -1)).passed)
    }

    func testPureRule() {
        XCTAssertFalse(DriveStartGate.passes(distance: 99.9, kmh: 50))
        XCTAssertFalse(DriveStartGate.passes(distance: 500, kmh: 10))
        XCTAssertTrue(DriveStartGate.passes(distance: 100, kmh: 10.1))
    }
}

import XCTest
@testable import LaptraceLogger

final class CoachTests: XCTestCase {
    private func ringLaps() -> (laps: [Coach.Lap], truth: [Double]) {
        let synth = SyntheticSession()
        let data = synth.generate()
        return (Exporter().coachLaps(fixes: data.fixes, track: synth.track), data.lapTimes)
    }

    func testDebriefOnSyntheticSession() throws {
        let (laps, truth) = ringLaps()
        let d = try XCTUnwrap(Coach.debrief(laps, trackName: "Synthetic ring"))
        XCTAssertEqual(d.stats.timedLaps, truth.count)
        XCTAssertEqual(d.stats.bestLap, truth.min()!, accuracy: 0.25)
        XCTAssertLessThan(d.stats.lapSD, 0.3)
        XCTAssertNotNil(d.stats.bestThreeAverage)
        XCTAssertFalse(d.goal.title.isEmpty)
        XCTAssertFalse(d.goal.text.isEmpty)
        XCTAssertTrue(Coach.numbersAreGrounded(d.goal.text, facts: d.factsJSON))
    }

    func testDebriefIsDeterministic() throws {
        let a = try XCTUnwrap(Coach.debrief(ringLaps().laps))
        let b = try XCTUnwrap(Coach.debrief(ringLaps().laps))
        XCTAssertEqual(a, b)
    }

    func testNumberCheckRejectsInventedNumbers() {
        let facts = #"{"bestLap":"1:12.412","goalText":"Corner 3: your best lap carried 62 km/h at the slowest point; your average was 57 km/h."}"#
        XCTAssertTrue(Coach.numbersAreGrounded("In corner 3 you managed 62 km/h on your best lap but usually 57 km/h.", facts: facts))
        XCTAssertFalse(Coach.numbersAreGrounded("In corner 3 aim for 65 km/h.", facts: facts))
        XCTAssertFalse(Coach.numbersAreGrounded("Your best was 1:12.4.", facts: facts))
    }

    // MARK: - Skill ladder on a simple oval: two 200 m straights, two 50 m-radius hairpins.

    private func ovalLap(_ number: Int, cornerSpeed: Double, brakeEarly: Double = 0) -> Coach.Lap {
        let r = 50.0, straight = 200.0, arc = .pi * r
        let length = 2 * straight + 2 * arc
        let vs = 35.0
        func speed(_ s: Double) -> Double {
            for entry in [straight, 2 * straight + arc] {
                let exit = entry + arc, ramp = 30 + brakeEarly
                if s >= entry && s <= exit { return cornerSpeed }
                if s < entry && s > entry - ramp { return vs + (cornerSpeed - vs) * (s - (entry - ramp)) / ramp }
                if s > exit && s < exit + 40 { return cornerSpeed + (vs - cornerSpeed) * (s - exit) / 40 }
            }
            return vs
        }
        func point(_ s: Double) -> (Double, Double) {
            if s < straight { return (s, -r) }
            if s < straight + arc { let a = -Double.pi / 2 + (s - straight) / r; return (straight + r * cos(a), r * sin(a)) }
            if s < 2 * straight + arc { return (straight - (s - straight - arc), r) }
            let a = Double.pi / 2 + (s - 2 * straight - arc) / r
            return (r * cos(a), r * sin(a))
        }
        var lap = Coach.Lap(number: number, duration: 0, t: [], x: [], y: [], speed: [])
        var s = 0.0, t = 0.0
        while s < length {
            let (x, y) = point(s)
            lap.t.append(t); lap.x.append(x); lap.y.append(y); lap.speed.append(speed(s))
            s += speed(s) * 0.1
            t += 0.1
        }
        lap.duration = t
        return lap
    }

    func testOvalFindsTwoCorners() {
        let g = Coach.resample(ovalLap(1, cornerSpeed: 20))
        let corners = Coach.detectCorners(g)
        XCTAssertEqual(corners.count, 2)
        for c in corners { XCTAssertEqual(c.angle, 180, accuracy: 25) }
    }

    func testInconsistentLapsGiveConsistencyGoal() throws {
        let laps = [20.0, 16, 19, 14].enumerated().map { ovalLap($0.offset + 1, cornerSpeed: $0.element) }
        let d = try XCTUnwrap(Coach.debrief(laps))
        XCTAssertGreaterThan(d.stats.lapSD, 1.2)
        XCTAssertEqual(d.goal.kind, .consistency)
    }

    func testSlowerCornersGiveCornerSpeedGoal() throws {
        let laps = [ovalLap(1, cornerSpeed: 19), ovalLap(2, cornerSpeed: 20), ovalLap(3, cornerSpeed: 19), ovalLap(4, cornerSpeed: 19)]
        let d = try XCTUnwrap(Coach.debrief(laps))
        XCTAssertEqual(d.stats.bestLapNumber, 2)
        XCTAssertEqual(d.goal.kind, .cornerSpeed)
        XCTAssertTrue(d.goal.text.contains("72 km/h"), d.goal.text)
        XCTAssertTrue(d.goal.text.contains("68 km/h"), d.goal.text)
    }

    func testLaterBrakingGivesBrakingGoal() throws {
        let laps = [ovalLap(1, cornerSpeed: 20, brakeEarly: 25), ovalLap(2, cornerSpeed: 20), ovalLap(3, cornerSpeed: 20, brakeEarly: 25)]
        let d = try XCTUnwrap(Coach.debrief(laps))
        XCTAssertEqual(d.goal.kind, .braking)
        XCTAssertNotNil(d.goal.corner)
    }

    // MARK: - Spoken cue and CSV metadata

    func testSpokenLapPhrase() {
        XCTAssertEqual(LapCue.phrase(duration: 72.41, previousBest: 71.8), "1 12.4. Plus 0.6.")
        XCTAssertEqual(LapCue.phrase(duration: 65.2, previousBest: nil), "1 oh 5.2.")
        XCTAssertEqual(LapCue.phrase(duration: 70.0, previousBest: 70.3), "1 10.0. Best lap. Minus 0.3.")
    }

    func testMetadataQuoting() throws {
        XCTAssertEqual(Exporter.quoted("Fast, \"wet\"\nday"), "\"Fast, \"\"wet\"\" day\"")
        let synth = SyntheticSession()
        let data = synth.generate()
        var ex = Exporter()
        ex.options.extraMeta = [("Driver", "Ana, \"Ace\""), ("Vehicle", "Civic"), ("Notes", ""), ("Video Start UTC", "2026-10-11T10:00:00Z")]
        let csv = try XCTUnwrap(ex.export(fixes: data.fixes, motion: data.motion, track: synth.track)).csv
        let head = csv.components(separatedBy: "\n\n")[0]
        XCTAssertTrue(head.contains("Driver,\"Ana, \"\"Ace\"\"\"\n"))
        XCTAssertTrue(head.contains("Vehicle,\"Civic\""))
        XCTAssertTrue(head.contains("Video Start UTC,\"2026-10-11T10:00:00Z\""))
        XCTAssertFalse(head.contains("Notes"))
    }

    func testDriveMetadata() throws {
        var meta = SessionMeta(id: "x", started: Date())
        XCTAssertEqual(meta.csvMeta.first?.key, "Mode")
        XCTAssertEqual(meta.csvMeta.first?.value, "Track")
        meta.mode = "drive"
        meta.trackName = "Ring"
        XCTAssertTrue(meta.isDrive)
        XCTAssertEqual(meta.title, "Drive")
        let synth = SyntheticSession()
        let data = synth.generate()
        var ex = Exporter()
        ex.options.extraMeta = meta.csvMeta
        let csv = try XCTUnwrap(ex.export(fixes: data.fixes, motion: data.motion, track: nil)).csv
        XCTAssertTrue(csv.components(separatedBy: "\n\n")[0].contains("Mode,\"Drive\""))
    }
}

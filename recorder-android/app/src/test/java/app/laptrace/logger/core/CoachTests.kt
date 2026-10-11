package app.laptrace.logger.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import kotlin.math.cos
import kotlin.math.sin

class CoachTests {
    private fun ringLaps(): Pair<List<Coach.Lap>, List<Double>> {
        val synth = SyntheticSession()
        val data = synth.generate()
        return Exporter().coachLaps(data.fixes, synth.track) to data.lapTimes
    }

    @Test
    fun debriefOnSyntheticSession() {
        val (laps, truth) = ringLaps()
        val d = assertNotNullReturn(Coach.debrief(laps, "Synthetic ring"))
        assertEquals(truth.size, d.stats.timedLaps)
        assertEquals(truth.min(), d.stats.bestLap, 0.25)
        assertTrue(d.stats.lapSD < 0.3)
        assertNotNull(d.stats.bestThreeAverage)
        assertFalse(d.goal.title.isEmpty())
        assertFalse(d.goal.text.isEmpty())
        assertTrue(Coach.numbersAreGrounded(d.goal.text, d.factsJSON))
    }

    @Test
    fun debriefIsDeterministic() {
        val a = assertNotNullReturn(Coach.debrief(ringLaps().first))
        val b = assertNotNullReturn(Coach.debrief(ringLaps().first))
        assertEquals(a, b)
    }

    @Test
    fun numberCheckRejectsInventedNumbers() {
        val facts = """{"bestLap":"1:12.412","goalText":"Corner 3: your best lap carried 62 km/h at the slowest point; your average was 57 km/h."}"""
        assertTrue(Coach.numbersAreGrounded("In corner 3 you managed 62 km/h on your best lap but usually 57 km/h.", facts))
        assertFalse(Coach.numbersAreGrounded("In corner 3 aim for 65 km/h.", facts))
        assertFalse(Coach.numbersAreGrounded("Your best was 1:12.4.", facts))
    }

    // Skill ladder on a simple oval: two 200 m straights, two 50 m-radius hairpins.

    private fun ovalLap(number: Int, cornerSpeed: Double, brakeEarly: Double = 0.0): Coach.Lap {
        val r = 50.0
        val straight = 200.0
        val arc = Math.PI * r
        val length = 2 * straight + 2 * arc
        val vs = 35.0
        fun speed(s: Double): Double {
            for (entry in listOf(straight, 2 * straight + arc)) {
                val exit = entry + arc
                val ramp = 30 + brakeEarly
                if (s >= entry && s <= exit) return cornerSpeed
                if (s < entry && s > entry - ramp) return vs + (cornerSpeed - vs) * (s - (entry - ramp)) / ramp
                if (s > exit && s < exit + 40) return cornerSpeed + (vs - cornerSpeed) * (s - exit) / 40
            }
            return vs
        }
        fun point(s: Double): Pair<Double, Double> {
            if (s < straight) return s to -r
            if (s < straight + arc) { val a = -Math.PI / 2 + (s - straight) / r; return (straight + r * cos(a)) to (r * sin(a)) }
            if (s < 2 * straight + arc) return (straight - (s - straight - arc)) to r
            val a = Math.PI / 2 + (s - 2 * straight - arc) / r
            return (r * cos(a)) to (r * sin(a))
        }
        val t = ArrayList<Double>(); val x = ArrayList<Double>(); val y = ArrayList<Double>(); val v = ArrayList<Double>()
        var s = 0.0
        var tt = 0.0
        while (s < length) {
            val (px, py) = point(s)
            t.add(tt); x.add(px); y.add(py); v.add(speed(s))
            s += speed(s) * 0.1
            tt += 0.1
        }
        return Coach.Lap(number, tt, t.toDoubleArray(), x.toDoubleArray(), y.toDoubleArray(), v.toDoubleArray())
    }

    @Test
    fun ovalFindsTwoCorners() {
        val g = Coach.resample(ovalLap(1, 20.0))
        val corners = Coach.detectCorners(g)
        assertEquals(2, corners.size)
        for (c in corners) assertEquals(180.0, c.angle, 25.0)
    }

    @Test
    fun inconsistentLapsGiveConsistencyGoal() {
        val laps = listOf(20.0, 16.0, 19.0, 14.0).mapIndexed { i, cs -> ovalLap(i + 1, cs) }
        val d = assertNotNullReturn(Coach.debrief(laps))
        assertTrue(d.stats.lapSD > 1.2)
        assertEquals(Coach.GoalKind.CONSISTENCY, d.goal.kind)
    }

    @Test
    fun slowerCornersGiveCornerSpeedGoal() {
        val laps = listOf(ovalLap(1, 19.0), ovalLap(2, 20.0), ovalLap(3, 19.0), ovalLap(4, 19.0))
        val d = assertNotNullReturn(Coach.debrief(laps))
        assertEquals(2, d.stats.bestLapNumber)
        assertEquals(Coach.GoalKind.CORNER_SPEED, d.goal.kind)
        assertTrue(d.goal.text, d.goal.text.contains("72 km/h"))
        assertTrue(d.goal.text, d.goal.text.contains("68 km/h"))
    }

    @Test
    fun laterBrakingGivesBrakingGoal() {
        val laps = listOf(ovalLap(1, 20.0, 25.0), ovalLap(2, 20.0), ovalLap(3, 20.0, 25.0))
        val d = assertNotNullReturn(Coach.debrief(laps))
        assertEquals(Coach.GoalKind.BRAKING, d.goal.kind)
        assertNotNull(d.goal.corner)
    }

    // Spoken cue and CSV metadata

    @Test
    fun spokenLapPhrase() {
        assertEquals("1 12.4. Plus 0.6.", LapCuePhrase.phrase(72.41, 71.8))
        assertEquals("1 oh 5.2.", LapCuePhrase.phrase(65.2, null))
        assertEquals("1 10.0. Best lap. Minus 0.3.", LapCuePhrase.phrase(70.0, 70.3))
    }

    @Test
    fun metadataQuoting() {
        assertEquals("\"Fast, \"\"wet\"\" day\"", Exporter.quoted("Fast, \"wet\"\nday"))
        val synth = SyntheticSession()
        val data = synth.generate()
        val ex = Exporter(Exporter.Options(extraMeta = listOf(
            "Driver" to "Ana, \"Ace\"", "Vehicle" to "Civic", "Notes" to "", "Video Start UTC" to "2026-10-11T10:00:00Z",
        )))
        val csv = assertNotNullReturn(ex.export(data.fixes, data.motion, synth.track)).csv
        val head = csv.split("\n\n")[0]
        assertTrue(head.contains("Driver,\"Ana, \"\"Ace\"\"\"\n"))
        assertTrue(head.contains("Vehicle,\"Civic\""))
        assertTrue(head.contains("Video Start UTC,\"2026-10-11T10:00:00Z\""))
        assertFalse(head.contains("Notes"))
    }

    @Test
    fun driveMetadata() {
        var meta = SessionMeta(id = "x", started = Instant.now())
        assertEquals("Mode", meta.csvMeta.first().first)
        assertEquals("Track", meta.csvMeta.first().second)
        meta = meta.copy(mode = "drive", trackName = "Ring")
        assertTrue(meta.isDrive)
        assertEquals("Drive", meta.title)
        assertEquals("Laptrace_Drive_x.csv", meta.exportFileName)
        val synth = SyntheticSession()
        val data = synth.generate()
        val ex = Exporter(Exporter.Options(extraMeta = meta.csvMeta))
        val csv = assertNotNullReturn(ex.export(data.fixes, data.motion, null)).csv
        assertTrue(csv.split("\n\n")[0].contains("Mode,\"Drive\""))
    }
}

package app.laptrace.logger.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ExporterTests {
    @Test
    fun syntheticRingRecoversLapsAndGForces() {
        val synth = SyntheticSession()
        val data = synth.generate()
        val result = assertNotNullReturn(Exporter().export(data.fixes, data.motion, synth.track))

        // Laps: same count as truth, each within 0.25 s.
        assertEquals(data.lapTimes.size, result.summary.laps.size)
        for ((lap, truth) in result.summary.laps.zip(data.lapTimes)) {
            assertEquals(truth, lap.duration, 0.25)
        }

        // IMU calibration should lock on and keep the sign: right-hand ring → positive lateral.
        assertTrue(result.summary.calibration.calibrated)
        assertTrue(result.summary.calibration.lateralCorrelation > 0.8)

        val rows = result.csv.split("\n").dropWhile { !it.startsWith("Time,") }
        val header = rows.first().split(",")
        val latIdx = header.indexOf("Lateral (g)")
        assertTrue(latIdx >= 0)
        val lats = rows.drop(1).filter { it.isNotEmpty() }.mapNotNull { it.split(",")[latIdx].toDoubleOrNull() }
        val mean = lats.sum() / lats.size
        assertTrue("mean lateral $mean", mean > 0.2)
    }

    @Test
    fun gateCrossingDirection() {
        val gate = Gate.perpendicular("sf", "SF", LatLon(42.0, 23.0), 90.0)
        val det = GateDetector(listOf(gate))
        val proj = LocalProjection(LatLon(42.0, 23.0))
        val west = TimedPoint(0.0, proj.unproject(Vec2(-10.0, 0.0)))
        val east = TimedPoint(1.0, proj.unproject(Vec2(10.0, 0.0)))
        assertEquals(0.5, det.crossings(west, east).firstOrNull()?.t ?: -1.0, 0.01)
        assertTrue(det.crossings(east, west).isEmpty())
    }

    @Test
    fun motionRoundTrip() {
        val s = MotionSample(1_760_000_000.123456, Vec3(0.1, -0.2, 0.3), Vec3(0.0, 0.0, -1.0), Vec3(1.0, 2.0, 3.0))
        val back = MotionSample.decodeAll(s.toBytes())
        assertEquals(1, back.size)
        assertEquals(s.t, back[0].t, 0.0)
        assertEquals(-0.2, back[0].accel.y, 1e-6)
    }

    @Test
    fun gpsLineRoundTrip() {
        val f = GPSFix(1_760_000_000.25, 42.1234567, 23.7654321, 600.5, 4.0, 22.5, 91.0)
        val back = assertNotNullReturn(GPSFix.parse(f.csvLine.trim()))
        assertEquals(f.lat, back.lat, 1e-7)
        assertEquals(f.speed, back.speed, 1e-6)
    }

    @Test
    fun printfStyleFormatting() {
        assertEquals("1.000", fmt(1.0, 3))
        assertEquals("2", fmt(2.5, 0)) // printf rounds exact ties to even
        assertEquals("-0.000", fmt(-0.0001, 3))
        assertEquals("0", fmt(Double.NaN, 0))
        assertEquals("1:05.200", Fmt.lap(65.2))
        assertEquals("−0.30", Fmt.delta(-0.3))
        assertEquals("+0.60", Fmt.delta(0.6))
        assertEquals("950 m", Fmt.km(950.0))
        assertEquals("12.3 km", Fmt.km(12_345.0))
        assertEquals("1:01:01", Fmt.duration(3661.0))
    }
}

fun <T> assertNotNullReturn(v: T?): T {
    assertNotNull(v)
    return v!!
}

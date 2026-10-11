package app.laptrace.logger.core

import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.sin

/**
 * Synthetic session: a car lapping a circle clockwise at varying speed, with a
 * phone mounted at an arbitrary tilt/yaw. Used to check that the exporter
 * recovers laps and car-frame g-forces from 1 Hz GPS + 50 Hz IMU.
 */
class SyntheticSession(
    val center: LatLon = LatLon(42.3155, 23.5385),
    val radius: Double = 120.0,
    val laps: Int = 4,
    val t0: Double = 1_760_000_000.0,
    /** Phone orientation: yaw then pitch then roll (degrees), applied car→phone. */
    val mountYaw: Double = 37.0,
    val mountPitch: Double = -25.0,
    val mountRoll: Double = 12.0,
) {
    /** Lap speed profile (m/s) as a function of angle around the circle. */
    fun speed(theta: Double): Double = 22 + 6 * sin(2 * theta)

    val track: Track
        get() {
            // Start/finish across the circle at its northernmost point; travel is clockwise → east (90°).
            val proj = LocalProjection(center)
            val p = proj.unproject(Vec2(0.0, radius))
            val sf = Gate.perpendicular("sf", "Start / Finish", p, 90.0)
            return Track(id = "synthetic", name = "Synthetic ring", country = null, center = center, radiusMeters = 2000.0, gates = listOf(sf))
        }

    data class Truth(val t: Double, val long: Double, val lat: Double)

    class Data(val fixes: List<GPSFix>, val motion: List<MotionSample>, val truth: List<Truth>, val lapTimes: List<Double>)

    fun generate(): Data {
        val proj = LocalProjection(center)
        val dt = 0.001
        // Start just before the line (theta measured clockwise from north).
        var theta = -0.4
        var t = t0
        val lapTimes = ArrayList<Double>()
        var lastLap: Double? = null
        val fixes = ArrayList<GPSFix>()
        val motion = ArrayList<MotionSample>()
        val truth = ArrayList<Truth>()
        var nextFix = t0
        var nextMotion = t0
        var prevV = speed(theta)
        val end = 2 * Math.PI * laps + 0.6
        while (theta < end) {
            val v = speed(theta)
            val long = (v - prevV) / dt / 9.80665
            prevV = v
            val lat = v * v / radius / 9.80665 // clockwise = right turn = positive
            if (t >= nextMotion) {
                // Car frame: x forward, y right, z up. Phone sees R * (car vector).
                val carAcc = Vec3(long, lat, 0.0)
                val carGrav = Vec3(0.0, 0.0, -1.0)
                motion.add(MotionSample(t, rotate(carAcc), rotate(carGrav), Vec3.ZERO))
                truth.add(Truth(t, long, lat))
                nextMotion += 0.02
            }
            if (t >= nextFix) {
                val pos = Vec2(radius * sin(theta), radius * cos(theta))
                val course = normalizeDegrees(theta * 180 / Math.PI + 90)
                val ll = proj.unproject(pos)
                fixes.add(GPSFix(t, ll.lat, ll.lon, 600.0, 4.0, v, course))
                nextFix += 1
            }
            val newTheta = theta + v / radius * dt
            // Lap boundary when crossing theta = 2πk.
            val k = floor(newTheta / (2 * Math.PI))
            if (k > floor(theta / (2 * Math.PI))) {
                lastLap?.let { lapTimes.add(t - it) }
                lastLap = t
            }
            theta = newTheta
            t += dt
        }
        return Data(fixes, motion, truth, lapTimes)
    }

    private fun rotate(v: Vec3): Vec3 {
        val y = mountYaw * Math.PI / 180
        val p = mountPitch * Math.PI / 180
        val r = mountRoll * Math.PI / 180
        var a = Vec3(v.x * cos(y) - v.y * sin(y), v.x * sin(y) + v.y * cos(y), v.z)
        a = Vec3(a.x * cos(p) + a.z * sin(p), a.y, -a.x * sin(p) + a.z * cos(p))
        a = Vec3(a.x, a.y * cos(r) - a.z * sin(r), a.y * sin(r) + a.z * cos(r))
        return a
    }
}

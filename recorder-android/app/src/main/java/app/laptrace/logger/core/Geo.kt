package app.laptrace.logger.core

import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** WGS84 coordinate in decimal degrees. */
@Serializable
data class LatLon(val lat: Double, val lon: Double)

/**
 * Local east/north plane (metres) around an origin. Accurate to centimetres
 * across a race track, which is all lap timing needs.
 */
class LocalProjection(val origin: LatLon) {
    private val mPerDegLat: Double
    private val mPerDegLon: Double

    init {
        val phi = origin.lat * Math.PI / 180
        mPerDegLat = 111_132.92 - 559.82 * cos(2 * phi) + 1.175 * cos(4 * phi)
        mPerDegLon = 111_412.84 * cos(phi) - 93.5 * cos(3 * phi)
    }

    fun project(p: LatLon): Vec2 =
        Vec2((p.lon - origin.lon) * mPerDegLon, (p.lat - origin.lat) * mPerDegLat)

    fun unproject(v: Vec2): LatLon =
        LatLon(origin.lat + v.y / mPerDegLat, origin.lon + v.x / mPerDegLon)
}

data class Vec2(val x: Double, val y: Double) {
    operator fun plus(b: Vec2) = Vec2(x + b.x, y + b.y)
    operator fun minus(b: Vec2) = Vec2(x - b.x, y - b.y)
    operator fun times(s: Double) = Vec2(x * s, y * s)
    val length: Double get() = sqrt(x * x + y * y)
    fun cross(o: Vec2): Double = x * o.y - y * o.x

    /** Compass bearing (0 = north, clockwise) of this vector, degrees. */
    val bearing: Double get() = normalizeDegrees(atan2(x, y) * 180 / Math.PI)

    companion object {
        /** Unit vector for a compass bearing. */
        fun fromBearing(deg: Double): Vec2 {
            val r = deg * Math.PI / 180
            return Vec2(sin(r), cos(r))
        }
    }
}

data class Vec3(val x: Double, val y: Double, val z: Double) {
    operator fun plus(b: Vec3) = Vec3(x + b.x, y + b.y, z + b.z)
    operator fun minus(b: Vec3) = Vec3(x - b.x, y - b.y, z - b.z)
    operator fun times(s: Double) = Vec3(x * s, y * s, z * s)
    fun dot(o: Vec3): Double = x * o.x + y * o.y + z * o.z
    fun cross(o: Vec3) = Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    val length: Double get() = sqrt(dot(this))
    val normalized: Vec3 get() { val l = length; return if (l > 0) this * (1 / l) else this }

    companion object {
        val ZERO = Vec3(0.0, 0.0, 0.0)
    }
}

fun normalizeDegrees(d: Double): Double {
    val r = d % 360 // same sign as dividend, like truncatingRemainder
    return if (r < 0) r + 360 else r
}

/** Signed smallest difference b - a in degrees, in (-180, 180]. */
fun angleDelta(a: Double, b: Double): Double {
    var d = normalizeDegrees(b - a)
    if (d > 180) d -= 360
    return d
}

/**
 * Intersection of segment p0→p1 with segment q0→q1.
 * Returns the fraction along p (0..1) or null.
 */
fun segmentIntersection(p0: Vec2, p1: Vec2, q0: Vec2, q1: Vec2): Double? {
    val r = p1 - p0
    val s = q1 - q0
    val denom = r.cross(s)
    if (abs(denom) <= 1e-12) return null
    val qp = q0 - p0
    val t = qp.cross(s) / denom
    val u = qp.cross(r) / denom
    if (!(t >= 0 && t <= 1 && u >= 0 && u <= 1)) return null
    return t
}

fun haversineMeters(a: LatLon, b: LatLon): Double {
    val r = 6_371_000.0
    val dLat = (b.lat - a.lat) * Math.PI / 180
    val dLon = (b.lon - a.lon) * Math.PI / 180
    val h = sin(dLat / 2) * sin(dLat / 2) +
        cos(a.lat * Math.PI / 180) * cos(b.lat * Math.PI / 180) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * r * asin(min(1.0, sqrt(h)))
}

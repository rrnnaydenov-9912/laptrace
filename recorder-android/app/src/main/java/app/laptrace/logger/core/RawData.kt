package app.laptrace.logger.core

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale

/** One GPS fix. Negative speed/course = invalid. */
data class GPSFix(
    val t: Double,       // Unix seconds
    val lat: Double,
    val lon: Double,
    val alt: Double,     // metres
    val hAcc: Double,    // horizontal accuracy, metres
    val speed: Double,   // m/s
    val course: Double,  // degrees, 0 = north
) {
    val latLon: LatLon get() = LatLon(lat, lon)

    val csvLine: String
        get() = String.format(Locale.US, "%.3f,%.8f,%.8f,%.2f,%.2f,%.3f,%.2f\n", t, lat, lon, alt, hAcc, speed, course)

    companion object {
        fun parse(line: String): GPSFix? {
            val f = line.split(",").filter { it.isNotEmpty() }.mapNotNull { it.trim().toDoubleOrNull() }
            if (f.size != 7) return null
            return GPSFix(f[0], f[1], f[2], f[3], f[4], f[5], f[6])
        }
    }
}

/**
 * One motion sample in the phone's own axes, in the same units as the iOS recorder:
 * accel = user acceleration in g (gravity removed), gravity = gravity direction in g
 * (pointing towards the earth), rotation = rate in rad/s.
 */
data class MotionSample(val t: Double, val accel: Vec3, val gravity: Vec3, val rotation: Vec3) {

    fun appendTo(buf: ByteBuffer) {
        buf.order(ByteOrder.LITTLE_ENDIAN)
        buf.putDouble(t)
        for (v in doubleArrayOf(accel.x, accel.y, accel.z, gravity.x, gravity.y, gravity.z, rotation.x, rotation.y, rotation.z)) {
            buf.putFloat(v.toFloat())
        }
    }

    fun toBytes(): ByteArray {
        val b = ByteBuffer.allocate(BYTE_COUNT)
        appendTo(b)
        return b.array()
    }

    companion object {
        const val BYTE_COUNT = 8 + 9 * 4

        fun decodeAll(data: ByteArray): List<MotionSample> {
            val n = data.size / BYTE_COUNT
            val out = ArrayList<MotionSample>(n)
            val b = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
            for (i in 0 until n) {
                val base = i * BYTE_COUNT
                val t = b.getDouble(base)
                val f = DoubleArray(9) { k -> b.getFloat(base + 8 + k * 4).toDouble() }
                out.add(MotionSample(t, Vec3(f[0], f[1], f[2]), Vec3(f[3], f[4], f[5]), Vec3(f[6], f[7], f[8])))
            }
            return out
        }
    }
}

/** Buffered append-only file writer, safe to call from any thread. */
class AppendWriter(file: File, private val flushThreshold: Int = 32_768) {
    private val out = FileOutputStream(file, true)
    private val buffer = ByteArrayOutputStream()
    private val lock = Any()
    private var closed = false

    fun append(data: ByteArray) = synchronized(lock) {
        if (closed) return
        buffer.write(data)
        if (buffer.size() >= flushThreshold) flushLocked()
    }

    fun flush() = synchronized(lock) { if (!closed) flushLocked() }

    fun close() = synchronized(lock) {
        if (closed) return
        flushLocked()
        runCatching { out.close() }
        closed = true
    }

    private fun flushLocked() {
        if (buffer.size() == 0) return
        runCatching {
            buffer.writeTo(out)
            out.flush()
        }
        buffer.reset()
    }
}

object RawFiles {
    fun readFixes(file: File): List<GPSFix> {
        val text = runCatching { file.readText(Charsets.UTF_8) }.getOrNull() ?: return emptyList()
        return text.split("\n").filter { it.isNotEmpty() }.mapNotNull { GPSFix.parse(it) }
    }

    fun readMotion(file: File): List<MotionSample> {
        val data = runCatching { file.readBytes() }.getOrNull() ?: return emptyList()
        return MotionSample.decodeAll(data)
    }
}

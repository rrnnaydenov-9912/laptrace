package app.laptrace.logger.core

import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * Turns a raw recording (≈1 Hz GPS + ≈50 Hz motion) into the shared CSV
 * contract (see shared/CSV-FORMAT.md):
 * - positions on a fixed-rate grid, Hermite-interpolated between fixes using
 *   the GPS velocity, so curves stay curved;
 * - g-forces rotated into the car's axes by learning the phone mount from the
 *   session itself (correlating motion with GPS speed and heading changes);
 * - lap labels from start/finish crossings on the interpolated path.
 */
class Exporter(val options: Options = Options()) {

    data class Options(
        var rateHz: Double = 10.0,
        var maxAccuracy: Double = 30.0,   // drop fixes worse than this (m)
        var maxGap: Double = 3.0,         // no rows inside GPS gaps longer than this (s)
        var gWindow: Double = 0.15,       // ± seconds averaged per g-force row
        var device: String = "Android",
        var extraMeta: List<Pair<String, String>> = emptyList(), // optional Mode / Driver / Vehicle / Notes / Video Start UTC
    )

    data class Calibration(
        val calibrated: Boolean,
        val intervals: Int,
        val longitudinalCorrelation: Double,
        val lateralCorrelation: Double,
    ) {
        val source: String
            get() = if (calibrated)
                "Phone IMU auto-aligned (r long ${fmt(longitudinalCorrelation, 2)} / lat ${fmt(lateralCorrelation, 2)})"
            else "Derived from GPS speed and heading"
    }

    data class Summary(
        val rows: Int,
        val duration: Double,
        val laps: List<CompletedLap>,
        val calibration: Calibration,
        val track: Track?,
    ) {
        val best: CompletedLap? get() = laps.minByOrNull { it.duration }
    }

    class Row(
        var t: Double,
        var p: LatLon,
        var alt: Double,
        var speed: Double, // m/s
        var heading: Double,
        var long: Double,
        var lat: Double,
        var vert: Double?,
        var acc: Double,
        var fix: Boolean,
        var lap: Int = 0,
    )

    data class Result(val csv: String, val summary: Summary)

    // region Public

    fun export(fixes: List<GPSFix>, motion: List<MotionSample>, track: Track?): Result? {
        val clean = clean(fixes)
        if (clean.size < 2) return null
        val proj = LocalProjection(clean[0].latLon)
        val rows = interpolate(clean, proj)
        if (rows.size < 2) return null
        val cal = applyGForces(rows, clean, motion)
        val laps = labelLaps(rows, track)
        val summary = Summary(rows.size, rows.last().t - rows.first().t, laps, cal, track)
        return Result(render(rows, summary), summary)
    }

    /** Interpolated laps (local metres) for the debrief; no g-force work. */
    fun coachLaps(fixes: List<GPSFix>, track: Track?): List<Coach.Lap> {
        val clean = clean(fixes)
        if (clean.size < 2) return emptyList()
        val proj = LocalProjection(clean[0].latLon)
        val rows = interpolate(clean, proj)
        val laps = labelLaps(rows, track)
        val groups = rows.filter { it.lap > 0 }.groupBy { it.lap }
        return groups.keys.sorted().mapNotNull { n ->
            val r = groups[n] ?: return@mapNotNull null
            if (r.size < 2) return@mapNotNull null
            val pts = r.map { proj.project(it.p) }
            val duration = if (n <= laps.size) laps[n - 1].duration else r.last().t - r.first().t
            Coach.Lap(
                number = n, duration = duration,
                t = r.map { it.t }.toDoubleArray(),
                x = pts.map { it.x }.toDoubleArray(),
                y = pts.map { it.y }.toDoubleArray(),
                speed = r.map { it.speed }.toDoubleArray(),
            )
        }
    }

    // endregion

    // region Fix cleaning

    fun clean(input: List<GPSFix>): List<GPSFix> {
        val out = ArrayList<GPSFix>()
        for (f in input.sortedBy { it.t }) {
            if (!(f.hAcc > 0 && f.hAcc <= options.maxAccuracy &&
                    abs(f.lat) <= 90 && abs(f.lon) <= 180 && !(f.lat == 0.0 && f.lon == 0.0))) continue
            val prev = out.lastOrNull()
            if (prev != null) {
                val dt = f.t - prev.t
                if (!(dt > 0.05)) continue
                // Reject teleports: faster than 120 m/s between fixes.
                if (haversineMeters(prev.latLon, f.latLon) / dt > 120) continue
            }
            out.add(f)
        }
        return out
    }

    // endregion

    // region Path interpolation

    private fun velocity(fixes: List<GPSFix>, pos: List<Vec2>, i: Int): Vec2 {
        val f = fixes[i]
        if (f.speed >= 0 && f.course >= 0 && f.speed > 1) return Vec2.fromBearing(f.course) * f.speed
        val a = max(0, i - 1)
        val b = min(fixes.size - 1, i + 1)
        val dt = fixes[b].t - fixes[a].t
        return if (dt > 0) (pos[b] - pos[a]) * (1 / dt) else Vec2(0.0, 0.0)
    }

    fun interpolate(fixes: List<GPSFix>, proj: LocalProjection): MutableList<Row> {
        val pos = fixes.map { proj.project(it.latLon) }
        val vel = fixes.indices.map { velocity(fixes, pos, it) }
        val rate = options.rateHz
        val step = 1 / rate
        var t = roundUp(fixes[0].t * rate) / rate
        var i = 0
        val lastT = fixes.last().t
        val rows = ArrayList<Row>(max(0, ((lastT - t) * rate).toInt() + 1))
        var lastHeading = if (fixes[0].course >= 0) fixes[0].course else 0.0
        while (t <= lastT + 1e-9) {
            while (i + 1 < fixes.size - 1 && fixes[i + 1].t <= t) i += 1
            val a = fixes[i]
            val b = fixes[min(i + 1, fixes.size - 1)]
            val dt = b.t - a.t
            val nearA = abs(t - a.t) < step / 2
            val nearB = abs(t - b.t) < step / 2
            if (dt > options.maxGap && !nearA && !nearB) {
                t = roundHalfAway((t + step) * rate) / rate
                continue
            }
            val s = if (dt > 0) min(max((t - a.t) / dt, 0.0), 1.0) else 0.0
            val s2 = s * s
            val s3 = s2 * s
            val p0 = pos[i]
            val p1 = pos[min(i + 1, pos.size - 1)]
            val v0 = vel[i] * dt
            val v1 = vel[min(i + 1, vel.size - 1)] * dt
            val p = p0 * (2 * s3 - 3 * s2 + 1) + v0 * (s3 - 2 * s2 + s) + p1 * (-2 * s3 + 3 * s2) + v1 * (s3 - s2)
            var dp = Vec2(0.0, 0.0)
            if (dt > 0) {
                dp = (p0 * (6 * s2 - 6 * s) + v0 * (3 * s2 - 4 * s + 1) + p1 * (-6 * s2 + 6 * s) + v1 * (3 * s2 - 2 * s)) * (1 / dt)
            }
            val speed = if (a.speed >= 0 && b.speed >= 0) a.speed + (b.speed - a.speed) * s else dp.length
            if (dp.length > 0.5) lastHeading = dp.bearing
            rows.add(
                Row(
                    t = t, p = proj.unproject(p), alt = a.alt + (b.alt - a.alt) * s,
                    speed = max(0.0, speed), heading = lastHeading, long = 0.0, lat = 0.0, vert = null,
                    acc = if (nearB) b.hAcc else a.hAcc + (b.hAcc - a.hAcc) * s, fix = nearA || nearB,
                )
            )
            t = roundHalfAway((t + step) * rate) / rate
        }
        return rows
    }

    // endregion

    // region G-forces

    private class GpsAccel(val t: Double, val long: Double, val lat: Double, val dt: Double, val a: GPSFix, val b: GPSFix)

    /** GPS-only estimate per fix interval: (mid time, long g, lat g). */
    private fun gpsAccelerations(fixes: List<GPSFix>): List<GpsAccel> {
        val out = ArrayList<GpsAccel>()
        for (j in 0 until fixes.size - 1) {
            val a = fixes[j]
            val b = fixes[j + 1]
            val dt = b.t - a.t
            if (!(dt > 0.2 && dt <= 2.5 && a.speed >= 0 && b.speed >= 0)) continue
            val long = (b.speed - a.speed) / dt / 9.80665
            var lat = 0.0
            if (a.course >= 0 && b.course >= 0 && a.speed > 3 && b.speed > 3) {
                val yaw = angleDelta(a.course, b.course) * Math.PI / 180 / dt // + = turning right
                lat = (a.speed + b.speed) / 2 * yaw / 9.80665
            }
            out.add(GpsAccel((a.t + b.t) / 2, long, lat, dt, a, b))
        }
        return out
    }

    fun applyGForces(rows: MutableList<Row>, fixes: List<GPSFix>, motion: List<MotionSample>): Calibration {
        val gps = gpsAccelerations(fixes)
        // GPS fallback, linearly interpolated at row times.
        var k = 0
        if (gps.isNotEmpty()) {
            for (row in rows) {
                while (k + 1 < gps.size && gps[k + 1].t <= row.t) k += 1
                val a = gps[k]
                val b = gps[min(k + 1, gps.size - 1)]
                val s = if (b.t > a.t) min(max((row.t - a.t) / (b.t - a.t), 0.0), 1.0) else 0.0
                row.long = a.long + (b.long - a.long) * s
                row.lat = a.lat + (b.lat - a.lat) * s
            }
        }

        val ms = motion.sortedBy { it.t }
        if (ms.size <= 100) return Calibration(false, 0, 0.0, 0.0)
        // Horizontal (gravity-removed, gravity-orthogonal) acceleration per sample.
        val up = ms.map { (it.gravity * -1.0).normalized }
        val horiz = ms.indices.map { i -> val a = ms[i].accel; a - up[i] * a.dot(up[i]) }
        val vert = DoubleArray(ms.size) { ms[it].accel.dot(up[it]) }
        val times = DoubleArray(ms.size) { ms[it].t }

        fun range(t0: Double, t1: Double): IntRange {
            val lo = lowerBound(times, t0)
            val hi = lowerBound(times, t1)
            return lo until hi
        }

        // Learn forward and lateral axes in the phone frame.
        var bigF = Vec3.ZERO
        var bigL = Vec3.ZERO
        var bigU = Vec3.ZERO
        val sH = ArrayList<Vec3>()
        val sLong = ArrayList<Double>()
        val sLat = ArrayList<Double>()
        for (g in gps) {
            if (!(g.a.speed > 5 && g.b.speed > 5)) continue
            val r = range(g.a.t, g.b.t)
            val count = if (r.isEmpty()) 0 else r.last - r.first + 1
            if (count < 5) continue
            var h = Vec3.ZERO
            var u = Vec3.ZERO
            for (i in r) { h = h + horiz[i]; u = u + up[i] }
            h = h * (1.0 / count)
            bigF = bigF + h * g.long
            bigL = bigL + h * g.lat
            bigU = bigU + u
            sH.add(h); sLong.add(g.long); sLat.add(g.lat)
        }
        if (sH.size < 15) return Calibration(false, sH.size, 0.0, 0.0)
        val upAxis = bigU.normalized
        val fwd = (bigF - upAxis * bigF.dot(upAxis)).normalized
        var side = upAxis.cross(fwd).normalized
        if (bigL.dot(side) < 0) side = side * -1.0

        val rLong = correlation(DoubleArray(sH.size) { sH[it].dot(fwd) }, sLong.toDoubleArray())
        val rLat = correlation(DoubleArray(sH.size) { sH[it].dot(side) }, sLat.toDoubleArray())
        // Require the learned axes to actually explain the GPS signal.
        if (!(rLong > 0.5 || rLat > 0.5)) return Calibration(false, sH.size, rLong, rLat)

        for (row in rows) {
            val rr = range(row.t - options.gWindow, row.t + options.gWindow)
            val count = if (rr.isEmpty()) 0 else rr.last - rr.first + 1
            if (count < 2) continue // keep GPS fallback
            var h = Vec3.ZERO
            var v = 0.0
            for (i in rr) { h = h + horiz[i]; v += vert[i] }
            val n = count.toDouble()
            h = h * (1 / n)
            if (rLong > 0.5) row.long = h.dot(fwd)
            if (rLat > 0.5) row.lat = h.dot(side)
            row.vert = 1 + v / n
        }
        return Calibration(true, sH.size, rLong, rLat)
    }

    // endregion

    // region Laps

    fun labelLaps(rows: MutableList<Row>, track: Track?): List<CompletedLap> {
        if (track == null || track.startFinish == null) return emptyList()
        val timer = LapTimer()
        timer.setTrack(track)
        val boundaries = ArrayList<Int>()
        for ((idx, r) in rows.withIndex()) {
            for (e in timer.ingest(TimedPoint(r.t, r.p))) {
                if (e is LapTimer.Event.LapStarted) boundaries.add(idx)
            }
        }
        if (boundaries.size < 2) return emptyList()
        for (n in 0 until boundaries.size - 1) {
            for (idx in boundaries[n] until boundaries[n + 1]) rows[idx].lap = n + 1
        }
        return timer.laps.toList()
    }

    // endregion

    // region CSV

    fun render(rows: List<Row>, summary: Summary): String {
        val hasLaps = summary.laps.isNotEmpty()
        val hasVert = rows.any { it.vert != null }
        fun meta(k: String, v: String) = "$k,${v.replace(",", " ")}\n"
        val s = StringBuilder(rows.size * 110 + 512)
        s.append(meta("Format", "Laptrace Logger CSV"))
        s.append(meta("Date UTC", isoUtc(rows[0].t)))
        s.append(meta("Track", summary.track?.name ?: "Unknown"))
        s.append(meta("Device", options.device))
        s.append(meta("GPS Source", "Phone GPS ~1 Hz interpolated to ${options.rateHz.toInt()} Hz"))
        s.append(meta("G-Force Source", summary.calibration.source))
        s.append(meta("Lateral Sign", "positive = right turn"))
        summary.best?.let { s.append(meta("Best Lap", "Lap ${it.number} ${fmt(it.duration, 3)} s")) }
        for ((k, v) in options.extraMeta) {
            if (v.isBlank()) continue
            s.append(k).append(',').append(quoted(v)).append('\n')
        }
        s.append('\n')
        val header = ArrayList<String>()
        header.add("Time")
        if (hasLaps) header.add("Lap")
        header += listOf("Latitude", "Longitude", "Altitude (m)", "Speed (km/h)", "Heading (deg)", "Longitudinal (g)", "Lateral (g)")
        if (hasVert) header.add("Vertical (g)")
        header += listOf("GPS Accuracy (m)", "GPS Fix")
        s.append(header.joinToString(",")).append('\n')
        for (r in rows) {
            s.append(fmt(r.t, 2))
            if (hasLaps) s.append(',').append(r.lap)
            s.append(',').append(fmt(r.p.lat, 7)).append(',').append(fmt(r.p.lon, 7))
                .append(',').append(fmt(r.alt, 1)).append(',').append(fmt(r.speed * 3.6, 2))
            s.append(',').append(fmt(r.heading, 1)).append(',').append(fmt(r.long, 3)).append(',').append(fmt(r.lat, 3))
            if (hasVert) s.append(',').append(fmt(r.vert ?: 1.0, 3))
            s.append(',').append(fmt(r.acc, 1)).append(',').append(if (r.fix) "1" else "0").append('\n')
        }
        return s.toString()
    }

    // endregion

    companion object {
        private val NEWLINES = Regex("[\\n\\r\\u000B\\u000C\\u0085\\u2028\\u2029]")

        /** A metadata value as one quoted CSV field: inner quotes doubled, line breaks folded to spaces. */
        fun quoted(v: String): String {
            val oneLine = v.split(NEWLINES).map { it.trim(' ', '\t') }.filter { it.isNotEmpty() }.joinToString(" ")
            return "\"" + oneLine.replace("\"", "\"\"") + "\""
        }

        /** ISO 8601 in UTC without fractional seconds, e.g. 2026-10-11T10:00:00Z. */
        fun isoUtc(unixSeconds: Double): String {
            val ms = floor(unixSeconds * 1000).toLong()
            return DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(ms).truncatedTo(ChronoUnit.SECONDS))
        }
    }
}

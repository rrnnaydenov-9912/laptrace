package app.laptrace.logger.core

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Post-session debrief: lap statistics plus one rule-based coaching goal.
 * Works on plain arrays (local metres, m/s) so it can be unit-tested.
 */
object Coach {
    class Lap(
        val number: Int,
        val duration: Double,
        val t: DoubleArray,
        val x: DoubleArray,
        val y: DoubleArray,
        val speed: DoubleArray, // m/s
    )

    data class Stats(
        val timedLaps: Int,
        val bestLap: Double,
        val bestLapNumber: Int,
        val lapSD: Double,
        val bestToMedian: Double,
        val bestThreeAverage: Double?,
    )

    data class CornerStats(
        val number: Int,
        val entryKmh: Double,
        val minKmh: Double,
        val exitKmh: Double,
        val brakeAt: Double?,   // metres from the start line
        val lossVsBest: Double, // seconds; average of the other laps
    )

    enum class GoalKind(val raw: String) { CONSISTENCY("consistency"), BRAKING("braking"), CORNER_SPEED("cornerSpeed"), EXIT("exit") }

    data class Goal(val kind: GoalKind, val title: String, val text: String, val corner: Int?)

    data class Debrief(val stats: Stats, val corners: List<CornerStats>, val goal: Goal, val factsJSON: String)

    const val GRID_STEP = 1.0
    const val MIN_CURVATURE = 1.0 / 200
    const val MIN_CORNER_ANGLE = 20.0
    const val MERGE_GAP = 25.0

    // region Debrief

    fun debrief(laps: List<Lap>, trackName: String? = null): Debrief? {
        val timed = timedLaps(laps)
        val ref = timed.minByOrNull { it.duration } ?: return null
        val stats = sessionStats(timed, ref)

        val refGrid = resample(ref)
        val length = refGrid.s.lastOrNull() ?: 0.0
        val others = timed.filter { it.number != ref.number }.map { aligned(resample(it), length) }
        val corners = detectCorners(refGrid)
        val zones = cornerZones(corners, length)

        val cornerStats = ArrayList<CornerStats>()
        val compare = ArrayList<Pair<Measure, Measure?>>()
        for ((i, c) in corners.withIndex()) {
            val r = measure(refGrid, c, zones[i])
            val ms = others.map { measure(it, c, zones[i]) }
            val avg = average(ms)
            compare.add(r to avg)
            cornerStats.add(
                CornerStats(i + 1, r.entry * 3.6, r.min * 3.6, r.exit * 3.6, r.brake, avg?.let { it.time - r.time } ?: 0.0)
            )
        }

        val goal = pickGoal(stats, compare)
        val facts = linkedMapOf<String, Any?>(
            "track" to trackName,
            "timedLaps" to stats.timedLaps,
            "bestLap" to Fmt.lap(stats.bestLap),
            "bestLapNumber" to stats.bestLapNumber,
            "lapSpreadSeconds" to fmt(stats.lapSD, 2),
            "bestToMedianSeconds" to fmt(stats.bestToMedian, 2),
            "bestThreeLapAverage" to stats.bestThreeAverage?.let { Fmt.lap(it) },
            "goalTitle" to goal.title,
            "goalText" to goal.text,
        )
        return Debrief(stats, cornerStats, goal, factsJson(facts))
    }

    /** Pretty-printed JSON with sorted keys and nulls omitted, in the same shape as the iOS encoder. */
    private fun factsJson(facts: Map<String, Any?>): String {
        val entries = facts.filterValues { it != null }.toSortedMap()
        if (entries.isEmpty()) return "{}"
        return entries.entries.joinToString(",\n", "{\n", "\n}") { (k, v) ->
            "  " + jsonString(k) + " : " + (if (v is String) jsonString(v) else v.toString())
        }
    }

    private fun jsonString(s: String): String {
        val b = StringBuilder("\"")
        for (c in s) {
            when {
                c == '"' -> b.append("\\\"")
                c == '\\' -> b.append("\\\\")
                c == '/' -> b.append("\\/")
                c == '\n' -> b.append("\\n")
                c == '\r' -> b.append("\\r")
                c == '\t' -> b.append("\\t")
                c < ' ' -> b.append(String.format(java.util.Locale.US, "\\u%04x", c.code))
                else -> b.append(c)
            }
        }
        return b.append('"').toString()
    }

    /** Complete laps that look like real timed laps (no pit stops or spins: within 1.5× the median). */
    fun timedLaps(laps: List<Lap>): List<Lap> {
        val ok = laps.filter { it.duration > 0 && it.t.size >= 2 }
        val med = median(ok.map { it.duration }) ?: return emptyList()
        return ok.filter { it.duration <= med * 1.5 }
    }

    fun sessionStats(timed: List<Lap>, best: Lap): Stats {
        val d = timed.map { it.duration }
        val byNumber = timed.sortedBy { it.number }
        var best3: Double? = null
        if (byNumber.size >= 3) {
            for (i in 0..(byNumber.size - 3)) {
                val w = byNumber.subList(i, i + 3)
                if (w.last().number - w.first().number != 2) continue
                val avg = w.sumOf { it.duration } / 3
                best3 = min(best3 ?: Double.POSITIVE_INFINITY, avg)
            }
        }
        return Stats(timed.size, best.duration, best.number, stdDev(d), (median(d) ?: best.duration) - best.duration, best3)
    }

    // endregion

    // region Resampling

    class Grid(val s: DoubleArray, val t: DoubleArray, val x: DoubleArray, val y: DoubleArray, val v: DoubleArray)

    /** Resample a lap onto a 1 m distance grid. */
    fun resample(lap: Lap): Grid {
        val d = DoubleArray(lap.x.size)
        for (i in 1 until lap.x.size) d[i] = d[i - 1] + hypot(lap.x[i] - lap.x[i - 1], lap.y[i] - lap.y[i - 1])
        val total = d.lastOrNull() ?: 0.0
        val gs = ArrayList<Double>(); val gt = ArrayList<Double>(); val gx = ArrayList<Double>()
        val gy = ArrayList<Double>(); val gv = ArrayList<Double>()
        var j = 0
        var s = 0.0
        while (s <= total) {
            while (j < d.size - 2 && d[j + 1] < s) j += 1
            val span = d[j + 1] - d[j]
            val f = if (span > 0) (s - d[j]) / span else 0.0
            fun lerp(a: DoubleArray) = a[j] + (a[j + 1] - a[j]) * f
            gs.add(s); gt.add(lerp(lap.t)); gx.add(lerp(lap.x)); gy.add(lerp(lap.y)); gv.add(lerp(lap.speed))
            s += GRID_STEP
        }
        return Grid(gs.toDoubleArray(), gt.toDoubleArray(), gx.toDoubleArray(), gy.toDoubleArray(), gv.toDoubleArray())
    }

    /** Stretch a lap's grid onto the reference length so distances line up. */
    fun aligned(g: Grid, length: Double): Grid {
        val own = g.s.lastOrNull() ?: return g
        if (!(own > 0 && length > 0)) return g
        val k = length / own
        return Grid(DoubleArray(g.s.size) { g.s[it] * k }, g.t, g.x, g.y, g.v)
    }

    private fun index(g: Grid, s: Double): Int = min(max(lowerBound(g.s, s), 0), g.s.size - 1)

    private fun time(g: Grid, s: Double): Double {
        val i = index(g, s)
        if (i <= 0) return g.t[0]
        val f = (s - g.s[i - 1]) / max(g.s[i] - g.s[i - 1], 1e-9)
        return g.t[i - 1] + (g.t[i] - g.t[i - 1]) * min(max(f, 0.0), 1.0)
    }

    // endregion

    // region Corners

    data class Corner(val start: Double, val end: Double, val angle: Double)

    fun detectCorners(g: Grid): List<Corner> {
        val n = g.s.size
        if (n <= 20) return emptyList()
        val w = 8
        val h = DoubleArray(n)
        for (i in 0 until n) {
            val a = max(i - w, 0)
            val b = min(i + w, n - 1)
            h[i] = atan2(g.x[b] - g.x[a], g.y[b] - g.y[a])
        }
        val k = DoubleArray(n)
        for (i in 1 until n - 1) {
            var dh = h[i + 1] - h[i - 1]
            while (dh > Math.PI) dh -= 2 * Math.PI
            while (dh < -Math.PI) dh += 2 * Math.PI
            k[i] = dh / max(g.s[i + 1] - g.s[i - 1], 1e-9)
        }
        val half = 7
        val ks = DoubleArray(n)
        for (i in 0 until n) {
            val a = max(i - half, 0)
            val b = min(i + half, n - 1)
            var sum = 0.0
            for (q in a..b) sum += k[q]
            ks[i] = sum / (b - a + 1)
        }
        val runs = ArrayList<IntArray>()
        var i = 0
        while (i < n) {
            if (!(abs(ks[i]) > MIN_CURVATURE)) { i += 1; continue }
            var j = i
            while (j + 1 < n && abs(ks[j + 1]) > MIN_CURVATURE) j += 1
            val last = runs.lastOrNull()
            if (last != null && g.s[i] - g.s[last[1]] < MERGE_GAP) last[1] = j else runs.add(intArrayOf(i, j))
            i = j + 1
        }
        return runs.mapNotNull { (a, b) ->
            var sum = 0.0
            for (q in a..b) sum += ks[q]
            val angle = abs(sum * GRID_STEP) * 180 / Math.PI
            if (angle >= MIN_CORNER_ANGLE && g.s[b] - g.s[a] >= 10) Corner(g.s[a], g.s[b], angle) else null
        }
    }

    /** Each corner owns the track from the midpoint after the previous corner to the midpoint before the next. */
    fun cornerZones(corners: List<Corner>, length: Double): List<Pair<Double, Double>> =
        corners.indices.map { i ->
            val a = if (i == 0) 0.0 else (corners[i - 1].end + corners[i].start) / 2
            val b = if (i == corners.size - 1) length else (corners[i].end + corners[i + 1].start) / 2
            a to b
        }

    data class Measure(val entry: Double, val min: Double, val minAt: Double, val exit: Double, val brake: Double?, val time: Double)

    fun measure(g: Grid, c: Corner, zone: Pair<Double, Double>): Measure {
        val lo = index(g, c.start - 20)
        val hi = index(g, c.end + 10)
        var m = lo
        for (i in lo..max(lo, hi)) if (g.v[i] < g.v[m]) m = i
        val z0 = index(g, zone.first)
        var p = min(z0, m)
        for (i in min(z0, m)..m) if (g.v[i] >= g.v[p]) p = i // last peak = where braking starts
        val brake = if ((g.v[p] - g.v[m]) * 3.6 > 5) g.s[p] else null
        return Measure(
            entry = g.v[index(g, c.start)], min = g.v[m], minAt = g.s[m], exit = g.v[index(g, c.end)],
            brake = brake, time = time(g, zone.second) - time(g, zone.first),
        )
    }

    fun average(ms: List<Measure>): Measure? {
        if (ms.isEmpty()) return null
        val n = ms.size.toDouble()
        val brakes = ms.mapNotNull { it.brake }
        return Measure(
            entry = ms.sumOf { it.entry } / n, min = ms.sumOf { it.min } / n,
            minAt = ms.sumOf { it.minAt } / n, exit = ms.sumOf { it.exit } / n,
            brake = if (brakes.isEmpty()) null else brakes.sum() / brakes.size,
            time = ms.sumOf { it.time } / n,
        )
    }

    // endregion

    // region Skill ladder

    fun pickGoal(stats: Stats, compare: List<Pair<Measure, Measure?>>): Goal {
        if (stats.lapSD > 1.2) {
            return Goal(
                GoalKind.CONSISTENCY, "Be consistent first",
                "Your lap times varied by ${fmt(stats.lapSD, 1)} s. Repeat the line from your best lap (lap ${stats.bestLapNumber}, ${Fmt.lap(stats.bestLap)}) and aim for laps within ±0.6 s of each other before chasing speed.",
                null,
            )
        }
        data class WithAvg(val n: Int, val r: Measure, val a: Measure)
        val withAvg = compare.mapIndexedNotNull { i, (r, a) -> a?.let { WithAvg(i + 1, r, it) } }

        val braking = withAvg.mapNotNull { (n, r, a) ->
            val rb = r.brake
            val ab = a.brake
            if (rb == null || ab == null || !(rb - ab > 5) || !(a.time - r.time > 0)) null
            else Triple(n, rb - ab, a.time - r.time)
        }.maxByOrNull { it.third }
        if (braking != null) {
            val (n, metres, loss) = braking
            return Goal(
                GoalKind.BRAKING, "Brake later into corner $n",
                "Corner $n: on your best lap you started braking ${fmt(metres, 0)} m later than your average and lost ${fmt(loss, 2)} s less there. Pick a fixed braking marker and move it a little closer each lap.",
                n,
            )
        }

        val speed = withAvg.map { (n, r, a) -> Triple(n, r.min * 3.6, a.min * 3.6) }.maxByOrNull { it.second - it.third }
        if (speed != null && speed.second - speed.third > 2) {
            val (n, best, avg) = speed
            return Goal(
                GoalKind.CORNER_SPEED, "Carry more speed through corner $n",
                "Corner $n: your best lap carried ${fmt(best, 0)} km/h at the slowest point; your average was ${fmt(avg, 0)} km/h. Brake a little less and roll more speed to the apex.",
                n,
            )
        }

        val exit = withAvg.maxByOrNull { it.r.exit - it.a.exit }
        if (exit != null) {
            val (n, r, a) = exit
            return Goal(
                GoalKind.EXIT, "Get on the throttle earlier out of corner $n",
                "Corner $n: your best lap left the corner at ${fmt(r.exit * 3.6, 0)} km/h; your average was ${fmt(a.exit * 3.6, 0)} km/h. Once the car points down the next straight, squeeze the throttle smoothly and early.",
                n,
            )
        }
        val first = compare.firstOrNull()?.first
        if (first != null) {
            return Goal(
                GoalKind.EXIT, "Get on the throttle earlier out of corner 1",
                "Corner 1: your best lap left the corner at ${fmt(first.exit * 3.6, 0)} km/h. Drive a few more laps so there is something to compare; meanwhile squeeze the throttle smoothly as soon as the car points down the straight.",
                1,
            )
        }
        return Goal(
            GoalKind.EXIT, "Smooth, early throttle",
            "Your best lap was ${Fmt.lap(stats.bestLap)}. Focus on squeezing the throttle smoothly as soon as the car points down each straight.",
            null,
        )
    }

    // endregion

    // region Grounding check for generated text

    private val NUMBER = Regex("""\d+(?:\.\d+)?""")

    fun numbers(text: String): List<Double> = NUMBER.findAll(text).mapNotNull { it.value.toDoubleOrNull() }.toList()

    /** True when every number in `text` also appears in `facts`. */
    fun numbersAreGrounded(text: String, facts: String): Boolean {
        val allowed = numbers(facts).toSet()
        return numbers(text).all { it in allowed }
    }

    // endregion

    // region Helpers

    fun median(v: List<Double>): Double? {
        if (v.isEmpty()) return null
        val s = v.sorted()
        val m = s.size / 2
        return if (s.size % 2 == 0) (s[m - 1] + s[m]) / 2 else s[m]
    }

    fun stdDev(v: List<Double>): Double {
        if (v.size < 2) return 0.0
        val mean = v.sum() / v.size
        return sqrt(v.sumOf { (it - mean) * (it - mean) } / (v.size - 1))
    }

    // endregion
}

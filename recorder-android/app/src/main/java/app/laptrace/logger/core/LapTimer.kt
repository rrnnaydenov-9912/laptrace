package app.laptrace.logger.core

import kotlinx.serialization.Serializable
import kotlin.math.abs

/** Timed position used for crossing detection. */
data class TimedPoint(val t: Double, val p: LatLon)

data class GateCrossing(val gate: Gate, val t: Double)

/**
 * Finds directed gate crossings along a path. Gates are lengthened by
 * `tolerance` metres on both ends because 1 Hz phone GPS cuts chords.
 */
class GateDetector(val gates: List<Gate>, val tolerance: Double = 12.0) {
    fun crossings(a: TimedPoint, b: TimedPoint): List<GateCrossing> {
        if (!(b.t > a.t)) return emptyList()
        val out = ArrayList<GateCrossing>()
        for (gate in gates) {
            val proj = LocalProjection(gate.start)
            var g0 = proj.project(gate.start)
            var g1 = proj.project(gate.end)
            val dir = g1 - g0
            val len = dir.length
            if (!(len > 0)) continue
            val ext = dir * (tolerance / len)
            g0 = g0 - ext; g1 = g1 + ext
            val p0 = proj.project(a.p)
            val p1 = proj.project(b.p)
            val travel = p1 - p0
            if (!(travel.length > 0.01)) continue
            if (!(abs(angleDelta(gate.travelBearing, travel.bearing)) < 90)) continue
            val f = segmentIntersection(p0, p1, g0, g1) ?: continue
            out.add(GateCrossing(gate, a.t + f * (b.t - a.t)))
        }
        return out.sortedBy { it.t }
    }
}

@Serializable
data class CompletedLap(
    val number: Int,
    val start: Double,
    val end: Double,
    /** Elapsed seconds from lap start at each split gate. */
    val splits: Map<String, Double> = emptyMap(),
) {
    val duration: Double get() = end - start
}

/** Live lap timing from GPS fixes. */
class LapTimer {
    var track: Track? = null
        private set
    private var detector: GateDetector? = null
    private var last: TimedPoint? = null
    var currentLapStart: Double? = null
        private set
    var currentSplits: Map<String, Double> = emptyMap()
        private set
    private val _laps = ArrayList<CompletedLap>()
    val laps: List<CompletedLap> get() = _laps

    /** Lap number in progress (1-based) or null before the first crossing. */
    val currentLapNumber: Int? get() = if (currentLapStart == null) null else _laps.size + 1
    val best: CompletedLap? get() = _laps.minByOrNull { it.duration }

    /** Minimum plausible lap; filters gate jitter when parked near the line. */
    var minimumLapSeconds: Double = 20.0

    sealed class Event {
        data class LapStarted(val at: Double) : Event()
        data class LapCompleted(val lap: CompletedLap) : Event()
        data class Split(val gate: Gate, val elapsed: Double, val deltaToBest: Double?) : Event()
    }

    fun setTrack(track: Track?) {
        this.track = track
        detector = track?.let { GateDetector(it.gates) }
    }

    fun reset() {
        last = null; currentLapStart = null; currentSplits = emptyMap(); _laps.clear()
    }

    fun ingest(point: TimedPoint): List<Event> {
        val prev = last
        last = point
        val detector = detector
        if (prev == null || detector == null) return emptyList()
        val events = ArrayList<Event>()
        for (c in detector.crossings(prev, point)) {
            if (c.gate.isStartFinish) {
                val start = currentLapStart
                if (start != null) {
                    if (c.t - start < minimumLapSeconds) continue
                    val lap = CompletedLap(_laps.size + 1, start, c.t, currentSplits)
                    _laps.add(lap)
                    events.add(Event.LapCompleted(lap))
                }
                currentLapStart = c.t
                currentSplits = emptyMap()
                events.add(Event.LapStarted(c.t))
            } else {
                val start = currentLapStart
                if (start != null && currentSplits[c.gate.id] == null) {
                    val elapsed = c.t - start
                    currentSplits = currentSplits + (c.gate.id to elapsed)
                    val delta = best?.splits?.get(c.gate.id)?.let { elapsed - it }
                    events.add(Event.Split(c.gate, elapsed, delta))
                }
            }
        }
        return events
    }
}

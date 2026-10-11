package app.laptrace.logger.core

import kotlin.math.abs

/** The spoken lap cue, e.g. "1 12.4. Plus 0.6." ("one twelve point four"; "1 oh 5.2" reads "one oh five point two"). */
object LapCuePhrase {
    fun phrase(duration: Double, previousBest: Double?): String {
        val tenths = roundHalfAway(duration * 10).toInt()
        val m = tenths / 600
        val sec = (tenths % 600).toDouble() / 10
        var s = when {
            m == 0 -> fmt(sec, 1)
            sec < 10 -> "$m oh ${fmt(sec, 1)}"
            else -> "$m ${fmt(sec, 1)}"
        }
        s += "."
        if (previousBest != null) {
            val d = (duration - previousBest) * 10
            val r = abs(roundHalfAway(d)) / 10
            s += if (d < 0) " Best lap. Minus ${fmt(r, 1)}." else " Plus ${fmt(r, 1)}."
        }
        return s
    }
}

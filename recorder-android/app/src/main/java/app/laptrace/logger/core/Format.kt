package app.laptrace.logger.core

import java.math.BigDecimal
import java.math.RoundingMode
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor

/**
 * C-printf style "%.{decimals}f": rounds the exact binary value, ties to even, keeps "-0.000".
 * java.util.Formatter rounds differently in edge cases, and the CSV must match the iOS output.
 * Non-finite values are written as 0, like the iOS exporter.
 */
fun fmt(v: Double, decimals: Int): String {
    val x = if (v.isFinite()) v else 0.0
    val s = BigDecimal(x).setScale(decimals, RoundingMode.HALF_EVEN).toPlainString()
    val negative = x < 0 || (x == 0.0 && 1 / x < 0)
    return if (negative && !s.startsWith("-")) "-$s" else s
}

/** Swift's `Double.rounded()`: ties away from zero (Kotlin's round() is ties-to-even). */
fun roundHalfAway(x: Double): Double = if (x >= 0) floor(x + 0.5) else -floor(-x + 0.5)

/** Swift's `Double.rounded(.up)`. */
fun roundUp(x: Double): Double = ceil(x)

/** Index of the first element >= x in an ascending array. */
fun lowerBound(a: DoubleArray, x: Double): Int {
    var lo = 0
    var hi = a.size
    while (lo < hi) {
        val m = (lo + hi) / 2
        if (a[m] < x) lo = m + 1 else hi = m
    }
    return lo
}

fun correlation(x: DoubleArray, y: DoubleArray): Double {
    val n = x.size.toDouble()
    if (!(n > 2)) return 0.0
    val mx = x.sum() / n
    val my = y.sum() / n
    var sxy = 0.0
    var sxx = 0.0
    var syy = 0.0
    for (i in x.indices) {
        val dx = x[i] - mx
        val dy = y[i] - my
        sxy += dx * dy; sxx += dx * dx; syy += dy * dy
    }
    return if (sxx > 0 && syy > 0) sxy / Math.sqrt(sxx * syy) else 0.0
}

/** Display formatting shared by the screens and the debrief text. */
object Fmt {
    fun lap(s: Double?): String {
        if (s == null || !s.isFinite() || s < 0) return "–:–.–"
        val m = s.toInt() / 60
        val rest = s - (m * 60).toDouble()
        return "$m:" + fmt(rest, 3).padStart(6, '0')
    }

    fun delta(d: Double?): String {
        if (d == null) return ""
        return (if (d >= 0) "+" else "−") + fmt(abs(d), 2)
    }

    fun km(m: Double?): String {
        if (m == null) return "–"
        return if (m < 1000) fmt(m, 0) + " m" else fmt(m / 1000, 1) + " km"
    }

    fun duration(s: Double): String {
        val total = s.toInt()
        val h = total / 3600
        val m = total / 60 % 60
        val sec = total % 60
        return if (h > 0) String.format(java.util.Locale.US, "%d:%02d:%02d", h, m, sec)
        else String.format(java.util.Locale.US, "%d:%02d", m, sec)
    }
}

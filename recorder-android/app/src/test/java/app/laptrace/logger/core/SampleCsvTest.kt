package app.laptrace.logger.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Android export must stay readable next to the shared sample (shared/sample-phone-session.csv). */
class SampleCsvTest {
    private fun sample(): String =
        requireNotNull(javaClass.classLoader?.getResource("sample-phone-session.csv")) { "sample CSV missing" }.readText()

    private fun split(csv: String): Pair<Map<String, String>, List<String>> {
        val (head, body) = csv.split("\n\n", limit = 2).let { it[0] to it[1] }
        val meta = head.lines().filter { it.isNotBlank() }.associate { it.substringBefore(',') to it.substringAfter(',') }
        return meta to body.lines()
    }

    @Test
    fun exportHasSameShapeAsSharedSample() {
        val (sampleMeta, sampleBody) = split(sample())
        val sampleHeader = sampleBody.first().split(",")
        assertTrue(sampleMeta.containsKey("Format"))
        assertTrue(sampleMeta.containsKey("Date UTC"))

        val synth = SyntheticSession()
        val data = synth.generate()
        val result = assertNotNullReturn(Exporter().export(data.fixes, data.motion, synth.track))
        val (meta, body) = split(result.csv)
        val header = body.first().split(",")

        // Metadata block: the same keys as the sample, plus ours; Device says Android.
        assertEquals("Laptrace Logger CSV", meta["Format"])
        assertTrue(meta["Date UTC"]!!.matches(Regex("""\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ""")))
        assertEquals("Android", meta["Device"])
        assertEquals("Synthetic ring", meta["Track"])
        assertTrue(meta["Best Lap"]!!.matches(Regex("""Lap \d+ \d+\.\d{3} s""")))

        // Every sample column exists, in the same order, with the same spelling.
        val positions = sampleHeader.map { header.indexOf(it) }
        assertTrue("missing columns: $sampleHeader vs $header", positions.all { it >= 0 })
        assertEquals(positions.sorted(), positions)
        assertEquals(listOf("GPS Accuracy (m)", "GPS Fix"), header.takeLast(2))

        // Data rows: numeric, one value per column, 10 Hz time grid.
        val rows = body.drop(1).filter { it.isNotEmpty() }.map { it.split(",") }
        assertTrue(rows.all { it.size == header.size })
        assertTrue(rows.all { r -> r.all { it.toDoubleOrNull() != null } })
        assertEquals(0.1, rows[1][0].toDouble() - rows[0][0].toDouble(), 1e-6)
    }
}

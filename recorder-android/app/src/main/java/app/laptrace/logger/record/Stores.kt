package app.laptrace.logger.record

import android.content.Context
import android.os.Build
import app.laptrace.logger.core.Coach
import app.laptrace.logger.core.Exporter
import app.laptrace.logger.core.Gate
import app.laptrace.logger.core.LatLon
import app.laptrace.logger.core.RawFiles
import app.laptrace.logger.core.SessionMeta
import app.laptrace.logger.core.Track
import app.laptrace.logger.core.TrackJson
import app.laptrace.logger.core.fmt
import app.laptrace.logger.core.haversineMeters
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.Json
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

/**
 * Sessions live in filesDir/Sessions/<id>/:
 * meta.json, gps.csv (raw fixes), motion.bin (raw IMU), and the exported CSV.
 */
object SessionStore {
    private lateinit var root: File
    private val _sessions = MutableStateFlow<List<SessionMeta>>(emptyList())
    val sessions: StateFlow<List<SessionMeta>> = _sessions

    private val json = Json { prettyPrint = true; explicitNulls = false; ignoreUnknownKeys = true; encodeDefaults = true }
    private val idFormat = DateTimeFormatter.ofPattern("yyyy-MM-dd_HH-mm-ss", Locale.US)

    fun init(context: Context) {
        if (::root.isInitialized) return
        root = File(context.filesDir, "Sessions").apply { mkdirs() }
        reload()
    }

    fun folder(id: String) = File(root, id)
    fun gpsFile(id: String) = File(folder(id), "gps.csv")
    fun motionFile(id: String) = File(folder(id), "motion.bin")
    private fun metaFile(id: String) = File(folder(id), "meta.json")

    @Synchronized
    fun reload() {
        val dirs = root.listFiles()?.filter { it.isDirectory } ?: emptyList()
        _sessions.value = dirs.mapNotNull { dir ->
            runCatching { json.decodeFromString(SessionMeta.serializer(), File(dir, "meta.json").readText()) }.getOrNull()
        }.sortedByDescending { it.started }
    }

    fun get(id: String): SessionMeta? = _sessions.value.firstOrNull { it.id == id }

    fun create(trackId: String?, trackName: String?, mode: String? = null): SessionMeta {
        val now = Instant.now().truncatedTo(ChronoUnit.SECONDS)
        var id = idFormat.format(now.atZone(ZoneId.systemDefault()))
        // Two recordings in the same second (e.g. a discarded auto-start) must not share a folder.
        var n = 2
        while (folder(id).exists()) { id = idFormat.format(now.atZone(ZoneId.systemDefault())) + "-" + n++ }
        val meta = SessionMeta(id = id, started = now, trackId = trackId, trackName = trackName, mode = mode)
        folder(meta.id).mkdirs()
        save(meta)
        return meta
    }

    fun save(meta: SessionMeta) {
        val f = metaFile(meta.id)
        f.parentFile?.mkdirs()
        val tmp = File(f.parentFile, "meta.json.tmp")
        tmp.writeText(json.encodeToString(SessionMeta.serializer(), meta))
        tmp.renameTo(f)
        reload()
    }

    fun delete(meta: SessionMeta) {
        folder(meta.id).deleteRecursively()
        reload()
    }

    class ExportException(message: String) : Exception(message)

    /** Builds the shared-format CSV for a session and writes it into the session folder. */
    fun exportCSV(meta: SessionMeta, track: Track?): Pair<File, Exporter.Summary> {
        val fixes = RawFiles.readFixes(gpsFile(meta.id))
        val motion = RawFiles.readMotion(motionFile(meta.id))
        val exporter = Exporter(Exporter.Options(device = deviceName(), extraMeta = meta.csvMeta))
        val result = exporter.export(fixes, motion, track)
            ?: throw ExportException("Not enough usable GPS fixes to export this session.")
        val file = File(folder(meta.id), meta.exportFileName)
        file.writeText(result.csv, Charsets.UTF_8)
        return file to result.summary
    }

    /** Lap stats and one coaching goal, computed from the raw GPS file. */
    fun debrief(meta: SessionMeta, track: Track?): Coach.Debrief? {
        val laps = Exporter().coachLaps(RawFiles.readFixes(gpsFile(meta.id)), track)
        return Coach.debrief(laps, meta.trackName)
    }

    private fun deviceName() = "Laptrace Logger on Android ${Build.MODEL}"
}

/** Built-in tracks from assets/tracks.json plus start/finish lines the driver set. */
object TrackStore {
    private lateinit var customFile: File
    private val _bundled = MutableStateFlow<List<Track>>(emptyList())
    private val _custom = MutableStateFlow<List<Track>>(emptyList())
    val bundled: StateFlow<List<Track>> = _bundled
    val custom: StateFlow<List<Track>> = _custom
    val all: List<Track> get() = _custom.value + _bundled.value

    fun init(context: Context) {
        if (::customFile.isInitialized) return
        customFile = File(context.filesDir, "custom-tracks.json")
        _bundled.value = runCatching {
            context.assets.open("tracks.json").use { TrackJson.parseBundled(it.readBytes().toString(Charsets.UTF_8)) }
        }.getOrDefault(emptyList())
        _custom.value = runCatching { TrackJson.parseList(customFile.readText()) }.getOrDefault(emptyList())
    }

    fun byId(id: String?): Track? = id?.let { i -> all.firstOrNull { it.id == i } }

    fun nearest(p: LatLon): Track? = TrackJson.nearest(all, p)

    /** Creates (or replaces) a custom track with a start/finish line at `point`. */
    fun saveCustomStartFinish(point: LatLon, travelBearing: Double, name: String? = null): Track {
        val sf = Gate.perpendicular("sf", "Start / Finish", point, travelBearing)
        val track = Track(
            id = "custom-${System.currentTimeMillis() / 1000}",
            name = name ?: "Custom track ${fmt(point.lat, 4)}, ${fmt(point.lon, 4)}",
            country = null, center = point, radiusMeters = 2000.0, gates = listOf(sf),
        )
        _custom.value = listOf(track) + _custom.value.filter { haversineMeters(it.center, point) >= 2000 }
        runCatching { customFile.writeText(TrackJson.encodeList(_custom.value)) }
        return track
    }
}

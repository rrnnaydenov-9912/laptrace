package app.laptrace.logger.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * Directed timing line. A crossing counts when the path intersects
 * start→end while travelling within ±90° of `travelBearing`.
 */
@Serializable
data class Gate(
    val id: String,
    val label: String,
    val start: LatLon,
    val end: LatLon,
    val travelBearing: Double,
) {
    val isStartFinish: Boolean get() = id == "sf"

    companion object {
        /** Gate built perpendicular to the direction of travel through `point`. */
        fun perpendicular(id: String, label: String, through: LatLon, travelBearing: Double, halfWidth: Double = 15.0): Gate {
            val proj = LocalProjection(through)
            val side = Vec2.fromBearing(travelBearing + 90) * halfWidth
            return Gate(
                id = id, label = label,
                start = proj.unproject(Vec2(0.0, 0.0) - side),
                end = proj.unproject(side),
                travelBearing = normalizeDegrees(travelBearing),
            )
        }
    }
}

@Serializable
data class Track(
    val id: String,
    val name: String,
    val country: String? = null,
    val center: LatLon,
    val radiusMeters: Double,
    val gates: List<Gate>,
    val corners: List<TrackCorner>? = null,
) {
    val startFinish: Gate? get() = gates.firstOrNull { it.isStartFinish }
    val splits: List<Gate> get() = gates.filter { !it.isStartFinish }
}

/** Optional named corner in tracks.json, e.g. {"number": 1, "name": "Hairpin", "note": "Brake at the 100 m board"}. */
@Serializable
data class TrackCorner(val number: Int, val name: String? = null, val note: String? = null)

@Serializable
private data class TrackFile(val version: Int, val tracks: List<Track>)

object TrackJson {
    val json = Json { ignoreUnknownKeys = true; explicitNulls = false; prettyPrint = false }

    fun parseBundled(text: String): List<Track> =
        runCatching { json.decodeFromString(TrackFile.serializer(), text).tracks }.getOrDefault(emptyList())

    fun parseList(text: String): List<Track> =
        runCatching { json.decodeFromString(ListSerializer(Track.serializer()), text) }.getOrDefault(emptyList())

    fun encodeList(tracks: List<Track>): String = json.encodeToString(ListSerializer(Track.serializer()), tracks)

    /** Closest track whose radius contains `p`. */
    fun nearest(tracks: List<Track>, p: LatLon): Track? =
        tracks.map { it to haversineMeters(it.center, p) }
            .filter { it.second <= it.first.radiusMeters }
            .minByOrNull { it.second }?.first
}

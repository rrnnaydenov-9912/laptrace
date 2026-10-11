package app.laptrace.logger.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.time.Instant
import java.time.temporal.ChronoUnit

/** ISO 8601 (UTC, whole seconds) like the iOS meta.json. */
object IsoInstantSerializer : KSerializer<Instant> {
    override val descriptor = PrimitiveSerialDescriptor("IsoInstant", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeString(value.truncatedTo(ChronoUnit.SECONDS).toString())
    override fun deserialize(decoder: Decoder): Instant = Instant.parse(decoder.decodeString())
}

/** Metadata saved next to the raw files of one recording. */
@Serializable
data class SessionMeta(
    val id: String,
    @Serializable(with = IsoInstantSerializer::class) val started: Instant,
    @Serializable(with = IsoInstantSerializer::class) val ended: Instant? = null,
    val trackId: String? = null,
    val trackName: String? = null,
    val fixCount: Int = 0,
    val motionCount: Int = 0,
    val laps: List<CompletedLap> = emptyList(),
    val driver: String? = null,
    val vehicle: String? = null,
    val notes: String? = null,
    @Serializable(with = IsoInstantSerializer::class) val videoStart: Instant? = null,
    /** "drive" for a road drive, null or "track" for a track session. */
    val mode: String? = null,
    /** Road drives only: metres travelled and top speed in km/h. */
    val distance: Double? = null,
    val topSpeed: Double? = null,
) {
    val isDrive: Boolean get() = mode == "drive"
    val duration: Double get() = ((ended ?: Instant.now()).toEpochMilli() - started.toEpochMilli()) / 1000.0
    val best: CompletedLap? get() = laps.minByOrNull { it.duration }
    val title: String get() = if (isDrive) "Drive" else (trackName ?: "Session")

    /** Optional rows for the CSV metadata block. */
    val csvMeta: List<Pair<String, String>>
        get() {
            val out = mutableListOf("Mode" to if (isDrive) "Drive" else "Track")
            driver?.let { out.add("Driver" to it) }
            vehicle?.let { out.add("Vehicle" to it) }
            notes?.let { out.add("Notes" to it) }
            videoStart?.let { out.add("Video Start UTC" to it.truncatedTo(ChronoUnit.SECONDS).toString()) }
            return out
        }

    /** File-name-safe label used in the export name. */
    val safeTitle: String
        get() = (if (isDrive) "Drive" else trackName ?: "session").replace(Regex("[^A-Za-z0-9]+"), "-")

    val exportFileName: String get() = "Laptrace_${safeTitle}_$id.csv"
}

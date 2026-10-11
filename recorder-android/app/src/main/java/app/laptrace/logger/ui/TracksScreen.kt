package app.laptrace.logger.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.outlined.Flag
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.laptrace.logger.core.LocalProjection
import app.laptrace.logger.core.Track
import app.laptrace.logger.record.TrackStore
import kotlin.math.max

@Composable
fun TracksScreen() {
    val custom by TrackStore.custom.collectAsState()
    val bundled by TrackStore.bundled.collectAsState()
    var openId by rememberSaveable { mutableStateOf<String?>(null) }
    val open = openId?.let { id -> (custom + bundled).firstOrNull { it.id == id } }
    if (open != null) {
        BackHandler { openId = null }
        TrackDetail(open) { openId = null }
        return
    }
    LazyColumn(Modifier.fillMaxSize()) {
        item { ScreenTitle("Tracks") }
        if (custom.isNotEmpty()) item {
            Section("Your tracks") {
                custom.forEachIndexed { i, t ->
                    if (i > 0) RowDivider()
                    NavRow(t.name) { openId = t.id }
                }
            }
        }
        item {
            Section("Built in") {
                bundled.forEachIndexed { i, t ->
                    if (i > 0) RowDivider()
                    NavRow(t.name) { openId = t.id }
                }
            }
        }
        item {
            Section {
                Text(
                    "Tip: at a track that isn't listed, drive over the start line once and tap Set start/finish here on the Record tab.",
                    fontSize = 13.sp, color = Secondary, modifier = Modifier.padding(16.dp),
                )
            }
        }
    }
}

@Composable
fun NavRow(text: String, sub: String? = null, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (sub != null) Text(sub, fontSize = 12.sp, color = Secondary)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = Secondary)
    }
}

@Composable
fun DetailTopBar(title: String, onBack: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Orange) }
        Text(title, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

private val flags = listOf(
    Triple(Green, "Green", "Track is clear. Go."),
    Triple(Yellow, "Yellow", "Danger ahead. Slow down, no overtaking, be ready to stop."),
    Triple(Red, "Red", "Session stopped. Slow down, stop safely if told to, and return to the pits slowly."),
    Triple(Blue, "Blue", "A faster car is behind you. Hold your line and let it by."),
    Triple(Color.Black, "Black", "Come into the pits."),
    Triple(Color.White, "Chequered", "Session over. Do one slow cool-down lap, then pit."),
)

@Composable
private fun TrackDetail(track: Track, onBack: () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        DetailTopBar(track.name, onBack)
        LazyColumn(Modifier.fillMaxSize()) {
            item { GateSketch(track) }
            item {
                Section("Before you drive") {
                    flags.forEachIndexed { i, (color, name, meaning) ->
                        if (i > 0) RowDivider()
                        Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
                            val shape = RoundedCornerShape(3.dp)
                            val swatch = Modifier.padding(top = 3.dp).size(22.dp, 14.dp)
                            Spacer(
                                if (name == "Chequered")
                                    swatch.background(Brush.horizontalGradient(listOf(Color.White, Color.Black, Color.White, Color.Black)), shape)
                                else swatch.background(color, shape).then(if (color == Color.Black) Modifier.border(1.dp, Secondary, shape) else Modifier),
                            )
                            Spacer(Modifier.width(12.dp))
                            Column {
                                Text("$name flag", fontWeight = FontWeight.Bold, fontSize = 15.sp)
                                Text(meaning, fontSize = 15.sp, color = Secondary)
                            }
                        }
                    }
                }
            }
            item {
                Section("Good habits") {
                    listOf(
                        Icons.Filled.Speed to "Keep to the pit-lane speed limit, in and out.",
                        Icons.Filled.Visibility to "Your first laps are sighting laps: learn the track, don't push.",
                        Icons.Filled.Thermostat to "Tyres and brakes need a lap or two to warm up.",
                        Icons.Filled.SwapHoriz to "Leave a big gap to the car in front.",
                        Icons.Filled.DirectionsCar to "Check your mirrors before moving off the racing line.",
                    ).forEachIndexed { i, (icon, text) ->
                        if (i > 0) RowDivider()
                        Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(icon, contentDescription = null, tint = Orange)
                            Spacer(Modifier.width(12.dp))
                            Text(text)
                        }
                    }
                }
            }
            item {
                val corners = track.corners
                if (!corners.isNullOrEmpty()) {
                    Section("Corners") {
                        corners.forEachIndexed { i, c ->
                            if (i > 0) RowDivider()
                            Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
                                Text("Corner ${c.number}" + (c.name?.let { " – $it" } ?: ""), fontWeight = FontWeight.Bold, fontSize = 15.sp)
                                c.note?.let { Text(it, fontSize = 15.sp, color = Secondary) }
                            }
                        }
                    }
                } else {
                    Section("Timing lines", footer = "Lap and sector times are taken as you cross these lines.") {
                        track.gates.forEachIndexed { i, g ->
                            if (i > 0) RowDivider()
                            Row(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                                Icon(if (g.isStartFinish) Icons.Filled.Flag else Icons.Outlined.Flag, contentDescription = null, tint = Orange)
                                Spacer(Modifier.width(12.dp))
                                Text(g.label)
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Offline stand-in for the iOS satellite map: the track's timing lines drawn
 * to scale in a local metric plane, start/finish in orange, splits in cyan.
 */
@Composable
private fun GateSketch(track: Track) {
    val cyan = Color(0xFF32D2F0)
    Canvas(
        Modifier.fillMaxWidth().height(260.dp).padding(horizontal = 16.dp, vertical = 8.dp)
            .background(Color(0xFF101418), RoundedCornerShape(12.dp)),
    ) {
        val proj = LocalProjection(track.center)
        val segs = track.gates.map { g -> Triple(proj.project(g.start), proj.project(g.end), g.isStartFinish) }
        val xs = segs.flatMap { listOf(it.first.x, it.second.x) } + 0.0
        val ys = segs.flatMap { listOf(it.first.y, it.second.y) } + 0.0
        val spanX = max(xs.max() - xs.min(), 1.0)
        val spanY = max(ys.max() - ys.min(), 1.0)
        val pad = 32f
        val scale = minOf((size.width - 2 * pad) / spanX, (size.height - 2 * pad) / spanY).coerceAtMost(4.0)
        val cx = (xs.max() + xs.min()) / 2
        val cy = (ys.max() + ys.min()) / 2
        fun toScreen(x: Double, y: Double) = Offset(
            (size.width / 2 + (x - cx) * scale).toFloat(),
            (size.height / 2 - (y - cy) * scale).toFloat(),
        )
        // Centre marker and radius ring for context.
        drawCircle(Color(0x33FFFFFF), radius = (track.radiusMeters * scale).toFloat().coerceAtMost(size.minDimension), center = toScreen(0.0, 0.0), style = androidx.compose.ui.graphics.drawscope.Stroke(1f))
        for ((a, b, sf) in segs) {
            val c = if (sf) Orange else cyan
            drawLine(c, toScreen(a.x, a.y), toScreen(b.x, b.y), strokeWidth = 8f, cap = StrokeCap.Round)
            drawCircle(c, radius = 8f, center = toScreen(a.x, a.y))
        }
    }
}

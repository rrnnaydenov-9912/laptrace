package app.laptrace.logger.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GpsFixed
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.laptrace.logger.core.Coach
import app.laptrace.logger.core.Fmt
import app.laptrace.logger.core.SessionMeta
import app.laptrace.logger.core.fmt
import app.laptrace.logger.record.SessionStore
import app.laptrace.logger.record.TrackStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Debrief sections for a saved track session (rule-based coach; no on-device language model on Android). */
@Composable
fun DebriefSections(meta: SessionMeta) {
    var debrief by remember(meta.id) { mutableStateOf<Coach.Debrief?>(null) }
    var loaded by remember(meta.id) { mutableStateOf(false) }
    LaunchedEffect(meta.id) {
        val track = TrackStore.byId(meta.trackId)
        debrief = withContext(Dispatchers.Default) { runCatching { SessionStore.debrief(meta, track) }.getOrNull() }
        loaded = true
    }
    val d = debrief
    when {
        d != null -> {
            Section("Debrief") {
                KeyValue("Best lap", "${Fmt.lap(d.stats.bestLap)}  (lap ${d.stats.bestLapNumber})")
                RowDivider()
                KeyValue("Timed laps", "${d.stats.timedLaps}")
                RowDivider()
                KeyValue("Lap-time spread", "±${fmt(d.stats.lapSD, 2)} s")
                RowDivider()
                KeyValue("Best vs typical lap", "${fmt(d.stats.bestToMedian, 2)} s")
                d.stats.bestThreeAverage?.let {
                    RowDivider()
                    KeyValue("Best 3 laps in a row", Fmt.lap(it))
                }
            }
            Section("Next session goal", footer = "One thing to work on, based on your best lap compared with your others.") {
                Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.GpsFixed, contentDescription = null, tint = Orange)
                        Spacer(Modifier.width(8.dp))
                        Text(d.goal.title, color = Orange, fontWeight = FontWeight.SemiBold)
                    }
                    Text(d.goal.text)
                }
            }
        }
        loaded -> Section("Debrief") {
            Text(
                "No timed laps yet. Laps are counted when you cross the start/finish line, so pick a track or set the line before you drive.",
                color = Secondary, modifier = Modifier.padding(16.dp),
            )
        }
        else -> Section("Debrief") {
            Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Orange) }
        }
    }
}

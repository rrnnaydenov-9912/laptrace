package app.laptrace.logger.ui

import android.content.ClipData
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import app.laptrace.logger.core.Exporter
import app.laptrace.logger.core.Fmt
import app.laptrace.logger.core.SessionMeta
import app.laptrace.logger.core.fmt
import app.laptrace.logger.record.SessionStore
import app.laptrace.logger.record.TrackStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

private val rowDate = DateTimeFormatter.ofPattern("d MMM, HH:mm").withZone(ZoneId.systemDefault())
private val fullDate = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM).withZone(ZoneId.systemDefault())
private val timeOnly = DateTimeFormatter.ofPattern("HH:mm:ss").withZone(ZoneId.systemDefault())

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SessionsScreen() {
    LaunchedEffect(Unit) { SessionStore.reload() }
    val sessions by SessionStore.sessions.collectAsState()
    var openId by rememberSaveable { mutableStateOf<String?>(null) }
    var pendingDelete by remember { mutableStateOf<SessionMeta?>(null) }

    val open = openId?.let { SessionStore.get(it) }
    if (open != null) {
        BackHandler { openId = null }
        SessionDetail(open) { openId = null }
        return
    }

    Column(Modifier.fillMaxSize()) {
        ScreenTitle("Sessions")
        if (sessions.isEmpty()) {
            Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Filled.Flag, contentDescription = null, tint = Secondary, modifier = Modifier.size(48.dp))
                Spacer(Modifier.size(12.dp))
                Text("No sessions yet", fontSize = 22.sp, fontWeight = FontWeight.Bold)
                Text("Recordings appear here after you press Stop.", color = Secondary, textAlign = TextAlign.Center)
            }
        } else {
            LazyColumn(Modifier.fillMaxSize()) {
                item {
                    Section(footer = "Long-press a session to delete it.") {
                        sessions.forEachIndexed { i, s ->
                            if (i > 0) RowDivider()
                            SessionRow(s, Modifier.combinedClickable(onClick = { openId = s.id }, onLongClick = { pendingDelete = s }))
                        }
                    }
                }
            }
        }
    }

    pendingDelete?.let { s ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete this session?") },
            text = { Text("${s.title}, ${rowDate.format(s.started)}. The raw recording and any exported CSV are removed from this phone.") },
            confirmButton = { TextButton(onClick = { SessionStore.delete(s); pendingDelete = null }) { Text("Delete", color = Red) } },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun SessionRow(meta: SessionMeta, modifier: Modifier) {
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(if (meta.isDrive) Icons.Filled.DirectionsCar else Icons.Filled.Flag, contentDescription = null, tint = Orange, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(meta.title, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
        }
        val parts = mutableListOf(rowDate.format(meta.started))
        if (meta.isDrive) {
            parts += Fmt.km(meta.distance)
            meta.topSpeed?.let { parts += "top ${fmt(it, 0)} km/h" }
        } else {
            parts += "${meta.laps.size} laps"
            meta.best?.let { parts += "best ${Fmt.lap(it.duration)}" }
        }
        Text(parts.joinToString(" · "), fontSize = 12.sp, color = Secondary)
    }
}

@Composable
private fun SessionDetail(initial: SessionMeta, onBack: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var meta by remember(initial.id) { mutableStateOf(initial) }
    var exportFile by remember(initial.id) { mutableStateOf<File?>(null) }
    var summary by remember(initial.id) { mutableStateOf<Exporter.Summary?>(null) }
    var error by remember(initial.id) { mutableStateOf<String?>(null) }
    var working by remember(initial.id) { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }

    // Save edits when leaving, like the iOS onDisappear.
    val latest = remember { mutableStateOf(meta) }
    latest.value = meta
    DisposableEffect(initial.id) { onDispose { if (SessionStore.get(latest.value.id) != null) SessionStore.save(latest.value) } }

    fun edit(change: (SessionMeta) -> SessionMeta) { meta = change(meta); exportFile = null }

    fun share(file: File) {
        val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/csv"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, file.name)
            clipData = ClipData.newRawUri(file.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        ctx.startActivity(Intent.createChooser(send, "Share CSV"))
    }

    Column(Modifier.fillMaxSize()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) { DetailTopBar(meta.title, onBack) }
            IconButton(onClick = { confirmDelete = true }) { Icon(Icons.Filled.Delete, contentDescription = "Delete", tint = Red) }
        }
        LazyColumn(Modifier.fillMaxSize()) {
            if (!meta.isDrive) item { DebriefSections(meta) }
            item {
                Section("Details", footer = "Saved with the session and added to the CSV.") {
                    Column(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Field("Driver", meta.driver) { v -> edit { it.copy(driver = v) } }
                        Field("Car", meta.vehicle) { v -> edit { it.copy(vehicle = v) } }
                        Field("Notes (tyres, weather, setup…)", meta.notes, singleLine = false) { v -> edit { it.copy(notes = v) } }
                    }
                    meta.videoStart?.let { RowDivider(); KeyValue("Video started", timeOnly.format(it)) }
                }
            }
            item {
                Section(if (meta.isDrive) "Drive" else "Session") {
                    if (meta.isDrive) {
                        KeyValue("Distance", Fmt.km(meta.distance)); RowDivider()
                        KeyValue("Top speed", meta.topSpeed?.let { "${fmt(it, 0)} km/h" } ?: "–")
                    } else {
                        KeyValue("Track", meta.trackName ?: "None")
                    }
                    RowDivider(); KeyValue("Started", fullDate.format(meta.started))
                    RowDivider(); KeyValue("Duration", Fmt.duration(meta.duration))
                    RowDivider(); KeyValue("GPS fixes", "${meta.fixCount}")
                    RowDivider(); KeyValue("IMU samples", "${meta.motionCount}")
                }
            }
            if (!meta.isDrive && meta.laps.isNotEmpty()) item {
                Section("Laps (live timing)") {
                    val bestN = meta.best?.number
                    meta.laps.forEachIndexed { i, lap ->
                        if (i > 0) RowDivider()
                        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 11.dp)) {
                            Text("Lap ${lap.number}", modifier = Modifier.weight(1f))
                            Text(
                                Fmt.lap(lap.duration), fontFamily = FontFamily.Monospace,
                                fontWeight = if (lap.number == bestN) FontWeight.Bold else FontWeight.Normal,
                                color = if (lap.number == bestN) Green else Color.White,
                            )
                        }
                    }
                }
            }
            item {
                Section("Export", footer = "10 Hz CSV in the shared Laptrace format. Raw files stay in the app's Sessions folder.") {
                    val file = exportFile
                    if (file != null) {
                        ActionRow("Share CSV", Icons.Filled.Share) { share(file) }
                        summary?.let { sm ->
                            RowDivider(); KeyValue("Rows", "${sm.rows}")
                            RowDivider(); KeyValue("G-forces", if (sm.calibration.calibrated) "Phone IMU" else "From GPS")
                            Text(sm.calibration.source, fontSize = 12.sp, color = Secondary, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
                        }
                    } else {
                        ActionRow("Build CSV for Laptrace Studio", Icons.Outlined.Description, busy = working, enabled = !working) {
                            working = true; error = null
                            SessionStore.save(meta)
                            val m = meta
                            scope.launch {
                                val r = withContext(Dispatchers.Default) {
                                    runCatching { SessionStore.exportCSV(m, TrackStore.byId(m.trackId)) }
                                }
                                r.onSuccess { (f, sm) -> exportFile = f; summary = sm }
                                    .onFailure { error = it.message ?: "Export failed." }
                                working = false
                            }
                        }
                    }
                    error?.let { Text(it, color = Red, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) }
                }
            }
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete this session?") },
            text = { Text("The raw recording and any exported CSV are removed from this phone.") },
            confirmButton = { TextButton(onClick = { confirmDelete = false; SessionStore.delete(meta); onBack() }) { Text("Delete", color = Red) } },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun Field(label: String, value: String?, singleLine: Boolean = true, onChange: (String?) -> Unit) {
    OutlinedTextField(
        value = value ?: "",
        onValueChange = { onChange(it.ifEmpty { null }) },
        label = { Text(label) },
        singleLine = singleLine,
        maxLines = if (singleLine) 1 else 5,
        modifier = Modifier.fillMaxWidth(),
        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Orange, focusedLabelColor = Orange, cursorColor = Orange),
    )
}

@Composable
private fun ActionRow(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, busy: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = Orange)
        Spacer(Modifier.width(12.dp))
        Text(label, color = Orange, modifier = Modifier.weight(1f))
        if (busy) CircularProgressIndicator(Modifier.size(20.dp), color = Orange, strokeWidth = 2.dp)
    }
}

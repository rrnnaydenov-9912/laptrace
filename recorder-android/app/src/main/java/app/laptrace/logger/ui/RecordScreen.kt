package app.laptrace.logger.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BatteryStd
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.DoNotDisturbOn
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.ScreenLockRotation
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.PinDrop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.runtime.DisposableEffect
import app.laptrace.logger.core.Fmt
import app.laptrace.logger.core.fmt
import app.laptrace.logger.record.DriveDetection
import app.laptrace.logger.record.Permissions
import app.laptrace.logger.record.Prefs
import app.laptrace.logger.record.RecMode
import app.laptrace.logger.record.Recorder
import app.laptrace.logger.record.RecordingService
import app.laptrace.logger.record.TrackStore

private val mono = FontFamily.Monospace

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecordScreen() {
    val ctx = LocalContext.current
    val s by Recorder.state.collectAsState()
    val lastStopped by Recorder.lastStopped.collectAsState()
    val prefs = remember { Prefs.of(ctx) }
    var checklistDone by remember { mutableStateOf(prefs.getBoolean(Prefs.CHECKLIST_DONE, false)) }
    var showSettings by remember { mutableStateOf(false) }
    var showTrackPicker by remember { mutableStateOf(false) }
    var confirmStop by remember { mutableStateOf(false) }
    var sfMessage by remember { mutableStateOf<String?>(null) }
    var videoMarked by rememberSaveable { mutableStateOf(false) }

    val isDrive = if (s.recording) s.session?.isDrive == true else s.mode == RecMode.DRIVE

    val askLocation = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        Recorder.refreshPermission()
        Recorder.startPreview()
    }

    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        // Top bar: settings, title, track.
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { showSettings = true }) { Icon(Icons.Filled.Settings, contentDescription = "Settings", tint = Orange) }
            Text("Laptrace", fontWeight = FontWeight.SemiBold, fontSize = 17.sp, modifier = Modifier.weight(1f), textAlign = TextAlign.Center)
            if (!isDrive) {
                TextButton(onClick = { showTrackPicker = true }) {
                    Icon(Icons.Filled.Flag, contentDescription = null, tint = Orange, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(4.dp))
                    Text(s.track?.name ?: "No track", color = Orange, fontSize = 15.sp, maxLines = 1)
                }
            } else {
                Spacer(Modifier.width(48.dp))
            }
        }

        StatusBar(s.hasLocationPermission, s.gpsAccuracy, s.motionAvailable, s.recording, s.motionRate) {
            if (!s.hasLocationPermission) askLocation.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
        }

        if (!s.recording) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                listOf("Track" to RecMode.TRACK, "Drive" to RecMode.DRIVE).forEachIndexed { i, (label, m) ->
                    SegmentedButton(
                        selected = s.mode == m,
                        onClick = { Recorder.setMode(m) },
                        shape = SegmentedButtonDefaults.itemShape(i, 2),
                    ) { Text(label) }
                }
            }
        }

        Spacer(Modifier.weight(1f))
        if (isDrive) {
            BigClock(
                header = if (s.recording) (if (s.autoStarted) "Drive · started automatically" else "Drive") else "Road drive",
                clock = s.elapsed?.let { Fmt.duration(it) } ?: "0:00",
                speed = s.speedKmh,
            )
        } else {
            BigClock(
                header = if (s.currentLapStart == null) "Waiting for start line" else "Lap ${s.laps.size + 1}",
                clock = Fmt.lap(s.currentLapElapsed),
                speed = s.speedKmh,
            )
            val split = s.lastSplit
            Row(Modifier.fillMaxWidth().height(40.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                if (split != null) {
                    Text(split.label, color = Secondary)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        if (split.delta == null) "best" else Fmt.delta(split.delta),
                        fontSize = 28.sp, fontWeight = FontWeight.Bold, fontFamily = mono,
                        color = if ((split.delta ?: -1.0) < 0) Green else Red,
                    )
                }
            }
        }
        Spacer(Modifier.weight(1f))

        if (isDrive) {
            Stats(
                "Distance" to (if (s.recording) Fmt.km(s.driveDistance) else "–"),
                "Top speed" to (if (s.recording) "${fmt(s.driveTopSpeed, 0)} km/h" else "–"),
            )
        } else {
            Stats(
                "Last" to Fmt.lap(s.laps.lastOrNull()?.duration),
                "Best" to Fmt.lap(s.best?.duration),
                "Laps" to "${s.laps.size}",
            )
        }

        // Controls
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = {
                    if (s.recording) confirmStop = true
                    else if (!s.hasLocationPermission) askLocation.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
                    else {
                        videoMarked = false
                        RecordingService.start(ctx, s.mode, false)
                    }
                },
                modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = if (s.recording) Red else Orange, contentColor = Color.White),
            ) { Text(if (s.recording) "Stop" else "Start recording", fontSize = 20.sp, fontWeight = FontWeight.Bold) }

            if (s.recording) {
                OutlinedButton(onClick = { Recorder.markVideoStart(); videoMarked = true }, modifier = Modifier.fillMaxWidth()) {
                    Icon(if (videoMarked) Icons.Filled.CheckCircle else Icons.Filled.Videocam, contentDescription = null, tint = Orange)
                    Spacer(Modifier.width(8.dp))
                    Text(if (videoMarked) "Video start marked – tap again to re-mark" else "Mark video start", color = Orange)
                }
            }
            if (!isDrive) {
                OutlinedButton(onClick = {
                    sfMessage = if (Recorder.setStartFinishHere())
                        "Start/finish line set here. Laps count from your next crossing."
                    else
                        "Drive over the line at more than ~10 km/h to set it, so the direction is known."
                }, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Outlined.PinDrop, contentDescription = null, tint = Orange)
                    Spacer(Modifier.width(8.dp))
                    Text("Set start/finish here", color = Orange)
                }
            }
        }
    }

    if (!checklistDone && !s.recording) {
        Checklist { prefs.edit().putBoolean(Prefs.CHECKLIST_DONE, true).apply(); checklistDone = true }
    }

    if (confirmStop) {
        AlertDialog(
            onDismissRequest = { confirmStop = false },
            title = { Text("Stop recording?") },
            confirmButton = { TextButton(onClick = { confirmStop = false; Recorder.stop() }) { Text("Stop and save", color = Red) } },
            dismissButton = { TextButton(onClick = { confirmStop = false }) { Text("Cancel") } },
        )
    }
    sfMessage?.let { msg ->
        AlertDialog(
            onDismissRequest = { sfMessage = null },
            text = { Text(msg) },
            confirmButton = { TextButton(onClick = { sfMessage = null }) { Text("OK") } },
        )
    }
    if (showSettings) RecordSettings { showSettings = false }
    if (showTrackPicker) TrackPicker(selectedId = s.track?.id) { showTrackPicker = false }

    lastStopped?.let { meta ->
        val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet(onDismissRequest = { Recorder.lastStopped.value = null }, sheetState = sheet, containerColor = Color.Black) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Debrief", fontWeight = FontWeight.SemiBold, fontSize = 17.sp, modifier = Modifier.weight(1f))
                TextButton(onClick = { Recorder.lastStopped.value = null }) { Text("Done", fontWeight = FontWeight.Bold) }
            }
            LazyColumn(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
                item { DebriefSections(meta) }
            }
        }
    }
}

@Composable
private fun StatusBar(hasPermission: Boolean, acc: Double?, motion: Boolean, recording: Boolean, rate: Double, onGpsTap: () -> Unit) {
    val gpsText = when {
        !hasPermission -> "Allow location"
        acc == null || acc <= 0 -> "Searching…"
        else -> "GPS ±${fmt(acc, 0)} m"
    }
    val gpsColor = when {
        acc == null || acc <= 0 || !hasPermission -> Secondary
        acc <= 8 -> Green
        acc <= 20 -> Yellow
        else -> Red
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Pill(gpsText, gpsColor, Icons.Filled.MyLocation, Modifier.clickable(onClick = onGpsTap))
        Pill(
            if (motion) (if (recording) "IMU ${fmt(rate, 0)} Hz" else "IMU ready") else "No IMU",
            if (motion) Green else Secondary, Icons.Filled.PhoneAndroid,
        )
        Spacer(Modifier.weight(1f))
        if (recording) {
            Box(Modifier.size(8.dp).background(Red, CircleShape))
            Text("REC", color = Red, fontWeight = FontWeight.Bold, fontSize = 12.sp)
        }
    }
}

@Composable
private fun Pill(text: String, color: Color, icon: ImageVector, modifier: Modifier = Modifier) {
    Row(
        modifier.background(color.copy(alpha = 0.18f), RoundedCornerShape(50)).padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(4.dp))
        Text(text, color = color, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun BigClock(header: String, clock: String, speed: Double) {
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(header, color = Secondary, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
        Text(clock, fontSize = 64.sp, fontWeight = FontWeight.Bold, fontFamily = mono, maxLines = 1)
        Text("${fmt(speed, 0)} km/h", fontSize = 28.sp, fontWeight = FontWeight.SemiBold, fontFamily = mono, color = Secondary)
    }
}

@Composable
private fun Stats(vararg items: Pair<String, String>) {
    Row(
        Modifier.fillMaxWidth().background(Card, RoundedCornerShape(16.dp)).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        items.forEachIndexed { i, (label, value) ->
            if (i > 0) VerticalDivider(Modifier.height(40.dp), color = Color(0xFF38383A))
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(label, color = Secondary, fontSize = 12.sp)
                Text(value, fontSize = 20.sp, fontWeight = FontWeight.Bold, fontFamily = mono)
            }
        }
    }
}

@Composable
private fun Checklist(onDone: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.6f)).clickable(enabled = false) {}, contentAlignment = Alignment.Center) {
        Column(
            Modifier.padding(24.dp).background(Color(0xFF2C2C2E), RoundedCornerShape(20.dp)).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Before your first session", fontSize = 22.sp, fontWeight = FontWeight.Bold)
            listOf(
                Icons.Filled.PhoneAndroid to "Phone mounted firmly, so it can't move or fall",
                Icons.Filled.ScreenLockRotation to "Screen orientation locked",
                Icons.Filled.DoNotDisturbOn to "Do Not Disturb on, so calls don't interrupt",
                Icons.Filled.BatteryStd to "Battery above 50%",
            ).forEach { (icon, text) ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(icon, contentDescription = null, tint = Orange)
                    Spacer(Modifier.width(12.dp))
                    Text(text)
                }
            }
            Button(onClick = onDone, modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(top = 6.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Orange, contentColor = Color.White)) {
                Text("Got it", fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

private fun openAppSettings(ctx: Context) {
    ctx.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", ctx.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

/**
 * Settings sheet. Turning auto-detect on walks the Android permission ladder:
 * precise location, then background ("Allow all the time", which Android only
 * grants from a second request or the settings screen), then physical
 * activity, then notifications.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RecordSettings(onClose: () -> Unit) {
    val ctx = LocalContext.current
    val prefs = remember { Prefs.of(ctx) }
    var speakLaps by remember { mutableStateOf(prefs.getBoolean(Prefs.SPEAK_LAP_TIMES, true)) }
    val autoOn by DriveDetection.enabled.collectAsState()
    var perms by remember { mutableStateOf(0) } // bumps to recompose after permission results
    var needsBackground by remember { mutableStateOf(DriveDetection.needsBackgroundLocation(ctx)) }

    // Re-check when returning from the system settings screen.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val obs = LifecycleEventObserver { _, e ->
            if (e == Lifecycle.Event.ON_RESUME) {
                needsBackground = DriveDetection.needsBackgroundLocation(ctx)
                if (DriveDetection.enabled.value) DriveDetection.resume()
            }
        }
        lifecycle.addObserver(obs)
        onDispose { lifecycle.removeObserver(obs) }
    }

    fun finish() {
        DriveDetection.setEnabled(true)
        needsBackground = DriveDetection.needsBackgroundLocation(ctx)
        perms++
    }

    val askNotifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { finish() }
    fun stepNotifications() {
        if (Build.VERSION.SDK_INT >= 33 && !Permissions.hasNotifications(ctx)) askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS) else finish()
    }
    val askActivity = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { stepNotifications() }
    fun stepActivity() {
        if (Build.VERSION.SDK_INT >= 29 && !Permissions.hasActivityRecognition(ctx)) askActivity.launch(Manifest.permission.ACTIVITY_RECOGNITION) else stepNotifications()
    }
    val askBackground = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { stepActivity() }
    fun stepBackground() {
        if (Build.VERSION.SDK_INT >= 29 && !Permissions.hasBackgroundLocation(ctx)) askBackground.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION) else stepActivity()
    }
    val askFine = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        Recorder.refreshPermission()
        if (Permissions.hasFineLocation(ctx)) stepBackground() else finish()
    }
    fun enableAuto() {
        if (!Permissions.hasFineLocation(ctx)) askFine.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
        else stepBackground()
    }

    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = onClose, sheetState = sheet, containerColor = Color.Black) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Settings", fontWeight = FontWeight.SemiBold, fontSize = 17.sp, modifier = Modifier.weight(1f))
            TextButton(onClick = onClose) { Text("Done", fontWeight = FontWeight.Bold) }
        }
        LazyColumn(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            item {
                Section("Track") {
                    ToggleRow("Speak lap times", speakLaps) {
                        speakLaps = it
                        prefs.edit().putBoolean(Prefs.SPEAK_LAP_TIMES, it).apply()
                    }
                }
                Section(
                    "Drives",
                    footer = "Laptrace starts recording when it notices you're driving, and saves the drive when you've been parked for about 4 minutes. You don't need to open the app. Drives under 500 m are discarded. This needs location access set to \"Allow all the time\", and uses a little more battery. Turn off battery optimisation for Laptrace so Android doesn't stop it in the background.",
                ) {
                    ToggleRow("Auto-detect drives", autoOn) { on -> if (on) enableAuto() else DriveDetection.setEnabled(false) }
                    if (autoOn && needsBackground) {
                        RowDivider()
                        Row(
                            Modifier.fillMaxWidth().clickable { openAppSettings(ctx) }.padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Filled.Warning, contentDescription = null, tint = Orange)
                            Spacer(Modifier.width(12.dp))
                            Text("Set location access to \"Allow all the time\"", color = Orange)
                        }
                    }
                    if (autoOn) {
                        RowDivider()
                        Row(
                            Modifier.fillMaxWidth().clickable {
                                runCatching {
                                    ctx.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                                }.onFailure { openAppSettings(ctx) }
                            }.padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) { Text("Battery optimisation settings", color = Orange) }
                    }
                }
            }
        }
    }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TrackPicker(selectedId: String?, onClose: () -> Unit) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val custom by TrackStore.custom.collectAsState()
    val bundled by TrackStore.bundled.collectAsState()
    ModalBottomSheet(onDismissRequest = onClose, sheetState = sheet, containerColor = Color.Black) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Track", fontWeight = FontWeight.SemiBold, fontSize = 17.sp, modifier = Modifier.weight(1f))
            TextButton(onClick = onClose) { Text("Close") }
        }
        LazyColumn(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            item {
                Text("Auto-detect nearest track", color = Orange,
                    modifier = Modifier.fillMaxWidth().clickable { Recorder.selectTrack(null); onClose() }.padding(horizontal = 20.dp, vertical = 14.dp))
            }
            items(custom + bundled, key = { it.id }) { t ->
                Row(
                    Modifier.fillMaxWidth().clickable { Recorder.selectTrack(t); onClose() }.padding(horizontal = 20.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(t.name)
                        Text("${t.splits.size} splits", fontSize = 12.sp, color = Secondary)
                    }
                    if (t.id == selectedId) Icon(Icons.Filled.Check, contentDescription = null, tint = Orange)
                }
            }
        }
    }
}

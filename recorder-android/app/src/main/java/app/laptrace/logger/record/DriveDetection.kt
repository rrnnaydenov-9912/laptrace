package app.laptrace.logger.record

import android.annotation.SuppressLint
import android.app.ForegroundServiceStartNotAllowedException
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import app.laptrace.logger.core.GPSFix
import app.laptrace.logger.core.fmt
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Starts and stops road-drive recordings on its own.
 *
 * Waking up: the Activity Recognition Transition API sends IN_VEHICLE / WALKING transitions to
 * DriveTransitionReceiver, even when the app is closed. Passive location updates (fixes other apps
 * already asked for) are a second source of speed.
 * Starting: IN_VEHICLE ENTER, or three fixes within 30 s above 30 km/h.
 * Stopping (auto-started drives only): 4 minutes without a fix at 8 km/h or more, or 90 s of walking.
 * Drives shorter than 500 m are thrown away as false starts.
 */
@SuppressLint("StaticFieldLeak") // application context only
object DriveDetection {
    const val START_SPEED_KMH = 30.0
    const val STOP_SPEED_KMH = 8.0
    const val STOP_AFTER_SLOW_S = 240.0
    const val STOP_AFTER_WALKING_S = 90.0
    const val MIN_DRIVE_METERS = 500.0

    private lateinit var app: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private val _enabled = MutableStateFlow(false)
    val enabled: StateFlow<Boolean> = _enabled

    private val fastFixTimes = ArrayList<Double>()
    /** Wall-clock time the car was last seen moving. Parked phones often stop sending fixes. */
    private var lastMovingAt: Long? = null
    private var walkingSince: Long? = null
    private var parkTimer: Job? = null
    /** Set between asking for the service and the recorder actually starting. */
    private var starting = false

    fun init(context: Context) {
        if (::app.isInitialized) return
        app = context.applicationContext
        _enabled.value = Prefs.of(app).getBoolean(Prefs.AUTO_DETECT_DRIVES, false)
    }

    /** Auto-detect only works with "Allow all the time" location access. */
    fun needsBackgroundLocation(c: Context) = _enabled.value && !Permissions.hasBackgroundLocation(c)

    /** Called at every launch, at boot and after an app update. Registrations don't survive a reboot. */
    fun resume() {
        if (_enabled.value) begin()
    }

    fun setEnabled(on: Boolean) {
        _enabled.value = on
        Prefs.of(app).edit().putBoolean(Prefs.AUTO_DETECT_DRIVES, on).apply()
        if (on) begin() else end()
    }

    // ---------------------------------------------------------------- Monitoring

    private fun receiverIntent(action: String): PendingIntent {
        val i = Intent(app, DriveTransitionReceiver::class.java).setAction(action)
        // Mutable: Play services fills in the result extras.
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
        return PendingIntent.getBroadcast(app, action.hashCode(), i, flags)
    }

    @SuppressLint("MissingPermission")
    fun begin() {
        Recorder.onFix = { handle(it) }
        if (Permissions.hasActivityRecognition(app)) {
            val types = listOf(DetectedActivity.IN_VEHICLE, DetectedActivity.WALKING, DetectedActivity.RUNNING)
            val transitions = types.flatMap { t ->
                listOf(ActivityTransition.ACTIVITY_TRANSITION_ENTER, ActivityTransition.ACTIVITY_TRANSITION_EXIT).map {
                    ActivityTransition.Builder().setActivityType(t).setActivityTransition(it).build()
                }
            }
            try {
                ActivityRecognition.getClient(app)
                    .requestActivityTransitionUpdates(ActivityTransitionRequest(transitions), receiverIntent(ACTION_TRANSITION))
            } catch (_: SecurityException) {}
        }
        if (Permissions.hasFineLocation(app) && Permissions.hasBackgroundLocation(app)) {
            val req = LocationRequest.Builder(Priority.PRIORITY_PASSIVE, 5_000).setMinUpdateIntervalMillis(1_000).build()
            try {
                LocationServices.getFusedLocationProviderClient(app).requestLocationUpdates(req, receiverIntent(ACTION_LOCATION))
            } catch (_: SecurityException) {}
        }
    }

    @SuppressLint("MissingPermission")
    private fun end() {
        Recorder.onFix = null
        try { ActivityRecognition.getClient(app).removeActivityTransitionUpdates(receiverIntent(ACTION_TRANSITION)) } catch (_: Exception) {}
        try { LocationServices.getFusedLocationProviderClient(app).removeLocationUpdates(receiverIntent(ACTION_LOCATION)) } catch (_: Exception) {}
        fastFixTimes.clear()
    }

    // ---------------------------------------------------------------- Decisions

    fun onTransitions(result: ActivityTransitionResult) {
        if (!_enabled.value) return
        for (e in result.transitionEvents) {
            val enter = e.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER
            when (e.activityType) {
                DetectedActivity.WALKING, DetectedActivity.RUNNING ->
                    walkingSince = if (enter) (walkingSince ?: System.currentTimeMillis()) else null
                DetectedActivity.IN_VEHICLE -> {
                    if (enter) {
                        walkingSince = null
                        if (!Recorder.current.recording) startDrive()
                    }
                }
            }
        }
        if (Recorder.current.recording) checkParked()
    }

    fun handle(fix: GPSFix) {
        if (!_enabled.value || fix.hAcc <= 0 || fix.hAcc > 50 || fix.speed < 0) return
        val kmh = fix.speed * 3.6
        val s = Recorder.current
        if (!s.recording) {
            if (kmh > START_SPEED_KMH) {
                fastFixTimes.add(fix.t)
                fastFixTimes.removeAll { fix.t - it > 30 }
                if (fastFixTimes.size >= 3) startDrive()
            }
        } else {
            if (!s.autoStarted) return
            if (kmh >= STOP_SPEED_KMH) lastMovingAt = System.currentTimeMillis()
            checkParked()
        }
    }

    /** From the "Driving? Tap to record" notification: the app is in front, so the start is allowed. */
    fun startDriveFromPrompt() {
        Notifications.cancelPrompt(app)
        if (!Recorder.current.recording) startDrive()
    }

    private fun startDrive() {
        if (Recorder.current.recording || starting) return
        fastFixTimes.clear()
        lastMovingAt = System.currentTimeMillis()
        walkingSince = null
        starting = true
        try {
            RecordingService.start(app, RecMode.DRIVE, auto = true)
        } catch (e: Exception) {
            starting = false
            if (Build.VERSION.SDK_INT >= 31 && e is ForegroundServiceStartNotAllowedException) {
                Notifications.drivePrompt(app)
            } else if (e is IllegalStateException || e is SecurityException) {
                Notifications.drivePrompt(app)
            }
            return
        }
        parkTimer?.cancel()
        parkTimer = scope.launch {
            // Wait for the service to start the recorder, then check every 15 s.
            var waited = 0
            while (isActive && !Recorder.current.recording && waited < 20) { delay(500); waited++ }
            starting = false
            if (!Recorder.current.recording) return@launch
            Notifications.cancelPrompt(app)
            Notifications.post(app, "Recording a drive", "Laptrace noticed you're driving and started recording. It stops on its own when you park.")
            while (isActive && Recorder.current.recording) { delay(15_000); checkParked() }
        }
    }

    /** Stops an auto-started drive after 4 minutes without moving, or 90 s of walking. */
    private fun checkParked() {
        val s = Recorder.current
        if (!s.recording || !s.autoStarted) return
        val now = System.currentTimeMillis()
        lastMovingAt?.let { if ((now - it) / 1000.0 >= STOP_AFTER_SLOW_S) { stopDrive(); return } }
        walkingSince?.let { if ((now - it) / 1000.0 >= STOP_AFTER_WALKING_S) stopDrive() }
    }

    private fun stopDrive() {
        parkTimer?.cancel(); parkTimer = null
        lastMovingAt = null
        walkingSince = null
        val saved = Recorder.stop(MIN_DRIVE_METERS) ?: return
        val km = (saved.distance ?: 0.0) / 1000
        Notifications.post(app, "Drive saved", "${fmt(km, 1)} km, top speed ${fmt(saved.topSpeed ?: 0.0, 0)} km/h. Open Laptrace to export it.")
    }

    const val ACTION_TRANSITION = "app.laptrace.logger.DRIVE_TRANSITION"
    const val ACTION_LOCATION = "app.laptrace.logger.DRIVE_LOCATION"
}

/** Activity transitions and passive fixes for drive detection. Runs even when the app is closed. */
class DriveTransitionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // LaptraceApp.onCreate has already set up the stores and drive detection.
        if (ActivityTransitionResult.hasResult(intent)) {
            ActivityTransitionResult.extractResult(intent)?.let { DriveDetection.onTransitions(it) }
        }
        if (LocationResult.hasResult(intent)) {
            // While recording, the recorder's own GPS is the source; passive copies would duplicate rows.
            if (!Recorder.current.recording) {
                LocationResult.extractResult(intent)?.locations?.forEach { DriveDetection.handle(Recorder.fixFrom(it)) }
            }
        }
    }
}

/** Activity transition and passive location registrations don't survive a reboot or an update. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        DriveDetection.resume()
    }
}

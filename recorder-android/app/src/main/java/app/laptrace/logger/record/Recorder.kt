package app.laptrace.logger.record

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import app.laptrace.logger.core.AppendWriter
import app.laptrace.logger.core.CompletedLap
import app.laptrace.logger.core.GPSFix
import app.laptrace.logger.core.LapTimer
import app.laptrace.logger.core.MotionSample
import app.laptrace.logger.core.SessionMeta
import app.laptrace.logger.core.TimedPoint
import app.laptrace.logger.core.Track
import app.laptrace.logger.core.Vec3
import app.laptrace.logger.core.haversineMeters
import com.google.android.gms.location.LocationCallback
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
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.max

enum class RecMode { TRACK, DRIVE }

data class LastSplit(val label: String, val delta: Double?)

/** Everything the UI and the notification show. */
data class RecState(
    val recording: Boolean = false,
    val mode: RecMode = RecMode.TRACK,
    val autoStarted: Boolean = false,
    val driveDistance: Double = 0.0,
    val driveTopSpeed: Double = 0.0,
    val lastFix: GPSFix? = null,
    val track: Track? = null,
    val session: SessionMeta? = null,
    val laps: List<CompletedLap> = emptyList(),
    val currentLapStart: Double? = null,
    val lastSplit: LastSplit? = null,
    val motionAvailable: Boolean = false,
    val motionRate: Double = 0.0,
    val now: Instant = Instant.now(),
    val hasLocationPermission: Boolean = false,
) {
    val best: CompletedLap? get() = laps.minByOrNull { it.duration }
    val elapsed: Double? get() = session?.let { (now.toEpochMilli() - it.started.toEpochMilli()) / 1000.0 }
    val currentLapElapsed: Double? get() = currentLapStart?.let { now.toEpochMilli() / 1000.0 - it }
    val speedKmh: Double get() = max(0.0, lastFix?.speed ?: 0.0) * 3.6
    val gpsAccuracy: Double? get() = lastFix?.hAcc
}

/**
 * Owns the sensors. Raw data goes straight to disk; live timing runs on GPS.
 * One recorder for the app, so drive detection can start a recording without the UI.
 * All state changes happen on the main thread; IMU samples are written from a sensor thread.
 */
@SuppressLint("StaticFieldLeak") // holds the application context only
object Recorder {
    private lateinit var app: Context
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private val _state = MutableStateFlow(RecState())
    val state: StateFlow<RecState> = _state
    val current: RecState get() = _state.value

    /** The session just saved by Stop, for the debrief sheet. */
    val lastStopped = MutableStateFlow<SessionMeta?>(null)

    /** Fixes go to this hook too, so drive detection can watch speed without its own client. */
    var onFix: ((GPSFix) -> Unit)? = null

    private val timer = LapTimer()
    private lateinit var cue: LapCue
    private var gpsWriter: AppendWriter? = null
    @Volatile private var motionWriter: AppendWriter? = null
    private var fixCount = 0
    private val motionCount = AtomicInteger(0)
    private var motionCountAtTick = 0
    private var tick: Job? = null
    private var manualTrack = false
    private var lastDriveFix: GPSFix? = null
    private var gpsOn = false
    private var previewing = false
    private var sensorThread: HandlerThread? = null
    private var bootOffset = 0.0

    fun init(context: Context) {
        if (::app.isInitialized) return
        app = context.applicationContext
        cue = LapCue(app)
        val sm = app.getSystemService(SensorManager::class.java)
        val available = sm?.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION) != null &&
            sm.getDefaultSensor(Sensor.TYPE_GRAVITY) != null
        _state.update { it.copy(motionAvailable = available, hasLocationPermission = Permissions.hasFineLocation(app)) }
    }

    // ---------------------------------------------------------------- Preview

    /** GPS on without recording, so the driver sees accuracy and the track before starting. */
    fun startPreview() {
        previewing = true
        refreshPermission()
        startGPS()
    }

    /** Leaves GPS running while recording. */
    fun stopPreviewIfIdle() {
        previewing = false
        if (!current.recording) stopGPS()
    }

    fun refreshPermission() {
        val ok = Permissions.hasFineLocation(app)
        _state.update { it.copy(hasLocationPermission = ok) }
        if (ok && (previewing || current.recording)) startGPS()
    }

    private val locationCallback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            for (loc in result.locations) handle(fixFrom(loc))
        }
    }

    fun fixFrom(loc: Location) = GPSFix(
        t = loc.time / 1000.0,
        lat = loc.latitude, lon = loc.longitude,
        alt = if (loc.hasAltitude()) loc.altitude else 0.0,
        hAcc = if (loc.hasAccuracy()) loc.accuracy.toDouble() else -1.0,
        speed = if (loc.hasSpeed()) loc.speed.toDouble() else -1.0,
        course = if (loc.hasBearing()) loc.bearing.toDouble() else -1.0,
    )

    @SuppressLint("MissingPermission")
    private fun startGPS() {
        if (gpsOn || !Permissions.hasFineLocation(app)) return
        val req = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000)
            .setMinUpdateIntervalMillis(500)
            .setMinUpdateDistanceMeters(0f)
            .setWaitForAccurateLocation(false)
            .build()
        try {
            LocationServices.getFusedLocationProviderClient(app)
                .requestLocationUpdates(req, locationCallback, Looper.getMainLooper())
            gpsOn = true
        } catch (_: SecurityException) {
            gpsOn = false
        }
    }

    private fun stopGPS() {
        if (!gpsOn) return
        LocationServices.getFusedLocationProviderClient(app).removeLocationUpdates(locationCallback)
        gpsOn = false
    }

    // ---------------------------------------------------------------- Track selection

    fun selectTrack(t: Track?) {
        manualTrack = t != null
        timer.setTrack(if (current.recording && current.mode == RecMode.DRIVE) null else t)
        _state.update { it.copy(track = t) }
    }

    fun setMode(mode: RecMode) {
        if (!current.recording) _state.update { it.copy(mode = mode) }
    }

    /** Start/finish line here, perpendicular to the current direction of travel. */
    fun setStartFinishHere(): Boolean {
        val fix = current.lastFix ?: return false
        if (fix.course < 0 || fix.speed <= 3) return false
        val t = TrackStore.saveCustomStartFinish(fix.latLon, fix.course)
        selectTrack(t)
        current.session?.let { s -> _state.update { it.copy(session = s.copy(trackId = t.id, trackName = t.name)) } }
        return true
    }

    // ---------------------------------------------------------------- Recording

    /** Called by RecordingService once it is in the foreground. */
    fun start(mode: RecMode?, auto: Boolean) {
        if (current.recording) return
        val m = mode ?: current.mode
        val drive = m == RecMode.DRIVE
        lastDriveFix = null
        val track = current.track
        val meta = if (drive) SessionStore.create(null, null, "drive") else SessionStore.create(track?.id, track?.name)
        gpsWriter = AppendWriter(SessionStore.gpsFile(meta.id), flushThreshold = 4096)
        motionWriter = AppendWriter(SessionStore.motionFile(meta.id))
        fixCount = 0; motionCount.set(0); motionCountAtTick = 0
        timer.reset()
        timer.setTrack(if (drive) null else track)
        cue.prepare()
        _state.update {
            it.copy(
                recording = true, mode = m, autoStarted = auto, driveDistance = 0.0, driveTopSpeed = 0.0,
                session = meta, laps = emptyList(), currentLapStart = null, lastSplit = null, now = Instant.now(),
            )
        }
        startGPS()
        startMotion()
        tick?.cancel()
        tick = scope.launch {
            while (isActive) { delay(100); onTick() }
        }
    }

    /**
     * Stops and saves. Returns the saved session, or null when nothing was saved.
     * `minDistance` drops a drive that covered less distance (metres), e.g. a false auto-start.
     */
    fun stop(minDistance: Double = 0.0): SessionMeta? {
        val s = current
        var meta = s.session ?: return null
        if (!s.recording) return null
        tick?.cancel(); tick = null
        stopMotion()
        gpsWriter?.close(); motionWriter?.close()
        gpsWriter = null; motionWriter = null
        meta = meta.copy(ended = Instant.now(), fixCount = fixCount, motionCount = motionCount.get())
        val wasAuto = s.autoStarted
        _state.update { it.copy(recording = false, session = null, motionRate = 0.0, autoStarted = false) }
        if (!previewing) stopGPS()
        if (meta.isDrive) {
            meta = meta.copy(distance = s.driveDistance, topSpeed = s.driveTopSpeed)
            if (s.driveDistance < minDistance) {
                SessionStore.delete(meta)
                return null
            }
        } else {
            meta = meta.copy(laps = s.laps, trackId = s.track?.id, trackName = s.track?.name)
        }
        SessionStore.save(meta)
        // The debrief is about laps; drives (manual or automatic) don't get one.
        if (!wasAuto && !meta.isDrive) lastStopped.value = meta
        return meta
    }

    /** Remember the moment a camera started, so video can be lined up with the data later. */
    fun markVideoStart() {
        val s = current.session ?: return
        if (!current.recording) return
        val updated = s.copy(videoStart = Instant.now())
        _state.update { it.copy(session = updated) }
        SessionStore.save(updated)
    }

    private fun onTick() {
        val n = motionCount.get()
        val rate = current.motionRate * 0.8 + (n - motionCountAtTick) * 10 * 0.2
        motionCountAtTick = n
        _state.update { it.copy(now = Instant.now(), motionRate = rate) }
        gpsWriter?.flush()
    }

    // ---------------------------------------------------------------- IMU

    private var linear: FloatArray? = null
    private var gravity: FloatArray? = null
    private var gyro = FloatArray(3)

    private val sensorListener = object : SensorEventListener {
        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        override fun onSensorChanged(e: SensorEvent) {
            when (e.sensor.type) {
                Sensor.TYPE_GYROSCOPE -> gyro = e.values.copyOf(3)
                Sensor.TYPE_GRAVITY -> gravity = e.values.copyOf(3)
                Sensor.TYPE_LINEAR_ACCELERATION -> {
                    linear = e.values.copyOf(3)
                    // One sample per linear-acceleration event (50 Hz), with the latest gravity and rotation.
                    val g = gravity ?: return
                    val w = motionWriter ?: return
                    val a = e.values
                    val s = MotionSample(
                        t = bootOffset + e.timestamp / 1e9,
                        // Same units as the iOS recorder: user acceleration and gravity in g,
                        // gravity pointing towards the earth, rotation in rad/s.
                        accel = Vec3(a[0] / G, a[1] / G, a[2] / G),
                        gravity = Vec3(-g[0] / G, -g[1] / G, -g[2] / G),
                        rotation = Vec3(gyro[0].toDouble(), gyro[1].toDouble(), gyro[2].toDouble()),
                    )
                    w.append(s.toBytes())
                    motionCount.incrementAndGet()
                }
            }
        }
    }

    private const val G = 9.80665

    private fun startMotion() {
        val sm = app.getSystemService(SensorManager::class.java) ?: return
        val lin = sm.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION) ?: return
        val grav = sm.getDefaultSensor(Sensor.TYPE_GRAVITY) ?: return
        // Sensor timestamps are nanoseconds since boot; convert once to Unix time.
        bootOffset = System.currentTimeMillis() / 1000.0 - SystemClock.elapsedRealtimeNanos() / 1e9
        val thread = HandlerThread("laptrace-imu").apply { start() }
        sensorThread = thread
        val handler = Handler(thread.looper)
        val period = 20_000 // µs = 50 Hz
        sm.registerListener(sensorListener, lin, period, handler)
        sm.registerListener(sensorListener, grav, period, handler)
        sm.getDefaultSensor(Sensor.TYPE_GYROSCOPE)?.let { sm.registerListener(sensorListener, it, period, handler) }
    }

    private fun stopMotion() {
        app.getSystemService(SensorManager::class.java)?.unregisterListener(sensorListener)
        sensorThread?.quitSafely()
        sensorThread?.join(500)
        sensorThread = null
        gravity = null; linear = null
    }

    // ---------------------------------------------------------------- GPS

    /** Every fix from the recorder's own GPS, and from drive detection's passive updates while idle. */
    fun handle(fix: GPSFix) {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { handle(fix) }; return }
        _state.update { it.copy(lastFix = fix) }
        onFix?.invoke(fix)
        val s = current
        if (!manualTrack && (s.track == null || !s.recording)) {
            val t = TrackStore.nearest(fix.latLon)
            if (t != null && t.id != s.track?.id) {
                if (!(s.recording && s.mode == RecMode.DRIVE)) timer.setTrack(t)
                _state.update { it.copy(track = t) }
            }
        }
        if (!current.recording) return
        gpsWriter?.let { it.append(fix.csvLine.toByteArray(Charsets.UTF_8)); fixCount++ }
        if (fix.hAcc <= 0 || fix.hAcc > 30) return
        if (current.session?.isDrive == true) { accumulateDrive(fix); return }
        for (e in timer.ingest(TimedPoint(fix.t, fix.latLon))) {
            when (e) {
                is LapTimer.Event.LapStarted -> _state.update { it.copy(currentLapStart = e.at) }
                is LapTimer.Event.LapCompleted -> {
                    val lap = e.lap
                    cue.speak(lap.duration, current.best?.duration)
                    _state.update { st ->
                        val laps = st.laps + lap
                        val best = laps.minByOrNull { it.duration }
                        val delta = best?.let { lap.duration - it.duration }
                        st.copy(laps = laps, lastSplit = LastSplit("Lap ${lap.number}", if (lap.number == best?.number) null else delta))
                    }
                    vibrate()
                }
                is LapTimer.Event.Split -> _state.update { it.copy(lastSplit = LastSplit(e.gate.label, e.deltaToBest)) }
            }
        }
    }

    private fun accumulateDrive(fix: GPSFix) {
        if (fix.speed >= 0) _state.update { it.copy(driveTopSpeed = max(it.driveTopSpeed, fix.speed * 3.6)) }
        val prev = lastDriveFix
        lastDriveFix = fix
        if (prev == null) return
        val d = haversineMeters(prev.latLon, fix.latLon)
        // Ignore GPS jitter while parked and jumps that would need over 400 km/h.
        val dt = fix.t - prev.t
        if (d >= 1 && dt > 0 && d / dt < 110) _state.update { it.copy(driveDistance = it.driveDistance + d) }
    }

    private fun vibrate() {
        val v: Vibrator? = if (Build.VERSION.SDK_INT >= 31) {
            app.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION") app.getSystemService(Vibrator::class.java)
        }
        v?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 60, 80, 60), -1))
    }
}

package app.laptrace.logger.record

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import app.laptrace.logger.core.Fmt
import app.laptrace.logger.core.fmt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** Keeps the process alive and GPS flowing while a session records, with the screen off or the app closed. */
class RecordingService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var wakeLock: PowerManager.WakeLock? = null
    private var loop: kotlinx.coroutines.Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val mode = intent?.getStringExtra(EXTRA_MODE)?.let { RecMode.valueOf(it) }
        val auto = intent?.getBooleanExtra(EXTRA_AUTO, false) ?: false
        val notification = Notifications.recording(this, "Laptrace", "Starting…")
        try {
            ServiceCompat.startForeground(
                this, Notifications.ID_RECORDING, notification,
                if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0,
            )
        } catch (e: Exception) {
            // Location permission missing, or a background start Android refused.
            stopSelf()
            return START_NOT_STICKY
        }
        if (!Recorder.current.recording) Recorder.start(mode, auto)
        if (wakeLock == null) {
            wakeLock = getSystemService(PowerManager::class.java)
                ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "laptrace:recording")
                ?.apply { acquire(12 * 60 * 60 * 1000L) }
        }
        if (loop?.isActive != true) loop = scope.launch {
            while (isActive) {
                val s = Recorder.current
                if (!s.recording) { stopEverything(); break }
                update(s)
                delay(1000)
            }
        }
        return START_NOT_STICKY
    }

    private fun update(s: RecState) {
        val speed = "${fmt(s.speedKmh, 0)} km/h"
        val elapsed = Fmt.duration(s.elapsed ?: 0.0)
        val (title, text) = if (s.mode == RecMode.DRIVE) {
            (if (s.autoStarted) "Recording a drive" else "Recording drive") to "$elapsed · $speed · ${Fmt.km(s.driveDistance)}"
        } else {
            val lap = s.currentLapStart?.let { "Lap ${s.laps.size + 1} ${Fmt.lap(s.currentLapElapsed)}" } ?: "Waiting for start line"
            "Recording · ${s.track?.name ?: "No track"}" to "$lap · $speed · $elapsed"
        }
        try {
            NotificationManagerCompat.from(this).notify(Notifications.ID_RECORDING, Notifications.recording(this, title, text))
        } catch (_: SecurityException) {}
    }

    private fun stopEverything() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        scope.cancel()
        wakeLock?.let { if (it.isHeld) it.release() }
        // Swiped away or killed while recording: save what we have.
        if (Recorder.current.recording) Recorder.stop()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_MODE = "mode"
        const val EXTRA_AUTO = "auto"

        /** Throws ForegroundServiceStartNotAllowedException (API 31+) when Android refuses a background start. */
        fun start(c: Context, mode: RecMode, auto: Boolean) {
            val i = Intent(c, RecordingService::class.java)
                .putExtra(EXTRA_MODE, mode.name)
                .putExtra(EXTRA_AUTO, auto)
            c.startForegroundService(i)
        }
    }
}

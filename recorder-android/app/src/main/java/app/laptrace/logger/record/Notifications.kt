package app.laptrace.logger.record

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import app.laptrace.logger.MainActivity
import app.laptrace.logger.R

object Notifications {
    const val CH_RECORDING = "recording"
    const val CH_DRIVES = "drives"
    const val CH_PROMPT = "drive_prompt"
    const val ID_RECORDING = 1
    const val ID_PROMPT = 2
    private var nextId = 100

    fun createChannels(c: Context) {
        val nm = c.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannels(
            listOf(
                NotificationChannel(CH_RECORDING, "Recording", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while Laptrace is recording."
                },
                NotificationChannel(CH_DRIVES, "Drives", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "Automatic drive recordings started and saved."
                },
                NotificationChannel(CH_PROMPT, "Drive prompts", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Asks you to tap when Android won't let a drive start on its own."
                },
            )
        )
    }

    fun openApp(c: Context, startDrive: Boolean = false): PendingIntent {
        val i = Intent(c, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            if (startDrive) putExtra(MainActivity.EXTRA_START_DRIVE, true)
        }
        return PendingIntent.getActivity(c, if (startDrive) 1 else 0, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    fun recording(c: Context, title: String, text: String): Notification =
        NotificationCompat.Builder(c, CH_RECORDING)
            .setSmallIcon(R.drawable.ic_stat_laptrace)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(openApp(c))
            .build()

    fun post(c: Context, title: String, body: String) {
        if (!Permissions.hasNotifications(c)) return
        val n = NotificationCompat.Builder(c, CH_DRIVES)
            .setSmallIcon(R.drawable.ic_stat_laptrace)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(openApp(c))
            .build()
        try { NotificationManagerCompat.from(c).notify(nextId++, n) } catch (_: SecurityException) {}
    }

    /** Android blocked a background start: ask the driver to tap, which starts the drive from the foreground. */
    fun drivePrompt(c: Context) {
        if (!Permissions.hasNotifications(c)) return
        val n = NotificationCompat.Builder(c, CH_PROMPT)
            .setSmallIcon(R.drawable.ic_stat_laptrace)
            .setContentTitle("Driving? Tap to record")
            .setContentText("Android didn't let Laptrace start on its own. Tap to record this drive.")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setAutoCancel(true)
            .setTimeoutAfter(10 * 60 * 1000L)
            .setContentIntent(openApp(c, startDrive = true))
            .build()
        try { NotificationManagerCompat.from(c).notify(ID_PROMPT, n) } catch (_: SecurityException) {}
    }

    fun cancelPrompt(c: Context) = NotificationManagerCompat.from(c).cancel(ID_PROMPT)
}

package app.laptrace.logger.record

import android.content.Context
import android.content.SharedPreferences

/** Small settings, same keys as the iOS app's UserDefaults. */
object Prefs {
    const val SPEAK_LAP_TIMES = "speakLapTimes"
    const val AUTO_DETECT_DRIVES = "autoDetectDrives"
    const val CHECKLIST_DONE = "checklistDone"

    fun of(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences("laptrace", Context.MODE_PRIVATE)
}

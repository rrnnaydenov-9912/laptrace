package app.laptrace.logger.record

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

object Permissions {
    private fun granted(c: Context, p: String) = ContextCompat.checkSelfPermission(c, p) == PackageManager.PERMISSION_GRANTED

    fun hasFineLocation(c: Context) = granted(c, Manifest.permission.ACCESS_FINE_LOCATION)

    /** "Allow all the time". Needed for auto drives, which start while the app is closed. */
    fun hasBackgroundLocation(c: Context) =
        Build.VERSION.SDK_INT < 29 || granted(c, Manifest.permission.ACCESS_BACKGROUND_LOCATION)

    fun hasActivityRecognition(c: Context) =
        if (Build.VERSION.SDK_INT >= 29) granted(c, Manifest.permission.ACTIVITY_RECOGNITION)
        else granted(c, "com.google.android.gms.permission.ACTIVITY_RECOGNITION")

    fun hasNotifications(c: Context) =
        Build.VERSION.SDK_INT < 33 || granted(c, Manifest.permission.POST_NOTIFICATIONS)
}

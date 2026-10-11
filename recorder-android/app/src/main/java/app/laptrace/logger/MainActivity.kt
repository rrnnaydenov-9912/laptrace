package app.laptrace.logger

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.lifecycleScope
import app.laptrace.logger.record.DriveDetection
import app.laptrace.logger.record.Permissions
import app.laptrace.logger.record.Recorder
import app.laptrace.logger.ui.LaptraceTheme
import app.laptrace.logger.ui.Orange
import app.laptrace.logger.ui.RecordScreen
import app.laptrace.logger.ui.Secondary
import app.laptrace.logger.ui.SessionsScreen
import app.laptrace.logger.ui.TracksScreen
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    /** First launch: precise location (needed to record at all), then notifications on Android 13+. */
    private val askLocation = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        Recorder.refreshPermission()
        if (Build.VERSION.SDK_INT >= 33 && !Permissions.hasNotifications(this)) askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
    private val askNotifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        DriveDetection.resume()
        if (!Permissions.hasFineLocation(this)) {
            askLocation.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
        }
        handleIntent(intent)

        // Keep the screen on while recording, like the iOS idle-timer switch.
        lifecycleScope.launch {
            Recorder.state.collect { s ->
                if (s.recording) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }

        setContent {
            LaptraceTheme {
                var tab by rememberSaveable { mutableIntStateOf(0) }
                Scaffold(
                    containerColor = Color.Black,
                    bottomBar = {
                        NavigationBar(containerColor = Color(0xFF121212)) {
                            val items = listOf(
                                Triple("Record", Icons.Filled.FiberManualRecord, 0),
                                Triple("Sessions", Icons.AutoMirrored.Filled.List, 1),
                                Triple("Tracks", Icons.Filled.Flag, 2),
                            )
                            for ((label, icon, i) in items) {
                                NavigationBarItem(
                                    selected = tab == i,
                                    onClick = { tab = i },
                                    icon = { Icon(icon, contentDescription = null) },
                                    label = { Text(label) },
                                    colors = NavigationBarItemDefaults.colors(
                                        selectedIconColor = Orange, selectedTextColor = Orange,
                                        indicatorColor = Color.Transparent,
                                        unselectedIconColor = Secondary, unselectedTextColor = Secondary,
                                    ),
                                )
                            }
                        }
                    },
                ) { pad ->
                    Box(Modifier.fillMaxSize().padding(pad)) {
                        when (tab) {
                            0 -> RecordScreen()
                            1 -> SessionsScreen()
                            else -> TracksScreen()
                        }
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onStart() {
        super.onStart()
        Recorder.startPreview()
    }

    override fun onStop() {
        super.onStop()
        Recorder.stopPreviewIfIdle()
    }

    private fun handleIntent(i: Intent?) {
        if (i?.getBooleanExtra(EXTRA_START_DRIVE, false) == true) {
            i.removeExtra(EXTRA_START_DRIVE)
            DriveDetection.startDriveFromPrompt()
        }
    }

    companion object {
        const val EXTRA_START_DRIVE = "startDrive"
    }
}

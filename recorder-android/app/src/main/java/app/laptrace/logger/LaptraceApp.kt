package app.laptrace.logger

import android.app.Application
import app.laptrace.logger.record.DriveDetection
import app.laptrace.logger.record.Notifications
import app.laptrace.logger.record.Recorder
import app.laptrace.logger.record.SessionStore
import app.laptrace.logger.record.TrackStore

class LaptraceApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Notifications.createChannels(this)
        SessionStore.init(this)
        TrackStore.init(this)
        Recorder.init(this)
        DriveDetection.init(this)
        DriveDetection.resume()
    }
}

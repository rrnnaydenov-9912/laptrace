# Laptrace for Android

This is the Android version of the Laptrace logger. It records GPS at 1 Hz and the phone's motion sensors at 50 Hz, times laps on a known track, and logs road drives. It can also start a drive recording on its own. Sessions are exported as the shared 10 Hz Laptrace CSV, which Laptrace Studio opens.

It runs on Android 8.0 (API 26) and later. Auto drive detection needs Google Play services.

## Install it on a tester's phone

1. **Get the APK.** Either:
   - download `Laptrace-debug.apk` from the GitHub Releases page of this repo, or
   - get the file directly from whoever built it (Drive, Slack, email or USB).
2. **Allow the install.** Open the APK on the phone. Android asks for permission to install unknown apps from the app you opened it with (Files, Chrome, Drive and so on). Tap **Settings**, turn on **Allow from this source**, go back and tap **Install**. If Play Protect warns about an unknown developer, choose **Install anyway**.
3. **Grant location.** Open Laptrace. Allow location access when it asks, and allow notifications.
4. **For auto drive detection**, open the cog icon on the Record screen and turn on **Auto-detect drives**. The app then asks for these, in order:
   - **Location: "Allow all the time".** Android only offers this on the system settings page, not in the first pop-up. If the settings sheet shows the orange warning row, tap it, then choose *Permissions → Location → Allow all the time*.
   - **Physical activity**, which Android uses to tell when you start driving.
   - **Notifications.**
5. **Turn off battery optimisation.** Use the *Battery optimisation settings* row in the same settings sheet, or go to *Settings → Apps → Laptrace → Battery* and set it to **Unrestricted**. Samsung, Xiaomi, OnePlus and Huawei phones kill background apps aggressively. Without this step, auto-detect and long recordings can stop without warning.

### Updating

This build is signed with the **debug key of the machine that built it**. Android only installs an update over an existing copy if both are signed with the same key. Every update therefore has to come from the same build machine. If someone else builds it, the tester has to uninstall first, and uninstalling deletes the sessions stored on the phone. Share any sessions you want to keep before uninstalling.

## Using it

- **Record:** pick a track, or leave it on auto-detect to use the nearest built-in track. Choose *Track* or *Drive* and press **Start**. On a track, lap times are spoken (you can turn this off in settings) and a debrief appears after you stop. *Set start/finish here* makes a custom timing line where you are standing.
- **Sessions:** tap a session for details, driver, car and notes, and to build and share the CSV. Long-press a session, or use the bin icon, to delete it.
- **Tracks:** the built-in track list, with a sketch of the timing lines and pre-drive notes.

## Build

You need JDK 17 and the Android SDK (platform 35, build-tools 35).

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
./gradlew assembleDebug testDebugUnitTest
cp app/build/outputs/apk/debug/app-debug.apk dist/Laptrace-debug.apk
```

Toolchain: AGP 8.7.3, Kotlin 2.0.21, Gradle 8.11.1, Compose BOM 2024.12.01, minSdk 26, targetSdk 35.

The `core/` package is a line-for-line port of the iOS core: CSV export, lap timing, track geometry and the coach. It is covered by JVM unit tests, which compare its output against the iOS sample fixtures.

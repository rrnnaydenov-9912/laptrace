import Foundation
import CoreLocation
import CoreMotion
import Observation
import UserNotifications

/// Starts and stops road-drive recordings on its own.
///
/// Waking up: significant-change location monitoring relaunches the app in the background
/// after a few hundred metres of movement. That opens a short probe with full GPS.
/// Starting: the motion coprocessor reports driving, or three fixes within 30 s are above 30 km/h.
/// Stopping (auto-started drives only): 4 minutes below 8 km/h, or 90 s of walking.
/// Drives shorter than 500 m are thrown away as false starts.
@Observable
final class DriveDetection: NSObject, CLLocationManagerDelegate {
    static let shared = DriveDetection()

    static let startSpeedKmh = 30.0
    static let stopSpeedKmh = 8.0
    static let stopAfterSlow: Double = 240
    static let stopAfterWalking: Double = 90
    static let probeLength: Double = 90
    static let minDriveMeters = 500.0

    private static let enabledKey = "autoDetectDrives"

    private(set) var enabled = UserDefaults.standard.bool(forKey: enabledKey)
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Auto-detect only works in the background with Always location access.
    var needsAlways: Bool { enabled && authorization != .authorizedAlways && authorization != .notDetermined }

    @ObservationIgnored private let wake = CLLocationManager()
    @ObservationIgnored private let activity = CMMotionActivityManager()
    @ObservationIgnored private var recorder: Recorder { .shared }
    @ObservationIgnored private var probeUntil: Date?
    @ObservationIgnored private var probeTimer: Timer?
    @ObservationIgnored private var fastFixTimes: [Double] = []
    /// Wall-clock time the car was last seen moving. Parked phones (and garages) often stop sending fixes,
    /// so the stop rule can't wait for a run of slow fixes.
    @ObservationIgnored private var lastMovingAt: Date?
    @ObservationIgnored private var parkTimer: Timer?
    @ObservationIgnored private var walkingSince: Date?
    @ObservationIgnored private var running = false

    override init() {
        super.init()
        wake.delegate = self
        authorization = wake.authorizationStatus
    }

    /// Called at every launch, including background relaunches from a location wake-up.
    func resume() {
        if enabled { begin() }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            if authorization == .notDetermined || authorization == .authorizedWhenInUse {
                wake.requestAlwaysAuthorization()
            }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            begin()
        } else {
            end()
        }
    }

    // MARK: - Monitoring

    private func begin() {
        guard !running else { return }
        running = true
        wake.startMonitoringSignificantLocationChanges()
        if CMMotionActivityManager.isActivityAvailable() {
            activity.startActivityUpdates(to: .main) { [weak self] a in
                if let a { self?.handle(activity: a) }
            }
        }
        recorder.onFix = { [weak self] fix in self?.handle(fix: fix) }
    }

    private func end() {
        guard running else { return }
        running = false
        wake.stopMonitoringSignificantLocationChanges()
        activity.stopActivityUpdates()
        recorder.onFix = nil
        endProbe()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
    }

    /// A significant-change wake-up: look closer with full GPS for a short while.
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard enabled else { return }
        startProbe()
        // The wake-up fix itself often already shows driving speed.
        for loc in locations where loc.speed >= 0 {
            handle(fix: GPSFix(t: loc.timestamp.timeIntervalSince1970,
                               lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                               alt: loc.altitude, hAcc: loc.horizontalAccuracy,
                               speed: loc.speed, course: loc.course))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func startProbe() {
        guard recorder.state == .idle else { return }
        probeUntil = Date().addingTimeInterval(Self.probeLength)
        recorder.keepGPSOn = true
        recorder.startBackgroundGPS()
        probeTimer?.invalidate()
        probeTimer = Timer.scheduledTimer(withTimeInterval: Self.probeLength, repeats: false) { [weak self] _ in
            self?.probeExpired()
        }
    }

    private func probeExpired() {
        guard recorder.state == .idle else { return }
        endProbe()
    }

    private func endProbe() {
        probeTimer?.invalidate(); probeTimer = nil
        probeUntil = nil
        fastFixTimes = []
        recorder.keepGPSOn = false
        recorder.stopBackgroundGPSIfIdle()
    }

    // MARK: - Decisions

    private func handle(activity a: CMMotionActivity) {
        guard enabled else { return }
        if a.walking || a.running {
            walkingSince = walkingSince ?? a.startDate
        } else {
            walkingSince = nil
        }
        switch recorder.state {
        case .idle:
            if a.automotive && a.confidence != .low { startDrive() }
        case .recording:
            checkParked()
        }
    }

    private func handle(fix: GPSFix) {
        guard enabled, fix.hAcc > 0, fix.hAcc <= 50, fix.speed >= 0 else { return }
        let kmh = fix.speed * 3.6
        switch recorder.state {
        case .idle:
            if let until = probeUntil, Date() > until { endProbe(); return }
            if kmh > Self.startSpeedKmh {
                fastFixTimes.append(fix.t)
                fastFixTimes.removeAll { fix.t - $0 > 30 }
                if fastFixTimes.count >= 3 { startDrive() }
            }
        case .recording:
            guard recorder.autoStarted else { return }
            if kmh >= Self.stopSpeedKmh { lastMovingAt = Date() }
            checkParked()
        }
    }

    private func startDrive() {
        guard recorder.state == .idle else { return }
        probeTimer?.invalidate(); probeTimer = nil
        probeUntil = nil
        fastFixTimes = []
        lastMovingAt = Date()
        walkingSince = nil
        recorder.keepGPSOn = true
        recorder.start(mode: .drive, auto: true)
        parkTimer?.invalidate()
        parkTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.checkParked() }
        notify(title: "Recording a drive", body: "Laptrace noticed you're driving and started recording. It stops on its own when you park.")
    }

    /// Stops an auto-started drive after 4 minutes without moving, or 90 s of walking.
    private func checkParked() {
        guard recorder.state == .recording, recorder.autoStarted else { return }
        let now = Date()
        if let moved = lastMovingAt, now.timeIntervalSince(moved) >= Self.stopAfterSlow { stopDrive(); return }
        if let since = walkingSince, now.timeIntervalSince(since) >= Self.stopAfterWalking { stopDrive() }
    }

    private func stopDrive() {
        parkTimer?.invalidate(); parkTimer = nil
        lastMovingAt = nil
        walkingSince = nil
        let saved = recorder.stop(discardShorterThan: Self.minDriveMeters)
        recorder.keepGPSOn = false
        recorder.stopBackgroundGPSIfIdle()
        if let saved {
            let km = (saved.distance ?? 0) / 1000
            notify(title: "Drive saved", body: String(format: "%.1f km, top speed %.0f km/h. Open Laptrace to export it.", km, saved.topSpeed ?? 0))
        }
    }

    private func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

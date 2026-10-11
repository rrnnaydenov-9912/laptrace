import Foundation
import CoreLocation
import CoreMotion
import Observation
import UIKit

/// Owns the sensors. Raw data goes straight to disk; live timing runs on GPS.
@Observable
final class Recorder: NSObject, CLLocationManagerDelegate {
    enum State: Equatable { case idle, recording }

    // Live state for the UI
    private(set) var state: State = .idle
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var lastFix: GPSFix?
    private(set) var track: Track?
    private(set) var session: SessionMeta?
    private(set) var laps: [CompletedLap] = []
    private(set) var currentLapStart: Double?
    private(set) var lastSplit: (label: String, delta: Double?)?
    private(set) var motionAvailable = CMMotionManager().isDeviceMotionAvailable
    private(set) var motionRate: Double = 0
    var now = Date()

    var best: CompletedLap? { laps.min(by: { $0.duration < $1.duration }) }
    var currentLapElapsed: Double? { currentLapStart.map { now.timeIntervalSince1970 - $0 } }
    var speedKmh: Double { max(0, lastFix?.speed ?? 0) * 3.6 }
    var gpsAccuracy: Double? { lastFix?.hAcc }

    private let location = CLLocationManager()
    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()
    private let timer = LapTimer()
    private var gpsWriter: AppendWriter?
    private var motionWriter: AppendWriter?
    @ObservationIgnored private var fixCount = 0
    @ObservationIgnored private var motionCount = 0
    @ObservationIgnored private var motionCountAtTick = 0
    @ObservationIgnored private var tick: Timer?
    private var manualTrack = false

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.distanceFilter = kCLDistanceFilterNone
        location.activityType = .automotiveNavigation
        location.pausesLocationUpdatesAutomatically = false
        authorization = location.authorizationStatus
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInitiated
    }

    // MARK: - Permissions & preview

    func requestPermission() { location.requestWhenInUseAuthorization() }

    /// GPS on without recording, so the driver sees accuracy and the track before starting.
    func startPreview() {
        if authorization == .notDetermined { requestPermission() }
        location.startUpdatingLocation()
    }

    func stopPreviewIfIdle() {
        if state == .idle { location.stopUpdatingLocation() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    // MARK: - Track selection

    func selectTrack(_ t: Track?) {
        manualTrack = t != nil
        track = t
        timer.setTrack(t)
    }

    /// Start/finish line here, perpendicular to the current direction of travel.
    func setStartFinishHere() -> Bool {
        guard let fix = lastFix, fix.course >= 0, fix.speed > 3 else { return false }
        let t = TrackStore.shared.saveCustomStartFinish(at: fix.latLon, travelBearing: fix.course)
        selectTrack(t)
        if var s = session { s.trackId = t.id; s.trackName = t.name; session = s }
        return true
    }

    // MARK: - Recording

    func start() {
        guard state == .idle else { return }
        let meta = SessionStore.shared.create(trackId: track?.id, trackName: track?.name)
        session = meta
        gpsWriter = try? AppendWriter(url: SessionStore.shared.gpsURL(meta.id), flushThreshold: 4_096)
        motionWriter = try? AppendWriter(url: SessionStore.shared.motionURL(meta.id))
        fixCount = 0; motionCount = 0; motionCountAtTick = 0
        laps = []; currentLapStart = nil; lastSplit = nil
        timer.reset()
        timer.setTrack(track)

        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.startUpdatingLocation()
        startMotion()
        UIApplication.shared.isIdleTimerDisabled = true
        state = .recording

        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.onTick() }
    }

    func stop() {
        guard state == .recording, var meta = session else { return }
        tick?.invalidate(); tick = nil
        motion.stopDeviceMotionUpdates()
        motionQueue.waitUntilAllOperationsAreFinished()
        gpsWriter?.close(); motionWriter?.close()
        gpsWriter = nil; motionWriter = nil
        location.allowsBackgroundLocationUpdates = false
        UIApplication.shared.isIdleTimerDisabled = false
        meta.ended = Date()
        meta.fixCount = fixCount
        meta.motionCount = motionCount
        meta.laps = laps
        meta.trackId = track?.id
        meta.trackName = track?.name
        SessionStore.shared.save(meta)
        session = nil
        state = .idle
        motionRate = 0
    }

    private func onTick() {
        now = Date()
        let n = motionCount
        motionRate = motionRate * 0.8 + Double(n - motionCountAtTick) * 10 * 0.2
        motionCountAtTick = n
        gpsWriter?.flush()
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 50
        // CoreMotion timestamps are seconds since boot; convert once to Unix time.
        let bootOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] dm, _ in
            guard let self, let dm, let writer = self.motionWriter else { return }
            let s = MotionSample(t: bootOffset + dm.timestamp,
                                 accel: Vec3(x: dm.userAcceleration.x, y: dm.userAcceleration.y, z: dm.userAcceleration.z),
                                 gravity: Vec3(x: dm.gravity.x, y: dm.gravity.y, z: dm.gravity.z),
                                 rotation: Vec3(x: dm.rotationRate.x, y: dm.rotationRate.y, z: dm.rotationRate.z))
            var data = Data(capacity: MotionSample.byteCount)
            s.append(to: &data)
            writer.append(data)
            self.motionCount += 1
        }
    }

    // MARK: - GPS

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations {
            let fix = GPSFix(t: loc.timestamp.timeIntervalSince1970,
                             lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                             alt: loc.altitude, hAcc: loc.horizontalAccuracy,
                             speed: loc.speed, course: loc.course)
            handle(fix)
        }
    }

    private func handle(_ fix: GPSFix) {
        lastFix = fix
        if !manualTrack, track == nil || state == .idle, let t = TrackStore.shared.nearest(to: fix.latLon), t.id != track?.id {
            track = t
            timer.setTrack(t)
        }
        guard state == .recording else { return }
        if let w = gpsWriter, let data = fix.csvLine.data(using: .utf8) {
            w.append(data)
            fixCount += 1
        }
        guard fix.hAcc > 0, fix.hAcc <= 30 else { return }
        for e in timer.ingest(TimedPoint(t: fix.t, p: fix.latLon)) {
            switch e {
            case .lapStarted(let t):
                currentLapStart = t
            case .lapCompleted(let lap):
                laps.append(lap)
                let delta = best.map { lap.duration - $0.duration }
                lastSplit = ("Lap \(lap.number)", lap.number == best?.number ? nil : delta)
                Haptics.lap()
            case .split(let gate, _, let delta):
                lastSplit = (gate.label, delta)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

enum Haptics {
    static func lap() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

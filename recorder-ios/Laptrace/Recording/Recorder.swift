import Foundation
import CoreLocation
import CoreMotion
import Observation
import UIKit

/// Owns the sensors. Raw data goes straight to disk; live timing runs on GPS.
@Observable
final class Recorder: NSObject, CLLocationManagerDelegate {
    enum State: Equatable { case idle, recording }
    enum Mode: String { case track, drive }

    /// One recorder for the app, so drive detection can start a recording without the UI.
    static let shared = Recorder()

    // Live state for the UI
    private(set) var state: State = .idle
    /// Chosen in the Record tab; a running recording keeps the mode it started with.
    var mode: Mode = .track
    /// True when drive detection started the current recording, so it may also stop it.
    private(set) var autoStarted = false
    private(set) var driveDistance: Double = 0
    private(set) var driveTopSpeed: Double = 0
    @ObservationIgnored private var lastDriveFix: GPSFix?
    /// Fixes go to this hook too, so drive detection can watch speed without its own manager.
    @ObservationIgnored var onFix: ((GPSFix) -> Void)?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var lastFix: GPSFix?
    private(set) var track: Track?
    private(set) var session: SessionMeta?
    /// The session just saved by Stop, for the debrief sheet.
    var lastStopped: SessionMeta?
    private(set) var laps: [CompletedLap] = []
    private(set) var currentLapStart: Double?
    private(set) var lastSplit: (label: String, delta: Double?)?
    private(set) var motionAvailable = CMMotionManager().isDeviceMotionAvailable
    private(set) var motionRate: Double = 0
    /// Current lap against the best lap, for the track screen.
    private(set) var line = LiveLine()
    /// Acceleration timer; nil unless the acceleration screen is open.
    var accel: AccelMeter?
    var now = Date()

    var best: CompletedLap? { laps.min(by: { $0.duration < $1.duration }) }
    var elapsed: Double? { session.map { now.timeIntervalSince($0.started) } }
    var currentLapElapsed: Double? { currentLapStart.map { now.timeIntervalSince1970 - $0 } }
    var speedKmh: Double { max(0, lastFix?.speed ?? 0) * 3.6 }
    var gpsAccuracy: Double? { lastFix?.hAcc }

    private let location = CLLocationManager()
    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()
    private let timer = LapTimer()
    @ObservationIgnored private let cue = LapCue()
    private var gpsWriter: AppendWriter?
    private var motionWriter: AppendWriter?
    private var obdWriter: AppendWriter?
    private var obdCount = 0
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

    /// Leaves GPS running while recording or while drive detection is checking a possible drive.
    func stopPreviewIfIdle() {
        if state == .idle && !keepGPSOn && accel == nil { location.stopUpdatingLocation() }
    }

    @ObservationIgnored var keepGPSOn = false

    /// Background-capable GPS for drive detection's probe window.
    func startBackgroundGPS() {
        location.allowsBackgroundLocationUpdates = true
        location.startUpdatingLocation()
    }

    func stopBackgroundGPSIfIdle() {
        guard state == .idle else { return }
        location.allowsBackgroundLocationUpdates = false
        location.stopUpdatingLocation()
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

    func start(mode: Mode? = nil, auto: Bool = false) {
        guard state == .idle else { return }
        if let mode { self.mode = mode }
        autoStarted = auto
        let drive = self.mode == .drive
        driveDistance = 0; driveTopSpeed = 0; lastDriveFix = nil
        let meta = drive
            ? SessionStore.shared.create(trackId: nil, trackName: nil, mode: "drive")
            : SessionStore.shared.create(trackId: track?.id, trackName: track?.name)
        session = meta
        gpsWriter = try? AppendWriter(url: SessionStore.shared.gpsURL(meta.id), flushThreshold: 4_096)
        motionWriter = try? AppendWriter(url: SessionStore.shared.motionURL(meta.id))
        obdWriter = try? AppendWriter(url: SessionStore.shared.obdURL(meta.id), flushThreshold: 4_096)
        obdCount = 0
        fixCount = 0; motionCount = 0; motionCountAtTick = 0
        laps = []; currentLapStart = nil; lastSplit = nil
        line.reset()
        timer.reset()
        timer.setTrack(drive ? nil : track)

        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.startUpdatingLocation()
        startMotion()
        UIApplication.shared.isIdleTimerDisabled = true
        state = .recording

        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.onTick() }
    }

    /// Stops and saves. Returns the saved session, or nil when nothing was saved.
    /// `discardShorterThan` drops a drive that covered less distance (metres), e.g. a false auto-start.
    @discardableResult
    func stop(discardShorterThan minDistance: Double = 0) -> SessionMeta? {
        guard state == .recording, var meta = session else { return nil }
        tick?.invalidate(); tick = nil
        motion.stopDeviceMotionUpdates()
        motionQueue.waitUntilAllOperationsAreFinished()
        gpsWriter?.close(); motionWriter?.close()
        gpsWriter = nil; motionWriter = nil
        obdWriter?.close(); obdWriter = nil
        keepGPSOn = false
        location.allowsBackgroundLocationUpdates = false
        UIApplication.shared.isIdleTimerDisabled = false
        meta.ended = Date()
        meta.fixCount = fixCount
        meta.motionCount = motionCount
        if obdCount > 0 { meta.obdCount = obdCount; meta.obdReader = OBDLive.shared.readerName }
        session = nil
        state = .idle
        motionRate = 0
        let wasAuto = autoStarted
        autoStarted = false
        if meta.isDrive {
            meta.distance = driveDistance
            meta.topSpeed = driveTopSpeed
            if driveDistance < minDistance {
                SessionStore.shared.delete(meta)
                return nil
            }
        } else {
            meta.laps = laps
            meta.trackId = track?.id
            meta.trackName = track?.name
        }
        SessionStore.shared.save(meta)
        // The debrief is about laps; drives (manual or automatic) don't get one.
        if !wasAuto && !meta.isDrive { lastStopped = meta }
        return meta
    }

    /// Car data from the OBD reader, written alongside GPS while recording. Called on the main queue.
    func record(_ sample: OBDSample) {
        guard state == .recording, let w = obdWriter, !sample.isEmpty,
              let data = sample.csvLine.data(using: .utf8) else { return }
        w.append(data)
        obdCount += 1
    }

    /// Remember the moment a camera started, so video can be lined up with the data later.
    func markVideoStart() {
        guard state == .recording, var s = session else { return }
        s.videoStart = Date()
        session = s
        SessionStore.shared.save(s)
    }

    private func onTick() {
        now = Date()
        let n = motionCount
        motionRate = motionRate * 0.8 + Double(n - motionCountAtTick) * 10 * 0.2
        motionCountAtTick = n
        gpsWriter?.flush()
        obdWriter?.flush()
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
            if accel != nil, loc.speed >= 0 {
                let obd = OBDLive.shared
                accel?.add(AccelSample(t: fix.t, v: loc.speed, alt: loc.altitude, hAcc: loc.horizontalAccuracy,
                                       vAcc: loc.verticalAccuracy, obdKmh: obd.isLive ? obd.values[0x0D] : nil))
            }
            handle(fix)
        }
    }

    private func handle(_ fix: GPSFix) {
        lastFix = fix
        onFix?(fix)
        if !manualTrack, track == nil || state == .idle, let t = TrackStore.shared.nearest(to: fix.latLon), t.id != track?.id {
            track = t
            timer.setTrack(t)
        }
        let obd = OBDLive.shared
        let livePedal = obd.isLive ? (obd.values[0x49] ?? obd.values[0x11]) : nil
        guard state == .recording else {
            // Draw the line on the track screen before recording starts too; start() resets it.
            if fix.hAcc > 0, fix.hAcc <= 30 { line.add(fix, pedal: livePedal) }
            return
        }
        if let w = gpsWriter, let data = fix.csvLine.data(using: .utf8) {
            w.append(data)
            fixCount += 1
        }
        guard fix.hAcc > 0, fix.hAcc <= 30 else { return }
        if session?.isDrive == true {
            accumulateDrive(fix)
            return
        }
        line.add(fix, pedal: livePedal)
        if line.takeBrakeAlert() != nil { cue.brakeWarning() }
        for e in timer.ingest(TimedPoint(t: fix.t, p: fix.latLon)) {
            switch e {
            case .lapStarted(let t):
                currentLapStart = t
                line.lapStarted(at: t)
            case .lapCompleted(let lap):
                cue.speak(duration: lap.duration, previousBest: best?.duration)
                line.lapCompleted(number: lap.number, duration: lap.duration, isBest: lap.duration < (best?.duration ?? .infinity))
                laps.append(lap)
                let delta = best.map { lap.duration - $0.duration }
                lastSplit = ("Lap \(lap.number)", lap.number == best?.number ? nil : delta)
                Haptics.lap()
            case .split(let gate, _, let delta):
                lastSplit = (gate.label, delta)
            }
        }
    }

    private func accumulateDrive(_ fix: GPSFix) {
        if fix.speed >= 0 { driveTopSpeed = max(driveTopSpeed, fix.speed * 3.6) }
        defer { lastDriveFix = fix }
        guard let prev = lastDriveFix else { return }
        let d = haversineMeters(prev.latLon, fix.latLon)
        // Ignore GPS jitter while parked and jumps that would need over 400 km/h.
        let dt = fix.t - prev.t
        if d >= 1, dt > 0, d / dt < 110 { driveDistance += d }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

enum Haptics {
    static func lap() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func brake() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
}

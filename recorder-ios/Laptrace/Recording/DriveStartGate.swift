import Foundation

/// Decides when a road drive really starts: the car is at least `minMeters` from where the session
/// began and is going faster than `minKmh`. Until then nothing counts as a drive.
/// Distance is straight-line from the first good fix, not the summed path, so GPS jitter in a parking
/// space (which wanders a few metres back and forth forever) can never add up to 100 m.
/// Once passed it stays passed for the rest of the session.
struct DriveStartGate {
    static let minMeters = 100.0
    static let minKmh = 10.0

    private(set) var passed = false
    /// Straight-line metres from the first good fix to the latest one.
    private(set) var distance = 0.0
    private var anchor: GPSFix?
    private var last: GPSFix?

    /// Feeds one fix. Returns true once the gate has passed (on this fix or earlier).
    @discardableResult
    mutating func add(_ fix: GPSFix) -> Bool {
        if passed { return true }
        guard fix.hAcc > 0, fix.hAcc <= 30 else { return false }
        defer { last = fix }
        guard let start = anchor, let prev = last else { anchor = fix; return false }
        distance = haversineMeters(start.latLon, fix.latLon)
        let dt = fix.t - prev.t
        guard dt > 0 else { return false }
        // Reported speed when the receiver has one, else the speed implied by the step.
        let kmh = (fix.speed >= 0 ? fix.speed : haversineMeters(prev.latLon, fix.latLon) / dt) * 3.6
        passed = Self.passes(distance: distance, kmh: kmh)
        return passed
    }

    /// The pure rule: far enough from the start and currently fast enough.
    static func passes(distance: Double, kmh: Double) -> Bool {
        distance >= minMeters && kmh > minKmh
    }
}

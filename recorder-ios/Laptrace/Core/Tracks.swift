import Foundation

/// Directed timing line. A crossing counts when the path intersects
/// start→end while travelling within ±90° of `travelBearing`.
struct Gate: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var start: LatLon
    var end: LatLon
    var travelBearing: Double

    var isStartFinish: Bool { id == "sf" }

    /// Gate built perpendicular to the direction of travel through `point`.
    static func perpendicular(id: String, label: String, through point: LatLon, travelBearing: Double, halfWidth: Double = 15) -> Gate {
        let proj = LocalProjection(origin: point)
        let side = Vec2.fromBearing(travelBearing + 90) * halfWidth
        return Gate(id: id, label: label,
                    start: proj.unproject(Vec2(x: 0, y: 0) - side),
                    end: proj.unproject(side),
                    travelBearing: normalizeDegrees(travelBearing))
    }
}

struct Track: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var country: String?
    var center: LatLon
    var radiusMeters: Double
    var gates: [Gate]
    var corners: [TrackCorner]? = nil

    var startFinish: Gate? { gates.first(where: \.isStartFinish) }
    var splits: [Gate] { gates.filter { !$0.isStartFinish } }
}

/// Optional named corner in tracks.json, e.g. {"number": 1, "name": "Hairpin", "note": "Brake at the 100 m board"}.
struct TrackCorner: Codable, Hashable {
    var number: Int
    var name: String?
    var note: String?
}

private struct TrackFile: Codable {
    var version: Int
    var tracks: [Track]
}

/// Bundled tracks (shared/tracks.json) plus tracks the driver created on the phone.
final class TrackStore {
    static let shared = TrackStore()

    private(set) var bundled: [Track] = []
    private(set) var custom: [Track] = []
    var all: [Track] { custom + bundled }

    private var customURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("custom-tracks.json")
    }

    init() {
        if let url = Bundle.main.url(forResource: "tracks", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(TrackFile.self, from: data) {
            bundled = file.tracks
        }
        if let data = try? Data(contentsOf: customURL),
           let tracks = try? JSONDecoder().decode([Track].self, from: data) {
            custom = tracks
        }
    }

    func nearest(to p: LatLon) -> Track? {
        all.map { ($0, haversineMeters($0.center, p)) }
            .filter { $0.1 <= $0.0.radiusMeters }
            .min(by: { $0.1 < $1.1 })?.0
    }

    /// Creates (or replaces) a custom track with a start/finish line at `point`.
    @discardableResult
    func saveCustomStartFinish(at point: LatLon, travelBearing: Double, name: String? = nil) -> Track {
        let sf = Gate.perpendicular(id: "sf", label: "Start / Finish", through: point, travelBearing: travelBearing)
        let track = Track(id: "custom-\(Int(Date().timeIntervalSince1970))",
                          name: name ?? String(format: "Custom track %.4f, %.4f", point.lat, point.lon),
                          country: nil, center: point, radiusMeters: 2000, gates: [sf])
        custom.removeAll { haversineMeters($0.center, point) < 2000 }
        custom.insert(track, at: 0)
        persist()
        return track
    }

    func deleteCustom(_ track: Track) {
        custom.removeAll { $0.id == track.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(custom) { try? data.write(to: customURL, options: .atomic) }
    }
}

import Foundation
import Observation

/// Metadata saved next to the raw files of one recording.
struct SessionMeta: Codable, Identifiable, Hashable {
    var id: String
    var started: Date
    var ended: Date?
    var trackId: String?
    var trackName: String?
    var fixCount: Int = 0
    var motionCount: Int = 0
    var laps: [CompletedLap] = []
    var driver: String?
    var vehicle: String?
    var notes: String?
    var videoStart: Date?
    /// "drive" for a road drive, nil or "track" for a track session.
    var mode: String?
    /// Road drives only: metres travelled and top speed in km/h.
    var distance: Double?
    var topSpeed: Double?
    /// Name of the OBD reader that was connected while recording, if any.
    var obdReader: String?
    var obdCount: Int?

    var isDrive: Bool { mode == "drive" }
    var duration: Double { (ended ?? Date()).timeIntervalSince(started) }
    var best: CompletedLap? { laps.min(by: { $0.duration < $1.duration }) }
    var title: String { isDrive ? "Drive" : (trackName ?? "Session") }
    /// No GPS, or a stub: no laps, under a minute and under 100 m.
    var isEmpty: Bool { fixCount == 0 || (laps.isEmpty && duration < 60 && (distance ?? 0) < 100) }

    /// Optional rows for the CSV metadata block.
    var csvMeta: [(key: String, value: String)] {
        var out: [(String, String)] = [("Mode", isDrive ? "Drive" : "Track")]
        if let driver { out.append(("Driver", driver)) }
        if let vehicle { out.append(("Vehicle", vehicle)) }
        if let notes { out.append(("Notes", notes)) }
        if let videoStart { out.append(("Video Start UTC", ISO8601DateFormatter().string(from: videoStart))) }
        return out
    }
}

/// Sessions live in Documents/Sessions/<id>/ (visible in the Files app):
/// meta.json, gps.csv (raw fixes), motion.bin (raw IMU), obd.csv (car data, when a reader was
/// connected), and the exported CSV.
@Observable
final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [SessionMeta] = []

    let root: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() { reload() }

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func gpsURL(_ id: String) -> URL { folder(id).appendingPathComponent("gps.csv") }
    func motionURL(_ id: String) -> URL { folder(id).appendingPathComponent("motion.bin") }
    func obdURL(_ id: String) -> URL { folder(id).appendingPathComponent("obd.csv") }
    private func metaURL(_ id: String) -> URL { folder(id).appendingPathComponent("meta.json") }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        sessions = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
            return try? dec.decode(SessionMeta.self, from: data)
        }.sorted { $0.started > $1.started }
    }

    func create(trackId: String?, trackName: String?, mode: String? = nil) -> SessionMeta {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let meta = SessionMeta(id: f.string(from: Date()), started: Date(), trackId: trackId, trackName: trackName, mode: mode)
        try? FileManager.default.createDirectory(at: folder(meta.id), withIntermediateDirectories: true)
        save(meta)
        return meta
    }

    func save(_ meta: SessionMeta) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(meta) { try? data.write(to: metaURL(meta.id), options: .atomic) }
        reload()
    }

    func delete(_ meta: SessionMeta) {
        try? FileManager.default.removeItem(at: folder(meta.id))
        reload()
    }

    /// Removes every empty session except the one being recorded. Returns how many went.
    @discardableResult func deleteEmpty(except activeId: String? = nil) -> Int {
        let gone = sessions.filter { $0.isEmpty && $0.id != activeId }
        for m in gone { try? FileManager.default.removeItem(at: folder(m.id)) }
        reload()
        return gone.count
    }

    /// Builds the shared-format CSV for a session and writes it into the session folder.
    func exportCSV(_ meta: SessionMeta, track: Track?) throws -> (url: URL, summary: Exporter.Summary) {
        let fixes = RawFiles.readFixes(gpsURL(meta.id))
        let motion = RawFiles.readMotion(motionURL(meta.id))
        let obd = RawFiles.readOBD(obdURL(meta.id))
        var exporter = Exporter()
        exporter.options.device = deviceName()
        exporter.options.extraMeta = meta.csvMeta
        if !obd.isEmpty { exporter.options.obdSource = meta.obdReader ?? "ELM327 OBD reader" }
        guard let result = exporter.export(fixes: fixes, motion: motion, track: track, obd: obd) else {
            throw ExportError.notEnoughData
        }
        let safeTrack = (meta.isDrive ? "Drive" : meta.trackName ?? "session").replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
        let url = folder(meta.id).appendingPathComponent("Laptrace_\(safeTrack)_\(meta.id).csv")
        try result.csv.write(to: url, atomically: true, encoding: .utf8)
        return (url, result.summary)
    }

    /// Lap stats and one coaching goal, computed from the raw GPS file.
    func debrief(_ meta: SessionMeta, track: Track?) -> Coach.Debrief? {
        let laps = Exporter().coachLaps(fixes: RawFiles.readFixes(gpsURL(meta.id)), track: track)
        return Coach.debrief(laps, trackName: meta.trackName)
    }

    enum ExportError: LocalizedError {
        case notEnoughData
        var errorDescription: String? { "Not enough usable GPS fixes to export this session." }
    }

    private func deviceName() -> String {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return "Laptrace Logger on \(model)"
    }
}

import SwiftUI

/// Corpus rows for a saved road drive, meant to sit inside a List: this drive's numbers and how
/// they compare with earlier drives by the same driver in the same car.
struct DriveInsightsView: View {
    let session: SessionMeta
    @State private var report: DriveInsights.Report?
    @State private var loaded = false

    var body: some View {
        Group {
            if let r = report {
                Section("Driving") {
                    LabeledContent("Average speed", value: String(format: "%.0f km/h", r.stats.avgKmh))
                    LabeledContent("Braking", value: String(format: "%.2f g", r.stats.brakeG))
                    LabeledContent("Acceleration", value: String(format: "%.2f g", r.stats.accelG))
                    LabeledContent("Smoothness (jerk)", value: String(format: "%.3f g/s", r.stats.jerk))
                    LabeledContent("Harsh brakes", value: "\(r.stats.harshBrakes)")
                }
                Section {
                    ForEach(r.insights, id: \.self) { Text($0) }
                } header: {
                    Text("Compared with your drives")
                } footer: {
                    Text(footer(r))
                }
            } else if loaded {
                Section("Driving") {
                    Text("Not enough GPS to judge this drive. It needs 500 m after the car starts moving.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Driving") { ProgressView() }
            }
        }
        .task(id: session.id) {
            let session = session, all = SessionStore.shared.sessions
            report = await Task.detached(priority: .userInitiated) { DriveInsights.report(for: session, among: all) }.value
            loaded = true
        }
    }

    private func footer(_ r: DriveInsights.Report) -> String {
        guard r.baselineCount >= DriveCorpus.minBaselineDrives else {
            return "Builds up as you record drives of 500 m or more."
        }
        let who = r.sameCar ? "with this driver and car" : "in any car (fewer than 3 with this driver and car so far)"
        return "Your last \(r.baselineCount) drives \(who), unusual drives left out. Braking and acceleration are the 95th percentile from GPS speed."
    }
}

/// Loads one drive's stats and compares it with the drives recorded before it.
enum DriveInsights {
    struct Report {
        var stats: DriveStats
        var insights: [String]
        /// Drives the baseline was built from after outliers were dropped.
        var baselineCount: Int
        /// True when the baseline is this driver and car only, false when it fell back to all drives.
        var sameCar: Bool
    }

    static let historyLimit = 20

    /// Nil when the drive itself is too short to judge. History is the 20 most recent earlier drives
    /// with the same driver and car, or all earlier drives when that leaves fewer than 3 for a baseline.
    static func report(for session: SessionMeta, among all: [SessionMeta]) -> Report? {
        guard let stats = load(session) else { return nil }
        let earlier = all
            .filter { $0.isDrive && ($0.distance ?? 0) >= DriveCorpus.minDistance && $0.started < session.started }
            .sorted { $0.started < $1.started }

        var cache: [String: DriveStats?] = [:]
        func history(_ drives: [SessionMeta]) -> [DriveStats] {
            drives.suffix(historyLimit).compactMap { m -> DriveStats? in
                if let s = cache[m.id] { return s }
                let s = load(m)
                cache[m.id] = s
                return s
            }
        }

        let mine = history(earlier.filter { key($0) == key(session) })
        let sameCar = DriveCorpus.baseline(from: mine) != nil
        let h = sameCar ? mine : history(earlier)
        return Report(stats: stats, insights: DriveCorpus.insights(for: stats, history: h),
                      baselineCount: DriveCorpus.baselineDrives(from: h).count, sameCar: sameCar)
    }

    private static func load(_ meta: SessionMeta) -> DriveStats? {
        DriveCorpus.stats(id: meta.id, fixes: RawFiles.readFixes(SessionStore.shared.gpsURL(meta.id)))
    }

    /// Driver and car, ignoring case and surrounding spaces; blank counts as unset.
    private static func key(_ m: SessionMeta) -> [String] {
        [m.driver, m.vehicle].map { ($0 ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
    }
}

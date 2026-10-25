import SwiftUI
import Charts

struct SessionsView: View {
    @State private var store = SessionStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    ContentUnavailableView("No sessions yet", systemImage: "flag.checkered",
                                           description: Text("Recordings appear here after you press Stop."))
                } else {
                    List {
                        ForEach(store.sessions) { s in
                            NavigationLink(value: s) { SessionRow(meta: s) }
                        }
                        .onDelete { idx in idx.map { store.sessions[$0] }.forEach(store.delete) }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: SessionMeta.self) { SessionDetail(meta: $0) }
            .onAppear { store.reload() }
        }
    }
}

struct SessionRow: View {
    let meta: SessionMeta
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(meta.title, systemImage: meta.isDrive ? "car" : "flag.checkered").font(.headline)
            HStack {
                Text(meta.started, format: .dateTime.day().month().hour().minute())
                if meta.isDrive {
                    Text("· \(Fmt.km(meta.distance))")
                    if let v = meta.topSpeed { Text(String(format: "· top %.0f km/h", v)) }
                } else {
                    Text("· \(meta.laps.count) laps")
                    if let b = meta.best { Text("· best \(Fmt.lap(b.duration))") }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct SessionDetail: View {
    @State private var meta: SessionMeta
    @State private var exportURL: URL?
    @State private var summary: Exporter.Summary?
    @State private var error: String?
    @State private var working = false

    init(meta: SessionMeta) { _meta = State(initialValue: meta) }

    private var track: Track? { TrackStore.shared.all.first { $0.id == meta.trackId } }

    private func text(_ key: WritableKeyPath<SessionMeta, String?>) -> Binding<String> {
        Binding(get: { meta[keyPath: key] ?? "" },
                set: { meta[keyPath: key] = $0.isEmpty ? nil : $0; exportURL = nil })
    }

    var body: some View {
        List {
            if !meta.isDrive {
                DebriefSections(meta: meta)
                Section {
                    NavigationLink("Lap lines") { LapOverlayView(meta: meta, track: track) }
                    NavigationLink("Detailed analysis") { SessionAnalysisView(meta: meta, track: track) }
                }
            }
            Section {
                TextField("Driver", text: text(\.driver))
                TextField("Car", text: text(\.vehicle))
                TextField("Notes (tyres, weather, setup…)", text: text(\.notes), axis: .vertical)
                    .lineLimit(1...5)
                if let v = meta.videoStart {
                    LabeledContent("Video started") { Text(v, format: .dateTime.hour().minute().second()) }
                }
            } header: {
                Text("Details")
            } footer: {
                Text("Saved with the session and added to the CSV.")
            }
            Section(meta.isDrive ? "Drive" : "Session") {
                if meta.isDrive {
                    LabeledContent("Distance", value: Fmt.km(meta.distance))
                    LabeledContent("Top speed", value: meta.topSpeed.map { String(format: "%.0f km/h", $0) } ?? "–")
                } else {
                    LabeledContent("Track", value: meta.trackName ?? "None")
                }
                LabeledContent("Started") { Text(meta.started, format: .dateTime) }
                LabeledContent("Duration", value: Fmt.duration(meta.duration))
                LabeledContent("GPS fixes", value: "\(meta.fixCount)")
                LabeledContent("IMU samples", value: "\(meta.motionCount)")
            }
            if !meta.isDrive && !meta.laps.isEmpty {
                Section("Laps (live timing)") {
                    ForEach(meta.laps) { lap in
                        NavigationLink { LapOverlayView(meta: meta, track: track, focus: lap.number) } label: { HStack {
                            Text("Lap \(lap.number)")
                            Spacer()
                            Text(Fmt.lap(lap.duration))
                                .monospacedDigit()
                                .fontWeight(lap.number == meta.best?.number ? .bold : .regular)
                                .foregroundStyle(lap.number == meta.best?.number ? .green : .primary)
                        } }
                    }
                }
            }
            Section {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share CSV", systemImage: "square.and.arrow.up")
                    }
                    if let summary {
                        LabeledContent("Rows", value: "\(summary.rows)")
                        LabeledContent("G-forces", value: summary.calibration.calibrated ? "Phone IMU" : "From GPS")
                        Text(summary.calibration.source).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        export()
                    } label: {
                        HStack {
                            Label("Build CSV for Laptrace Studio", systemImage: "doc.text")
                            if working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(working)
                }
                if let error { Text(error).foregroundStyle(.red) }
            } header: {
                Text("Export")
            } footer: {
                Text("10 Hz CSV in the shared Laptrace format. Raw files stay in Files › Laptrace › Sessions.")
            }
        }
        .navigationTitle(meta.title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { SessionStore.shared.save(meta) }
    }

    private func export() {
        working = true
        error = nil
        SessionStore.shared.save(meta)
        let meta = meta, track = track
        Task.detached(priority: .userInitiated) {
            do {
                let r = try SessionStore.shared.exportCSV(meta, track: track)
                await MainActor.run { exportURL = r.url; summary = r.summary; working = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; working = false }
            }
        }
    }
}

/// Post-session analysis: potential best, sector splits, corner losses and a speed trace.
enum SessionAnalysis {
    struct Sector: Identifiable {
        var id: Int
        var name: String
        var best: Double
        var bestLap: Int
        var times: [Int: Double]   // lap number → sector time
    }

    struct TracePoint: Identifiable {
        var lap: Int
        var s: Double
        var kmh: Double
        var id: String { "\(lap)-\(s)" }
    }

    struct Result {
        var lapTimes: [(number: Int, duration: Double)]
        var bestLap: Int
        var bestTime: Double
        var potential: Double
        var sectors: [Sector]
        var sectorSource: String
        var corners: [Coach.CornerStats]
        var traces: [Int: [TracePoint]]
        var tips: [String]
    }

    static let traceStep = 5.0

    static func run(meta: SessionMeta, track: Track?) -> Result? {
        let fixes = RawFiles.readFixes(SessionStore.shared.gpsURL(meta.id))
        let laps = Coach.timedLaps(Exporter().coachLaps(fixes: fixes, track: track))
        guard let best = laps.min(by: { $0.duration < $1.duration }), best.x.count > 2 else { return nil }

        let bestGrid = Coach.resample(best)
        guard let length = bestGrid.s.last, length > 0 else { return nil }
        var grids: [Int: Coach.Grid] = [best.number: bestGrid]
        for lap in laps where lap.number != best.number && lap.x.count > 2 {
            grids[lap.number] = Coach.aligned(Coach.resample(lap), to: length)
        }

        var traces: [Int: [TracePoint]] = [:]
        for (n, g) in grids {
            var pts: [TracePoint] = []
            var s = 0.0
            while s <= length {
                let i = index(g, at: s)
                pts.append(TracePoint(lap: n, s: s, kmh: g.v[i] * 3.6))
                s += traceStep
            }
            traces[n] = pts
        }

        var sectors = gateSectors(meta: meta, track: track)
        var source = "Split gates"
        var bestTime = best.duration
        var bestLap = best.number
        var lapTimes = laps.map { (number: $0.number, duration: $0.duration) }
        if let s = sectors {
            // Gate sectors come from the recorder's own laps; compare against the same set.
            let nums = Set(s.first?.times.keys.map { $0 } ?? [])
            let pool = meta.laps.filter { nums.contains($0.number) }
            if let b = pool.min(by: { $0.duration < $1.duration }) { bestTime = b.duration; bestLap = b.number }
            lapTimes = pool.map { (number: $0.number, duration: $0.duration) }
        } else {
            sectors = gridSectors(grids: grids, length: length)
            source = "10 equal-distance segments"
        }
        let secs = sectors ?? []
        let potential = secs.isEmpty ? bestTime : secs.reduce(0) { $0 + $1.best }

        let corners = (Coach.debrief(laps, trackName: meta.trackName)?.corners ?? [])
            .sorted { $0.lossVsBest > $1.lossVsBest }

        var tips: [String] = []
        if bestTime - potential > 0.05 {
            tips.append("Your best sectors add up to \(Fmt.lap(potential)) — \(String(format: "%.2f", bestTime - potential)) s quicker than your best lap.")
        }
        let gaps = secs.compactMap { sec -> (String, Double, Int)? in
            guard let mine = sec.times[bestLap] else { return nil }
            let gap = mine - sec.best
            return gap > 0.05 ? (sec.name, gap, sec.bestLap) : nil
        }.sorted { $0.1 > $1.1 }
        for g in gaps.prefix(2) {
            tips.append("\(g.0): lap \(g.2) was \(String(format: "%.2f", g.1)) s faster than your best lap here.")
        }
        for c in corners.prefix(3) where c.lossVsBest > 0.05 {
            var line = "T\(c.number): typical lap loses \(String(format: "%.2f", c.lossVsBest)) s vs your best"
            if let b = c.brakeAt { line += " (best lap brakes at \(Int(b)) m)" }
            tips.append(line + ".")
        }

        return Result(lapTimes: lapTimes.sorted { $0.number < $1.number }, bestLap: bestLap, bestTime: bestTime,
                      potential: potential, sectors: secs, sectorSource: source, corners: corners,
                      traces: traces, tips: tips)
    }

    /// Sectors from the recorder's split gates, if the track has them and enough laps crossed all of them.
    private static func gateSectors(meta: SessionMeta, track: Track?) -> [Sector]? {
        guard let track, !track.splits.isEmpty else { return nil }
        let ids = track.splits.map(\.id)
        let complete = meta.laps.filter { lap in ids.allSatisfy { lap.splits[$0] != nil } }
        guard complete.count >= 2 else { return nil }
        let sortedDur = complete.map(\.duration).sorted()
        let median = sortedDur[sortedDur.count / 2]
        let laps = complete.filter { $0.duration <= median * 1.5 }
        guard laps.count >= 2, let ref = laps.min(by: { $0.duration < $1.duration }) else { return nil }

        let order = track.splits.sorted { (ref.splits[$0.id] ?? 0) < (ref.splits[$1.id] ?? 0) }
        var names = order.map(\.label)
        names.append("Finish")
        var sectors = names.enumerated().map { Sector(id: $0.offset, name: "S\($0.offset + 1) → \($0.element)", best: .infinity, bestLap: 0, times: [:]) }
        for lap in laps {
            let marks = [0] + order.map { lap.splits[$0.id] ?? 0 } + [lap.duration]
            for k in 0..<sectors.count {
                let t = marks[k + 1] - marks[k]
                guard t > 0 else { continue }
                sectors[k].times[lap.number] = t
                if t < sectors[k].best { sectors[k].best = t; sectors[k].bestLap = lap.number }
            }
        }
        return sectors.allSatisfy { $0.best.isFinite } ? sectors : nil
    }

    /// Fallback: split each lap into equal-distance segments on the best lap's distance grid.
    private static func gridSectors(grids: [Int: Coach.Grid], length: Double, count: Int = 10) -> [Sector] {
        var sectors = (0..<count).map { k in
            Sector(id: k, name: "\(Int(length * Double(k) / Double(count)))–\(Int(length * Double(k + 1) / Double(count))) m",
                   best: .infinity, bestLap: 0, times: [:])
        }
        for (n, g) in grids {
            let t0 = g.t[0]
            let marks = (0...count).map { time(g, at: length * Double($0) / Double(count)) - t0 }
            for k in 0..<count {
                let t = marks[k + 1] - marks[k]
                guard t > 0 else { continue }
                sectors[k].times[n] = t
                if t < sectors[k].best { sectors[k].best = t; sectors[k].bestLap = n }
            }
        }
        return sectors.filter { $0.best.isFinite }
    }

    private static func index(_ g: Coach.Grid, at s: Double) -> Int {
        var lo = 0, hi = g.s.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if g.s[mid] < s { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func time(_ g: Coach.Grid, at s: Double) -> Double {
        let i = index(g, at: s)
        guard i > 0 else { return g.t[0] }
        let f = (s - g.s[i - 1]) / max(g.s[i] - g.s[i - 1], 1e-9)
        return g.t[i - 1] + (g.t[i] - g.t[i - 1]) * min(max(f, 0), 1)
    }
}

struct SessionAnalysisView: View {
    let meta: SessionMeta
    let track: Track?
    @State private var result: SessionAnalysis.Result?
    @State private var loaded = false
    @State private var compare: Int?

    var body: some View {
        List {
            if let r = result {
                summary(r)
                if !r.tips.isEmpty {
                    Section("Where to improve") {
                        ForEach(r.tips, id: \.self) { Text($0) }
                    }
                }
                sectors(r)
                corners(r)
                trace(r)
            } else if loaded {
                Text("Not enough GPS data for an analysis.").foregroundStyle(.secondary)
            } else {
                HStack { ProgressView(); Text("Analysing laps…").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: meta.id) {
            let meta = meta, track = track
            let r = await Task.detached(priority: .userInitiated) { SessionAnalysis.run(meta: meta, track: track) }.value
            result = r
            // Default comparison: the second-fastest lap that has a trace.
            compare = r.flatMap { r in
                r.lapTimes
                    .filter { $0.number != r.bestLap && r.traces[$0.number] != nil }
                    .min { $0.duration < $1.duration }?.number
            }
            loaded = true
        }
    }

    private func summary(_ r: SessionAnalysis.Result) -> some View {
        Section {
            LabeledContent("Best lap") { Text("\(Fmt.lap(r.bestTime)) · lap \(r.bestLap)").monospacedDigit() }
            LabeledContent("Potential best") {
                Text(Fmt.lap(r.potential)).monospacedDigit().foregroundStyle(.green).fontWeight(.bold)
            }
            LabeledContent("Left on the table") { Text("\(String(format: "%.2f", r.bestTime - r.potential)) s").monospacedDigit() }
        } footer: {
            Text("Potential best = sum of your fastest time in each sector (\(r.sectorSource.lowercased())).")
        }
    }

    private func sectors(_ r: SessionAnalysis.Result) -> some View {
        Section {
            ForEach(r.sectors) { sec in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(sec.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(String(format: "%.2f s", sec.best)).monospacedDigit().foregroundStyle(.green)
                        Text("L\(sec.bestLap)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(r.lapTimes.compactMap { l in
                        sec.times[l.number].map { "L\(l.number) \(Fmt.delta($0 - sec.best))" }
                    }.joined(separator: "  "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Sectors")
        } footer: {
            Text("Best time per sector and the lap that set it; the line below shows each lap's gap to that best.")
        }
    }

    @ViewBuilder
    private func corners(_ r: SessionAnalysis.Result) -> some View {
        if !r.corners.isEmpty {
            Section {
                ForEach(r.corners, id: \.number) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("T\(c.number)").font(.subheadline.weight(.semibold))
                            Text(String(format: "%.0f → %.0f → %.0f km/h", c.entryKmh, c.minKmh, c.exitKmh))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if let b = c.brakeAt {
                                Text("Brake at \(Int(b)) m").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(Fmt.delta(c.lossVsBest)).monospacedDigit()
                            .foregroundStyle(c.lossVsBest > 0.1 ? .red : .primary)
                    }
                }
            } header: {
                Text("Corners")
            } footer: {
                Text("Speeds are from your best lap. The figure on the right is how much time a typical lap loses there vs the best.")
            }
        }
    }

    @ViewBuilder
    private func trace(_ r: SessionAnalysis.Result) -> some View {
        let others = r.lapTimes.map(\.number).filter { $0 != r.bestLap && r.traces[$0] != nil }
        let shown = [r.bestLap] + (compare.map { [$0] } ?? [])
        let points = shown.flatMap { r.traces[$0] ?? [] }
        Section {
            if !others.isEmpty {
                Picker("Compare with", selection: $compare) {
                    ForEach(others, id: \.self) { Text("Lap \($0)").tag(Optional($0)) }
                }
            }
            Chart(points) { p in
                LineMark(x: .value("Distance (m)", p.s), y: .value("km/h", p.kmh))
                    .foregroundStyle(by: .value("Lap", p.lap == r.bestLap ? "Best (L\(p.lap))" : "L\(p.lap)"))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXAxisLabel("Distance from start line (m)")
            .chartYAxisLabel("km/h")
            .frame(height: 220)
        } header: {
            Text("Speed trace")
        }
    }
}

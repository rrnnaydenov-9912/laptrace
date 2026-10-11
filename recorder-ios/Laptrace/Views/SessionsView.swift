import SwiftUI

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
            if !meta.isDrive { DebriefSections(meta: meta) }
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
                        HStack {
                            Text("Lap \(lap.number)")
                            Spacer()
                            Text(Fmt.lap(lap.duration))
                                .monospacedDigit()
                                .fontWeight(lap.number == meta.best?.number ? .bold : .regular)
                                .foregroundStyle(lap.number == meta.best?.number ? .green : .primary)
                        }
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

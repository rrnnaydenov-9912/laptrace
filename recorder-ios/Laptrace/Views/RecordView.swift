import SwiftUI
import CoreLocation

struct RecordView: View {
    @Environment(Recorder.self) private var rec
    @State private var showTrackPicker = false
    @State private var confirmStop = false
    @State private var sfMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                statusBar
                Spacer(minLength: 0)
                lapClock
                deltaRow
                Spacer(minLength: 0)
                lapStats
                controls
            }
            .padding()
            .navigationTitle("Laptrace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTrackPicker = true } label: {
                        Label(rec.track?.name ?? "No track", systemImage: "flag.checkered")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                    }
                }
            }
            .sheet(isPresented: $showTrackPicker) { TrackPicker() }
            .onAppear { rec.startPreview() }
            .onDisappear { rec.stopPreviewIfIdle() }
            .confirmationDialog("Stop recording?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop and save", role: .destructive) { rec.stop() }
            }
            .alert(sfMessage ?? "", isPresented: Binding(get: { sfMessage != nil }, set: { if !$0 { sfMessage = nil } })) {
                Button("OK") {}
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            pill(gpsText, color: gpsColor, icon: "location.fill")
            pill(rec.motionAvailable ? (rec.state == .recording ? String(format: "IMU %.0f Hz", rec.motionRate) : "IMU ready") : "No IMU",
                 color: rec.motionAvailable ? .green : .gray, icon: "gyroscope")
            Spacer()
            if rec.state == .recording {
                Label("REC", systemImage: "circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
            }
        }
    }

    private var gpsText: String {
        switch rec.authorization {
        case .denied, .restricted: return "Location off"
        case .notDetermined: return "Allow location"
        default: break
        }
        guard let acc = rec.gpsAccuracy, acc > 0 else { return "Searching…" }
        return String(format: "GPS ±%.0f m", acc)
    }

    private var gpsColor: Color {
        guard let acc = rec.gpsAccuracy, acc > 0 else { return .gray }
        return acc <= 8 ? .green : acc <= 20 ? .yellow : .red
    }

    private func pill(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var lapClock: some View {
        VStack(spacing: 4) {
            Text(rec.currentLapStart == nil ? "Waiting for start line" : "Lap \(rec.laps.count + 1)")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(Fmt.lap(rec.currentLapElapsed))
                .font(.system(size: 76, weight: .bold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(String(format: "%.0f km/h", rec.speedKmh))
                .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var deltaRow: some View {
        if let split = rec.lastSplit {
            HStack {
                Text(split.label).foregroundStyle(.secondary)
                Text(split.delta == nil ? "best" : Fmt.delta(split.delta))
                    .font(.title.bold().monospacedDigit())
                    .foregroundStyle((split.delta ?? -1) < 0 ? .green : .red)
            }
        } else {
            Text(" ").font(.title)
        }
    }

    private var lapStats: some View {
        HStack {
            stat("Last", Fmt.lap(rec.laps.last?.duration))
            Divider().frame(height: 40)
            stat("Best", Fmt.lap(rec.best?.duration))
            Divider().frame(height: 40)
            stat("Laps", "\(rec.laps.count)")
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                if rec.state == .recording {
                    confirmStop = true
                } else {
                    rec.start()
                }
            } label: {
                Text(rec.state == .recording ? "Stop" : "Start recording")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(rec.state == .recording ? .red : .orange)

            Button {
                sfMessage = rec.setStartFinishHere()
                    ? "Start/finish line set here. Laps count from your next crossing."
                    : "Drive over the line at more than ~10 km/h to set it, so the direction is known."
            } label: {
                Label("Set start/finish here", systemImage: "mappin.and.ellipse")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct TrackPicker: View {
    @Environment(Recorder.self) private var rec
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button("Auto-detect nearest track") { rec.selectTrack(nil); dismiss() }
                ForEach(TrackStore.shared.all) { t in
                    Button {
                        rec.selectTrack(t); dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(t.name)
                                Text("\(t.splits.count) splits").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if t.id == rec.track?.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            .navigationTitle("Track")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

import SwiftUI
import CoreLocation

struct RecordView: View {
    @Environment(Recorder.self) private var rec
    @State private var showTrackPicker = false
    @State private var confirmStop = false
    @State private var sfMessage: String?
    @State private var videoMarked = false
    @State private var showSettings = false
    @State private var showDash = false
    @State private var showAccel = false
    @AppStorage("checklistDone") private var checklistDone = false

    /// The running recording's mode, or the one picked for the next recording.
    private var isDrive: Bool { rec.state == .recording ? rec.session?.isDrive == true : rec.mode == .drive }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                statusBar
                if rec.state == .idle { modePicker }
                Spacer(minLength: 0)
                if isDrive {
                    driveClock
                } else {
                    lapClock
                    deltaRow
                }
                Spacer(minLength: 0)
                if isDrive { driveStats } else { lapStats }
                controls
            }
            .padding()
            .navigationTitle("Laptrace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                if !isDrive {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showTrackPicker = true } label: {
                            Label(rec.track?.name ?? "No track", systemImage: "flag.checkered")
                                .labelStyle(.titleAndIcon)
                                .font(.subheadline)
                        }
                    }
                }
            }
            .sheet(isPresented: $showTrackPicker) { TrackPicker() }
            .sheet(isPresented: $showSettings) { RecordSettings() }
            .fullScreenCover(isPresented: $showDash) { TrackDashView() }
            .fullScreenCover(isPresented: $showAccel) { AccelView() }
            .sheet(item: Binding(get: { rec.lastStopped }, set: { rec.lastStopped = $0 })) { DebriefSheet(meta: $0) }
            .overlay { if !checklistDone && rec.state == .idle { checklist } }
            .onAppear { rec.startPreview() }
            .onDisappear { rec.stopPreviewIfIdle() }
            .confirmationDialog("Stop recording?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop and save", role: .destructive) { rec.stopFromUser() }
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

    private var modePicker: some View {
        Picker("Mode", selection: Binding(get: { rec.mode }, set: { rec.mode = $0 })) {
            Text("Track").tag(Recorder.Mode.track)
            Text("Drive").tag(Recorder.Mode.drive)
        }
        .pickerStyle(.segmented)
    }

    private var driveClock: some View {
        VStack(spacing: 4) {
            Text(rec.state == .recording ? (rec.autoStarted ? "Drive · started automatically" : "Drive") : "Road drive")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(rec.elapsed.map(Fmt.duration) ?? "0:00")
                .font(.system(size: 76, weight: .bold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(String(format: "%.0f km/h", rec.speedKmh))
                .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var driveStats: some View {
        HStack {
            stat("Distance", rec.state == .recording ? Fmt.km(rec.driveDistance) : "–")
            Divider().frame(height: 40)
            stat("Top speed", rec.state == .recording ? String(format: "%.0f km/h", rec.driveTopSpeed) : "–")
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
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

    private var checklist: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("Before your first session").font(.title2.bold())
                ForEach([("iphone.gen3", "Phone mounted firmly, so it can't move or fall"),
                         ("lock.rotation", "Screen orientation locked"),
                         ("moon.fill", "Do Not Disturb on, so calls don't interrupt"),
                         ("battery.75percent", "Battery above 50%")], id: \.1) { icon, text in
                    Label(text, systemImage: icon)
                }
                Button {
                    checklistDone = true
                } label: {
                    Text("Got it").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(24)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                if rec.state == .recording {
                    confirmStop = true
                } else {
                    videoMarked = false
                    rec.start(mode: rec.mode)
                }
            } label: {
                Text(rec.state == .recording ? "Stop" : "Start recording")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(rec.state == .recording ? .red : .orange)

            if rec.state == .recording {
                Button {
                    rec.markVideoStart()
                    videoMarked = true
                } label: {
                    Label(videoMarked ? "Video start marked – tap again to re-mark" : "Mark video start",
                          systemImage: videoMarked ? "checkmark.circle" : "video")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if !isDrive {
            Button { showDash = true } label: {
                Label("Track screen", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)

            Button { showAccel = true } label: {
                Label("Acceleration timer", systemImage: "stopwatch")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

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
}

struct RecordSettings: View {
    @Environment(DriveDetection.self) private var detection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(LapCue.enabledKey) private var speakLaps = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $speakLaps) { Label("Speak lap times", systemImage: "speaker.wave.2") }
                } header: {
                    Text("Track")
                }
                Section {
                    Toggle(isOn: Binding(get: { detection.enabled }, set: { detection.setEnabled($0) })) {
                        Label("Auto-record drives", systemImage: "car")
                    }
                    if detection.needsAlways {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } label: {
                            Label("Set location access to Always", systemImage: "exclamationmark.triangle")
                        }
                        .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Drives")
                } footer: {
                    Text("Laptrace starts recording when it notices you're driving, and saves the drive when you've been parked for about 4 minutes. You don't need to open the app. Drives under 500 m are discarded. This needs location access set to Always, and uses a little more battery.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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

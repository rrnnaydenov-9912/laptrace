import SwiftUI

/// "Car" tab: connect the OBD reader and run the one-off probe.
struct ProbeView: View {
    @State private var probe = OBDProbe()

    private var link: ELM327Link { probe.link }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Plug the reader into the OBD port under the dashboard.", systemImage: "1.circle")
                    Label("Park, handbrake on, gearbox in neutral, engine running.", systemImage: "2.circle")
                    Label("Connect below and run the probe. It takes about 2 minutes.", systemImage: "3.circle")
                } footer: {
                    Text("Read-only: the probe only asks for data. It never clears fault codes or changes anything in the car.")
                }

                readerSection

                if link.state == .ready || !probe.steps.isEmpty {
                    probeSection
                }

                if let l = probe.listening { listenSection(l) }

                if !probe.steps.isEmpty {
                    Section("Results") {
                        ForEach(probe.steps) { StepRow(step: $0) }
                    }
                }

                if !probe.findings.isEmpty {
                    Section("What this means") {
                        ForEach(probe.findings, id: \.self) { Text($0).font(.callout) }
                    }
                }

                if let url = probe.logURL {
                    Section {
                        ShareLink(item: url) { Label("Share probe log", systemImage: "square.and.arrow.up") }
                    } footer: {
                        Text("Also saved in Files › Laptrace › Probes. Send it over and the car's data map gets built from it.")
                    }
                }
            }
            .navigationTitle("Car")
            .onDisappear { if link.state == .scanning { link.stopScan() } }
        }
    }

    @ViewBuilder private var readerSection: some View {
        Section {
            switch link.state {
            case .ready:
                LabeledContent("Connected", value: link.deviceName ?? "Reader")
                Button("Disconnect", role: .destructive) { link.disconnect() }
                    .disabled(probe.running)
            case .connecting:
                HStack { Text("Connecting to \(link.deviceName ?? "reader")…"); Spacer(); ProgressView() }
            case .bluetoothOff:
                Text("Bluetooth is off. Turn it on in Control Centre.").foregroundStyle(.orange)
            case .unauthorized:
                Text("Laptrace isn't allowed to use Bluetooth. Turn it on in Settings › Laptrace.").foregroundStyle(.orange)
            case .idle, .scanning, .failed:
                if case .failed(let why) = link.state { Text(why).foregroundStyle(.red) }
                if link.state == .scanning {
                    HStack { Text("Looking for readers…").foregroundStyle(.secondary); Spacer(); ProgressView() }
                    ForEach(link.found) { d in
                        Button { Task { try? await link.connect(d) } } label: {
                            HStack {
                                Label(d.name, systemImage: d.looksLikeOBD ? "car.side" : "dot.radiowaves.left.and.right")
                                Spacer()
                                Text("\(d.rssi) dBm").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Stop looking") { link.stopScan() }
                } else {
                    Button { link.scan() } label: { Label("Find OBD reader", systemImage: "antenna.radiowaves.left.and.right") }
                }
            }
        } header: {
            Text("OBD reader")
        } footer: {
            if link.state == .scanning {
                Text("Readers usually show up as OBDII, OBDBLE, IOS-Vlink or similar. If yours is missing, unplug it for a few seconds.")
            }
        }
    }

    private var probeSection: some View {
        Section {
            Button {
                Task { await probe.run() }
            } label: {
                HStack {
                    Label(probe.steps.isEmpty ? "Run probe" : "Run probe again", systemImage: "stethoscope")
                    if probe.running { Spacer(); ProgressView() }
                }
            }
            .disabled(probe.running || link.state != .ready)
            if !probe.live.isEmpty {
                HStack {
                    liveValue(0x0C, "rpm", "%.0f")
                    liveValue(0x0D, "km/h", "%.0f")
                    liveValue(0x11, "% thr", "%.0f")
                    liveValue(0x49, "% pedal", "%.0f")
                }
            }
        }
    }

    private func liveValue(_ pid: UInt8, _ unit: String, _ fmt: String) -> some View {
        VStack {
            Text(probe.live[pid].map { String(format: fmt, $0) } ?? "–").font(.title3.bold()).monospacedDigit()
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func listenSection(_ l: (phase: OBDProbe.ListenPhase, secondsLeft: Int, frames: Int)) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(l.phase.title).font(.title2.bold())
                    Spacer()
                    Text("\(l.secondsLeft)s").font(.title.bold()).monospacedDigit().foregroundStyle(.orange)
                }
                Text(l.phase.instruction).font(.headline)
                Text("\(l.frames) messages heard").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } header: {
            Text("Do this now")
        }
    }
}

private struct StepRow: View {
    let step: OBDProbe.Step

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.headline)
                if !step.detail.isEmpty { Text(step.detail).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.status {
        case .running: ProgressView()
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

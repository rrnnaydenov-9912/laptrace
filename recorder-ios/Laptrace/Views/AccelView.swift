import SwiftUI

/// Acceleration and braking timer. Stop the car, then launch: the run starts by itself.
struct AccelView: View {
    @Environment(Recorder.self) private var rec
    @Environment(\.dismiss) private var dismiss

    private var meter: AccelMeter { rec.accel ?? AccelMeter() }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            VStack(spacing: 12) {
                header
                status(at: ctx.date)
                Text(String(format: "%.0f", rec.speedKmh))
                    .font(.system(size: 110, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottomTrailing) { Text("km/h").font(.title3).foregroundStyle(.secondary) }
                results
                footer
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear {
            if rec.accel == nil { rec.accel = AccelMeter() }
            rec.startPreview()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            rec.accel = nil
            rec.stopPreviewIfIdle()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var header: some View {
        HStack {
            Text("Acceleration timer").font(.headline)
            Spacer()
            Button("Clear") { rec.accel = AccelMeter() }
                .disabled(meter.runs.isEmpty)
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                .accessibilityLabel("Close")
        }
    }

    @ViewBuilder private func status(at date: Date) -> some View {
        let acc = rec.lastFix?.hAcc ?? -1
        let gpsOK = acc > 0 && acc <= AccelMeter.maxHAcc
        HStack {
            switch meter.phase {
            case .moving:
                Label("Stop the car to arm", systemImage: "pause.circle").foregroundStyle(.secondary)
            case .ready:
                Label(gpsOK ? "Ready – launch when you like" : "Waiting for better GPS",
                      systemImage: gpsOK ? "flag.checkered" : "location.slash")
                    .foregroundStyle(gpsOK ? .green : .orange)
            case .running:
                let t = date.timeIntervalSince1970 - (meter.runStart ?? date.timeIntervalSince1970)
                Label(String(format: "%.1f s · %.0f m", t, meter.runDistance), systemImage: "stopwatch")
                    .foregroundStyle(.yellow)
                    .monospacedDigit()
            }
            Spacer()
            Text(acc > 0 ? String(format: "GPS ±%.0f m", acc) : "No GPS")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background((gpsOK ? Color.green : Color.orange).opacity(0.25), in: Capsule())
        }
        .font(.title3.weight(.semibold))
    }

    private var results: some View {
        let latest = Dictionary(meter.runs.map { ($0.kind, $0) }, uniquingKeysWith: { _, b in b })
        return ScrollView {
            VStack(spacing: 8) {
                ForEach(AccelRun.Kind.allCases, id: \.self) { kind in
                    row(kind, latest[kind], best: meter.runs.filter { $0.kind == kind && $0.valid }.map(\.time).min())
                }
            }
        }
    }

    private func row(_ kind: AccelRun.Kind, _ run: AccelRun?, best: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.rawValue).font(.headline)
                Spacer()
                if let run {
                    Text(String(format: "%.2f s", run.time))
                        .font(.title2.weight(.bold).monospacedDigit())
                        .foregroundStyle(run.valid ? .white : .orange)
                } else {
                    Text("–").font(.title2).foregroundStyle(.secondary)
                }
            }
            if let run {
                Text(detail(run, best: best)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                ForEach(run.issues, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func detail(_ r: AccelRun, best: Double?) -> String {
        var parts: [String] = []
        if let n = r.timeNoRollout { parts.append(String(format: "%.2f s without rollout", n)) }
        if let trap = r.trapKmh { parts.append(String(format: "trap %.0f km/h", trap)) }
        if r.kind == .brake60to0 || r.kind == .quarterMile { parts.append(String(format: "%.1f m", r.distance)) }
        if let s = r.slopePct { parts.append(String(format: "slope %+.1f%%", s)) }
        if let l = r.levelTime, let s = r.slopePct, abs(s) >= 0.2 { parts.append(String(format: "level %.2f s", l)) }
        if let best, meter.runs.filter({ $0.kind == r.kind }).count > 1 { parts.append(String(format: "best %.2f s", best)) }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        VStack(spacing: 4) {
            if let e = meter.speedoErrorPct {
                Text(String(format: "Car speedo reads %+.1f%% against GPS", e)).font(.footnote)
            } else {
                Text("Connect the OBD reader to compare the car's speedo with GPS.").font(.footnote).foregroundStyle(.secondary)
            }
            Text("Phone GPS updates about once a second, so times are good to roughly ±0.2 s. Runs on a slope over 1% or with GPS worse than ±10 m are flagged. Only time runs on a closed road or track.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

import SwiftUI

/// Full-screen track mode: your line against your best lap, speed and revs, pedal and brake,
/// engine temperatures and a cue for the next corner. Built to be read at a glance.
struct TrackDashView: View {
    @Environment(Recorder.self) private var rec
    @Environment(\.dismiss) private var dismiss
    private var obd: OBDLive { OBDLive.shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            GeometryReader { geo in
                VStack(spacing: 8) {
                    // Upper half: clock, line and the next-corner cue.
                    VStack(spacing: 8) {
                        topBar
                        LineMap(line: rec.line)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                        cueRow
                    }
                    .frame(height: (geo.size.height - 8) / 2)

                    // Lower half: the numbers, big enough to read at a glance.
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            tile(String(format: "%.0f", speedKmh), "km/h", color: .white)
                            tile(rpm.map { String(format: "%.0f", $0) } ?? "–", "rpm",
                                 color: (rpm ?? 0) > 6_200 ? .red : .white)
                        }
                        .frame(maxHeight: .infinity)
                        pedals
                        HStack(spacing: 8) {
                            temp("Coolant", obd.values[0x05], warn: 105, cold: 70)
                            temp("Oil", obd.values[0x5C], warn: 130, cold: 80)
                            temp("Intake", obd.values[0x0F], warn: 55, cold: nil)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: (geo.size.height - 8) / 2)
                }
            }
            .padding(10)
            .foregroundStyle(.white)
            .background(Color.black.ignoresSafeArea())
        }
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Top: close, lap clock, reader, delta

    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.bold()) }
                .buttonStyle(.bordered).tint(.gray)
                .accessibilityLabel("Close track screen")
            VStack(alignment: .leading, spacing: 0) {
                Text(Fmt.lap(rec.currentLapElapsed)).font(.title.bold()).monospacedDigit()
                Text("best \(Fmt.lap(rec.best?.duration))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            readerButton
            if let d = rec.line.now?.deltaKmh {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "%+.0f", d)).font(.title.bold()).monospacedDigit()
                        .foregroundStyle(d >= 0 ? .green : .red)
                    Text("km/h vs best").font(.caption).foregroundStyle(.secondary)
                }
            } else if let split = rec.lastSplit, let d = split.delta {
                Text(Fmt.delta(d)).font(.title.bold()).monospacedDigit().foregroundStyle(d < 0 ? .green : .red)
            }
        }
    }

    @ViewBuilder private var cueRow: some View {
        if let cue = rec.line.cue {
            Text(cue)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        } else {
            Text(rec.laps.isEmpty ? "Corner coaching starts after your first full lap." : " ")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    // MARK: Tiles

    /// One big number with its unit, filling its share of the lower half.
    private func tile(_ value: String, _ unit: String, color: Color) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 96, weight: .heavy)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.3)
                .foregroundStyle(color)
            Text(unit).font(.headline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private var speedKmh: Double {
        if obd.isLive, let v = obd.values[0x0D], rec.lastFix == nil { return v }
        return rec.speedKmh
    }

    private var rpm: Double? { obd.isLive ? obd.values[0x0C] : nil }

    // MARK: Pedal and brake

    private var pedals: some View {
        let pedal = obd.isLive ? (obd.values[0x49] ?? obd.values[0x11]) : nil
        let braking = max(0, -rec.line.accelG)
        return VStack(spacing: 8) {
            bar("Throttle", value: pedal.map { $0 / 100 } ?? 0, text: pedal.map { String(format: "%.0f%%", $0) } ?? "–", color: .green)
            bar("Brake", value: min(1, braking / 1.0), text: String(format: "%.2f g", braking), color: .red)
        }
        .frame(maxHeight: .infinity)
    }

    private func bar(_ label: String, value: Double, text: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.title3.bold()).frame(width: 96, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12))
                    RoundedRectangle(cornerRadius: 8).fill(color).frame(width: geo.size.width * min(max(value, 0), 1))
                }
            }
            Text(text).font(.system(size: 30, weight: .bold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(width: 110, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Temperatures and reader status

    private func temp(_ label: String, _ v: Double?, warn: Double, cold: Double?) -> some View {
        let color: Color = {
            guard let v else { return .secondary }
            if v >= warn { return .red }
            if let cold, v < cold { return .cyan }
            return .white
        }()
        return VStack(spacing: 0) {
            Text(v.map { String(format: "%.0f°", $0) } ?? "–")
                .font(.system(size: 64, weight: .heavy)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.3)
                .foregroundStyle(color)
            Text(label).font(.headline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background((v.map { $0 >= warn } ?? false ? Color.red.opacity(0.25) : Color.white.opacity(0.06)),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var readerButton: some View {
        if obd.isLive {
            Label(String(format: "%.0f Hz", obd.hz), systemImage: "car.side").font(.caption).foregroundStyle(.green)
        } else {
            Button {
                Task { await obd.autoConnect() }
            } label: {
                Label(obd.running ? "Connecting…" : "Connect car", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent).tint(.orange)
            .disabled(obd.running)
            .overlay(alignment: .top) {
                if let p = obd.problem {
                    Text(p).font(.caption2).foregroundStyle(.orange).fixedSize().offset(y: -18)
                }
            }
        }
    }
}

/// Map of the best lap (grey), the lap in progress coloured by pedal, corner numbers and the car.
struct LineMap: View {
    let line: LiveLine

    var body: some View {
        Canvas { ctx, size in
            let pts = line.best + line.current
            guard pts.count > 1 else {
                ctx.draw(Text("Your line appears here once you're moving.").foregroundStyle(.secondary),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
            let scale = min((size.width - 24) / max(maxX - minX, 1), (size.height - 24) / max(maxY - minY, 1))
            let ox = (size.width - (maxX - minX) * scale) / 2, oy = (size.height - (maxY - minY) * scale) / 2
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + (x - minX) * scale, y: size.height - oy - (y - minY) * scale) }

            if line.best.count > 1 {
                var path = Path()
                path.move(to: p(line.best[0].x, line.best[0].y))
                for q in line.best.dropFirst() { path.addLine(to: p(q.x, q.y)) }
                ctx.stroke(path, with: .color(.gray.opacity(0.6)), lineWidth: 6)
            }
            for (a, b) in zip(line.current, line.current.dropFirst()) {
                var seg = Path()
                seg.move(to: p(a.x, a.y)); seg.addLine(to: p(b.x, b.y))
                ctx.stroke(seg, with: .color(Self.color(b.pedal)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            for c in line.corners {
                ctx.draw(Text("T\(c.number)").font(.caption2.bold()).foregroundStyle(.white.opacity(0.8)), at: p(c.x, c.y))
            }
            if let car = line.current.last {
                let at = p(car.x, car.y)
                ctx.fill(Path(ellipseIn: CGRect(x: at.x - 7, y: at.y - 7, width: 14, height: 14)), with: .color(.white))
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 10) {
                legend(.green, "throttle"); legend(.red, "brake"); legend(.yellow, "coast"); legend(.gray, "best")
            }
            .font(.caption2).padding(8)
        }
        .accessibilityLabel("Track map with your current lap and best lap")
    }

    static func color(_ p: LiveLine.Pedal) -> Color {
        switch p { case .throttle: .green; case .brake: .red; case .coast: .yellow }
    }

    private func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 3) { Circle().fill(c).frame(width: 7, height: 7); Text(s).foregroundStyle(.secondary) }
    }
}

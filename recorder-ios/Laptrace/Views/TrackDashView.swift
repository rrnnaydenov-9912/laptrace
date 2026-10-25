import Combine
import SwiftUI

/// Full-screen track mode: your line against your best lap, speed and revs, pedal and brake,
/// engine temperatures and a cue for the next corner. Built to be read at a glance.
struct TrackDashView: View {
    @Environment(Recorder.self) private var rec
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Self.shiftKey) private var shiftRPM = 6_200
    @State private var thermal = ProcessInfo.processInfo.thermalState
    /// Brightness before the thermal guard dimmed the screen; nil while not dimmed.
    @State private var savedBrightness: CGFloat?
    @State private var freeBytes: Int64?
    private var obd: OBDLive { OBDLive.shared }

    static let shiftKey = "shiftRPM"

    /// Serious or critical: iOS is about to throttle, so the screen redraws and polls less.
    private var hot: Bool { thermal == .serious || thermal == .critical }

    var body: some View {
        TimelineView(.periodic(from: .now, by: hot ? 0.5 : 0.2)) { context in
            GeometryReader { geo in
                VStack(spacing: 8) {
                    // Upper half: clock, line and the next-corner cue.
                    VStack(spacing: 8) {
                        DeltaBar(seconds: rec.line.now?.deltaSeconds)
                        topBar
                        if speedKmh < 20 || rec.laps.isEmpty { readiness }
                        LineMap(line: rec.line, hint: mapHint, showLegend: speedKmh < 20)
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
                                 color: atShift ? .red : .white)
                        }
                        .frame(maxHeight: .infinity)
                        pedals
                        HStack(spacing: 8) {
                            temp("Coolant", obd.values[0x05], warn: 105, cold: 70, reported: obd.reports(0x05))
                            temp("Oil", obd.values[0x5C], warn: 130, cold: 80, reported: obd.reports(0x5C))
                            temp("Intake", obd.values[0x0F], warn: 55, cold: nil, reported: obd.reports(0x0F))
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: (geo.size.height - 8) / 2)
                }
            }
            .padding(10)
            .foregroundStyle(.white)
            .background(Color.black.ignoresSafeArea())
            // Shift light: a red frame round the whole screen, flashing on every other tick.
            .overlay {
                if atShift && Int(context.date.timeIntervalSinceReferenceDate / (hot ? 0.5 : 0.2)) % 2 == 0 {
                    Rectangle().strokeBorder(Color.red, lineWidth: 18).ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
            // Fixed full-screen layout: large accessibility text would truncate the labels, not help.
            .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            UIDevice.current.isBatteryMonitoringEnabled = true
            DriveDetection.shared.trackScreenOpen = true
            // Keeps GPS (and the app) alive if the screen locks or another app comes forward.
            rec.startPreview(background: true)
            applyThermal(ProcessInfo.processInfo.thermalState)
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in
            applyThermal(ProcessInfo.processInfo.thermalState)
        }
        .task {
            while !Task.isCancelled {
                let url = URL(fileURLWithPath: NSHomeDirectory())
                freeBytes = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onDisappear {
            DriveDetection.shared.trackScreenOpen = false
            rec.stopPreviewIfIdle()
            UIApplication.shared.isIdleTimerDisabled = rec.state == .recording
            UIDevice.current.isBatteryMonitoringEnabled = false
            if let b = savedBrightness { UIScreen.main.brightness = b; savedBrightness = nil }
            obd.easeOffWhenHot = false
        }
    }

    /// Dims the screen and slows redraws and polling while hot; puts everything back once it cools.
    private func applyThermal(_ state: ProcessInfo.ThermalState) {
        thermal = state
        obd.easeOffWhenHot = hot
        if hot, savedBrightness == nil {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = min(UIScreen.main.brightness, 0.5)
        } else if !hot, let b = savedBrightness {
            UIScreen.main.brightness = b
            savedBrightness = nil
        }
    }

    private var atShift: Bool { (rpm ?? 0) >= Double(shiftRPM) }

    // MARK: Readiness: GPS, car, battery, storage

    /// Shown while slow or before the first lap, so a weak fix or a full phone is caught in the pits.
    private var readiness: some View {
        let hAcc = rec.lastFix?.hAcc
        let battery = UIDevice.current.batteryLevel   // -1 when unknown
        let gb = freeBytes.map { Double($0) / 1_000_000_000 }
        return HStack(spacing: 6) {
            chip("location.fill",
                 hAcc.map { $0 > 0 ? String(format: "±%.0f m", $0) : "GPS –" } ?? "No GPS",
                 hAcc.map { $0 > 0 && $0 <= 5 ? .green : ($0 > 0 && $0 <= 30 ? .orange : .red) } ?? .red)
            chip("car.side.fill",
                 obd.isLive ? String(format: "%.0f Hz", obd.hz) : "OBD off",
                 obd.isLive ? (obd.hz >= 5 ? .green : .orange) : .secondary)
            chip("battery.75percent",
                 battery < 0 ? "–" : String(format: "%.0f%%", battery * 100),
                 battery < 0 ? .secondary : (battery < 0.2 ? .red : (battery < 0.4 ? .orange : .green)))
            chip("internaldrive",
                 gb.map { String(format: "%.1f GB", $0) } ?? "–",
                 gb.map { $0 < 1 ? .red : ($0 < 5 ? .orange : .green) } ?? .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func chip(_ icon: String, _ text: String, _ color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.06), in: Capsule())
    }

    /// What the empty map says, so a dark panel is never a mystery.
    private var mapHint: String {
        guard let fix = rec.lastFix else { return "Waiting for GPS…\nAllow location access and keep the phone where it can see the sky." }
        if fix.hAcc <= 0 || fix.hAcc > 30 { return String(format: "GPS accuracy is ±%.0f m.\nYour line appears once it is below 30 m.", fix.hAcc) }
        return "Your line appears here once you're moving."
    }

    // MARK: Top: close, lap clock, reader, delta

    /// Glove-sized: every control up here is at least 56 pt.
    private static let glove: CGFloat = 56

    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 22, weight: .bold))
                    .frame(width: Self.glove, height: Self.glove)
            }
            .buttonStyle(.bordered).tint(.gray)
            .accessibilityLabel("Close track screen")
            VStack(alignment: .leading, spacing: 0) {
                Text(Fmt.lap(rec.currentLapElapsed)).font(.system(size: 34, weight: .bold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let p = rec.line.now?.predicted {
                    Text("predicted \(Fmt.lap(p))").font(.system(size: 15, weight: .bold)).foregroundStyle(.cyan)
                } else {
                    Text("best \(Fmt.lap(rec.best?.duration))").font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if hot {
                Label("Phone hot", systemImage: "thermometer.high")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.orange, in: Capsule())
                    .accessibilityLabel("Phone is hot, screen dimmed")
            }
            readerButton
            delta
        }
    }

    /// The number you glance for. The slot keeps its width when there is no delta yet, so nothing jumps.
    private var delta: some View {
        let big = Font.system(size: 48, weight: .heavy)
        return VStack(alignment: .trailing, spacing: 0) {
            if let d = rec.line.now?.deltaSeconds {
                Text(Fmt.delta(d)).font(big).foregroundStyle(d <= 0 ? .green : .red)
                Text((rec.line.now?.deltaKmh).map { String(format: "%+.0f km/h", $0) } ?? "s vs best")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            } else if let d = rec.line.now?.deltaKmh {
                Text(String(format: "%+.0f", d)).font(big).foregroundStyle(d >= 0 ? .green : .red)
                Text("km/h vs best").font(.system(size: 15)).foregroundStyle(.secondary)
            } else if let split = rec.lastSplit, let d = split.delta {
                Text(Fmt.delta(d)).font(big).foregroundStyle(d < 0 ? .green : .red)
                Text(split.label).font(.system(size: 15)).foregroundStyle(.secondary)
            } else {
                Text("–").font(big).foregroundStyle(.secondary)
                Text("vs best").font(.system(size: 15)).foregroundStyle(.secondary)
            }
        }
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
        .frame(minWidth: 120, alignment: .trailing)
    }

    /// Engine too hot, only for temperatures the car actually reports. Beats the corner cue.
    private var tempWarning: String? {
        if obd.reports(0x05), let c = obd.values[0x05], c >= 105 { return String(format: "Coolant %.0f° — ease off", c) }
        if obd.reports(0x5C), let o = obd.values[0x5C], o >= 130 { return String(format: "Oil %.0f° — ease off", o) }
        return nil
    }

    @ViewBuilder private var cueRow: some View {
        if obd.isLive, let warn = tempWarning {
            Label(warn, systemImage: "thermometer.sun.fill")
                .font(.system(size: 22, weight: .heavy))
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 10))
        } else if let cue = rec.line.cue {
            Text(cue)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        } else if !obd.isLive, let p = obd.problem {
            // Reader trouble gets the full row instead of a caption squeezed over the clock.
            Label(p, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(.orange)
                .lineLimit(2).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
        } else {
            Text(rec.laps.isEmpty ? "Corner coaching starts after your first full lap." : " ")
                .font(.system(size: 17)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
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
        let g = rec.liveG.reading
        let braking = max(0, -(g?.long ?? rec.line.accelG))
        let lat = abs(g?.lat ?? 0)
        return VStack(spacing: 8) {
            bar("Throttle", value: pedal.map { $0 / 100 } ?? 0, text: pedal.map { String(format: "%.0f%%", $0) } ?? "–", color: .green)
            bar("Brake", value: min(1, braking / 1.0), text: String(format: "%.2f g", braking), color: .red)
            bar(g?.fromIMU == true ? "Lat·IMU" : "Lat", value: min(1, lat / 1.5), text: String(format: "%.2f g", lat), color: .orange)
        }
        .frame(maxHeight: .infinity)
    }

    private func bar(_ label: String, value: Double, text: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 20, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(width: 96, alignment: .leading)
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

    /// `reported` is false when the car says it doesn't publish this PID (many cars don't send oil temperature on standard OBD).
    private func temp(_ label: String, _ v: Double?, warn: Double, cold: Double?, reported: Bool = true) -> some View {
        let color: Color = {
            guard let v else { return .secondary }
            if v >= warn { return .red }
            if let cold, v < cold { return .cyan }
            return .white
        }()
        return VStack(spacing: 0) {
            Text(v.map { String(format: "%.0f°", $0) } ?? (reported ? "–" : "n/a"))
                .font(.system(size: reported || v != nil ? 64 : 34, weight: .heavy)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.3)
                .foregroundStyle(color)
            Text(label).font(.headline).foregroundStyle(.secondary)
            if !reported && v == nil {
                Text("Car doesn't report it").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background((v.map { $0 >= warn } ?? false ? Color.red.opacity(0.25) : Color.white.opacity(0.06)),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var readerButton: some View {
        if obd.isLive {
            Image(systemName: "car.side.fill").font(.system(size: 22)).foregroundStyle(.green)
                .accessibilityLabel(String(format: "Car connected, %.0f Hz", obd.hz))
        } else {
            Button {
                Task { await obd.autoConnect() }
            } label: {
                Image(systemName: obd.running ? "ellipsis" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .bold))
                    .frame(width: Self.glove, height: Self.glove)
            }
            .buttonStyle(.borderedProminent).tint(.orange)
            .disabled(obd.running)
            .accessibilityLabel(obd.running ? "Connecting to car" : "Connect car")
        }
    }
}

/// Map of the best lap (grey), the lap in progress coloured by pedal, corner numbers and the car.
struct LineMap: View {
    let line: LiveLine
    var hint = "Your line appears here once you're moving."
    /// The colour key is unreadable at speed, so the track screen shows it only when slow.
    var showLegend = true

    var body: some View {
        Canvas { ctx, size in
            let pts = line.best + line.current
            guard pts.count > 1 else {
                let mid = CGPoint(x: size.width / 2, y: size.height / 2)
                if !pts.isEmpty {
                    ctx.fill(Path(ellipseIn: CGRect(x: mid.x - 7, y: mid.y - 7, width: 14, height: 14)), with: .color(.white))
                }
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
            for m in line.brakeMarkers {   // where the best lap started braking
                let at = p(m.x, m.y)
                var bar = Path()
                bar.addRoundedRect(in: CGRect(x: at.x - 6, y: at.y - 2.5, width: 12, height: 5), cornerSize: CGSize(width: 2, height: 2))
                ctx.fill(bar, with: .color(.red))
                ctx.stroke(bar, with: .color(.white), lineWidth: 1)
            }
            for c in line.corners {
                ctx.draw(Text("T\(c.number)").font(.caption2.bold()).foregroundStyle(.white.opacity(0.8)), at: p(c.x, c.y))
            }
            if let g = line.ghost {   // the best lap at the same elapsed time
                let at = p(g.x, g.y)
                let r = CGRect(x: at.x - 6, y: at.y - 6, width: 12, height: 12)
                ctx.fill(Path(ellipseIn: r), with: .color(.cyan.opacity(0.35)))
                ctx.stroke(Path(ellipseIn: r), with: .color(.cyan), lineWidth: 2)
            }
            if let car = line.current.last {
                let at = p(car.x, car.y)
                ctx.fill(Path(ellipseIn: CGRect(x: at.x - 7, y: at.y - 7, width: 14, height: 14)), with: .color(.white))
            }
        }
        .overlay {
            if line.best.count + line.current.count <= 1 {
                Text(hint)
                    .font(.headline).multilineTextAlignment(.center)
                    .foregroundStyle(Color.white.opacity(0.8))
                    .padding(.horizontal, 20).offset(y: line.current.isEmpty ? 0 : 40)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if showLegend {
                HStack(spacing: 10) {
                    legend(.green, "throttle"); legend(.red, "brake"); legend(.yellow, "coast"); legend(.gray, "best"); legend(.cyan, "ghost")
                }
                .font(.caption2).padding(8)
            }
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


/// Running time gap to the best lap: fills right in red when slower, left in green when faster. Full scale ±2 s.
struct DeltaBar: View {
    let seconds: Double?
    static let fullScale = 2.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / 2
            let f = min(abs(seconds ?? 0) / Self.fullScale, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                if let s = seconds {
                    Rectangle().fill(s <= 0 ? Color.green : Color.red)
                        .frame(width: w * f)
                        .offset(x: s <= 0 ? w - w * f : w)
                }
                Rectangle().fill(Color.white).frame(width: 2).offset(x: w - 1)
            }
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .accessibilityLabel(seconds.map { String(format: "%+.2f seconds against best lap", $0) } ?? "No delta yet")
    }
}

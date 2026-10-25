import SwiftUI
import Charts

/// Every lap of a session drawn on top of each other from the recorded GPS, with speed and
/// time gained or lost against the best lap along the lap. `focus` opens one lap over the best.
struct LapOverlayView: View {
    let meta: SessionMeta
    let track: Track?
    var focus: Int? = nil

    var body: some View {
        List { LapOverlaySections(meta: meta, track: track, focus: focus) }
            .navigationTitle(focus.map { "Lap \($0) vs best" } ?? "Lap lines")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The lap-lines sections on their own, so the session screen can show them inline.
struct LapOverlaySections: View {
    let meta: SessionMeta
    let track: Track?
    var focus: Int? = nil

    struct LapLine: Identifiable {
        var id: Int { lap.number }
        let lap: Coach.Lap
        let grid: Coach.Grid     // aligned to the best lap's length
        let slow: Bool           // pit, traffic or spin: > slowLapFactor × median
    }

    struct Sample: Identifiable {
        let id = UUID()
        let lap: String
        let s: Double
        let value: Double
    }

    @State private var lines: [LapLine] = []
    @State private var bestNumber: Int?
    @State private var visible: Set<Int> = []
    @State private var bySpeed = false
    @State private var loaded = false
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var drag: CGSize = .zero

    private static let palette: [Color] = [.orange, .cyan, .pink, .yellow, .purple, .blue, .mint, .red, .teal, .indigo]

    var body: some View {
        Group {
            if !loaded {
                Section("Lap lines") { ProgressView("Loading laps…") }
            } else if lines.isEmpty {
                Section("Lap lines") { Text("No complete laps with GPS in this session.").foregroundStyle(.secondary) }
            } else {
                Section {
                    map.frame(height: 360).listRowInsets(EdgeInsets())
                    chips
                    Toggle("Colour by speed", isOn: $bySpeed)
                } footer: {
                    Text("Pinch to zoom, drag to pan, double-tap to reset. Best lap in green.")
                }
                Section("Time vs best (+ = slower)") { deltaChart }
                Section("Speed (km/h)") { speedChart }
            }
        }
        .task(id: meta.id) {
            let id = meta.id, track = track
            let laps = await Task.detached {
                Exporter().coachLaps(fixes: RawFiles.readFixes(SessionStore.shared.gpsURL(id)), track: track)
            }.value
            load(laps)
        }
    }

    private func load(_ laps: [Coach.Lap]) {
        let ok = laps.filter { $0.duration > 0 && $0.x.count > 20 }
        let sorted = ok.map(\.duration).sorted()
        guard !sorted.isEmpty else { loaded = true; return }
        let median = sorted[(sorted.count - 1) / 2]   // lower median, as LiveLine
        let isSlow = { (l: Coach.Lap) in l.duration > LiveLine.slowLapFactor * median }
        let best = ok.filter { !isSlow($0) }.min { $0.duration < $1.duration } ?? ok.min { $0.duration < $1.duration }!
        let length = Coach.resample(best).s.last ?? 0
        lines = ok.map { LapLine(lap: $0, grid: Coach.aligned(Coach.resample($0), to: length), slow: isSlow($0)) }
        bestNumber = best.number
        if let focus, ok.contains(where: { $0.number == focus }) {
            visible = [focus, best.number]
        } else {
            visible = Set(lines.filter { !$0.slow }.map(\.id))
        }
        loaded = true
    }

    private var shown: [LapLine] { lines.filter { visible.contains($0.id) } }

    private func color(_ n: Int) -> Color {
        if n == bestNumber { return .green }
        let others = lines.map(\.id).filter { $0 != bestNumber }
        return Self.palette[(others.firstIndex(of: n) ?? 0) % Self.palette.count]
    }

    private func label(_ n: Int) -> String { n == bestNumber ? "L\(n) best" : "L\(n)" }

    // MARK: - Map

    private var map: some View {
        let shown = shown
        let bestLine = lines.first { $0.id == bestNumber }
        let vs = shown.flatMap(\.grid.v)
        let vMin = vs.min() ?? 0, vMax = max(vs.max() ?? 1, vMin + 1)
        return Canvas { ctx, size in
            let frame = shown.isEmpty ? lines : shown
            let xs = frame.flatMap(\.grid.x), ys = frame.flatMap(\.grid.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
            let k = zoom * pinch
            let scale = min((size.width - 24) / max(maxX - minX, 1), (size.height - 24) / max(maxY - minY, 1)) * k
            let ox = (size.width - (maxX - minX) * scale) / 2 + pan.width + drag.width
            let oy = (size.height - (maxY - minY) * scale) / 2 - pan.height - drag.height
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + (x - minX) * scale, y: size.height - oy - (y - minY) * scale) }
            func path(_ g: Coach.Grid, step: Int = 2) -> Path {
                var path = Path()
                path.move(to: p(g.x[0], g.y[0]))
                for i in stride(from: step, to: g.x.count, by: step) { path.addLine(to: p(g.x[i], g.y[i])) }
                if let x = g.x.last, let y = g.y.last { path.addLine(to: p(x, y)) }
                return path
            }
            let width = max(2, min(5, 2 * sqrt(k)))
            // Others first, best on top so the reference line is always readable.
            for l in shown.sorted(by: { ($0.id == bestNumber ? 1 : 0) < ($1.id == bestNumber ? 1 : 0) }) where l.grid.x.count > 1 {
                if bySpeed {
                    for i in stride(from: 0, to: l.grid.x.count - 3, by: 3) {
                        var seg = Path()
                        seg.move(to: p(l.grid.x[i], l.grid.y[i])); seg.addLine(to: p(l.grid.x[i + 3], l.grid.y[i + 3]))
                        let f = (l.grid.v[i] - vMin) / (vMax - vMin)
                        ctx.stroke(seg, with: .color(Color(hue: 0.66 * (1 - f), saturation: 0.9, brightness: 0.95)),
                                   style: StrokeStyle(lineWidth: width, lineCap: .round))
                    }
                } else {
                    let best = l.id == bestNumber
                    ctx.stroke(path(l.grid), with: .color(color(l.id).opacity(best ? 1 : 0.8)),
                               style: StrokeStyle(lineWidth: best ? width + 1.5 : width, lineCap: .round, lineJoin: .round))
                }
            }
            if let b = bestLine, let x = b.grid.x.first, let y = b.grid.y.first {   // start / finish
                let at = p(x, y)
                ctx.fill(Path(ellipseIn: CGRect(x: at.x - 5, y: at.y - 5, width: 10, height: 10)), with: .color(.white))
                ctx.stroke(Path(ellipseIn: CGRect(x: at.x - 5, y: at.y - 5, width: 10, height: 10)), with: .color(.black), lineWidth: 1.5)
            }
        }
        .background(Color.black)
        .contentShape(Rectangle())
        .gesture(MagnifyGesture().onChanged { pinch = $0.magnification }
            .onEnded { _ in zoom = min(max(zoom * pinch, 1), 12); pinch = 1 })
        .simultaneousGesture(DragGesture().onChanged { drag = $0.translation }
            .onEnded { _ in pan.width += drag.width; pan.height += drag.height; drag = .zero })
        .onTapGesture(count: 2) { zoom = 1; pan = .zero }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All") { visible = Set(lines.map(\.id)) }
                chip("Clean") { visible = Set(lines.filter { !$0.slow }.map(\.id)) }
                if let b = bestNumber, let last = lines.last?.id { chip("Best + last") { visible = [b, last] } }
                ForEach(lines) { l in
                    let on = visible.contains(l.id)
                    Button {
                        if on { visible.remove(l.id) } else { visible.insert(l.id) }
                    } label: {
                        Text("\(label(l.id)) \(Fmt.lap(l.lap.duration))")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(on ? color(l.id).opacity(0.3) : Color.gray.opacity(0.15), in: Capsule())
                            .overlay(Capsule().stroke(on ? color(l.id) : .clear, lineWidth: 1.5))
                            .opacity(l.slow && !on ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).font(.caption.bold()).buttonStyle(.bordered)
    }

    // MARK: - Charts

    private var domain: (names: [String], colors: [Color]) {
        let ls = shown
        return (ls.map { label($0.id) }, ls.map { color($0.id) })
    }

    private var speedChart: some View {
        let data = shown.flatMap { l in
            stride(from: 0, to: l.grid.s.count, by: 5).map { Sample(lap: label(l.id), s: l.grid.s[$0], value: l.grid.v[$0] * 3.6) }
        }
        return Chart(data) {
            LineMark(x: .value("m", $0.s), y: .value("km/h", $0.value))
                .foregroundStyle(by: .value("Lap", $0.lap))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartForegroundStyleScale(domain: domain.names, range: domain.colors)
        .chartXAxisLabel("metres from the line")
        .frame(height: 220)
    }

    /// Elapsed time at each point minus the best lap's elapsed time at the same point.
    private var deltaChart: some View {
        let best = lines.first { $0.id == bestNumber }
        let data: [Sample] = best.map { b in
            shown.filter { $0.id != b.id }.flatMap { l -> [Sample] in
                guard let t0 = l.grid.t.first, let b0 = b.grid.t.first else { return [] }
                return stride(from: 0, to: l.grid.s.count, by: 10).map { i in
                    let s = l.grid.s[i]
                    let j = min(max(lowerBound(b.grid.s, s), 0), b.grid.s.count - 1)
                    return Sample(lap: label(l.id), s: s, value: (l.grid.t[i] - t0) - (b.grid.t[j] - b0))
                }
            }
        } ?? []
        return Group {
            if data.isEmpty {
                Text("Pick a lap other than the best to see where it gained or lost time.").foregroundStyle(.secondary)
            } else {
                Chart(data) {
                    RuleMark(y: .value("best", 0)).foregroundStyle(.green.opacity(0.6))
                    LineMark(x: .value("m", $0.s), y: .value("s", $0.value))
                        .foregroundStyle(by: .value("Lap", $0.lap))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .chartForegroundStyleScale(domain: domain.names, range: domain.colors)
                .chartXAxisLabel("metres from the line")
                .frame(height: 200)
            }
        }
    }
}

import SwiftUI

@main
struct LaptraceApp: App {
    @State private var recorder = Recorder()

    var body: some Scene {
        WindowGroup {
            TabView {
                RecordView()
                    .tabItem { Label("Record", systemImage: "record.circle") }
                SessionsView()
                    .tabItem { Label("Sessions", systemImage: "list.bullet.rectangle") }
                TracksView()
                    .tabItem { Label("Tracks", systemImage: "flag.checkered") }
            }
            .environment(recorder)
            .tint(.orange)
            .preferredColorScheme(.dark)
        }
    }
}

enum Fmt {
    static func lap(_ s: Double?) -> String {
        guard let s, s.isFinite, s >= 0 else { return "–:–.–" }
        let m = Int(s) / 60
        let rest = s - Double(m * 60)
        return String(format: "%d:%06.3f", m, rest)
    }

    static func delta(_ d: Double?) -> String {
        guard let d else { return "" }
        return String(format: "%@%.2f", d >= 0 ? "+" : "−", abs(d))
    }

    static func duration(_ s: Double) -> String {
        let h = Int(s) / 3600, m = Int(s) / 60 % 60, sec = Int(s) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

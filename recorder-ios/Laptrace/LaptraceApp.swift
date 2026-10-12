import SwiftUI
import UIKit

/// Runs at every launch, including when iOS relaunches the app in the background for a location
/// wake-up, so drive detection is listening before any UI exists.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = Recorder.shared
        DriveDetection.shared.resume()
        return true
    }
}

@main
struct LaptraceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var recorder = Recorder.shared
    @State private var detection = DriveDetection.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                RecordView()
                    .tabItem { Label("Record", systemImage: "record.circle") }
                SessionsView()
                    .tabItem { Label("Sessions", systemImage: "list.bullet.rectangle") }
                TracksView()
                    .tabItem { Label("Tracks", systemImage: "flag.checkered") }
                ProbeView()
                    .tabItem { Label("Car", systemImage: "car.side") }
            }
            .environment(recorder)
            .environment(detection)
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

    static func km(_ m: Double?) -> String {
        guard let m else { return "–" }
        return m < 1000 ? String(format: "%.0f m", m) : String(format: "%.1f km", m / 1000)
    }

    static func duration(_ s: Double) -> String {
        let h = Int(s) / 3600, m = Int(s) / 60 % 60, sec = Int(s) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

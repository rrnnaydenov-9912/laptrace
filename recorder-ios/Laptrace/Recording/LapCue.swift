import AVFoundation
import AudioToolbox

/// Speaks the lap time over whatever audio is playing, e.g. "1 12.4. Plus 0.6."
final class LapCue {
    static let enabledKey = "speakLapTimes"
    static let brakeBeepKey = "brakeBeep"
    private let synth = AVSpeechSynthesizer()

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    func speak(duration: Double, previousBest: Double?) {
        guard enabled else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: Self.phrase(duration: duration, previousBest: previousBest))
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synth.speak(u)
    }

    var brakeBeepEnabled: Bool { UserDefaults.standard.object(forKey: Self.brakeBeepKey) as? Bool ?? true }

    /// Short tick plus a heavy haptic, 50 m before the best lap's brake point.
    func brakeWarning() {
        guard brakeBeepEnabled else { return }
        AudioServicesPlaySystemSound(1057)
        Haptics.brake()
    }

    /// "1 12.4" reads as "one twelve point four"; "1 oh 5.2" as "one oh five point two".
    static func phrase(duration: Double, previousBest: Double?) -> String {
        let tenths = Int((duration * 10).rounded())
        let m = tenths / 600, sec = Double(tenths % 600) / 10
        var s: String
        if m == 0 { s = String(format: "%.1f", sec) }
        else { s = sec < 10 ? String(format: "%d oh %.1f", m, sec) : String(format: "%d %.1f", m, sec) }
        s += "."
        if let previousBest {
            let d = (duration - previousBest) * 10
            let r = abs(d.rounded()) / 10
            if d < 0 { s += String(format: " Best lap. Minus %.1f.", r) }
            else { s += String(format: " Plus %.1f.", r) }
        }
        return s
    }
}


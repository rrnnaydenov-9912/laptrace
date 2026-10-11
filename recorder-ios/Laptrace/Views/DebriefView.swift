import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Debrief rows for a saved session, meant to sit inside a List.
struct DebriefSections: View {
    let meta: SessionMeta
    @State private var debrief: Coach.Debrief?
    @State private var loaded = false
    @State private var explanation: String?
    @State private var explaining = false

    private var track: Track? { TrackStore.shared.all.first { $0.id == meta.trackId } }

    var body: some View {
        Group {
            if let d = debrief {
                Section("Debrief") {
                    LabeledContent("Best lap", value: "\(Fmt.lap(d.stats.bestLap))  (lap \(d.stats.bestLapNumber))")
                    LabeledContent("Timed laps", value: "\(d.stats.timedLaps)")
                    LabeledContent("Lap-time spread", value: String(format: "±%.2f s", d.stats.lapSD))
                    LabeledContent("Best vs typical lap", value: String(format: "%.2f s", d.stats.bestToMedian))
                    if let b3 = d.stats.bestThreeAverage { LabeledContent("Best 3 laps in a row", value: Fmt.lap(b3)) }
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(d.goal.title, systemImage: "target").font(.headline).foregroundStyle(.orange)
                        Text(explanation ?? d.goal.text)
                    }
                    .padding(.vertical, 4)
                    if Narrator.isAvailable && explanation == nil {
                        Button {
                            explaining = true
                            Task {
                                explanation = await Narrator.explain(d)
                                explaining = false
                            }
                        } label: {
                            HStack {
                                Label("Explain in plain words", systemImage: "text.bubble")
                                if explaining { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(explaining)
                    }
                } header: {
                    Text("Next session goal")
                } footer: {
                    Text("One thing to work on, based on your best lap compared with your others.")
                }
            } else if loaded {
                Section("Debrief") {
                    Text("No timed laps yet. Laps are counted when you cross the start/finish line, so pick a track or set the line before you drive.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Debrief") { ProgressView() }
            }
        }
        .task(id: meta.id) {
            let meta = meta, track = track
            debrief = await Task.detached(priority: .userInitiated) { SessionStore.shared.debrief(meta, track: track) }.value
            loaded = true
        }
    }
}

/// Shown on the Record tab right after Stop.
struct DebriefSheet: View {
    let meta: SessionMeta
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List { DebriefSections(meta: meta) }
                .navigationTitle("Debrief")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Rephrases the rule-based goal with the on-device model. Falls back to the
/// rule-based text if the model is missing, fails, or invents a number.
enum Narrator {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    static func explain(_ d: Coach.Debrief) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: """
                You are a friendly driving coach talking to a beginner after a track day in a car.
                Rephrase the goal in the facts below in two or three short, plain sentences.
                Only rephrase. Never introduce, round or change any number; copy numbers exactly as written in the facts.
                No jargon, no lists, no headings.
                """)
            if let r = try? await session.respond(to: "Facts (JSON):\n\(d.factsJSON)") {
                let text = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, Coach.numbersAreGrounded(text, facts: d.factsJSON) { return text }
            }
        }
        #endif
        return d.goal.text
    }
}

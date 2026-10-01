import SiliconElevenLabs
import SwiftUI

/// Live speech: the section the pane shows.
struct LiveSpeechSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LiveSpeechScreen(screen: model.elevenLabsPane.state(for: .liveSpeech) { LiveSpeechModel(context: .app(model)) })
    }
}

struct LiveSpeechScreen: View {
    @Bindable var screen: LiveSpeechModel
    /// A voice list other than the pane's (previews, tests).
    var voices: ElevenLabsVoiceDirectory?

    var body: some View {
        ElevenLabsSectionPage(.liveSpeech) {
            VStack(alignment: .leading, spacing: 16) {
                settings
                compose
                session
                if !screen.spoken.isEmpty || !screen.words.isEmpty { spoken }
            }
        }
        .onDisappear { screen.leave() }
    }

    private var settings: some View {
        LiveCard("Voice and model", subtitle: screen.settingsLocked ? "Locked while the stream is open — Stop it to change them." : nil) {
            VStack(alignment: .leading, spacing: 10) {
                ElevenLabsVoicePicker(selection: $screen.voiceID, directory: voices)
                Picker("Model", selection: $screen.modelID) {
                    ForEach(LiveSpeechModel.models, id: \.self) { Text($0).tag($0) }
                }
                Picker("Format", selection: $screen.outputFormat) {
                    ForEach(LiveSpeechModel.formats, id: \.self) { Text($0).tag($0) }
                }
                .help("PCM plays as it arrives; 192 kbps MP3 and 44.1 kHz PCM need higher plans.")
                HStack {
                    LabeledContent("Language") {
                        TextField("ISO 639-1, optional", text: $screen.languageCode)
                    }
                    .frame(maxWidth: 260)
                    Stepper("Close after \(screen.inactivityTimeout) s without text", value: $screen.inactivityTimeout, in: 5...180, step: 5)
                }
                Toggle("Speak as soon as possible (whole sentences only)", isOn: $screen.autoMode)
                Toggle("Override the voice's settings", isOn: $screen.overridesVoiceSettings)
                if screen.overridesVoiceSettings {
                    slider("Stability", value: $screen.stability, range: 0...1)
                    slider("Similarity", value: $screen.similarityBoost, range: 0...1)
                    slider("Style", value: $screen.style, range: 0...1)
                    slider("Speed", value: $screen.speed, range: 0.7...1.2)
                    Toggle("Speaker boost", isOn: $screen.useSpeakerBoost)
                }
            }
            .disabled(screen.settingsLocked)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                .font(.callout.monospacedDigit())
                .frame(width: 40)
        }
    }

    private var compose: some View {
        LiveCard("Text", subtitle: "Sent in pieces that end at sentences, and spoken as ElevenLabs generates them. More text can follow while the stream is open.") {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $screen.text)
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(alignment: .topLeading) {
                        if screen.text.isEmpty {
                            Text("Type or paste what to say…")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // Never the default button: Return in the text goes into the text.
                    Button {
                        Task { await screen.speak() }
                    } label: {
                        Label(screen.isOpen ? "Speak more" : "Speak", systemImage: "play.fill")
                    }
                    .disabled(screen.speakBlocker != nil)
                    .help(screen.speakBlocker ?? "Sends the text and plays the speech as it arrives")
                    if let blocker = screen.speakBlocker, !screen.text.isEmpty || screen.voiceID.isEmpty {
                        Text(blocker).font(.caption).foregroundStyle(.secondary)
                    } else if screen.pendingCharacters > 0 {
                        Text("Uses credits — about \(screen.pendingCharacters.formatted()) characters' worth.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var session: some View {
        LiveCard("Stream") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    LivePhaseLabel(text: phaseText, live: screen.phase == .live)
                    if let description = screen.sessionDescription {
                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if screen.phase == .live {
                        Button("Finish") { Task { await screen.finish() } }
                            .help("Speaks what is left, then closes")
                    }
                    if screen.isOpen {
                        Button("Stop", role: .destructive) { Task { await screen.stop() } }
                            .help("Closes now; nothing more is spoken")
                    }
                }
                LiveUsageLine(
                    usage: screen.usage, now: screen.now,
                    billedBy: "ElevenLabs bills speech by the characters sent. Nothing reconnects on its own: a stream that ends stays ended.",
                    showsCharacters: true
                )
                if let message = screen.serverMessage {
                    Text("ElevenLabs said: \(message)").font(.callout).foregroundStyle(.orange)
                }
                if let outcome = screen.outcome { LiveOutcomeBanner(outcome: outcome) }
                if !screen.isOpen, !screen.audio.isEmpty {
                    HStack(spacing: 10) {
                        Button("Save audio") { Task { await screen.save() } }
                        if screen.audioTruncated {
                            Text("Only the first \(LiveSpeechModel.audioLimit >> 20) MB is kept.").font(.caption).foregroundStyle(.secondary)
                        }
                        if let saved = screen.savedFile { LiveSavedFile(url: saved) }
                    }
                    if let problem = screen.saveProblem { Text(problem).font(.caption).foregroundStyle(.red) }
                }
            }
        }
    }

    private var spoken: some View {
        LiveCard("Spoken", subtitle: screen.words.isEmpty ? nil : "Each word with when it starts, from ElevenLabs' timings.") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(screen.spoken.enumerated()), id: \.offset) { _, text in
                    Text(text).font(.callout).textSelection(.enabled)
                }
                if !screen.words.isEmpty {
                    LiveWordFlow(words: screen.words.suffix(120).map { ($0.text, $0.startMs) })
                }
            }
        }
    }

    private var phaseText: String {
        switch screen.phase {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .live: "Open"
        case .finishing: "Finishing…"
        case .ended: "Ended"
        }
    }
}

/// Words with a time under each, wrapping.
struct LiveWordFlow: View {
    let words: [(String, Int)]

    var body: some View {
        LiveFlowLayout(spacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                VStack(spacing: 0) {
                    Text(word.0).font(.callout)
                    Text(String(format: "%.2f s", Double(word.1) / 1_000))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A plain wrapping layout.
struct LiveFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

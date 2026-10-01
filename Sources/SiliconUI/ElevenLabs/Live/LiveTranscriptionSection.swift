import AppKit
import SiliconElevenLabs
import SwiftUI
import UniformTypeIdentifiers

/// Live transcription: the section the pane shows.
struct LiveTranscriptionSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LiveTranscriptionScreen(screen: model.elevenLabsPane.state(for: .liveTranscription) {
            LiveTranscriptionModel(context: .app(model))
        })
    }
}

struct LiveTranscriptionScreen: View {
    @Bindable var screen: LiveTranscriptionModel

    /// The entity choices the realtime socket documents.
    static let entityChoices: [(String, String)] = [
        ("", "Off"), ("all", "All"), ("pii", "Personal (PII)"), ("phi", "Health (PHI)"), ("pci", "Payment (PCI)"),
        ("offensive_language", "Offensive language"), ("other", "Other"),
    ]

    var body: some View {
        ElevenLabsSectionPage(.liveTranscription) {
            VStack(alignment: .leading, spacing: 16) {
                settings
                controls
                transcript
            }
        }
        .onDisappear { screen.leave() }
    }

    private var settings: some View {
        LiveCard("Source and options", subtitle: screen.isOpen ? "Locked while transcribing — Stop to change them." : nil) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Listen to", selection: $screen.source) {
                    ForEach(LiveTranscriptionModel.Source.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                if screen.source == .file {
                    HStack {
                        Button("Choose a file…") { chooseFile() }
                        Text(screen.file?.lastPathComponent ?? "No file chosen")
                            .font(.callout)
                            .foregroundStyle(screen.file == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Picker("Commit", selection: $screen.commitStrategy) {
                        Text("At pauses (recommended)").tag(ElevenLabsTranscriptionStreamConfig.CommitStrategy.vad)
                        Text(screen.context.transcription.handCommitLabel).tag(ElevenLabsTranscriptionStreamConfig.CommitStrategy.manual)
                    }
                    .frame(maxWidth: 360)
                }
                HStack {
                    LabeledContent("Language") {
                        TextField("ISO code, or blank to detect", text: $screen.languageCode)
                    }
                    .frame(maxWidth: 300)
                    Picker("Entities", selection: $screen.entityDetection) {
                        ForEach(Self.entityChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .frame(maxWidth: 260)
                }
                LabeledContent("Key terms") {
                    TextField("comma-separated, up to 50 of 20 characters each", text: $screen.keyterms)
                }
                LabeledContent("Edit each segment") {
                    TextField("in plain words, optional", text: $screen.transcriptEdit)
                }
                HStack(spacing: 18) {
                    Toggle("Word timings", isOn: $screen.includeTimestamps)
                        .disabled(screen.filterBackgroundAudio)
                    Toggle("Leave out fillers", isOn: $screen.noVerbatim)
                    Toggle("Filter background speech", isOn: $screen.filterBackgroundAudio)
                }
                ForEach(screen.costLines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(screen.isOpen)
        }
    }

    private var controls: some View {
        LiveCard("Session") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if screen.isOpen {
                        Button(role: .destructive) {
                            Task { await screen.stop() }
                        } label: {
                            Label(screen.phase == .finishing ? "Finishing…" : "Stop", systemImage: "stop.fill")
                        }
                        .disabled(screen.phase == .finishing)
                    } else {
                        // Never the default button: Return does not start a billed session.
                        Button {
                            Task { await screen.start() }
                        } label: {
                            Label(screen.source == .file ? "Transcribe the file" : "Start listening", systemImage: "mic.fill")
                        }
                        .disabled(screen.startBlocker != nil)
                        .help(screen.startBlocker ?? "The microphone stays off until you press this.")
                    }
                    if screen.source == .microphone, screen.phase == .live {
                        Toggle("Mute", isOn: $screen.muted)
                            .toggleStyle(.button)
                            .help(LiveMicrophoneIndicator.muteHelp)
                        LiveLevelMeter(level: screen.level)
                    }
                    LiveMicrophoneIndicator(on: screen.microphoneOn, muted: screen.muted)
                    Spacer(minLength: 0)
                }
                if let blocker = screen.startBlocker, !screen.isOpen {
                    Text(blocker).font(.caption).foregroundStyle(.secondary)
                }
                if let description = screen.sessionDescription {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
                if let progress = screen.fileProgress {
                    ProgressView(value: min(progress.sent, progress.total), total: max(progress.total, 0.1)) {
                        Text("\(LiveClock.text(progress.sent)) of \(LiveClock.text(progress.total)) sent")
                            .font(.caption)
                    }
                    .frame(maxWidth: 360)
                }
                LiveUsageLine(
                    usage: screen.usage,
                    billedBy: "ElevenLabs bills realtime transcription by the length of the audio sent. Nothing reconnects on its own.",
                    showsAudioSent: true
                )
                ForEach(screen.warnings, id: \.self) { warning in
                    Text("ElevenLabs warned: \(warning)").font(.callout).foregroundStyle(.orange)
                }
                if let error = screen.serverError {
                    Text("ElevenLabs reported \(error)").font(.callout).foregroundStyle(.red)
                }
                if let outcome = screen.outcome { LiveOutcomeBanner(outcome: outcome) }
            }
        }
    }

    private var transcript: some View {
        LiveCard("Transcript", subtitle: "Grey text is still being heard; black text is final for its segment.") {
            VStack(alignment: .leading, spacing: 10) {
                if screen.segments.isEmpty, screen.partial.isEmpty {
                    Text(screen.isOpen ? "Listening…" : "Nothing yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(screen.segments) { segment in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let start = segment.start {
                                Text(LiveClock.text(start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text(segment.edited ?? segment.text).textSelection(.enabled)
                            if let language = segment.languageCode {
                                Text(language).font(.caption2).padding(.horizontal, 4)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            }
                        }
                        if segment.edited != nil {
                            Text("As said: \(segment.text)").font(.caption).foregroundStyle(.secondary)
                        }
                        if !segment.entities.isEmpty {
                            Text(segment.entities.map { "\($0.type): \($0.text)" }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.purple)
                        }
                    }
                }
                if !screen.partial.isEmpty {
                    Text(screen.partial).foregroundStyle(.secondary).italic()
                }
                if !screen.segments.isEmpty, !screen.isOpen {
                    HStack(spacing: 10) {
                        Button("Save as text and JSON") { Task { await screen.export() } }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(screen.fullText, forType: .string)
                        }
                    }
                    ForEach(screen.exported, id: \.self) { LiveSavedFile(url: $0) }
                    if let problem = screen.exportProblem { Text(problem).font(.caption).foregroundStyle(.red) }
                }
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { screen.file = panel.url }
    }
}

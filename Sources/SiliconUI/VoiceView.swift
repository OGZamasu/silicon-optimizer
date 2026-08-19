import AVFoundation
import SiliconCatalog
import SiliconRuntime
import SwiftUI
import UniformTypeIdentifiers

/// Plays one audio file at a time — the tiny state machine behind every play button.
@MainActor @Observable
final class AudioPreview {
    static let shared = AudioPreview()

    private var player: AVAudioPlayer?
    private(set) var playingPath: String?

    func toggle(_ url: URL) {
        if playingPath == url.path {
            stop()
            return
        }
        stop()
        guard let fresh = try? AVAudioPlayer(contentsOf: url) else { return }
        player = fresh
        playingPath = url.path
        fresh.play()
        Task { [weak self] in
            while let player = self?.player, player.isPlaying {
                try? await Task.sleep(for: .milliseconds(300))
            }
            if self?.player?.isPlaying != true {
                self?.playingPath = nil
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingPath = nil
    }
}

/// The Voice tab: text in, speech out — and the reverse. Same promise as every other
/// tab: what runs is stated plainly, and the result is a real file.
struct VoiceView: View {
    @Environment(AppModel.self) private var model
    @State private var preview = AudioPreview.shared
    @State private var recentAudio: [URL] = []
    @State private var showsRecents = false

    var body: some View {
        @Bindable var model = model
        GeometryReader { proxy in
            ScrollView {
                if proxy.size.width >= 900 {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            speakCard
                            transcribeCard
                        }
                        .frame(width: 400)
                        VStack(spacing: 16) {
                            resultsCard
                            recentsPane
                        }
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 16) {
                        speakCard
                        resultsCard
                        transcribeCard
                        recentsPane
                    }
                    .padding(20)
                }
            }
        }
        .background(.background)
        .navigationTitle("Voice")
        .task { refreshRecents() }
        .onChange(of: model.speechResults.count) { refreshRecents() }
    }

    private var selectedEntry: VoiceEntry? {
        VoiceCatalog.entry(id: model.selectedVoiceModel)
    }

    // MARK: - Speak

    private var speakCard: some View {
        @Bindable var model = model
        return Card(title: "Speak", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Model", selection: $model.selectedVoiceModel) {
                    ForEach(VoiceCatalog.speakers) { entry in
                        Text(entry.name).tag(entry.id)
                    }
                }

                if let entry = selectedEntry {
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    installRow(for: entry)

                    TextEditor(text: $model.voiceText)
                        .font(.body)
                        .frame(minHeight: 90)
                        .padding(6)
                        .background(.background.secondary, in: .rect(cornerRadius: 7))
                        .overlay(alignment: .topLeading) {
                            if model.voiceText.isEmpty {
                                Text("What should it say?")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 12)
                                    .padding(.leading, 11)
                                    .allowsHitTesting(false)
                            }
                        }

                    if !entry.voices.isEmpty {
                        Picker("Voice", selection: $model.selectedPresetVoice) {
                            ForEach(entry.voices, id: \.self) { voice in
                                Text(Self.voiceLabel(voice)).tag(voice)
                            }
                        }
                    }

                    if entry.supportsCloning {
                        referenceRow(required: entry.requiresReference)
                    }

                    if let error = model.voiceError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button {
                            model.speak()
                        } label: {
                            Label("Speak it", systemImage: "play.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.isSpeaking
                            || model.voiceText.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                            || !model.voiceInstallation(for: entry).isInstalled
                            || (entry.requiresReference && model.voiceReferenceAudio == nil)
                        )

                        if model.isSpeaking {
                            ProgressView().controlSize(.small)
                            Text(model.voiceStage ?? "Working")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Cancel") { model.cancelVoice() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    /// Preset voice codes read like radio call signs; people deserve names.
    static func voiceLabel(_ code: String) -> String {
        let names: [String: String] = [
            "af_heart": "Heart (American)", "af_bella": "Bella (American)",
            "af_nicole": "Nicole (American)", "af_sky": "Sky (American)",
            "am_adam": "Adam (American)", "am_michael": "Michael (American)",
            "bf_emma": "Emma (British)", "bm_george": "George (British)",
        ]
        return names[code] ?? code
    }

    @ViewBuilder
    private func installRow(for entry: VoiceEntry) -> some View {
        let installation = model.voiceInstallation(for: entry)
        if !installation.isInstalled {
            if let job = model.repairs[repairID(for: entry)] {
                HStack(spacing: 8) {
                    if job.error == nil { ProgressView().controlSize(.small) }
                    Text(job.error ?? job.stage)
                        .font(.caption)
                        .foregroundStyle(job.error == nil ? .secondary : Color.orange)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            } else {
                HStack(spacing: 10) {
                    Text(installation.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(entry.backend == .luxTTS ? "Install LuxTTS" : "Install voice tools") {
                        if entry.backend == .luxTTS {
                            model.installLuxTTS()
                        } else {
                            model.installVoiceTools()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func repairID(for entry: VoiceEntry) -> String {
        entry.backend == .luxTTS ? "luxtts-install" : "voice-install"
    }

    private func referenceRow(required: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.wave.2")
                .foregroundStyle(.secondary)
            if let reference = model.voiceReferenceAudio {
                Text(reference.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    model.voiceReferenceAudio = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
            } else {
                Text(required
                    ? "Add 3+ seconds of the voice to clone"
                    : "Optional: a recording to clone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Choose audio…") {
                    if let url = Self.pickAudio() {
                        model.voiceReferenceAudio = url
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer()
        }
    }

    static func pickAudio() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Results

    private var resultsCard: some View {
        Card(title: "Results", systemImage: "speaker.wave.2") {
            if model.speechResults.isEmpty {
                EmptyStateView(
                    systemImage: "waveform",
                    title: "Nothing spoken yet",
                    message: "Type something and hit Speak it. The audio lands here, and "
                        + "on disk as a WAV you can drop anywhere."
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(model.speechResults) { result in
                        audioRow(
                            url: result.audio,
                            title: result.audio.lastPathComponent,
                            subtitle: "\(result.modelName) · "
                                + String(format: "%.1f s", result.elapsed)
                        )
                    }
                }
            }
        }
    }

    private func audioRow(url: URL, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Button {
                preview.toggle(url)
            } label: {
                Image(systemName: preview.playingPath == url.path
                    ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")

            Button {
                if let entry = VoiceCatalog.entry(id: model.selectedVoiceModel),
                   entry.supportsCloning {
                    model.voiceReferenceAudio = url
                }
            } label: {
                Image(systemName: "person.wave.2")
            }
            .buttonStyle(.borderless)
            .help("Use this as the voice to clone")
        }
        .padding(8)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }

    // MARK: - Transcribe

    private var transcribeCard: some View {
        @Bindable var model = model
        return Card(title: "Transcribe", systemImage: "text.quote") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Model", selection: $model.selectedTranscriber) {
                    ForEach(VoiceCatalog.transcribers) { entry in
                        Text(entry.name).tag(entry.id)
                    }
                }

                if let entry = VoiceCatalog.entry(id: model.selectedTranscriber) {
                    installRow(for: entry)

                    HStack(spacing: 10) {
                        Button {
                            if let url = Self.pickAudio() {
                                model.transcribe(url)
                            }
                        } label: {
                            Label("Choose a recording…", systemImage: "waveform.badge.magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            model.isTranscribing
                            || !model.voiceInstallation(for: entry).isInstalled
                        )
                        if model.isTranscribing {
                            ProgressView().controlSize(.small)
                            Text("Listening…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(model.transcriptions) { transcription in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(transcription.source.lastPathComponent)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    transcription.text, forType: .string
                                )
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy the transcript")
                        }
                        Text(transcription.text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(.background.secondary, in: .rect(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Recents

    private var recentsPane: some View {
        RecentsPane(
            title: "Recent audio",
            systemImage: "clock",
            items: recentAudio.map { AudioFile(url: $0) },
            isExpanded: $showsRecents
        ) { item in
            VStack(spacing: 4) {
                Image(systemName: preview.playingPath == item.url.path
                    ? "stop.circle.fill" : "play.circle")
                    .font(.title2)
                    .frame(width: 96, height: 60)
                    .background(.background.secondary)
                    .clipShape(.rect(cornerRadius: 8))
                Text(item.url.lastPathComponent
                    .replacingOccurrences(of: "silicon-voice-", with: ""))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 96)
            }
        } onSelect: { item in
            preview.toggle(item.url)
        }
    }

    private struct AudioFile: Identifiable {
        var id: String { url.path }
        var url: URL
    }

    private func refreshRecents() {
        let directory = model.settings.resolvedVoiceOutputDirectory
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        recentAudio = contents
            .filter { ["wav", "flac", "mp3"].contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return dateA > dateB
            }
            .prefix(60)
            .map { $0 }
    }
}

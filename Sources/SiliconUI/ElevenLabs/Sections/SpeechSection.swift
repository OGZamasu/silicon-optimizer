import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Text to speech: a script, a voice, a model and its settings, played as it streams or when
/// it is done, with word timings when asked for.
struct SpeechSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SpeechScreen(screen: CreativeSession.shared(for: model).speech)
    }
}

/// What the Speech screen holds and sends. All of its logic, so it is tested without SwiftUI.
@MainActor
@Observable
final class SpeechScreenModel: CreativeScreenModel {

    /// Whole file once it is done, or played as it arrives.
    enum Delivery: String, CaseIterable, Identifiable {
        case whole
        case stream

        var id: String { rawValue }
        var title: String {
            switch self {
            case .whole: "When it's done"
            case .stream: "As it streams"
            }
        }
    }

    static let full = "text_to_speech_full"
    static let fullWithTimestamps = "text_to_speech_full_with_timestamps"
    static let stream = "text_to_speech_stream"
    static let streamWithTimestamps = "text_to_speech_stream_with_timestamps"
    static let operationIDs = [full, fullWithTimestamps, stream, streamWithTimestamps]

    static let controls: [CreativeControl] = [
        CreativeControl("Voice", operationIDs, "voice_id"),
        CreativeControl("Text", operationIDs, "text"),
        CreativeControl("Model", operationIDs, "model_id"),
        CreativeControl("Output format", operationIDs, "output_format"),
        CreativeControl("Stability", operationIDs, "voice_settings.stability"),
        CreativeControl("Similarity", operationIDs, "voice_settings.similarity_boost"),
        CreativeControl("Style exaggeration", operationIDs, "voice_settings.style"),
        CreativeControl("Speed", operationIDs, "voice_settings.speed"),
        CreativeControl("Speaker boost", operationIDs, "voice_settings.use_speaker_boost"),
        CreativeControl("Language", operationIDs, "language_code"),
        CreativeControl("Seed", operationIDs, "seed"),
        CreativeControl("Text before", operationIDs, "previous_text"),
        CreativeControl("Text after", operationIDs, "next_text"),
        CreativeControl("Continue from the last take", operationIDs, "previous_request_ids"),
        CreativeControl("Lead into a later take", operationIDs, "next_request_ids"),
        CreativeControl("Text normalization", operationIDs, "apply_text_normalization"),
        CreativeControl("Language normalization", operationIDs, "apply_language_text_normalization"),
        CreativeControl("Professional voice as instant", operationIDs, "use_pvc_as_ivc"),
        CreativeControl("History and stitching", operationIDs, "enable_logging"),
        CreativeControl("Latency optimization", operationIDs, "optimize_streaming_latency"),
        CreativeControl("Pronunciation dictionaries", operationIDs,
                        "pronunciation_dictionary_locators[].pronunciation_dictionary_id"),
        CreativeControl("Pronunciation dictionary version", operationIDs,
                        "pronunciation_dictionary_locators[].version_id"),
    ]

    let session: CreativeSession
    var voiceID = ""
    var text = ""
    var modelID: String
    var delivery: Delivery = .whole
    var timestamps = false
    var outputFormat: String
    let settings: CreativeVoiceSettings

    // Advanced
    var languageCode = ""
    var seed: Int?
    var previousText = ""
    var nextText = ""
    /// Sends the last take's request id as `previous_request_ids`, for continuity.
    var continueFromLastTake = false
    /// A later take's request id this one leads into (`next_request_ids`), when regenerating
    /// a clip in the middle of a sequence.
    var nextRequestID = ""
    var textNormalization: String
    var languageNormalization = false
    var usePVCAsIVC = false
    /// Off is zero-retention mode (enterprise only): no history, no stitching.
    var enableLogging = true
    /// `optimize_streaming_latency`, 0…4; nil leaves ElevenLabs' default.
    var latencyOptimization: Int?
    var dictionaries: [CreativeDictionaryLocator] = []

    /// This session's takes, newest first; the first is the one on screen.
    private(set) var takes: [CreativeTake] = []
    /// The words of the newest take, when it was made with timestamps.
    private(set) var words: [CreativeTimedWord] = []
    /// The runner that ran last: its errors, result and "Show API call" are on screen.
    private(set) var lastRunner: ElevenLabsRunner

    @ObservationIgnored private let runners: [String: ElevenLabsRunner]

    init(session: CreativeSession) {
        self.session = session
        modelID = CreativeSpec.defaultString(Self.full, "model_id") ?? ""
        outputFormat = CreativeSpec.defaultString(Self.full, "output_format") ?? ""
        textNormalization = CreativeSpec.defaultString(Self.full, "apply_text_normalization") ?? ""
        settings = CreativeVoiceSettings(
            schemaOperationID: Self.full,
            savedSettings: session.runner("get_voice_settings", records: false)
        )
        var runners: [String: ElevenLabsRunner] = [:]
        for id in Self.operationIDs { runners[id] = session.runner(id, title: "Speech") }
        self.runners = runners
        lastRunner = runners[Self.full]!
    }

    // MARK: - What will be sent

    /// The operation the current choices call.
    var operationID: String {
        switch (delivery, timestamps) {
        case (.whole, false): Self.full
        case (.whole, true): Self.fullWithTimestamps
        case (.stream, false): Self.stream
        case (.stream, true): Self.streamWithTimestamps
        }
    }

    var runner: ElevenLabsRunner { runners[operationID]! }

    /// Play a stream as it arrives, except with word timings: the shell's live collector keeps
    /// a timings stream as its JSON type rather than as audio, so those are collected (the
    /// client names the audio from `output_format`) until the shell's fix lands.
    var streamMode: ElevenLabsRunner.StreamMode { delivery == .stream && !timestamps ? .play : .collect }

    /// The run in flight, or waiting for its confirmation, whichever operation it is: the
    /// pickers that choose the operation can change while it runs, and must not hand the Run
    /// row an idle runner (a second paid run, and a Cancel that no longer reaches the first).
    var busyRunner: ElevenLabsRunner? {
        Self.operationIDs.compactMap { runners[$0] }.first { $0.isRunning || $0.isAwaitingConfirmation }
    }

    /// What the Run row shows: the run in flight, so Cancel reaches it, else the chosen one.
    var activeRunner: ElevenLabsRunner { busyRunner ?? runner }

    /// Said while a run is in flight.
    static let busyProblem = "Wait for the current take to finish, or cancel it."

    /// The formats the current operation takes: the streamed ones take no WAV.
    var outputFormats: [String] { CreativeSpec.choices(operationID, "output_format") }

    /// The chosen format, or the spec's default when the operation does not take it.
    var effectiveOutputFormat: String {
        outputFormats.contains(outputFormat)
            ? outputFormat : (CreativeSpec.defaultString(operationID, "output_format") ?? outputFormat)
    }

    var normalizationChoices: [String] { CreativeSpec.choices(operationID, "apply_text_normalization") }

    var selectedModel: CreativeModel? { session.models.model(id: modelID) }

    /// The most text the chosen model takes in one request, when the models list says.
    var characterLimit: Int? {
        selectedModel.flatMap { $0.maximumTextLengthPerRequest ?? $0.maxCharactersSubscribedUser }
    }

    /// What the text is likely to cost, by the model's rate when known.
    var estimatedCharacters: Int {
        selectedModel?.estimatedCost(characters: text.count) ?? text.count
    }

    /// The request id `continueFromLastTake` sends.
    var lastRequestID: String? { takes.first?.requestID }

    /// Why Generate is not ready, in the order to fix them.
    var problems: [String] {
        var problems: [String] = busyRunner == nil ? [] : [Self.busyProblem]
        if voiceID.isEmpty { problems.append("Choose a voice.") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("Write something to say.") }
        if let limit = characterLimit, text.count > limit {
            problems.append("\(selectedModel?.name ?? modelID) takes up to \(limit.formatted()) characters per request; this is \(text.count.formatted()).")
        }
        if let seed, let range = CreativeSpec.range(operationID, "seed"), !range.contains(Double(seed)) {
            problems.append("The seed must be between \(Int(range.lowerBound)) and \(Int(range.upperBound)).")
        }
        if let latency = latencyOptimization, !(0...4).contains(latency) {
            problems.append("Latency optimization goes from 0 to 4.")
        }
        return problems
    }

    /// The arguments for `operationID`. Optional values left blank are left out, so
    /// ElevenLabs applies its own defaults.
    func arguments() -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            "voice_id": .string(voiceID),
            "text": .string(text),
            "output_format": .string(effectiveOutputFormat),
        ]
        if !modelID.isEmpty { arguments["model_id"] = .string(modelID) }
        if let voiceSettings = settings.json(for: selectedModel) { arguments["voice_settings"] = voiceSettings }
        let language = languageCode.trimmingCharacters(in: .whitespaces)
        if !language.isEmpty { arguments["language_code"] = .string(language) }
        if let seed { arguments["seed"] = .number(Double(seed)) }
        if !previousText.isEmpty { arguments["previous_text"] = .string(previousText) }
        if !nextText.isEmpty { arguments["next_text"] = .string(nextText) }
        if continueFromLastTake, let lastRequestID { arguments["previous_request_ids"] = [.string(lastRequestID)] }
        let next = nextRequestID.trimmingCharacters(in: .whitespaces)
        if !next.isEmpty { arguments["next_request_ids"] = [.string(next)] }
        if !textNormalization.isEmpty, textNormalization != CreativeSpec.defaultString(operationID, "apply_text_normalization") {
            arguments["apply_text_normalization"] = .string(textNormalization)
        }
        if languageNormalization { arguments["apply_language_text_normalization"] = true }
        if usePVCAsIVC { arguments["use_pvc_as_ivc"] = true }
        if !enableLogging { arguments["enable_logging"] = false }
        if let latencyOptimization { arguments["optimize_streaming_latency"] = .number(Double(latencyOptimization)) }
        if !dictionaries.isEmpty { arguments["pronunciation_dictionary_locators"] = .array(dictionaries.map(\.json)) }
        return arguments
    }

    // MARK: - Running

    func generate() async {
        guard busyRunner == nil, problems.isEmpty else { return }
        let runner = runner
        guard CreativeRunGate.isKnown(runner) else { return }
        runner.streamMode = streamMode
        let voiceName = session.voices.voice(id: voiceID)?.name ?? voiceID
        runner.title = "Speech — \(voiceName)"
        lastRunner = runner
        guard let result = await runner.perform(arguments: arguments()) else { return }
        words = CreativeTimeline.words(fromCharacterAlignments: CreativeTimeline.characterAlignments(in: result))
        if let take = CreativeTake(result: result, title: Self.takeTitle(text, voice: voiceName), runner: runner) {
            takes.insert(take, at: 0)
        }
    }

    func removeTake(_ take: CreativeTake) {
        takes.removeAll { $0.id == take.id }
    }

    /// "Rachel: “Welcome to the show…”".
    static func takeTitle(_ text: String, voice: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let excerpt = flat.count > 48 ? String(flat.prefix(47)) + "…" : flat
        return "\(voice): “\(excerpt)”"
    }
}

/// The Speech screen.
struct SpeechScreen: View {
    @Bindable var screen: SpeechScreenModel
    @State private var showsAdvanced = false

    var body: some View {
        ElevenLabsSectionPage(.speech) {
            textCard
            voiceCard
            CreativeVoiceSettingsCard(settings: screen.settings, model: screen.selectedModel, voiceID: screen.voiceID)
            outputCard
            advanced
            CreativeRunRow(
                runner: screen.activeRunner, title: "Generate speech",
                estimatedCharacters: screen.estimatedCharacters, problems: screen.problems,
                note: screen.delivery == .stream && screen.timestamps
                    ? "With word timings the stream is collected, then played when it is done."
                    : screen.delivery == .stream && !CreativeOutputFormat.playsLive(screen.effectiveOutputFormat)
                    ? "\(CreativeOutputFormat.title(screen.effectiveOutputFormat)) is not played as it arrives; the whole answer is kept and plays when it is done."
                    : nil
            ) {
                Task { await screen.generate() }
            }
            result
            CreativeTakesList(takes: Array(screen.takes.dropFirst())) { screen.removeTake($0) }
        }
    }

    private var textCard: some View {
        CreativeCard("Text", systemImage: "text.alignleft") {
            HStack(spacing: 4) {
                Text(screen.text.count.formatted())
                if let limit = screen.characterLimit {
                    Text("/ \(limit.formatted())")
                }
                Text("characters")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle((screen.characterLimit.map { screen.text.count > $0 } ?? false) ? .red : .secondary)
        } content: {
            ElevenLabsTextArea(text: $screen.text, prompt: "What should the voice say?", minHeight: 140)
        }
    }

    private var voiceCard: some View {
        CreativeCard("Voice and model", systemImage: "person.wave.2") {
            ElevenLabsVoicePicker(selection: $screen.voiceID, directory: screen.session.voices)
            CreativeModelPicker(
                title: "Model", selection: $screen.modelID, directory: screen.session.models,
                include: \.canDoTextToSpeech
            )
            if let model = screen.selectedModel, !model.description.isEmpty {
                Text(model.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var outputCard: some View {
        CreativeCard("Output", systemImage: "waveform") {
            CreativeOutputFormatPicker(selection: $screen.outputFormat, choices: screen.outputFormats)
            if screen.effectiveOutputFormat != screen.outputFormat {
                Text("Streaming does not offer \(CreativeOutputFormat.title(screen.outputFormat)); \(CreativeOutputFormat.title(screen.effectiveOutputFormat)) will be used.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Picker("Play", selection: $screen.delivery) {
                ForEach(SpeechScreenModel.Delivery.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(screen.busyRunner != nil)
            Toggle("Word timings", isOn: $screen.timestamps)
                .help("Also get when each character is spoken, to follow along and export subtitles")
                .disabled(screen.busyRunner != nil)
        }
    }

    private var advanced: some View {
        CreativeCard {
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Language") {
                        TextField("Language", text: $screen.languageCode, prompt: Text("Automatic (ISO 639-1, e.g. en)"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(maxWidth: 240)
                    }
                    CreativeOptionalIntegerField(
                        title: "Seed", value: $screen.seed, range: CreativeSpec.range(screen.operationID, "seed")
                    )
                    CreativeChoicePicker(
                        title: "Text normalization", selection: $screen.textNormalization,
                        choices: screen.normalizationChoices
                    )
                    Toggle("Language text normalization (Japanese; slower)", isOn: $screen.languageNormalization)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Continuity").font(.callout)
                        Toggle("Continue from the last take", isOn: $screen.continueFromLastTake)
                            .disabled(screen.lastRequestID == nil)
                            .help("Sends the last take's request id so this one follows on smoothly")
                        TextField("Text before", text: $screen.previousText, prompt: Text("Text that comes before (ignored when continuing from a take)"))
                            .textFieldStyle(.roundedBorder)
                        TextField("Text after", text: $screen.nextText, prompt: Text("Text that comes after"))
                            .textFieldStyle(.roundedBorder)
                        TextField("Next take", text: $screen.nextRequestID, prompt: Text("Request id of a later take this leads into"))
                            .textFieldStyle(.roundedBorder)
                    }
                    CreativeDictionaryPicker(
                        locators: $screen.dictionaries, directory: screen.session.dictionaries,
                        maxItems: 3
                    )
                    Toggle("Use a professional voice's instant version", isOn: $screen.usePVCAsIVC)
                    Toggle("Keep in history (off is zero-retention, enterprise only)", isOn: $screen.enableLogging)
                    Picker("Latency optimization", selection: $screen.latencyOptimization) {
                        Text("Default").tag(Int?.none)
                        ForEach(0...4, id: \.self) { level in Text("\(level)").tag(Int?.some(level)) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var result: some View {
        let runner = screen.lastRunner
        if runner.phase != .idle || screen.takes.first != nil {
            CreativeCard("Result", systemImage: "play.circle") {
                if runner.isRunning, let player = runner.streamPlayer {
                    Label(player.receivedBytes > 0 ? "Streaming…" : "Waiting for the first audio…",
                          systemImage: "dot.radiowaves.left.and.right")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let problem = runner.streamPlayer?.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
                if let take = screen.takes.first {
                    if screen.words.isEmpty {
                        CreativeAudioResult(take: take)
                    } else {
                        CreativeTimedPlayer(url: take.file, words: screen.words, title: take.title, showsSpeakers: false, contentType: take.contentType, outputFormat: take.outputFormat)
                            .id(take.file)
                        subtitleExports
                    }
                    if let meta = runner.result?.meta {
                        ElevenLabsMetaLine(meta: meta)
                    }
                }
                ElevenLabsRunnerOutput(runner: runner, showsResult: false)
            }
        }
    }

    private var subtitleExports: some View {
        let segments = CreativeTimeline.segments(screen.words)
        return HStack(spacing: 8) {
            Text("Export timings:").font(.caption).foregroundStyle(.secondary)
            Button("SRT…") { CreativeExport.save(CreativeTimeline.srt(segments, speakers: false), suggestedName: "speech.srt", type: CreativeExport.srtType) }
            Button("VTT…") { CreativeExport.save(CreativeTimeline.vtt(segments, speakers: false), suggestedName: "speech.vtt", type: CreativeExport.vttType) }
            Button("JSON…") { CreativeExport.save(CreativeTimeline.json(screen.words).jsonString(pretty: true), suggestedName: "speech-timings.json", type: .json) }
        }
        .controlSize(.small)
    }
}

import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI
import UniformTypeIdentifiers

/// Speech to speech: a recording said again in another voice, keeping its timing and
/// delivery.
struct VoiceChangerSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VoiceChangerScreen(screen: CreativeSession.shared(for: model).voiceChanger)
    }
}

@MainActor
@Observable
final class VoiceChangerScreenModel: CreativeScreenModel {

    static let full = "speech_to_speech_full"
    static let stream = "speech_to_speech_stream"
    static let operationIDs = [full, stream]

    static let controls: [CreativeControl] = [
        CreativeControl("Recording", operationIDs, "audio"),
        CreativeControl("Target voice", operationIDs, "voice_id"),
        CreativeControl("Model", operationIDs, "model_id"),
        CreativeControl("Output format", operationIDs, "output_format"),
        CreativeControl("Remove background noise", operationIDs, "remove_background_noise"),
        CreativeControl("Voice settings (sent as JSON text)", operationIDs, "voice_settings"),
        // The sliders' ranges and defaults are the text-to-speech `voice_settings` schema's:
        // the speech-to-speech field is the same object, sent as a JSON string.
        CreativeControl("Stability", [SpeechScreenModel.full], "voice_settings.stability"),
        CreativeControl("Similarity", [SpeechScreenModel.full], "voice_settings.similarity_boost"),
        CreativeControl("Style exaggeration", [SpeechScreenModel.full], "voice_settings.style"),
        CreativeControl("Speed", [SpeechScreenModel.full], "voice_settings.speed"),
        CreativeControl("Speaker boost", [SpeechScreenModel.full], "voice_settings.use_speaker_boost"),
        CreativeControl("Input is raw 16 kHz PCM", operationIDs, "file_format"),
        CreativeControl("Seed", operationIDs, "seed"),
        CreativeControl("History and stitching", operationIDs, "enable_logging"),
        CreativeControl("Latency optimization", operationIDs, "optimize_streaming_latency"),
    ]

    let session: CreativeSession
    var source: URL?
    var voiceID = ""
    var modelID: String
    var outputFormat: String
    var delivery: SpeechScreenModel.Delivery = .whole
    var removeBackgroundNoise = false
    /// The input is 16-bit, 16 kHz, mono little-endian PCM (`file_format: pcm_s16le_16`).
    var rawPCMInput = false
    let settings: CreativeVoiceSettings
    var seed: Int?
    var enableLogging = true
    var latencyOptimization: Int?

    private(set) var takes: [CreativeTake] = []
    /// The recording each take was made from, by take.
    private(set) var sources: [CreativeTake.ID: URL] = [:]
    private(set) var lastRunner: ElevenLabsRunner
    @ObservationIgnored private let runners: [String: ElevenLabsRunner]

    init(session: CreativeSession) {
        self.session = session
        modelID = CreativeSpec.defaultString(Self.full, "model_id") ?? ""
        outputFormat = CreativeSpec.defaultString(Self.full, "output_format") ?? ""
        settings = CreativeVoiceSettings(
            schemaOperationID: SpeechScreenModel.full,
            savedSettings: session.runner("get_voice_settings", records: false)
        )
        var runners: [String: ElevenLabsRunner] = [:]
        for id in Self.operationIDs { runners[id] = session.runner(id, title: "Voice changer") }
        self.runners = runners
        lastRunner = runners[Self.full]!
    }

    var operationID: String { delivery == .stream ? Self.stream : Self.full }
    var runner: ElevenLabsRunner { runners[operationID]! }
    var outputFormats: [String] { CreativeSpec.choices(operationID, "output_format") }
    var effectiveOutputFormat: String {
        outputFormats.contains(outputFormat)
            ? outputFormat : (CreativeSpec.defaultString(operationID, "output_format") ?? outputFormat)
    }
    var selectedModel: CreativeModel? { session.models.model(id: modelID) }

    /// The `file_format` value for raw PCM input, from the spec's enum.
    var pcmFormatValue: String? {
        CreativeSpec.choices(operationID, "file_format").first { $0.hasPrefix("pcm") }
    }

    var problems: [String] {
        var problems: [String] = []
        if source == nil { problems.append("Choose a recording to change.") }
        if voiceID.isEmpty { problems.append("Choose the voice to change it into.") }
        if let seed, let range = CreativeSpec.range(operationID, "seed"), !range.contains(Double(seed)) {
            problems.append("The seed must be between \(Int(range.lowerBound)) and \(Int(range.upperBound)).")
        }
        return problems
    }

    func arguments() -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            "voice_id": .string(voiceID),
            "output_format": .string(effectiveOutputFormat),
        ]
        if !modelID.isEmpty { arguments["model_id"] = .string(modelID) }
        if removeBackgroundNoise { arguments["remove_background_noise"] = true }
        if rawPCMInput, let pcm = pcmFormatValue { arguments["file_format"] = .string(pcm) }
        // A JSON-encoded string in this multipart form, as the spec's description asks.
        if let voiceSettings = settings.json(for: selectedModel) {
            arguments["voice_settings"] = .string(voiceSettings.jsonString())
        }
        if let seed { arguments["seed"] = .number(Double(seed)) }
        if !enableLogging { arguments["enable_logging"] = false }
        if let latencyOptimization { arguments["optimize_streaming_latency"] = .number(Double(latencyOptimization)) }
        return arguments
    }

    func files() -> [String: [ElevenLabsFile]] {
        source.map { ["audio": [ElevenLabsFile(url: $0)]] } ?? [:]
    }

    func generate() async {
        guard problems.isEmpty else { return }
        let runner = runner
        guard CreativeRunGate.isKnown(runner) else { return }
        runner.streamMode = delivery == .stream ? .play : .collect
        lastRunner = runner
        guard let result = await runner.perform(arguments: arguments(), files: files()) else { return }
        let voiceName = session.voices.voice(id: voiceID)?.name ?? voiceID
        if let take = CreativeTake(result: result, title: "\(source?.lastPathComponent ?? "Recording") as \(voiceName)") {
            takes.insert(take, at: 0)
            sources[take.id] = source
        }
    }

    func removeTake(_ take: CreativeTake) {
        takes.removeAll { $0.id == take.id }
        sources[take.id] = nil
    }
}

struct VoiceChangerScreen: View {
    @Bindable var screen: VoiceChangerScreenModel
    @State private var showsAdvanced = false

    var body: some View {
        ElevenLabsSectionPage(.voiceChanger) {
            CreativeCard("Recording", systemImage: "waveform") {
                CreativeFileField(title: "Speech to change", url: $screen.source)
                Toggle("Remove background noise first", isOn: $screen.removeBackgroundNoise)
            }
            CreativeCard("Into", systemImage: "person.wave.2") {
                ElevenLabsVoicePicker(selection: $screen.voiceID, title: "Voice", directory: screen.session.voices)
                CreativeModelPicker(
                    title: "Model", selection: $screen.modelID, directory: screen.session.models,
                    include: \.canDoVoiceConversion
                )
                CreativeOutputFormatPicker(selection: $screen.outputFormat, choices: screen.outputFormats)
                Picker("Play", selection: $screen.delivery) {
                    ForEach(SpeechScreenModel.Delivery.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            CreativeVoiceSettingsCard(settings: screen.settings, model: screen.selectedModel, voiceID: screen.voiceID)
            CreativeCard {
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("The recording is raw 16-bit, 16 kHz mono PCM (lower latency)", isOn: $screen.rawPCMInput)
                            .disabled(screen.pcmFormatValue == nil)
                        CreativeOptionalIntegerField(title: "Seed", value: $screen.seed, range: CreativeSpec.range(screen.operationID, "seed"))
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
            CreativeRunRow(
                runner: screen.runner, title: "Change the voice", problems: screen.problems,
                note: screen.source.flatMap(CreativeMedia.duration(of:)).map {
                    "Billed by the recording's length: \(ElevenLabsAudioPlayerView.clock($0))."
                }
            ) {
                Task { await screen.generate() }
            }
            result
            CreativeTakesList(takes: Array(screen.takes.dropFirst())) { screen.removeTake($0) }
        }
    }

    @ViewBuilder
    private var result: some View {
        let runner = screen.lastRunner
        if runner.phase != .idle || screen.takes.first != nil {
            CreativeCard("Before and after", systemImage: "arrow.left.arrow.right") {
                if let take = screen.takes.first {
                    if let original = screen.sources[take.id] {
                        ElevenLabsAudioPlayerView(url: original, title: "Before — \(original.lastPathComponent)").id(original)
                    }
                    ElevenLabsAudioPlayerView(url: take.file, title: "After — \(take.title)").id(take.file)
                    if let meta = runner.result?.meta { ElevenLabsMetaLine(meta: meta) }
                }
                ElevenLabsRunnerOutput(runner: runner, showsResult: false)
            }
        }
    }
}

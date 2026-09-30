import AppKit
import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI
import UniformTypeIdentifiers

/// Speech to text (Scribe): a file or a link transcribed, with speakers, key terms, entities
/// and subtitle exports, and this session's transcripts to reopen or delete.
struct TranscriptionSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TranscriptionScreen(screen: CreativeSession.shared(for: model).transcription)
    }
}

/// A transcript this session made or opened.
struct TranscriptRecord: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var date: Date
    /// Sent to a webhook: ElevenLabs is still working on it, or it has not been fetched.
    var pending: Bool
}

/// An export ElevenLabs made alongside the transcript (`additional_formats`).
struct TranscriptExport: Identifiable, Hashable, Sendable {
    var id: String { format }
    var format: String
    var fileExtension: String
    var contentType: String
    var data: Data

    init?(json: JSONValue) {
        guard let format = json["requested_format"].stringValue, let content = json["content"].stringValue else { return nil }
        self.format = format
        fileExtension = json["file_extension"].stringValue ?? format
        contentType = json["content_type"].stringValue ?? "application/octet-stream"
        if json["is_base64_encoded"].boolValue == true {
            guard let decoded = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { return nil }
            data = decoded
        } else {
            data = Data(content.utf8)
        }
    }
}

/// An entity the transcript found (a name, a card number…).
struct TranscriptEntity: Hashable, Sendable {
    var text: String
    var type: String
    var start: Int
    var end: Int
}

@MainActor
@Observable
final class TranscriptionScreenModel: CreativeScreenModel {

    enum SourceKind: String, CaseIterable, Identifiable {
        case file
        case link

        var id: String { rawValue }
        var title: String { self == .file ? "A file" : "A link" }
    }

    static let convert = "speech_to_text"
    static let get = "get_transcript_by_id"
    static let delete = "delete_transcript_by_id"
    static let operationIDs = [convert, get, delete]

    static let controls: [CreativeControl] = [
        CreativeControl("File", [convert], "file"),
        CreativeControl("Link", [convert], "source_url"),
        CreativeControl("Model", [convert], "model_id"),
        CreativeControl("Language", [convert], "language_code"),
        CreativeControl("Tag sounds", [convert], "tag_audio_events"),
        CreativeControl("Timestamps", [convert], "timestamps_granularity"),
        CreativeControl("Who is speaking", [convert], "diarize"),
        CreativeControl("Most speakers", [convert], "num_speakers"),
        CreativeControl("Diarization threshold", [convert], "diarization_threshold"),
        CreativeControl("Speaker roles", [convert], "detect_speaker_roles"),
        CreativeControl("Speaker library", [convert], "use_speaker_library"),
        CreativeControl("Key terms", [convert], "keyterms"),
        CreativeControl("Detect entities", [convert], "entity_detection"),
        CreativeControl("Redact entities", [convert], "entity_redaction"),
        CreativeControl("Redaction style", [convert], "entity_redaction_mode"),
        CreativeControl("Exports", [convert], "additional_formats[].format"),
        CreativeControl("One speaker per channel", [convert], "use_multi_channel"),
        CreativeControl("Channel output", [convert], "multichannel_output_style"),
        CreativeControl("Temperature", [convert], "temperature"),
        CreativeControl("Seed", [convert], "seed"),
        CreativeControl("No filler words", [convert], "no_verbatim"),
        CreativeControl("Input is raw 16 kHz PCM", [convert], "file_format"),
        CreativeControl("Edit instruction", [convert], "transcript_edit"),
        CreativeControl("Send to a webhook", [convert], "webhook"),
        CreativeControl("Webhook", [convert], "webhook_id"),
        CreativeControl("Webhook metadata", [convert], "webhook_metadata"),
        CreativeControl("History", [convert], "enable_logging"),
        CreativeControl("Open a transcript", [get], "transcription_id"),
        CreativeControl("Delete a transcript", [delete], "transcription_id"),
    ]

    let session: CreativeSession
    let runner: ElevenLabsRunner
    let getRunner: ElevenLabsRunner
    let deleteRunner: ElevenLabsRunner

    var sourceKind: SourceKind = .file
    var source: URL?
    var sourceLink = ""
    var modelID: String
    var languageCode = ""
    var tagAudioEvents: Bool
    var timestampsGranularity: String
    var diarize = false
    var numSpeakers: Int?
    var usesDiarizationThreshold = false
    var diarizationThreshold: Double
    var detectSpeakerRoles = false
    var useSpeakerLibrary = false
    var keyterms: [String] = []
    var entityDetection: Set<String> = []
    var entityRedaction: Set<String> = []
    var entityRedactionMode: String
    var additionalFormats: Set<String> = []
    var useMultiChannel = false
    var multichannelOutputStyle: String
    var usesTemperature = false
    var temperature: Double = 0
    var seed: Int?
    var noVerbatim = false
    var rawPCMInput = false
    var transcriptEdit = ""
    var sendsToWebhook = false
    var webhookID = ""
    var webhookMetadata = ""
    var enableLogging = true

    /// The transcript on screen.
    private(set) var transcript: JSONValue?
    private(set) var words: [CreativeTimedWord] = []
    private(set) var entities: [TranscriptEntity] = []
    private(set) var exports: [TranscriptExport] = []
    /// The audio the transcript on screen came from, when it is a local file.
    private(set) var transcriptAudio: URL?
    private(set) var transcriptTitle = ""
    /// This session's transcripts, newest first.
    private(set) var records: [TranscriptRecord] = []
    var lookupID = ""

    init(session: CreativeSession) {
        self.session = session
        runner = session.runner(Self.convert, title: "Transcription")
        getRunner = session.runner(Self.get, records: false)
        deleteRunner = session.runner(Self.delete, records: false)
        modelID = CreativeSpec.defaultString(Self.convert, "model_id")
            ?? CreativeSpec.examples(Self.convert, "model_id").first ?? ""
        tagAudioEvents = CreativeSpec.defaultBool(Self.convert, "tag_audio_events") ?? true
        timestampsGranularity = CreativeSpec.defaultString(Self.convert, "timestamps_granularity") ?? ""
        entityRedactionMode = CreativeSpec.defaultString(Self.convert, "entity_redaction_mode") ?? ""
        multichannelOutputStyle = CreativeSpec.defaultString(Self.convert, "multichannel_output_style") ?? ""
        let threshold = CreativeSpec.range(Self.convert, "diarization_threshold") ?? 0.1...0.4
        diarizationThreshold = (threshold.lowerBound + threshold.upperBound) / 2
    }

    // MARK: - From the catalog

    var modelSuggestions: [String] { CreativeSpec.examples(Self.convert, "model_id") }
    var granularities: [String] { CreativeSpec.choices(Self.convert, "timestamps_granularity") }
    var entityCategories: [String] { CreativeSpec.documented(Self.convert, "entity_detection") }
    var redactionModes: [String] { CreativeSpec.documented(Self.convert, "entity_redaction_mode") }
    var exportFormats: [String] { CreativeSpec.variantTags(Self.convert, "additional_formats[]", tag: "format") }
    var channelStyles: [String] { CreativeSpec.choices(Self.convert, "multichannel_output_style") }
    var thresholdRange: ClosedRange<Double> { CreativeSpec.range(Self.convert, "diarization_threshold") ?? 0.1...0.4 }
    var temperatureRange: ClosedRange<Double> { CreativeSpec.range(Self.convert, "temperature") ?? 0...2 }
    var speakerRange: ClosedRange<Double> { CreativeSpec.range(Self.convert, "num_speakers") ?? 1...32 }
    var pcmFormatValue: String? { CreativeSpec.choices(Self.convert, "file_format").first { $0.hasPrefix("pcm") } }
    var editLimit: Int { CreativeSpec.maxLength(Self.convert, "transcript_edit") ?? 2000 }
    var keytermLimit: Int? { CreativeSpec.maxItems(Self.convert, "keyterms") }

    // MARK: - What will be sent

    /// The rules the argument descriptions state, checked before anything is sent.
    var problems: [String] {
        var problems: [String] = []
        switch sourceKind {
        case .file where source == nil: problems.append("Choose a file to transcribe.")
        case .link where !Self.isHTTPS(sourceLink): problems.append("Paste an https link to the audio or video.")
        default: break
        }
        if modelID.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Choose a model.") }
        if detectSpeakerRoles, !diarize { problems.append("Speaker roles need “Who is speaking” on.") }
        if detectSpeakerRoles, useMultiChannel { problems.append("Speaker roles cannot be used with one speaker per channel.") }
        if !entityRedaction.isEmpty, !entityRedaction.isSubset(of: entityDetection) {
            problems.append("Only detected entities can be redacted: detect every category you redact.")
        }
        let edit = transcriptEdit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !edit.isEmpty, !entityDetection.isEmpty || !entityRedaction.isEmpty || useMultiChannel {
            problems.append("An edit instruction cannot be combined with entities or one speaker per channel.")
        }
        if transcriptEdit.count > editLimit { problems.append("The edit instruction takes at most \(editLimit.formatted()) characters.") }
        if let numSpeakers, !speakerRange.contains(Double(numSpeakers)) {
            problems.append("Most speakers must be between \(Int(speakerRange.lowerBound)) and \(Int(speakerRange.upperBound)).")
        }
        if !webhookMetadata.isEmpty, (try? JSONValue(data: Data(webhookMetadata.utf8)))?.objectValue == nil {
            problems.append("Webhook metadata must be a JSON object.")
        }
        if let seed, let range = CreativeSpec.range(Self.convert, "seed"), !range.contains(Double(seed)) {
            problems.append("The seed must be between \(Int(range.lowerBound)) and \(Int(range.upperBound)).")
        }
        return problems
    }

    static func isHTTPS(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)) else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
    }

    func arguments() -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["model_id": .string(modelID.trimmingCharacters(in: .whitespaces))]
        if sourceKind == .link { arguments["source_url"] = .string(sourceLink.trimmingCharacters(in: .whitespaces)) }
        let language = languageCode.trimmingCharacters(in: .whitespaces)
        if !language.isEmpty { arguments["language_code"] = .string(language) }
        if tagAudioEvents != (CreativeSpec.defaultBool(Self.convert, "tag_audio_events") ?? true) {
            arguments["tag_audio_events"] = .bool(tagAudioEvents)
        }
        if !timestampsGranularity.isEmpty, timestampsGranularity != CreativeSpec.defaultString(Self.convert, "timestamps_granularity") {
            arguments["timestamps_granularity"] = .string(timestampsGranularity)
        }
        if diarize {
            arguments["diarize"] = true
            if let numSpeakers { arguments["num_speakers"] = .number(Double(numSpeakers)) }
            // The threshold only applies when the number of speakers is left open.
            if usesDiarizationThreshold, numSpeakers == nil {
                arguments["diarization_threshold"] = .number(CreativeVoiceSettings.rounded(diarizationThreshold))
            }
            if detectSpeakerRoles { arguments["detect_speaker_roles"] = true }
            if useSpeakerLibrary { arguments["use_speaker_library"] = true }
        } else if let numSpeakers {
            arguments["num_speakers"] = .number(Double(numSpeakers))
        }
        if !keyterms.isEmpty { arguments["keyterms"] = .array(keyterms.map(JSONValue.string)) }
        if let detection = Self.entitySelection(entityDetection) { arguments["entity_detection"] = detection }
        if let redaction = Self.entitySelection(entityRedaction) {
            arguments["entity_redaction"] = redaction
            if !entityRedactionMode.isEmpty, entityRedactionMode != CreativeSpec.defaultString(Self.convert, "entity_redaction_mode") {
                arguments["entity_redaction_mode"] = .string(entityRedactionMode)
            }
        }
        if !additionalFormats.isEmpty {
            arguments["additional_formats"] = .array(exportFormats.filter(additionalFormats.contains).map { ["format": .string($0)] })
        }
        if useMultiChannel {
            arguments["use_multi_channel"] = true
            if !multichannelOutputStyle.isEmpty, multichannelOutputStyle != CreativeSpec.defaultString(Self.convert, "multichannel_output_style") {
                arguments["multichannel_output_style"] = .string(multichannelOutputStyle)
            }
        }
        if usesTemperature { arguments["temperature"] = .number(CreativeVoiceSettings.rounded(temperature)) }
        if let seed { arguments["seed"] = .number(Double(seed)) }
        if noVerbatim { arguments["no_verbatim"] = true }
        if rawPCMInput, sourceKind == .file, let pcm = pcmFormatValue { arguments["file_format"] = .string(pcm) }
        let edit = transcriptEdit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !edit.isEmpty { arguments["transcript_edit"] = .string(edit) }
        if sendsToWebhook {
            arguments["webhook"] = true
            let id = webhookID.trimmingCharacters(in: .whitespaces)
            if !id.isEmpty { arguments["webhook_id"] = .string(id) }
            // Sent as a JSON string, as the description asks.
            if !webhookMetadata.isEmpty { arguments["webhook_metadata"] = .string(webhookMetadata) }
        }
        if !enableLogging { arguments["enable_logging"] = false }
        return arguments
    }

    // MARK: - What it costs

    /// A surcharge the spec states on the base transcription cost, with its words.
    struct Surcharge: Sendable {
        var argument: String
        var label: String
        var percent: Int
        var evidence: String
    }

    /// The spec's surcharges, in the order the note lists them.
    static let surcharges: [Surcharge] = [
        Surcharge(argument: "keyterms", label: "key terms", percent: 20,
                  evidence: "Usage of this parameter will incur an additional 20% surcharge on the base transcription cost."),
        Surcharge(argument: "detect_speaker_roles", label: "speaker roles", percent: 10,
                  evidence: "Usage incurs an additional 10% surcharge on base transcription cost."),
        Surcharge(argument: "entity_detection", label: "entity detection", percent: 30,
                  evidence: "Usage of this parameter will incur an additional 30% surcharge on the base transcription cost."),
        Surcharge(argument: "entity_redaction", label: "redaction", percent: 30,
                  evidence: "Usage of this parameter will incur an additional 30% surcharge on the base transcription cost."),
        Surcharge(argument: "transcript_edit", label: "edit instruction", percent: 30,
                  evidence: "Usage of this parameter will incur an additional 30% surcharge on the base transcription cost, billed for at least 10 seconds of audio."),
    ]

    /// Other prices the spec states, with the words that say so: (argument, evidence).
    static let priceRules: [(argument: String, evidence: String)] = [
        ("use_multi_channel", "Each channel is billed independently at the full audio duration"),
        ("use_multi_channel", "A maximum of 5 channels is supported."),
        ("keyterms", "When more than 100 keyterms are provided, a minimum billable duration of 20 seconds applies per request."),
    ]

    /// The most channels the spec supports with one speaker per channel.
    static let maxChannels = 5
    /// Past this many key terms, a request is billed for at least `keytermMinimumSeconds`.
    static let keytermMinimumAbove = 100
    static let keytermMinimumSeconds = 20
    static let editMinimumSeconds = 10

    /// The file's length, when it is a local file whose header says.
    var sourceSeconds: Double? {
        sourceKind == .file ? source.flatMap(CreativeMedia.duration(of:)) : nil
    }

    /// The channels billed: each channel at the full length with one speaker per channel, up to
    /// the spec's maximum; nil when that is not known (a link, or an unreadable file).
    var billedChannels: Int? {
        guard useMultiChannel else { return 1 }
        guard sourceKind == .file, let channels = source.flatMap(CreativeMedia.channelCount(of:)) else { return nil }
        return max(channels, 1)
    }

    /// The audio length billed at the base rate: the file's length, times its channels with
    /// one speaker per channel.
    var billedSeconds: Double? {
        guard let seconds = sourceSeconds, let channels = billedChannels, channels <= Self.maxChannels else { return nil }
        return seconds * Double(channels)
    }

    /// What the choices add to the price, in the spec's terms: one line per rule that applies.
    var costNote: String? {
        var lines: [String] = []
        if useMultiChannel {
            if let channels = billedChannels, channels > Self.maxChannels {
                lines.append("This file has \(channels) channels; files with more than \(Self.maxChannels) are not supported with one speaker per channel.")
            } else if let channels = billedChannels, let seconds = sourceSeconds {
                lines.append("One speaker per channel: each of the \(channels) channels is billed at the full length (\(ElevenLabsAudioPlayerView.clock(seconds)) × \(channels)).")
            } else {
                lines.append("One speaker per channel: each channel (up to \(Self.maxChannels)) is billed at the full length.")
            }
        }
        let sent = arguments()
        var added: [String] = []
        for surcharge in Self.surcharges where sent[surcharge.argument] != nil {
            var piece = "+\(surcharge.percent)% \(surcharge.label)"
            if surcharge.argument == "keyterms", keyterms.count > Self.keytermMinimumAbove {
                piece += " (at least \(Self.keytermMinimumSeconds) s billed with over \(Self.keytermMinimumAbove) terms)"
            }
            if surcharge.argument == "transcript_edit" {
                piece += " (on at least \(Self.editMinimumSeconds) s)"
            }
            added.append(piece)
        }
        if !added.isEmpty {
            lines.append("On the base cost: " + added.joined(separator: ", ") + ".")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// One category as a string, several as a list, "all" alone when chosen.
    static func entitySelection(_ selection: Set<String>) -> JSONValue? {
        guard !selection.isEmpty else { return nil }
        if selection.contains("all") { return "all" }
        let sorted = selection.sorted()
        return sorted.count == 1 ? .string(sorted[0]) : .array(sorted.map(JSONValue.string))
    }

    func files() -> [String: [ElevenLabsFile]] {
        guard sourceKind == .file, let source else { return [:] }
        return ["file": [ElevenLabsFile(url: source)]]
    }

    // MARK: - Running

    func transcribe() async {
        guard problems.isEmpty, CreativeRunGate.isKnown(runner) else { return }
        let title = sourceKind == .file ? (source?.lastPathComponent ?? "Recording") : sourceLink
        let audio = sourceKind == .file ? source : nil
        guard case .json(let value, _)? = await runner.perform(arguments: arguments(), files: files()) else { return }
        if value["words"] == .null, value["transcripts"] == .null {
            // Sent to a webhook: only the id comes back now.
            if let id = value["transcription_id"].stringValue {
                remember(TranscriptRecord(id: id, title: title, date: Date(), pending: true))
            }
            return
        }
        show(value, title: title, audio: audio)
        if let id = value["transcription_id"].stringValue {
            remember(TranscriptRecord(id: id, title: title, date: Date(), pending: false))
        }
    }

    /// Puts a transcript on screen.
    func show(_ value: JSONValue, title: String, audio: URL?) {
        transcript = value
        transcriptTitle = title
        transcriptAudio = audio
        words = CreativeTimeline.words(fromTranscript: value)
        let chunks = value["transcripts"].arrayValue ?? [value]
        entities = chunks.flatMap { chunk in
            (chunk["entities"].arrayValue ?? []).compactMap { entity -> TranscriptEntity? in
                guard let text = entity["text"].stringValue, let type = entity["entity_type"].stringValue else { return nil }
                return TranscriptEntity(text: text, type: type, start: entity["start_char"].intValue ?? 0, end: entity["end_char"].intValue ?? 0)
            }
        }
        exports = chunks.flatMap { ($0["additional_formats"].arrayValue ?? []).compactMap(TranscriptExport.init(json:)) }
    }

    /// The full text, as ElevenLabs wrote it (every channel's, for a multichannel answer).
    var fullText: String {
        guard let transcript else { return "" }
        let chunks = transcript["transcripts"].arrayValue ?? [transcript]
        return chunks.compactMap { $0["text"].stringValue }.joined(separator: "\n\n")
    }

    /// What `transcript_edit` made of the transcript, when one was asked for.
    var editedText: String? {
        guard let edited = transcript?["edited_transcript"], edited != .null else { return nil }
        return edited.stringValue ?? edited["text"].stringValue ?? edited.jsonString(pretty: true)
    }

    var languageLine: String? {
        guard let code = transcript?["language_code"].stringValue else { return nil }
        let probability = transcript?["language_probability"].doubleValue.map { String(format: " (%.0f%% sure)", $0 * 100) } ?? ""
        return (Locale.current.localizedString(forLanguageCode: code) ?? code) + probability
    }

    /// Opens a transcript by id (`GET …/transcripts/{id}`, free).
    func open(_ id: String) async {
        let id = id.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, CreativeRunGate.isKnown(getRunner) else { return }
        guard case .json(let value, _)? = await getRunner.perform(arguments: ["transcription_id": .string(id)]) else { return }
        let title = records.first { $0.id == id }?.title ?? "Transcript \(id.prefix(8))"
        show(value, title: title, audio: nil)
        remember(TranscriptRecord(id: id, title: title, date: records.first { $0.id == id }?.date ?? Date(), pending: false))
    }

    /// Deletes a transcript from ElevenLabs, after the confirmation naming it.
    func delete(_ record: TranscriptRecord) async {
        guard CreativeRunGate.isKnown(deleteRunner) else { return }
        let done = await deleteRunner.perform(
            arguments: ["transcription_id": .string(record.id)],
            subject: "the transcript “\(record.title)”",
            consequence: "ElevenLabs will delete this transcript. This cannot be undone."
        )
        guard done != nil else { return }
        records.removeAll { $0.id == record.id }
        if transcript?["transcription_id"].stringValue == record.id { clear() }
    }

    func clear() {
        transcript = nil
        words = []
        entities = []
        exports = []
        transcriptAudio = nil
        transcriptTitle = ""
    }

    private func remember(_ record: TranscriptRecord) {
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
    }
}

struct TranscriptionScreen: View {
    @Bindable var screen: TranscriptionScreenModel
    @State private var showsAdvanced = false

    var body: some View {
        ElevenLabsSectionPage(.transcription) {
            sourceCard
            speakersCard
            CreativeCard("Key terms and entities", systemImage: "tag") {
                CreativeTagField(title: "Key terms", tags: $screen.keyterms,
                                 prompt: "Names and jargon to listen for — Return to add",
                                 maxItems: screen.keytermLimit)
                entityRow("Detect", selection: $screen.entityDetection)
                entityRow("Redact", selection: $screen.entityRedaction)
                if !screen.entityRedaction.isEmpty, !screen.redactionModes.isEmpty {
                    CreativeChoicePicker(title: "Redaction style", selection: $screen.entityRedactionMode, choices: screen.redactionModes)
                }
                if !screen.entityDetection.isEmpty || !screen.entityRedaction.isEmpty {
                    Text("Detection and redaction each add 30% to the transcription's cost.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            advanced
            CreativeRunRow(
                runner: screen.runner, title: "Transcribe",
                estimatedSeconds: screen.billedSeconds, problems: screen.problems, note: screen.costNote
            ) {
                Task { await screen.transcribe() }
            }
            ElevenLabsRunnerOutput(runner: screen.runner, showsResult: false)
            transcriptCard
            recordsCard
        }
    }

    private var sourceCard: some View {
        CreativeCard("What to transcribe", systemImage: "waveform") {
            Picker("From", selection: $screen.sourceKind) {
                ForEach(TranscriptionScreenModel.SourceKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if screen.sourceKind == .file {
                CreativeFileField(title: "Audio or video", url: $screen.source)
            } else {
                TextField("Link", text: $screen.sourceLink, prompt: Text("https://… — hosted audio or video, YouTube, TikTok…"))
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Model") {
                HStack(spacing: 6) {
                    TextField("Model", text: $screen.modelID).textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 200)
                    if screen.modelSuggestions.count > 1 {
                        Menu("Suggestions") {
                            ForEach(screen.modelSuggestions, id: \.self) { id in Button(id) { screen.modelID = id } }
                        }
                        .fixedSize()
                    }
                }
            }
            LabeledContent("Language") {
                TextField("Language", text: $screen.languageCode, prompt: Text("Detect automatically (ISO 639-1 or -3)"))
                    .textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 280)
            }
            Toggle("Tag sounds like (laughter) and (footsteps)", isOn: $screen.tagAudioEvents)
            CreativeChoicePicker(title: "Timestamps", selection: $screen.timestampsGranularity, choices: screen.granularities)
        }
    }

    private var speakersCard: some View {
        CreativeCard("Speakers", systemImage: "person.2") {
            Toggle("Tell speakers apart", isOn: $screen.diarize)
            Stepper(value: Binding(
                get: { screen.numSpeakers ?? 0 },
                set: { screen.numSpeakers = $0 == 0 ? nil : $0 }
            ), in: 0...Int(screen.speakerRange.upperBound)) {
                Text(screen.numSpeakers.map { "At most \($0) speakers" } ?? "Any number of speakers")
            }
            if screen.diarize {
                Toggle("Set a diarization threshold", isOn: $screen.usesDiarizationThreshold)
                    .disabled(screen.numSpeakers != nil)
                    .help("Only used when the number of speakers is left open")
                if screen.usesDiarizationThreshold, screen.numSpeakers == nil {
                    CreativeSlider(
                        title: "Threshold", value: $screen.diarizationThreshold, range: screen.thresholdRange, step: 0.01,
                        low: "Split more", high: "Merge more"
                    )
                }
                Toggle("Label speakers as agent and customer", isOn: $screen.detectSpeakerRoles)
                Toggle("Match known speakers from the workspace's speaker library", isOn: $screen.useSpeakerLibrary)
            }
            Toggle("One speaker per channel", isOn: $screen.useMultiChannel)
            if screen.useMultiChannel {
                CreativeChoicePicker(title: "Channels", selection: $screen.multichannelOutputStyle, choices: screen.channelStyles)
            }
        }
    }

    private func entityRow(_ title: String, selection: Binding<Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            CreativeFlowLayout {
                ForEach(screen.entityCategories, id: \.self) { category in
                    CreativeChipToggle(
                        title: ["pii", "phi", "pci"].contains(category) ? category.uppercased() : ElevenLabsFormField.humanized(category),
                        isOn: creativeMembership(category, in: selection)
                    )
                }
            }
        }
    }

    private var advanced: some View {
        CreativeCard {
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Also export as").font(.callout)
                        CreativeFlowLayout {
                            ForEach(screen.exportFormats, id: \.self) { format in
                                CreativeChipToggle(
                                    title: format.replacingOccurrences(of: "_", with: " ").uppercased(),
                                    isOn: creativeMembership(format, in: $screen.additionalFormats)
                                )
                            }
                        }
                    }
                    Toggle("Leave out filler words and false starts", isOn: $screen.noVerbatim)
                    Toggle("Set a temperature", isOn: $screen.usesTemperature)
                    if screen.usesTemperature {
                        CreativeSlider(title: "Temperature", value: $screen.temperature, range: screen.temperatureRange, step: 0.05,
                                       low: "Deterministic", high: "Varied")
                    }
                    CreativeOptionalIntegerField(title: "Seed", value: $screen.seed, range: CreativeSpec.range(TranscriptionScreenModel.convert, "seed"))
                    Toggle("The file is raw 16-bit, 16 kHz mono PCM", isOn: $screen.rawPCMInput)
                        .disabled(screen.sourceKind != .file || screen.pcmFormatValue == nil)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Edit the transcript afterwards (+30%, on at least 10 s)").font(.callout)
                        TextField("Edit", text: $screen.transcriptEdit, prompt: Text("e.g. Fix product names and remove profanity"), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                    }
                    Toggle("Send the result to a webhook instead of waiting", isOn: $screen.sendsToWebhook)
                    if screen.sendsToWebhook {
                        TextField("Webhook", text: $screen.webhookID, prompt: Text("Webhook id (all speech-to-text webhooks when empty)"))
                            .textFieldStyle(.roundedBorder)
                        TextField("Metadata", text: $screen.webhookMetadata, prompt: Text(#"Metadata as JSON, e.g. {"job": "42"}"#))
                            .textFieldStyle(.roundedBorder)
                        Text("Webhooks are set up under Workspace → Webhooks.").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Keep in history (off is zero-retention, enterprise only)", isOn: $screen.enableLogging)
                }
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var transcriptCard: some View {
        if screen.transcript != nil {
            CreativeCard(screen.transcriptTitle.isEmpty ? "Transcript" : screen.transcriptTitle, systemImage: "text.quote") {
                Menu("Export") {
                    let segments = CreativeTimeline.segments(screen.words)
                    Button("Text…") { CreativeExport.save(CreativeTimeline.plainText(segments), suggestedName: "transcript.txt", type: .plainText) }
                    Button("SRT subtitles…") { CreativeExport.save(CreativeTimeline.srt(segments), suggestedName: "transcript.srt", type: CreativeExport.srtType) }
                    Button("WebVTT subtitles…") { CreativeExport.save(CreativeTimeline.vtt(segments), suggestedName: "transcript.vtt", type: CreativeExport.vttType) }
                    Button("Words as JSON…") { CreativeExport.save(CreativeTimeline.json(screen.words).jsonString(pretty: true), suggestedName: "transcript-words.json", type: .json) }
                    Button("Full answer as JSON…") { CreativeExport.save((screen.transcript ?? .null).jsonString(pretty: true), suggestedName: "transcript.json", type: .json) }
                    Divider()
                    Button("Copy text") { CreativeExport.copy(screen.fullText) }
                }
                .fixedSize()
            } content: {
                if let language = screen.languageLine {
                    Text("Language: \(language)").font(.caption).foregroundStyle(.secondary)
                }
                if let audio = screen.transcriptAudio, CreativeMedia.isAudio(audio), !screen.words.isEmpty {
                    CreativeTimedPlayer(url: audio, words: screen.words).id(audio)
                } else if !screen.words.isEmpty {
                    CreativeTranscriptView(segments: CreativeTimeline.segments(screen.words))
                } else {
                    Text(screen.fullText).textSelection(.enabled)
                }
                if let edited = screen.editedText {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Edited").font(.caption.weight(.semibold))
                        Text(edited).textSelection(.enabled)
                    }
                }
                if !screen.entities.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Entities").font(.caption.weight(.semibold))
                        CreativeFlowLayout {
                            ForEach(Array(screen.entities.enumerated()), id: \.offset) { _, entity in
                                Text("\(entity.text) · \(ElevenLabsFormField.humanized(entity.type))")
                                    .font(.caption)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.15), in: .capsule)
                            }
                        }
                    }
                }
                if !screen.exports.isEmpty {
                    HStack(spacing: 6) {
                        Text("From ElevenLabs:").font(.caption).foregroundStyle(.secondary)
                        ForEach(screen.exports) { export in
                            Button(export.format.uppercased() + "…") {
                                CreativeExport.save(data: export.data, suggestedName: "transcript.\(export.fileExtension)",
                                                    type: UTType(filenameExtension: export.fileExtension) ?? .data)
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var recordsCard: some View {
        CreativeCard("Transcripts", systemImage: "tray.full") {
            HStack(spacing: 6) {
                TextField("Transcript id", text: $screen.lookupID, prompt: Text("Open a transcript by its id"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await screen.open(screen.lookupID) } }
                Button("Open") { Task { await screen.open(screen.lookupID) } }
                    .disabled(screen.lookupID.trimmingCharacters(in: .whitespaces).isEmpty || screen.getRunner.isRunning)
            }
            if screen.records.isEmpty {
                Text("Transcripts made this session appear here, to reopen or delete. ElevenLabs has no list of past transcripts; keep an id to open one later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(screen.records) { record in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.title).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(record.id).textSelection(.enabled)
                            Text(record.date, style: .time)
                            if record.pending { Text("sent to webhook").foregroundStyle(.orange) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button(record.pending ? "Fetch" : "Open") { Task { await screen.open(record.id) } }
                        .controlSize(.small)
                        .disabled(screen.getRunner.isRunning)
                    Button {
                        Task { await screen.delete(record) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete \(record.title)")
                }
            }
            ElevenLabsRunnerOutput(runner: screen.getRunner, showsResult: false)
            ElevenLabsRunnerOutput(runner: screen.deleteRunner, showsResult: false)
        }
    }
}

extension CreativeExport {
    /// Asks where, then writes bytes there.
    static func save(data: Data, suggestedName: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }
}

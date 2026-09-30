import Foundation
import Observation
import SiliconElevenLabs

/// One voice ElevenLabs designed: its id to save it under, and its audio once there is some.
struct VoiceDesignPreview: Identifiable, Hashable, Sendable {
    var generatedVoiceID: String
    var file: URL?
    var durationSecs: Double?
    var language: String?
    var mediaType: String?
    var id: String { generatedVoiceID }
}

/// Voice design: new voices from a description (or an existing voice remixed by one), three
/// previews to listen to, and the chosen one saved to the account.
@MainActor
@Observable
final class VoiceDesignSectionModel {

    enum Mode: String, CaseIterable, Identifiable {
        case design, remix
        var id: String { rawValue }
        var title: String { self == .design ? "Design from a description" : "Remix one of my voices" }
        var operationID: String { self == .design ? "text_to_voice_design" : "text_to_voice_remix" }
    }

    let actions: VoicesStudioActions
    let directory: ElevenLabsVoiceDirectory

    var mode: Mode = .design
    var voiceDescription = ""
    var text = ""
    var autoGenerateText = true
    var modelID = ""
    var loudness: Double
    var guidanceScale: Double
    var setsQuality = false
    var quality: Double = 0.9
    var seed = ""
    var shouldEnhance = false
    var setsPromptStrength = false
    var promptStrength: Double = 0.5
    var referenceAudio: [URL] = []
    var outputFormat = ""
    var streamPreviews = false
    /// The voice a remix starts from.
    var remixVoiceID = ""

    private(set) var previews: [VoiceDesignPreview] = []
    /// The text ElevenLabs spoke the previews with (its own, when asked to write one).
    private(set) var previewText: String?
    /// The previews listened to, for `played_not_selected_voice_ids`.
    private(set) var played: Set<String> = []
    var chosenPreview: String?
    var saveName = ""
    var saveDescription = ""
    var saveLabels = ""
    /// The voice id of the last one saved.
    private(set) var savedVoiceID: String?
    /// Problems with the inputs, before anything is sent.
    private(set) var problems: [String] = []

    init(environment: VoicesStudioEnvironment) {
        actions = VoicesStudioActions(context: environment.context)
        directory = environment.voices
        loudness = VoicesStudioSchema.defaultNumber("text_to_voice_design", "loudness") ?? 0.5
        guidanceScale = VoicesStudioSchema.defaultNumber("text_to_voice_design", "guidance_scale") ?? 5
    }

    // MARK: Spec

    static let controls: [VoicesStudioControl] = [
        .init("text_to_voice_design", "voice_description"),
        .init("text_to_voice_design", "text"),
        .init("text_to_voice_design", "auto_generate_text"),
        .init("text_to_voice_design", "model_id", enumerated: true),
        .init("text_to_voice_design", "loudness"),
        .init("text_to_voice_design", "guidance_scale"),
        .init("text_to_voice_design", "quality"),
        .init("text_to_voice_design", "seed"),
        .init("text_to_voice_design", "should_enhance"),
        .init("text_to_voice_design", "prompt_strength"),
        .init("text_to_voice_design", "reference_audio_base64"),
        .init("text_to_voice_design", "output_format", enumerated: true),
        .init("text_to_voice_design", "stream_previews"),
        .init("text_to_voice_remix", "voice_id"),
        .init("text_to_voice_remix", "voice_description"),
        .init("text_to_voice_remix", "text"),
        .init("text_to_voice_remix", "auto_generate_text"),
        .init("text_to_voice_remix", "loudness"),
        .init("text_to_voice_remix", "guidance_scale"),
        .init("text_to_voice_remix", "seed"),
        .init("text_to_voice_remix", "prompt_strength"),
        .init("text_to_voice_remix", "output_format", enumerated: true),
        .init("text_to_voice_remix", "stream_previews"),
        .init("text_to_voice_preview_stream", "generated_voice_id"),
        .init("create_voice", "generated_voice_id"),
        .init("create_voice", "voice_name"),
        .init("create_voice", "voice_description"),
        .init("create_voice", "labels"),
        .init("create_voice", "played_not_selected_voice_ids"),
    ]

    static let callsWithoutControls: Set<String> = []

    static let explorerOnly: [String: String] = [
        "text_to_voice": "Deprecated in the spec (create-previews); the section designs with POST /v1/text-to-voice/design.",
    ]

    var operationID: String { mode.operationID }
    var models: [String] { VoicesStudioSchema.choices("text_to_voice_design", "model_id") }
    var outputFormats: [String] { VoicesStudioSchema.choices(operationID, "output_format") }
    var descriptionLimits: (Int?, Int?) {
        (VoicesStudioSchema.minLength(operationID, "voice_description"),
         VoicesStudioSchema.maxLength(operationID, "voice_description"))
    }
    var textLimits: (Int?, Int?) {
        (VoicesStudioSchema.minLength(operationID, "text"), VoicesStudioSchema.maxLength(operationID, "text"))
    }
    static func range(_ operationID: String, _ name: String, fallback: ClosedRange<Double>) -> ClosedRange<Double> {
        VoicesStudioSchema.range(operationID, name) ?? fallback
    }

    /// The prompt strength and reference audio only work with the v3 design model, as the
    /// spec's descriptions say; the remix follows the voice it starts from.
    var supportsReference: Bool { mode == .design && modelID.contains("v3") }


    // MARK: Arguments

    /// The arguments for a design or remix, and every problem with the inputs.
    /// The largest reference recording this screen reads: it goes base64 in the JSON body,
    /// held in memory, so a long file (or a video picked by mistake) is refused before it is read.
    static let referenceLimit = 10 * 1024 * 1024

    /// - Parameter reference: The reference recording, base64, read off the main actor by
    ///   `generate()`; the design leaves it out when nil.
    func arguments(reference: String? = nil) -> (arguments: [String: JSONValue], problems: [String]) {
        var arguments: [String: JSONValue] = [:]
        var problems: [String] = []
        let description = voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let (minimum, maximum) = descriptionLimits
        if let minimum, description.count < minimum {
            problems.append("The description needs at least \(minimum) characters.")
        }
        if let maximum, description.count > maximum {
            problems.append("The description takes at most \(maximum) characters.")
        }
        arguments["voice_description"] = .string(description)
        if autoGenerateText {
            arguments["auto_generate_text"] = true
        } else {
            let (low, high) = textLimits
            if let low, text.count < low { problems.append("The preview text needs at least \(low) characters.") }
            if let high, text.count > high { problems.append("The preview text takes at most \(high) characters.") }
            arguments["text"] = .string(text)
        }
        arguments["loudness"] = .number(loudness)
        arguments["guidance_scale"] = .number(guidanceScale)
        if let value = Int(seed.trimmingCharacters(in: .whitespaces)) { arguments["seed"] = .number(Double(value)) }
        if streamPreviews { arguments["stream_previews"] = true }
        arguments.voicesStudioSet("output_format", VoicesStudioFormat.text(outputFormat))
        switch mode {
        case .design:
            arguments.voicesStudioSet("model_id", VoicesStudioFormat.text(modelID))
            if setsQuality { arguments["quality"] = .number(quality) }
            if shouldEnhance { arguments["should_enhance"] = true }
            if supportsReference {
                if setsPromptStrength { arguments["prompt_strength"] = .number(promptStrength) }
                if let file = referenceAudio.first {
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size > Self.referenceLimit {
                        problems.append("\(file.lastPathComponent) is \(VoicesStudioFormat.bytes(size) ?? "too big"); "
                            + "a reference recording can be at most \(VoicesStudioFormat.bytes(Self.referenceLimit) ?? "10 MB") here.")
                    } else if let reference {
                        arguments["reference_audio_base64"] = .string(reference)
                    }
                }
            }
        case .remix:
            if remixVoiceID.isEmpty { problems.append("Choose the voice to remix.") }
            arguments["voice_id"] = .string(remixVoiceID)
            if setsPromptStrength { arguments["prompt_strength"] = .number(promptStrength) }
        }
        return (arguments, problems)
    }

    /// What `create_voice` sends for the chosen preview.
    func saveArguments() -> [String: JSONValue]? {
        guard let chosen = chosenPreview else { return nil }
        var arguments: [String: JSONValue] = [
            "generated_voice_id": .string(chosen),
            "voice_name": .string(saveName.trimmingCharacters(in: .whitespaces)),
            "voice_description": .string(saveDescription.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        let labels = VoicesSectionModel.labels(from: saveLabels)
        if !labels.isEmpty { arguments["labels"] = .object(labels) }
        let passedOver = played.subtracting([chosen]).sorted()
        if !passedOver.isEmpty { arguments["played_not_selected_voice_ids"] = .array(passedOver.map(JSONValue.string)) }
        return arguments
    }

    /// Previews already saved as voices: saving the same one again would make a second voice.
    private(set) var savedPreviews: Set<String> = []

    var canSave: Bool {
        guard let chosen = chosenPreview, !savedPreviews.contains(chosen),
              !saveName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let count = saveDescription.trimmingCharacters(in: .whitespacesAndNewlines).count
        if let minimum = VoicesStudioSchema.minLength("create_voice", "voice_description"), count < minimum { return false }
        return true
    }

    // MARK: Running

    func generate() async {
        var reference: String?
        if supportsReference, let file = referenceAudio.first,
           ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= Self.referenceLimit {
            // Read and encoded off the main actor, so a large file never stalls the window.
            reference = await Task.detached { (try? Data(contentsOf: file))?.base64EncodedString() }.value
            if reference == nil {
                problems = ["\(file.lastPathComponent) could not be read."]
                return
            }
        }
        let built = arguments(reference: reference)
        problems = built.problems
        guard problems.isEmpty else { return }
        let subject = mode == .design ? "Design a voice" : "Remix \(directory.voice(id: remixVoiceID)?.name ?? "a voice")"
        guard let result = await actions.perform(operationID, built.arguments, title: subject) else { return }
        take(result)
        if saveDescription.isEmpty, mode == .design { saveDescription = voiceDescription }
    }

    /// Reads the previews out of an answer: the JSON lists them in order, and the client has
    /// moved each one's base64 audio into a file, in the same order.
    func take(_ result: ElevenLabsResult) {
        let json = result.voicesStudioJSON ?? .null
        let files = result.voicesStudioFiles.filter(\.isAudio)
        let entries = json["previews"].arrayValue ?? []
        var withAudio = 0
        previews = entries.compactMap { entry in
            guard let id = entry["generated_voice_id"].stringValue else { return nil }
            let hasAudio = entry["audio_base_64_bytes"].intValue.map { $0 > 0 } ?? false
                || entry["audio_base_64"].stringValue?.isEmpty == false
            var file: URL?
            if hasAudio, withAudio < files.count {
                file = files[withAudio].url
                withAudio += 1
            }
            return VoiceDesignPreview(
                generatedVoiceID: id, file: file, durationSecs: entry["duration_secs"].doubleValue,
                language: entry["language"].stringValue, mediaType: entry["media_type"].stringValue
            )
        }
        previewText = json["text"].stringValue
        played = []
        chosenPreview = previews.first?.id
    }

    /// Fetches a preview's audio when the design asked for ids only (`stream_previews`).
    func fetchAudio(for preview: VoiceDesignPreview) async {
        guard let file = await actions.perform(
            "text_to_voice_preview_stream", ["generated_voice_id": .string(preview.generatedVoiceID)],
            title: "Preview \(preview.generatedVoiceID)"
        )?.voicesStudioFiles.first(where: \.isAudio),
              let index = previews.firstIndex(where: { $0.id == preview.id })
        else { return }
        previews[index].file = file.url
    }

    func notePlayed(_ preview: VoiceDesignPreview) {
        played.insert(preview.generatedVoiceID)
    }

    func save() async {
        // The preview saved is the one chosen when Save was pressed — another may be chosen by
        // the time the answer comes, and must not be marked saved in its place.
        guard let arguments = saveArguments(), let chosen = arguments["generated_voice_id"]?.stringValue,
              let json = await actions.perform("create_voice", arguments, title: "Save \(saveName)")?.voicesStudioJSON
        else { return }
        savedVoiceID = json["voice_id"].stringValue
        savedPreviews.insert(chosen)
        await directory.refresh()
    }

    // MARK: Test support

    func load(previews: [VoiceDesignPreview], text: String?) {
        self.previews = previews
        previewText = text
        chosenPreview = previews.first?.id
    }
}

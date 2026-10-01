import Foundation
import Observation
import SiliconElevenLabs

// MARK: - Data

/// A voice as `GET /v1/voices/{voice_id}` and the voices list describe it: enough to show,
/// edit and train it.
struct VoicesVoice: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var category: String?
    var description: String?
    var labels: [String: String]
    var previewURL: URL?
    var samples: [VoicesSample]
    var settings: VoicesSettings?
    var fineTuning: VoicesFineTuning?
    var isOwner: Bool?
    var createdAt: Int?
    var requiresVerification: Bool?
    var isVerified: Bool?
    var highQualityBaseModels: [String]
    var sharingStatus: String?

    init?(json: JSONValue) {
        guard let id = json["voice_id"].stringValue, !id.isEmpty else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        category = json["category"].stringValue
        description = json["description"].stringValue
        labels = (json["labels"].objectValue ?? [:]).compactMapValues(\.stringValue)
        previewURL = json["preview_url"].stringValue.flatMap(URL.init(string:)).flatMap {
            $0.scheme == "https" ? $0 : nil
        }
        samples = (json["samples"].arrayValue ?? []).compactMap(VoicesSample.init(json:))
        settings = json["settings"].objectValue == nil ? nil : VoicesSettings(json: json["settings"])
        fineTuning = json["fine_tuning"].objectValue == nil ? nil : VoicesFineTuning(json: json["fine_tuning"])
        isOwner = json["is_owner"].boolValue
        createdAt = json["created_at_unix"].intValue
        requiresVerification = json["voice_verification"]["requires_verification"].boolValue
        isVerified = json["voice_verification"]["is_verified"].boolValue
        highQualityBaseModels = json["high_quality_base_model_ids"].arrayValue?.compactMap(\.stringValue) ?? []
        sharingStatus = json["sharing"]["status"].stringValue
    }

    /// Professional clones are trained, verified and given samples through the PVC routes.
    var isProfessional: Bool { category == "professional" }

    /// The shell's picker type, so the pane's shared directory can be updated in place.
    var directoryEntry: ElevenLabsVoice {
        ElevenLabsVoice(id: id, name: name, category: category, description: description,
                        labels: labels, previewURL: previewURL)
    }

    var labelSummary: String { directoryEntry.labelSummary }
}

/// One sample of a voice.
struct VoicesSample: Identifiable, Hashable, Sendable {
    var id: String
    var fileName: String
    var mimeType: String?
    var sizeBytes: Int?
    var durationSecs: Double?
    var removeBackgroundNoise: Bool?
    var separationStatus: String?
    var selectedSpeakerIDs: [String]
    var trimStart: Int?
    var trimEnd: Int?

    init?(json: JSONValue) {
        guard let id = json["sample_id"].stringValue, !id.isEmpty else { return nil }
        self.id = id
        fileName = json["file_name"].stringValue ?? id
        mimeType = json["mime_type"].stringValue
        sizeBytes = json["size_bytes"].intValue
        durationSecs = json["duration_secs"].doubleValue
        removeBackgroundNoise = json["remove_background_noise"].boolValue
        separationStatus = json["speaker_separation"]["status"].stringValue
        selectedSpeakerIDs = json["speaker_separation"]["selected_speaker_ids"].arrayValue?
            .compactMap(\.stringValue) ?? []
        trimStart = json["trim_start"].intValue
        trimEnd = json["trim_end"].intValue
    }
}

/// A voice's settings: what `…/settings` returns and `…/settings/edit` takes.
struct VoicesSettings: Hashable, Sendable {
    var stability: Double
    var similarityBoost: Double
    var style: Double
    var speed: Double
    var useSpeakerBoost: Bool

    init(stability: Double, similarityBoost: Double, style: Double, speed: Double, useSpeakerBoost: Bool) {
        self.stability = stability
        self.similarityBoost = similarityBoost
        self.style = style
        self.speed = speed
        self.useSpeakerBoost = useSpeakerBoost
    }

    /// Missing values take the spec's defaults for `edit_voice_settings`.
    init(json: JSONValue) {
        func number(_ key: String) -> Double {
            json[key].doubleValue ?? VoicesStudioSchema.defaultNumber("edit_voice_settings", key) ?? 0
        }
        stability = number("stability")
        similarityBoost = number("similarity_boost")
        style = number("style")
        speed = number("speed")
        useSpeakerBoost = json["use_speaker_boost"].boolValue
            ?? VoicesStudioSchema.defaultValue("edit_voice_settings", "use_speaker_boost")?.boolValue ?? true
    }

    var arguments: [String: JSONValue] {
        ["stability": .number(stability), "similarity_boost": .number(similarityBoost),
         "style": .number(style), "speed": .number(speed), "use_speaker_boost": .bool(useSpeakerBoost)]
    }

    /// `fresh`'s values, except those the owner moved since the sliders held `base` — what they
    /// were filled with, or what a save sent: those stay where the owner put them.
    func merged(over fresh: VoicesSettings, base: VoicesSettings) -> VoicesSettings {
        var result = fresh
        if stability != base.stability { result.stability = stability }
        if similarityBoost != base.similarityBoost { result.similarityBoost = similarityBoost }
        if style != base.style { result.style = style }
        if speed != base.speed { result.speed = speed }
        if useSpeakerBoost != base.useSpeakerBoost { result.useSpeakerBoost = useSpeakerBoost }
        return result
    }
}

/// Where a professional clone is in its training.
struct VoicesFineTuning: Hashable, Sendable {
    var isAllowed: Bool
    /// Training state by model id.
    var states: [String: String]
    var progress: [String: Double]
    var messages: [String: String]
    var verificationFailures: [String]
    var verificationAttempts: Int
    var manualVerificationRequested: Bool
    var language: String?
    var datasetDuration: Double?

    init(json: JSONValue) {
        isAllowed = json["is_allowed_to_fine_tune"].boolValue ?? false
        states = (json["state"].objectValue ?? [:]).compactMapValues(\.stringValue)
        progress = (json["progress"].objectValue ?? [:]).compactMapValues(\.doubleValue)
        messages = (json["message"].objectValue ?? [:]).compactMapValues(\.stringValue)
        verificationFailures = json["verification_failures"].arrayValue?.compactMap(\.stringValue) ?? []
        verificationAttempts = json["verification_attempts_count"].intValue ?? 0
        manualVerificationRequested = json["manual_verification_requested"].boolValue ?? false
        language = json["language"].stringValue
        datasetDuration = json["dataset_duration_seconds"].doubleValue
    }
}

/// A voice from the shared library, as the similar-voices search returns it.
struct VoicesLibraryMatch: Identifiable, Hashable, Sendable {
    var voiceID: String
    var publicOwnerID: String
    var name: String
    var summary: String
    var previewURL: URL?
    var id: String { "\(publicOwnerID)/\(voiceID)" }

    init?(json: JSONValue) {
        guard let voiceID = json["voice_id"].stringValue, let owner = json["public_owner_id"].stringValue
        else { return nil }
        self.voiceID = voiceID
        publicOwnerID = owner
        name = json["name"].stringValue ?? voiceID
        summary = ["accent", "gender", "age", "descriptive", "use_case"]
            .compactMap { json[$0].stringValue }
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "_", with: " ") }
            .joined(separator: " · ")
        previewURL = json["preview_url"].stringValue.flatMap(URL.init(string:)).flatMap {
            $0.scheme == "https" ? $0 : nil
        }
    }
}

/// The speakers found in a professional sample.
struct VoicesSpeakers: Hashable, Sendable {
    struct Speaker: Identifiable, Hashable, Sendable {
        var id: String
        var duration: Double?
        var utterances: Int
    }

    var status: String
    var speakers: [Speaker]
    var selected: [String]

    init(json: JSONValue) {
        status = json["status"].stringValue ?? "not_started"
        speakers = (json["speakers"].objectValue ?? [:]).map { key, value in
            Speaker(id: value["speaker_id"].stringValue ?? key, duration: value["duration_secs"].doubleValue,
                    utterances: value["utterances"].arrayValue?.count ?? 0)
        }
        .sorted { $0.id < $1.id }
        selected = json["selected_speaker_ids"].arrayValue?.compactMap(\.stringValue) ?? []
    }
}

// MARK: - Drafts

/// The edit form for a voice: `POST /v1/voices/{voice_id}/edit` (multipart).
struct VoicesEditDraft: Hashable, Sendable {
    var name = ""
    var description = ""
    /// "key: value" per line.
    var labels = ""
    var files: [URL] = []
    var removeBackgroundNoise = false

    init() {}

    init(voice: VoicesVoice) {
        name = voice.name
        description = voice.description ?? ""
        labels = VoicesSectionModel.labelsText(voice.labels)
    }

    /// `fresh`'s fields, except those the owner changed since the form held `base` — what it was
    /// filled with, or what a save sent: that typing is kept. The files and the noise switch are
    /// the owner's picks and stay as they are.
    func merged(over fresh: VoicesEditDraft, base: VoicesEditDraft) -> VoicesEditDraft {
        var result = fresh
        if name != base.name { result.name = name }
        if description != base.description { result.description = description }
        if labels != base.labels { result.labels = labels }
        result.files = files
        result.removeBackgroundNoise = removeBackgroundNoise
        return result
    }
}

/// Instant voice cloning: `POST /v1/voices/add` (multipart).
struct VoicesCloneDraft: Hashable, Sendable {
    var name = ""
    var description = ""
    var labels = ""
    var files: [URL] = []
    var removeBackgroundNoise = false
}

/// A professional clone's details: `POST /v1/voices/pvc` and `POST /v1/voices/pvc/{voice_id}`.
struct VoicesProfessionalDraft: Hashable, Sendable {
    var name = ""
    var language = "en"
    var description = ""
    var labels = ""

    init() {}

    init(voice: VoicesVoice) {
        name = voice.name
        language = voice.fineTuning?.language ?? voice.labels["language"] ?? "en"
        description = voice.description ?? ""
        labels = VoicesSectionModel.labelsText(voice.labels)
    }

    /// `fresh`'s fields, except those the owner changed since the form held `base` — what it was
    /// filled with, or what a save sent: that typing is kept.
    func merged(over fresh: VoicesProfessionalDraft, base: VoicesProfessionalDraft) -> VoicesProfessionalDraft {
        var result = fresh
        if name != base.name { result.name = name }
        if language != base.language { result.language = language }
        if description != base.description { result.description = description }
        if labels != base.labels { result.labels = labels }
        return result
    }
}

/// One professional sample's training settings: `POST /v1/voices/pvc/{voice_id}/samples/{sample_id}`.
struct VoicesSampleDraft: Hashable, Sendable {
    var fileName = ""
    var removeBackgroundNoise = false
    /// Milliseconds, blank for the whole sample.
    var trimStart = ""
    var trimEnd = ""
    var selectedSpeakers: [String] = []

    init() {}

    init(sample: VoicesSample) {
        fileName = sample.fileName
        removeBackgroundNoise = sample.removeBackgroundNoise ?? false
        trimStart = sample.trimStart.map(String.init) ?? ""
        trimEnd = sample.trimEnd.map(String.init) ?? ""
        selectedSpeakers = sample.selectedSpeakerIDs
    }
}

// MARK: - Model

/// My voices: the list, one voice's details, settings and samples, instant cloning, the
/// professional-clone workflow, and a search for similar voices in the shared library.
@MainActor
@Observable
final class VoicesSectionModel {

    /// What the section is showing.
    enum Mode: String, CaseIterable, Identifiable {
        case voices, clone, professional, similar
        var id: String { rawValue }
        var title: String {
            switch self {
            case .voices: "My voices"
            case .clone: "Instant clone"
            case .professional: "Professional clone"
            case .similar: "Find similar"
            }
        }
    }

    let actions: VoicesStudioActions
    /// The pane's shared voices list: refreshed after anything that adds, renames or removes
    /// a voice, so every picker sees the change.
    let directory: ElevenLabsVoiceDirectory

    var mode: Mode = .voices

    // List
    var search = ""
    var category = ""
    var voiceType = ""
    var sort = ""
    private(set) var rows: [VoicesVoice] = []
    private(set) var hasMore = false
    private(set) var totalCount: Int?
    private(set) var loadedOnce = false
    @ObservationIgnored private var nextPageToken: String?

    // One voice
    private(set) var selected: VoicesVoice?
    var settingsDraft: VoicesSettings?
    var editDraft = VoicesEditDraft()
    /// What the edit form held when it was last filled from the voice, or what a save sent: a
    /// field that differs from it is the owner's typing, kept when the voice is fetched again.
    @ObservationIgnored private var editBase = VoicesEditDraft()
    /// Counts the times the edit form was filled afresh (another voice chosen): a save that went
    /// out before a refill does not speak for the form any more.
    @ObservationIgnored private var editFills = 0
    /// The same for the settings sliders and the professional details: what they held when last
    /// filled from the voice, or what a save sent. `editFills` counts their refills too.
    @ObservationIgnored private var settingsBase: VoicesSettings?
    @ObservationIgnored private var professionalBase = VoicesProfessionalDraft()
    /// Played sample audio, by sample id.
    private(set) var sampleFiles: [String: URL] = [:]
    var replicateWorkspaceID = ""
    var replicatePreservesID = true

    // Instant clone
    var clone = VoicesCloneDraft()

    // Professional
    var professional = VoicesProfessionalDraft()
    var professionalFiles: [URL] = []
    var professionalRemoveNoise = false
    var sampleDrafts: [String: VoicesSampleDraft] = [:]
    private(set) var waveforms: [String: [Double]] = [:]
    private(set) var speakers: [String: VoicesSpeakers] = [:]
    /// Separated speaker audio, by "sample/speaker".
    private(set) var speakerFiles: [String: URL] = [:]
    private(set) var captcha: ElevenLabsResult?
    var captchaRecording: [URL] = []
    var verificationFiles: [URL] = []
    var verificationNote = ""
    var trainingModel = ""

    // Similar
    var similarFile: [URL] = []
    var similarityThreshold = ""
    var similarTopK = ""
    private(set) var similarResults: [VoicesLibraryMatch] = []
    private(set) var searchedSimilar = false
    /// The library voice being added, while its name is edited.
    var addingName: [String: String] = [:]

    static let pageSize = 30

    init(environment: VoicesStudioEnvironment) {
        actions = VoicesStudioActions(context: environment.context)
        actions.readsShownInPlace = ["get_user_voices_v2", "get_voice_by_id", "get_voice_settings"]
        directory = environment.voices
    }

    // MARK: Spec

    /// Values the list filters offer that the spec lists in prose.
    static let categories = ["premade", "cloned", "generated", "professional"]
    static let voiceTypes = ["personal", "community", "default", "workspace", "non-default", "saved"]
    static let sorts = ["name", "created_at_unix"]

    /// Every control this section draws, and the spec argument it sets.
    static let controls: [VoicesStudioControl] = [
        .init("get_user_voices_v2", "search"),
        .init("get_user_voices_v2", "category", describedValues: categories),
        .init("get_user_voices_v2", "voice_type", describedValues: voiceTypes),
        .init("get_user_voices_v2", "sort", describedValues: sorts),
        .init("get_user_voices_v2", "page_size"),
        .init("get_user_voices_v2", "next_page_token"),
        .init("get_user_voices_v2", "include_total_count"),
        .init("get_voice_by_id", "voice_id"),
        .init("get_voice_settings", "voice_id"),
        .init("edit_voice_settings", "stability"),
        .init("edit_voice_settings", "similarity_boost"),
        .init("edit_voice_settings", "style"),
        .init("edit_voice_settings", "speed"),
        .init("edit_voice_settings", "use_speaker_boost"),
        .init("edit_voice", "name"),
        .init("edit_voice", "description"),
        .init("edit_voice", "labels"),
        .init("edit_voice", "files"),
        .init("edit_voice", "remove_background_noise"),
        .init("delete_voice", "voice_id"),
        .init("get_audio_from_sample", "sample_id"),
        .init("delete_sample", "sample_id"),
        .init("add_voice", "name"),
        .init("add_voice", "description"),
        .init("add_voice", "labels"),
        .init("add_voice", "files"),
        .init("add_voice", "remove_background_noise"),
        .init("replicate_voice_to_isolated_environment", "target_workspace_id"),
        .init("replicate_voice_to_isolated_environment", "preserve_voice_id"),
        .init("create_pvc_voice", "name"),
        .init("create_pvc_voice", "language"),
        .init("create_pvc_voice", "description"),
        .init("create_pvc_voice", "labels"),
        .init("edit_pvc_voice", "name"),
        .init("edit_pvc_voice", "language"),
        .init("edit_pvc_voice", "description"),
        .init("edit_pvc_voice", "labels"),
        .init("add_pvc_voice_samples", "files"),
        .init("add_pvc_voice_samples", "remove_background_noise"),
        .init("edit_pvc_voice_sample", "file_name"),
        .init("edit_pvc_voice_sample", "remove_background_noise"),
        .init("edit_pvc_voice_sample", "trim_start_time"),
        .init("edit_pvc_voice_sample", "trim_end_time"),
        .init("edit_pvc_voice_sample", "selected_speaker_ids"),
        .init("delete_pvc_voice_sample", "sample_id"),
        .init("get_pvc_sample_audio", "sample_id"),
        .init("get_pvc_sample_visual_waveform", "sample_id"),
        .init("get_pvc_sample_speakers", "sample_id"),
        .init("start_speaker_separation", "sample_id"),
        .init("get_speaker_audio", "speaker_id"),
        .init("get_pvc_voice_captcha", "voice_id"),
        .init("verify_pvc_voice_captcha", "recording"),
        .init("request_pvc_manual_verification", "files"),
        .init("request_pvc_manual_verification", "extra_text"),
        .init("run_pvc_voice_training", "model_id"),
        .init("get_similar_library_voices", "audio_file"),
        .init("get_similar_library_voices", "similarity_threshold", describedValues: ["0 to 2"]),
        .init("get_similar_library_voices", "top_k", describedValues: ["1 to 100"]),
        .init("add_sharing_voice", "public_user_id"),
        .init("add_sharing_voice", "voice_id"),
        .init("add_sharing_voice", "new_name"),
    ]

    /// Operations the screen calls with nothing the owner sets.
    static let callsWithoutControls: Set<String> = ["get_voice_settings_default"]

    /// Operations of this section left to the Explorer, and why.
    static let explorerOnly: [String: String] = [
        "get_voices": "The v1 list; the section lists voices with GET /v2/voices, which pages and filters.",
    ]

    /// The settings sliders' ranges: the spec's where it gives one, the documented span where
    /// it gives only a default.
    static var stabilityRange: ClosedRange<Double> { VoicesStudioSchema.range("edit_voice_settings", "stability") ?? 0...1 }
    static var similarityRange: ClosedRange<Double> { VoicesStudioSchema.range("edit_voice_settings", "similarity_boost") ?? 0...1 }
    static var styleRange: ClosedRange<Double> { VoicesStudioSchema.range("edit_voice_settings", "style") ?? 0...1 }
    static var speedRange: ClosedRange<Double> { VoicesStudioSchema.range("edit_voice_settings", "speed") ?? 0.7...1.2 }

    // MARK: Arguments

    func listArguments(after token: String?) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["page_size": .number(Double(Self.pageSize)), "include_total_count": true]
        arguments.voicesStudioSet("search", VoicesStudioFormat.text(search))
        arguments.voicesStudioSet("category", VoicesStudioFormat.text(category))
        arguments.voicesStudioSet("voice_type", VoicesStudioFormat.text(voiceType))
        arguments.voicesStudioSet("sort", VoicesStudioFormat.text(sort))
        arguments.voicesStudioSet("next_page_token", token.map(JSONValue.string))
        return arguments
    }

    nonisolated static func labelsText(_ labels: [String: String]) -> String {
        labels.keys.sorted().map { "\($0): \(labels[$0] ?? "")" }.joined(separator: "\n")
    }

    /// "key: value" lines as a labels object; lines without a colon are ignored.
    nonisolated static func labels(from text: String) -> [String: JSONValue] {
        var labels: [String: JSONValue] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            labels[parts[0]] = .string(parts[1])
        }
        return labels
    }

    /// Multipart forms take `labels` as JSON text.
    nonisolated static func labelsField(_ text: String) -> JSONValue? {
        let labels = labels(from: text)
        return labels.isEmpty ? nil : .string(JSONValue.object(labels).jsonString())
    }

    nonisolated static func editArguments(voiceID: String, draft: VoicesEditDraft) -> ([String: JSONValue], [String: [ElevenLabsFile]]) {
        var arguments: [String: JSONValue] = ["voice_id": .string(voiceID), "name": .string(draft.name.trimmingCharacters(in: .whitespaces))]
        arguments.voicesStudioSet("description", VoicesStudioFormat.text(draft.description))
        arguments.voicesStudioSet("labels", labelsField(draft.labels))
        if draft.removeBackgroundNoise { arguments["remove_background_noise"] = true }
        let files = draft.files.isEmpty ? [:] : ["files": draft.files.map { ElevenLabsFile(url: $0) }]
        return (arguments, files)
    }

    nonisolated static func cloneArguments(_ draft: VoicesCloneDraft) -> ([String: JSONValue], [String: [ElevenLabsFile]]) {
        var arguments: [String: JSONValue] = ["name": .string(draft.name.trimmingCharacters(in: .whitespaces))]
        arguments.voicesStudioSet("description", VoicesStudioFormat.text(draft.description))
        arguments.voicesStudioSet("labels", labelsField(draft.labels))
        if draft.removeBackgroundNoise { arguments["remove_background_noise"] = true }
        return (arguments, ["files": draft.files.map { ElevenLabsFile(url: $0) }])
    }

    nonisolated static func professionalArguments(_ draft: VoicesProfessionalDraft, voiceID: String? = nil) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [:]
        arguments.voicesStudioSet("voice_id", voiceID.map(JSONValue.string))
        arguments.voicesStudioSet("name", VoicesStudioFormat.text(draft.name))
        arguments.voicesStudioSet("language", VoicesStudioFormat.text(draft.language))
        arguments.voicesStudioSet("description", VoicesStudioFormat.text(draft.description))
        let labels = labels(from: draft.labels)
        if !labels.isEmpty { arguments["labels"] = .object(labels) }
        return arguments
    }

    nonisolated static func sampleArguments(voiceID: String, sampleID: String, draft: VoicesSampleDraft) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            "voice_id": .string(voiceID), "sample_id": .string(sampleID),
            "remove_background_noise": .bool(draft.removeBackgroundNoise),
        ]
        arguments.voicesStudioSet("file_name", VoicesStudioFormat.text(draft.fileName))
        if let start = Int(draft.trimStart.trimmingCharacters(in: .whitespaces)) {
            arguments["trim_start_time"] = .number(Double(start))
        }
        if let end = Int(draft.trimEnd.trimmingCharacters(in: .whitespaces)) {
            arguments["trim_end_time"] = .number(Double(end))
        }
        if !draft.selectedSpeakers.isEmpty {
            arguments["selected_speaker_ids"] = .array(draft.selectedSpeakers.map(JSONValue.string))
        }
        return arguments
    }

    func similarArguments() -> ([String: JSONValue], [String: [ElevenLabsFile]]) {
        var arguments: [String: JSONValue] = [:]
        if let threshold = Double(similarityThreshold.trimmingCharacters(in: .whitespaces)) {
            arguments["similarity_threshold"] = .number(threshold)
        }
        if let topK = Int(similarTopK.trimmingCharacters(in: .whitespaces)) {
            arguments["top_k"] = .number(Double(topK))
        }
        let files = similarFile.isEmpty ? [:] : ["audio_file": [ElevenLabsFile(url: similarFile[0])]]
        return (arguments, files)
    }

    // MARK: List

    var listRunner: ElevenLabsRunner? { actions.runner("get_user_voices_v2") }
    var listProblem: String? { actions.problem("get_user_voices_v2") }
    var isListing: Bool { actions.isRunning("get_user_voices_v2") }

    /// The first page again, with the filters as they are.
    func refresh() async {
        guard let page = await actions.perform("get_user_voices_v2", listArguments(after: nil), quietly: true)?
            .voicesStudioJSON else { return }
        rows = Self.voices(in: page)
        take(page)
    }

    func loadMore() async {
        guard hasMore, let token = nextPageToken,
              let page = await actions.perform("get_user_voices_v2", listArguments(after: token), quietly: true)?
                .voicesStudioJSON else { return }
        let known = Set(rows.map(\.id))
        rows += Self.voices(in: page).filter { !known.contains($0.id) }
        take(page)
    }

    func refreshIfNeeded() async {
        guard !loadedOnce else { return }
        await refresh()
    }

    private func take(_ page: JSONValue) {
        nextPageToken = page["next_page_token"].stringValue
        hasMore = page["has_more"].boolValue == true && nextPageToken != nil
        totalCount = page["total_count"].intValue
        loadedOnce = true
    }

    nonisolated static func voices(in page: JSONValue) -> [VoicesVoice] {
        (page["voices"].arrayValue ?? []).compactMap(VoicesVoice.init(json:))
    }

    // MARK: One voice

    /// The voice last chosen: a fetch that answers after another was chosen is dropped, so a
    /// slow answer never puts an old voice (and its drafts) back on screen.
    @ObservationIgnored private var wantedVoice: String?

    /// Why the selected voice's details or settings could not be read, if they could not.
    var detailProblem: String? { actions.problem("get_voice_by_id") ?? actions.problem("get_voice_settings") }

    /// Changes to each voice that have answered, by voice id. A read asked before one of them
    /// answered is older than it — even when it answers later, on another runner — and is dropped
    /// whole: the fetch after the change brings the newer voice.
    @ObservationIgnored private var landed: [String: Int] = [:]

    /// The voice whose own details the forms hold: until they arrive, the forms hold the list
    /// row's values, which may be older than ElevenLabs' (a description changed on the website).
    private(set) var detailsIn: String?

    /// Whether the open voice's details are in, so its forms may be saved: a save sends every
    /// field, and before then the untouched ones would be the list row's.
    var detailsAreIn: Bool {
        guard let id = selected?.id else { return false }
        return detailsIn == id && wantedVoice == id
    }

    /// Why the open voice's forms cannot be saved yet, when they cannot.
    var waitingForDetails: String? {
        guard selected != nil, !detailsAreIn else { return nil }
        return detailProblem == nil ? "Waiting for this voice's details." : "Its details could not be read — try again."
    }

    /// A change to `voiceID` has answered: reads asked before it are now stale.
    private func noteLanded(_ voiceID: String) {
        landed[voiceID, default: 0] += 1
    }

    func select(_ voiceID: String?) async {
        wantedVoice = voiceID
        guard let voiceID else {
            selected = nil
            return
        }
        if selected?.id != voiceID {
            selected = rows.first { $0.id == voiceID }
            detailsIn = nil
            settingsDraft = selected?.settings
            settingsBase = settingsDraft
            if let selected {
                editDraft = VoicesEditDraft(voice: selected)
                editBase = editDraft
                editFills += 1
                if selected.isProfessional {
                    professional = VoicesProfessionalDraft(voice: selected)
                    professionalBase = professional
                }
            }
            sampleFiles = [:]
            // What was picked or read for the previous voice is not offered for this one.
            captcha = nil
            captchaRecording = []
            professionalFiles = []
            verificationFiles = []
            verificationNote = ""
        }
        await reloadSelected(voiceID)
    }

    /// After a change to `voiceID`: fetch it again, onto the screen only while it is still the
    /// one open (its own runner, so the read of a voice opened meanwhile is not abandoned).
    private func refetch(_ voiceID: String) async {
        noteLanded(voiceID)
        await reloadSelected(voiceID, slot: VoicesStudioActions.afterChange(of: voiceID))
    }

    /// Whether `voiceID` is still the voice the owner has open — the only one whose drafts a
    /// finished change may clear.
    private func isOpen(_ voiceID: String) -> Bool { wantedVoice == voiceID }

    /// Fetches the selected voice (or `voiceID`) again, with its settings. An answer asked
    /// before a change to the voice answered is dropped whole (see `landed`).
    func reloadSelected(_ voiceID: String? = nil, slot: String? = nil) async {
        guard let voiceID = voiceID ?? selected?.id else { return }
        let changesBefore = landed[voiceID, default: 0]
        guard let json = await actions.perform(
                "get_voice_by_id", ["voice_id": .string(voiceID)], quietly: true, slot: slot
              )?.voicesStudioJSON,
              let voice = VoicesVoice(json: json),
              landed[voiceID, default: 0] == changesBefore
        else { return }
        if let index = rows.firstIndex(where: { $0.id == voice.id }) { rows[index] = voice }
        guard wantedVoice == voiceID else { return }
        selected = voice
        // The answer's `settings` may be null (and `with_settings` is deprecated and ignored):
        // then the settings route says them.
        if let settings = voice.settings {
            takeSettings(settings)
        } else if let json = await actions.perform(
            "get_voice_settings", ["voice_id": .string(voice.id)], quietly: true, slot: slot
        )?.voicesStudioJSON, selected?.id == voice.id, landed[voiceID, default: 0] == changesBefore {
            takeSettings(VoicesSettings(json: json))
        }
        guard selected?.id == voice.id, landed[voiceID, default: 0] == changesBefore else { return }
        // Field by field: what the owner typed since the form was filled (or since a save went
        // out, typing while it was on its way) stays; untouched fields take the fresh values.
        let fresh = VoicesEditDraft(voice: voice)
        editDraft = editDraft.merged(over: fresh, base: editBase)
        editBase = fresh
        if voice.isProfessional {
            let freshProfessional = VoicesProfessionalDraft(voice: voice)
            professional = professional.merged(over: freshProfessional, base: professionalBase)
            professionalBase = freshProfessional
        }
        for sample in voice.samples where sampleDrafts[sample.id] == nil {
            sampleDrafts[sample.id] = VoicesSampleDraft(sample: sample)
        }
        detailsIn = voice.id
    }

    /// Fresh settings for the open voice, merged slider by slider: one the owner moved since the
    /// sliders were filled (or since a save sent them) stays where it is.
    private func takeSettings(_ fresh: VoicesSettings) {
        if let current = settingsDraft, let base = settingsBase {
            settingsDraft = current.merged(over: fresh, base: base)
        } else {
            settingsDraft = fresh
        }
        settingsBase = fresh
    }

    func saveSettings() async {
        guard detailsAreIn, let voice = selected, let sent = settingsDraft else { return }
        let fills = editFills
        var arguments = sent.arguments
        arguments["voice_id"] = .string(voice.id)
        guard await actions.perform("edit_voice_settings", arguments, title: "Settings of \(voice.name)") != nil
        else { return }
        // The voice now holds what was sent; a slider moved since is the owner's.
        if isOpen(voice.id), editFills == fills { settingsBase = sent }
        // Like every change: reads asked before it are stale, and the voice is fetched again.
        await refetch(voice.id)
    }

    /// Puts the account's default settings in the sliders; nothing is saved until Save.
    func loadDefaultSettings() async {
        guard let voiceID = selected?.id,
              let json = await actions.perform("get_voice_settings_default", quietly: true)?.voicesStudioJSON,
              isOpen(voiceID) else { return }
        settingsDraft = VoicesSettings(json: json)
    }

    func saveEdit() async {
        guard detailsAreIn, let voice = selected else { return }
        let sent = editDraft
        let fills = editFills
        let (arguments, files) = Self.editArguments(voiceID: voice.id, draft: sent)
        guard await actions.perform("edit_voice", arguments, files: files, title: "Edit \(voice.name)") != nil
        else { return }
        if isOpen(voice.id) {
            editDraft.files = []
            // The voice now holds what was sent; anything else in the form was typed since.
            if editFills == fills { editBase = sent }
        }
        await refetch(voice.id)
        await directory.refresh()
    }

    func deleteSelected() async {
        guard let voice = selected else { return }
        guard await actions.perform(
            "delete_voice", ["voice_id": .string(voice.id)], subject: "the voice “\(voice.name)”",
            consequence: "“\(voice.name)” and its samples are removed from your account. Anything "
                + "that uses it — Studio projects, agents, saved settings — will need another voice."
        ) != nil else { return }
        // Clear the screen only if it still shows the deleted voice.
        if selected?.id == voice.id {
            selected = nil
            wantedVoice = nil
        }
        rows.removeAll { $0.id == voice.id }
        await directory.refresh()
    }

    func playSample(_ sample: VoicesSample) async {
        guard let voice = selected else { return }
        let operation = voice.isProfessional ? "get_pvc_sample_audio" : "get_audio_from_sample"
        guard let file = await actions.perform(
            operation, ["voice_id": .string(voice.id), "sample_id": .string(sample.id)],
            title: "Sample \(sample.fileName)"
        )?.voicesStudioFiles.first(where: \.isAudio) else { return }
        sampleFiles[sample.id] = file.url
    }

    func deleteSample(_ sample: VoicesSample) async {
        guard let voice = selected else { return }
        let operation = voice.isProfessional ? "delete_pvc_voice_sample" : "delete_sample"
        guard await actions.perform(
            operation, ["voice_id": .string(voice.id), "sample_id": .string(sample.id)],
            subject: "the sample “\(sample.fileName)” of “\(voice.name)”"
        ) != nil else { return }
        sampleFiles[sample.id] = nil
        await refetch(voice.id)
    }

    func replicate() async {
        guard let voice = selected else { return }
        let target = replicateWorkspaceID.trimmingCharacters(in: .whitespaces)
        await actions.perform(
            "replicate_voice_to_isolated_environment",
            ["voice_id": .string(voice.id), "target_workspace_id": .string(target),
             "preserve_voice_id": .bool(replicatePreservesID)],
            subject: "“\(voice.name)” to the workspace \(target)",
            question: VoicesStudioQuestion(
                "Copy “\(voice.name)” to the workspace \(target)?", button: "Copy voice",
                consequence: "A copy of “\(voice.name)” is made in another, isolated workspace, where "
                    + "that workspace's members can use it."
            )
        )
    }

    // MARK: Instant clone

    var canClone: Bool {
        !clone.name.trimmingCharacters(in: .whitespaces).isEmpty && !clone.files.isEmpty
    }

    func runClone() async {
        let (arguments, files) = Self.cloneArguments(clone)
        let chosen = wantedVoice
        guard let json = await actions.perform("add_voice", arguments, files: files, title: "Clone \(clone.name)")?
            .voicesStudioJSON, let voiceID = json["voice_id"].stringValue else { return }
        clone = VoicesCloneDraft()
        await directory.refresh()
        await refresh()
        // The new voice is opened unless the owner opened another meanwhile; the list shows
        // it unless the owner moved to another part of the section.
        guard wantedVoice == chosen else { return }
        if mode == .clone { mode = .voices }
        await select(voiceID)
    }

    // MARK: Professional

    /// Professional clones on the list: where the workflow picks up.
    var professionalVoices: [VoicesVoice] { rows.filter(\.isProfessional) }

    func createProfessional() async {
        guard let json = await actions.perform(
            "create_pvc_voice", Self.professionalArguments(professional), title: "Professional voice \(professional.name)"
        )?.voicesStudioJSON, let voiceID = json["voice_id"].stringValue else { return }
        let chosen = wantedVoice
        professional = VoicesProfessionalDraft()
        await refresh()
        guard wantedVoice == chosen else { return }
        await select(voiceID)
    }

    func editProfessional() async {
        guard detailsAreIn, let voice = selected else { return }
        let sent = professional
        let fills = editFills
        let saved = await actions.perform(
            "edit_pvc_voice", Self.professionalArguments(sent, voiceID: voice.id), title: "Edit \(voice.name)"
        ) != nil
        // The voice now holds what was sent; anything else in the form was typed since.
        if saved, isOpen(voice.id), editFills == fills { professionalBase = sent }
        await refetch(voice.id)
    }

    func addProfessionalSamples() async {
        guard let voice = selected, !professionalFiles.isEmpty else { return }
        var arguments: [String: JSONValue] = ["voice_id": .string(voice.id)]
        if professionalRemoveNoise { arguments["remove_background_noise"] = true }
        guard await actions.perform(
            "add_pvc_voice_samples", arguments,
            files: ["files": professionalFiles.map { ElevenLabsFile(url: $0) }],
            title: "Samples for \(voice.name)"
        ) != nil else { return }
        if isOpen(voice.id) { professionalFiles = [] }
        await refetch(voice.id)
    }

    func saveSample(_ sample: VoicesSample) async {
        guard let voice = selected else { return }
        let draft = sampleDrafts[sample.id] ?? VoicesSampleDraft(sample: sample)
        await actions.perform(
            "edit_pvc_voice_sample", Self.sampleArguments(voiceID: voice.id, sampleID: sample.id, draft: draft),
            title: "Sample \(sample.fileName)"
        )
        await refetch(voice.id)
    }

    func loadWaveform(_ sample: VoicesSample) async {
        guard let voice = selected,
              let json = await actions.perform(
                "get_pvc_sample_visual_waveform",
                ["voice_id": .string(voice.id), "sample_id": .string(sample.id)], quietly: true
              )?.voicesStudioJSON else { return }
        waveforms[sample.id] = json["visual_waveform"].arrayValue?.compactMap(\.doubleValue) ?? []
    }

    func separateSpeakers(_ sample: VoicesSample) async {
        guard let voice = selected else { return }
        guard await actions.perform(
            "start_speaker_separation", ["voice_id": .string(voice.id), "sample_id": .string(sample.id)],
            title: "Separate speakers in \(sample.fileName)"
        ) != nil else { return }
        await loadSpeakers(sample, of: voice.id)
    }

    /// The speakers found in a sample of `voiceID` (the open voice when nil) — asked for with
    /// that voice's id, whichever voice is open by then.
    func loadSpeakers(_ sample: VoicesSample, of voiceID: String? = nil) async {
        guard let voiceID = voiceID ?? selected?.id,
              let json = await actions.perform(
                "get_pvc_sample_speakers", ["voice_id": .string(voiceID), "sample_id": .string(sample.id)],
                quietly: true
              )?.voicesStudioJSON else { return }
        let found = VoicesSpeakers(json: json)
        speakers[sample.id] = found
        if !found.selected.isEmpty { sampleDrafts[sample.id, default: VoicesSampleDraft(sample: sample)].selectedSpeakers = found.selected }
    }

    func playSpeaker(_ speakerID: String, in sample: VoicesSample) async {
        guard let voice = selected,
              let file = await actions.perform(
                "get_speaker_audio",
                ["voice_id": .string(voice.id), "sample_id": .string(sample.id), "speaker_id": .string(speakerID)],
                title: "Speaker \(speakerID)"
              )?.voicesStudioFiles.first(where: \.isAudio) else { return }
        speakerFiles["\(sample.id)/\(speakerID)"] = file.url
    }

    func speakerFile(_ speakerID: String, in sample: VoicesSample) -> URL? {
        speakerFiles["\(sample.id)/\(speakerID)"]
    }

    /// The text to read aloud for this voice's verification. Shown only while that voice is
    /// open: read out for another voice, it would be a failed attempt.
    func loadCaptcha() async {
        guard let voice = selected else { return }
        let text = await actions.perform("get_pvc_voice_captcha", ["voice_id": .string(voice.id)], title: "Verification text")
        guard isOpen(voice.id) else { return }
        captcha = text
    }

    func verifyCaptcha() async {
        guard let voice = selected, let recording = captchaRecording.first else { return }
        guard await actions.perform(
            "verify_pvc_voice_captcha", ["voice_id": .string(voice.id)],
            files: ["recording": [ElevenLabsFile(url: recording)]], title: "Verify \(voice.name)"
        ) != nil else { return }
        if isOpen(voice.id) { captchaRecording = [] }
        await refetch(voice.id)
    }

    func requestManualVerification() async {
        guard let voice = selected, !verificationFiles.isEmpty else { return }
        var arguments: [String: JSONValue] = ["voice_id": .string(voice.id)]
        arguments.voicesStudioSet("extra_text", VoicesStudioFormat.text(verificationNote))
        guard await actions.perform(
            "request_pvc_manual_verification", arguments,
            files: ["files": verificationFiles.map { ElevenLabsFile(url: $0) }],
            title: "Manual verification for \(voice.name)"
        ) != nil else { return }
        if isOpen(voice.id) {
            verificationFiles = []
            verificationNote = ""
        }
        await refetch(voice.id)
    }

    /// The model ids ElevenLabs tracks training for on this voice — what "Train" can name.
    var trainingModels: [String] {
        guard let voice = selected else { return [] }
        let known = Set(voice.fineTuning?.states.keys.map { $0 } ?? []).union(voice.highQualityBaseModels)
        return known.sorted()
    }

    /// Whether a training run is under way for the selected voice (queued or fine-tuning).
    var isTraining: Bool {
        selected?.fineTuning?.states.values.contains { $0 == "queued" || $0 == "fine_tuning" } ?? false
    }

    func train() async {
        guard let voice = selected else { return }
        var arguments: [String: JSONValue] = ["voice_id": .string(voice.id)]
        arguments.voicesStudioSet("model_id", VoicesStudioFormat.text(trainingModel))
        guard await actions.perform("run_pvc_voice_training", arguments, title: "Train \(voice.name)") != nil
        else { return }
        await refetch(voice.id)
    }

    // MARK: Similar voices

    func findSimilar() async {
        let (arguments, files) = similarArguments()
        guard let json = await actions.perform(
            "get_similar_library_voices", arguments, files: files, title: "Similar voices"
        )?.voicesStudioJSON else { return }
        similarResults = (json["voices"].arrayValue ?? []).compactMap(VoicesLibraryMatch.init(json:))
        searchedSimilar = true
    }

    func addFromLibrary(_ match: VoicesLibraryMatch) async {
        let name = (addingName[match.id] ?? match.name).trimmingCharacters(in: .whitespaces)
        guard await actions.perform(
            "add_sharing_voice",
            ["public_user_id": .string(match.publicOwnerID), "voice_id": .string(match.voiceID),
             "new_name": .string(name.isEmpty ? match.name : name)],
            title: "Add \(match.name)"
        ) != nil else { return }
        await directory.refresh()
        await refresh()
    }

    // MARK: Test support

    /// Puts fake rows and a selection in place, for previews and snapshot tests.
    func load(rows: [VoicesVoice], selected: VoicesVoice? = nil, hasMore: Bool = false, total: Int? = nil) {
        self.rows = rows
        self.selected = selected
        wantedVoice = selected?.id
        detailsIn = selected?.id
        settingsDraft = selected?.settings
        settingsBase = settingsDraft
        if let selected {
            editDraft = VoicesEditDraft(voice: selected)
            editBase = editDraft
            editFills += 1
            if selected.isProfessional {
                professional = VoicesProfessionalDraft(voice: selected)
                professionalBase = professional
            }
            for sample in selected.samples { sampleDrafts[sample.id] = VoicesSampleDraft(sample: sample) }
        }
        self.hasMore = hasMore
        totalCount = total ?? rows.count
        loadedOnce = true
    }

    func load(similar: [VoicesLibraryMatch]) {
        similarResults = similar
        searchedSimilar = true
    }

    func load(waveform: [Double], for sampleID: String) {
        waveforms[sampleID] = waveform
    }
}

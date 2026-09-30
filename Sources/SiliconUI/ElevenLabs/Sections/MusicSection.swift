import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI
import UniformTypeIdentifiers

/// Music: songs from a prompt or an edited plan, streamed or with lyrics timings, stems split
/// out of a song, music scored to video, fine-tunes trained on the owner's own tracks, and
/// uploads to build on.
struct MusicSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MusicScreen(screen: CreativeSession.shared(for: model).music)
    }
}

/// A fine-tune, as the list describes it.
struct MusicFinetune: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var tags: [String]
    var primaryGenre: String?
    var modelID: String?
    var visibility: String?
    var createdBy: String?
    var status: String?
    var progress: Double?
    var failureReason: String?

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        tags = (json["tags"].arrayValue ?? []).compactMap(\.stringValue)
        primaryGenre = json["primary_genre"].stringValue
        modelID = json["model_id"].stringValue
        visibility = json["visibility"].stringValue
        createdBy = json["created_by"].stringValue
        status = json["status"].stringValue
        progress = json["training_progress"].doubleValue
        failureReason = json["failure_reason"].stringValue ?? json["failure_reason"]["message"].stringValue
    }

    init(id: String, name: String, tags: [String] = [], primaryGenre: String? = nil, modelID: String? = nil,
         visibility: String? = nil, createdBy: String? = nil, status: String? = nil, progress: Double? = nil) {
        self.id = id
        self.name = name
        self.tags = tags
        self.primaryGenre = primaryGenre
        self.modelID = modelID
        self.visibility = visibility
        self.createdBy = createdBy
        self.status = status
        self.progress = progress
    }

    /// Only the owner's own fine-tunes can be renamed or deleted.
    var isOwn: Bool { createdBy == nil || createdBy == "self" }
}

/// What an answer said about one song besides its audio: lyrics timings, waveform, the plan
/// and metadata the model used, and the song's id.
struct MusicDetails: Hashable, Sendable {
    var words: [CreativeTimedWord] = []
    var waveform: [Double] = []
    /// The plan and metadata, as the answer gave them.
    var metadata: JSONValue?
    var songID: String?

    init(words: [CreativeTimedWord] = [], waveform: [Double] = [], metadata: JSONValue? = nil, songID: String? = nil) {
        self.words = words
        self.waveform = waveform
        self.metadata = metadata
        self.songID = songID
    }

    /// From a detailed, streamed or upload answer: its JSON parts and events, and the
    /// `song-id` header.
    init(result: ElevenLabsResult) {
        let values = CreativeResults.jsonValues(in: result)
        words = values.flatMap { value -> [CreativeTimedWord] in
            let timestamps = value["words_timestamps"].arrayValue ?? value["song_metadata"]["words_timestamps"].arrayValue ?? []
            return timestamps.compactMap { word in
                guard let text = word["word"].stringValue ?? word["text"].stringValue else { return nil }
                return CreativeTimedWord(
                    text: text,
                    start: (word["start_ms"].doubleValue ?? 0) / 1000,
                    end: (word["end_ms"].doubleValue ?? 0) / 1000
                )
            }
        }
        waveform = values.flatMap { ($0["waveform_visual"].arrayValue ?? []).compactMap(\.doubleValue) }
        metadata = values.first { $0["composition_plan"] != .null || $0["song_metadata"] != .null }
        songID = result.meta.headers["song-id"] ?? values.lazy.compactMap { $0["song_id"].stringValue }.first
    }

    /// The plan the answer carried, if any.
    var plan: JSONValue? {
        guard let value = metadata?["composition_plan"], value != .null else { return nil }
        return value
    }

    var isEmpty: Bool { words.isEmpty && waveform.isEmpty && metadata == nil && songID == nil }
}

@MainActor
@Observable
final class MusicScreenModel: CreativeScreenModel {

    enum Tab: String, CaseIterable, Identifiable {
        case compose, plan, stems, video, finetunes, upload

        var id: String { rawValue }
        var title: String {
            switch self {
            case .compose: "Compose"
            case .plan: "Plan"
            case .stems: "Stems"
            case .video: "For video"
            case .finetunes: "Fine-tunes"
            case .upload: "Upload"
            }
        }
    }

    /// How a composition comes back.
    enum Delivery: String, CaseIterable, Identifiable {
        case whole, stream, detailed, detailedStream

        var id: String { rawValue }
        var title: String {
            switch self {
            case .whole: "Song"
            case .stream: "Streamed"
            case .detailed: "With details"
            case .detailedStream: "Details, streamed"
            }
        }
    }

    static let compose = "generate"
    static let composeStream = "stream_compose"
    static let composeDetailed = "compose_detailed"
    static let composeDetailedStream = "compose_detailed_stream"
    static let plan = "compose_plan"
    static let upload = "upload_song"
    static let stems = "separate_song_stems"
    static let videoToMusic = "video_to_music"
    static let listFinetunes = "get_finetunes"
    static let createFinetune = "create_finetune"
    static let getFinetune = "get_finetune"
    static let updateFinetune = "update_finetune"
    static let deleteFinetune = "delete_finetune"
    static let composeIDs = [compose, composeStream, composeDetailed, composeDetailedStream]
    static let operationIDs = composeIDs + [plan, upload, stems, videoToMusic, listFinetunes, createFinetune,
                                            getFinetune, updateFinetune, deleteFinetune]

    static let controls: [CreativeControl] = [
        CreativeControl("Prompt", composeIDs, "prompt"),
        CreativeControl("Plan", composeIDs, "composition_plan"),
        CreativeControl("Lyrics", composeIDs, "lyrics_text"),
        CreativeControl("Length", composeIDs, "music_length_ms"),
        CreativeControl("Instrumental", composeIDs, "force_instrumental"),
        CreativeControl("Model", composeIDs, "model_id"),
        CreativeControl("Kind", composeIDs, "generation_mode"),
        CreativeControl("Seed", composeIDs, "seed"),
        CreativeControl("Fine-tune", composeIDs, "finetune_id"),
        CreativeControl("Fine-tune strength", composeIDs, "finetune_strength"),
        CreativeControl("Keep for inpainting", composeIDs, "store_for_inpainting"),
        CreativeControl("Spell names phonetically", composeIDs, "use_phonetic_names"),
        CreativeControl("Output format", composeIDs, "output_format"),
        CreativeControl("Sign with C2PA", [compose, composeDetailed], "sign_with_c2pa"),
        CreativeControl("Keep section lengths", [compose, composeDetailed], "respect_sections_durations"),
        CreativeControl("Lyrics timings", [composeDetailed, composeDetailedStream], "with_timestamps"),
        CreativeControl("Waveform", [composeDetailed, composeDetailedStream], "with_waveform_visual"),
        CreativeControl("Plan prompt", [plan], "prompt"),
        CreativeControl("Plan length", [plan], "music_length_ms"),
        CreativeControl("Plan model", [plan], "model_id"),
        CreativeControl("Start from a plan", [plan], "source_composition_plan"),
        CreativeControl("Section name", [compose], "composition_plan.sections[].section_name"),
        CreativeControl("Section length", [compose], "composition_plan.sections[].duration_ms"),
        CreativeControl("Section lyrics", [compose], "composition_plan.sections[].lines"),
        CreativeControl("Section styles", [compose], "composition_plan.sections[].positive_local_styles"),
        CreativeControl("Section styles to avoid", [compose], "composition_plan.sections[].negative_local_styles"),
        CreativeControl("Styles to have", [compose], "composition_plan.positive_global_styles"),
        CreativeControl("Styles to avoid", [compose], "composition_plan.negative_global_styles"),
        CreativeControl("Song to split", [stems], "file"),
        CreativeControl("Stems", [stems], "stem_variation_id"),
        CreativeControl("Stems format", [stems], "output_format"),
        CreativeControl("Stems C2PA", [stems], "sign_with_c2pa"),
        CreativeControl("Videos", [videoToMusic], "videos"),
        CreativeControl("Music description", [videoToMusic], "description"),
        CreativeControl("Music tags", [videoToMusic], "tags"),
        CreativeControl("Video model", [videoToMusic], "model_id"),
        CreativeControl("Video format", [videoToMusic], "output_format"),
        CreativeControl("Video C2PA", [videoToMusic], "sign_with_c2pa"),
        CreativeControl("Visibility filter", [listFinetunes], "visibility"),
        CreativeControl("Made by", [listFinetunes], "created_by"),
        CreativeControl("Sort", [listFinetunes], "sort"),
        CreativeControl("Sort direction", [listFinetunes], "sort_direction"),
        CreativeControl("Page size", [listFinetunes], "page_size"),
        CreativeControl("More fine-tunes", [listFinetunes], "cursor"),
        CreativeControl("Fine-tune details", [getFinetune, updateFinetune, deleteFinetune], "finetune_id"),
        CreativeControl("Fine-tune name", [createFinetune, updateFinetune], "name"),
        CreativeControl("Fine-tune genre", [createFinetune, updateFinetune], "primary_genre"),
        CreativeControl("Fine-tune tags", [createFinetune, updateFinetune], "tags"),
        CreativeControl("Fine-tune visibility", [createFinetune, updateFinetune], "visibility"),
        CreativeControl("Training tracks", [createFinetune], "files"),
        CreativeControl("Fine-tune model", [createFinetune], "model_id"),
        CreativeControl("Song to upload", [upload], "file"),
        CreativeControl("Extract a plan", [upload], "extract_composition_plan"),
        CreativeControl("Upload lyrics timings", [upload], "with_timestamps"),
        CreativeControl("Upload waveform", [upload], "with_waveform_visual"),
    ]

    let session: CreativeSession
    var tab: Tab = .compose

    // MARK: Compose state
    var delivery: Delivery = .whole
    var prompt = ""
    var lyrics = ""
    /// Compose from `plan` instead of the prompt.
    var usesPlan = false
    var usesLength = false
    var lengthSeconds: Double
    var forceInstrumental = false
    var modelID: String
    var generationMode = ""
    var seed: Int?
    var finetuneID = ""
    var finetuneStrength: Double
    var signWithC2PA = false
    var storeForInpainting = false
    var usePhoneticNames = false
    var respectSectionsDurations: Bool
    var withTimestamps = true
    var withWaveform = false
    var outputFormat: String

    // MARK: Plan state
    var planPrompt = ""
    var planUsesLength = false
    var planLengthSeconds: Double
    var planModelID: String
    /// Start the new plan from the one being edited.
    var planFromCurrent = false
    /// The plan being edited, in the sections shape.
    var plan: MusicPlan?
    /// A plan in another shape (chunks), edited as JSON.
    var planJSON = ""

    // MARK: Stems, video, upload state
    var stemsSource: URL?
    var stemVariation: String
    var stemsFormat: String
    var stemsC2PA = false
    var videos: [URL] = []
    var videoDescription = ""
    var videoTags: [String] = []
    var videoModelID: String
    var videoFormat: String
    var videoC2PA = false
    var uploadSource: URL?
    var extractPlan: String = ""
    var uploadTimestamps = false
    var uploadWaveform = false
    private(set) var uploadedSongID: String?

    // MARK: Fine-tunes state
    var finetuneVisibilityFilter = ""
    var finetuneCreatorFilter = ""
    var finetuneSort: String
    var finetuneSortDirection: String
    private(set) var finetunes: [MusicFinetune] = []
    private(set) var finetuneCursor: String?
    private(set) var finetunesHaveMore = false
    var selectedFinetune: MusicFinetune?
    var editName = ""
    var editGenre = ""
    var editTags: [String] = []
    var editVisibility = ""
    var newName = ""
    var newGenre = ""
    var newTags: [String] = []
    var newVisibility = ""
    var newFiles: [URL] = []
    var newModelID: String

    // MARK: Results
    /// Composed songs, newest first.
    private(set) var takes: [CreativeTake] = []
    /// Scores made for video, newest first: their own list, so neither tab shows the other's.
    private(set) var videoTakes: [CreativeTake] = []
    /// What each take's answer said about it — lyrics timings, waveform, the plan used, the
    /// song id — so a take is only ever drawn with its own.
    private(set) var takeDetails: [CreativeTake.ID: MusicDetails] = [:]
    /// What the last upload's answer said about the uploaded song.
    private(set) var uploadDetails: MusicDetails?
    /// The compose runner that ran last: its errors, result and "Show API call" are on screen.
    private(set) var lastRunner: ElevenLabsRunner
    private(set) var lastOtherResult: ElevenLabsResult?

    @ObservationIgnored private let runners: [String: ElevenLabsRunner]

    init(session: CreativeSession) {
        self.session = session
        var runners: [String: ElevenLabsRunner] = [:]
        for id in Self.operationIDs {
            let reads = [Self.listFinetunes, Self.getFinetune].contains(id)
            runners[id] = session.runner(id, title: "Music", records: !reads)
        }
        self.runners = runners
        lastRunner = runners[Self.compose]!
        let length = CreativeSpec.range(Self.compose, "music_length_ms") ?? 3000...600_000
        let startLength = min(max(60, length.lowerBound / 1000), length.upperBound / 1000)
        lengthSeconds = startLength
        planLengthSeconds = startLength
        modelID = CreativeSpec.defaultString(Self.compose, "model_id") ?? ""
        planModelID = CreativeSpec.defaultString(Self.plan, "model_id") ?? ""
        videoModelID = CreativeSpec.defaultString(Self.videoToMusic, "model_id") ?? ""
        newModelID = CreativeSpec.defaultString(Self.createFinetune, "model_id") ?? ""
        finetuneStrength = CreativeSpec.defaultNumber(Self.compose, "finetune_strength") ?? 1
        respectSectionsDurations = CreativeSpec.defaultBool(Self.compose, "respect_sections_durations") ?? true
        outputFormat = CreativeSpec.defaultString(Self.compose, "output_format") ?? ""
        stemVariation = CreativeSpec.defaultString(Self.stems, "stem_variation_id") ?? ""
        stemsFormat = CreativeSpec.defaultString(Self.stems, "output_format") ?? ""
        videoFormat = CreativeSpec.defaultString(Self.videoToMusic, "output_format") ?? ""
        finetuneSort = CreativeSpec.defaultString(Self.listFinetunes, "sort") ?? ""
        finetuneSortDirection = CreativeSpec.defaultString(Self.listFinetunes, "sort_direction") ?? ""
        newVisibility = CreativeSpec.choices(Self.createFinetune, "visibility").first ?? ""
    }

    func runner(_ id: String) -> ElevenLabsRunner { runners[id]! }

    // MARK: - Compose

    var composeOperationID: String {
        switch delivery {
        case .whole: Self.compose
        case .stream: Self.composeStream
        case .detailed: Self.composeDetailed
        case .detailedStream: Self.composeDetailedStream
        }
    }

    var composeRunner: ElevenLabsRunner { runner(composeOperationID) }

    /// The run in flight, or waiting for its confirmation, whichever operation it is: the
    /// pickers that choose the operation can change while it runs, and must not hand the Run
    /// row an idle runner (a second paid run, and a Cancel that no longer reaches the first).
    var busyRunner: ElevenLabsRunner? {
        Self.composeIDs.compactMap { runners[$0] }.first { $0.isRunning || $0.isAwaitingConfirmation }
    }

    /// What the Run row shows: the run in flight, so Cancel reaches it, else the chosen one.
    var activeComposeRunner: ElevenLabsRunner { busyRunner ?? composeRunner }

    /// Said while a run is in flight.
    static let busyProblem = "Wait for the current take to finish, or cancel it."
    var models: [String] { CreativeSpec.choices(Self.compose, "model_id") }
    var generationModes: [String] { CreativeSpec.choices(Self.compose, "generation_mode") }
    var outputFormats: [String] { CreativeSpec.choices(composeOperationID, "output_format") }
    var lengthRange: ClosedRange<Double> {
        let range = CreativeSpec.range(Self.compose, "music_length_ms") ?? 3000...600_000
        return (range.lowerBound / 1000)...(range.upperBound / 1000)
    }
    var strengthRange: ClosedRange<Double> {
        let range = CreativeSpec.range(Self.compose, "finetune_strength") ?? 0...2
        // The lower bound is excluded: start the slider a step above it.
        return (CreativeSpec.excludesLowerBound(Self.compose, "finetune_strength") ? range.lowerBound + 0.05 : range.lowerBound)...range.upperBound
    }
    var isDetailed: Bool { delivery == .detailed || delivery == .detailedStream }
    var isStreamed: Bool { delivery == .stream || delivery == .detailedStream }

    /// The song's length as set, for the cost note: the slider with a prompt, the plan's
    /// sections with a plan; nil when the model chooses.
    var estimatedSeconds: Double? {
        if usesPlan { return plan.map { Double($0.totalMs) / 1000 } }
        return usesLength ? lengthSeconds : nil
    }

    /// A streamed song plays as it arrives, detailed or not: the shell keeps an event stream's
    /// audio as the format asked for.
    var streamMode: ElevenLabsRunner.StreamMode { isStreamed ? .play : .collect }

    /// The chosen format, or the operation's default when it does not take the chosen one.
    var effectiveOutputFormat: String? {
        outputFormats.contains(outputFormat) ? outputFormat : CreativeSpec.defaultString(composeOperationID, "output_format")
    }

    /// Whether a streamed song plays as it arrives: the default is MP3, and the shell's
    /// stream player decodes MP3 and raw PCM.
    var streamsLive: Bool {
        guard let format = effectiveOutputFormat else { return true }
        return format == CreativeSpec.defaultString(composeOperationID, "output_format")
            || CreativeOutputFormat.playsLive(format)
    }

    var composeProblems: [String] {
        var problems: [String] = busyRunner == nil ? [] : [Self.busyProblem]
        if usesPlan {
            if let plan { problems += plan.problems() } else if planJSONValue == nil { problems.append("Make or load a plan under Plan first.") }
        } else if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("Describe the song.")
        }
        if let limit = CreativeSpec.maxLength(Self.compose, "prompt"), prompt.count > limit {
            problems.append("The prompt takes at most \(limit.formatted()) characters.")
        }
        if let limit = CreativeSpec.maxLength(Self.compose, "lyrics_text"), lyrics.count > limit {
            problems.append("Lyrics take at most \(limit.formatted()) characters.")
        }
        if let seed, let range = CreativeSpec.range(Self.compose, "seed"), !range.contains(Double(seed)) {
            problems.append("The seed must be between \(Int(range.lowerBound)) and \(Int(range.upperBound)).")
        }
        return problems
    }

    /// The plan to send: the edited one, or the JSON one.
    var planJSONValue: JSONValue? {
        if let plan { return plan.json }
        let text = planJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let value = try? JSONValue(data: Data(text.utf8)), value.objectValue != nil else { return nil }
        return value
    }

    /// Arguments the spec's descriptions allow only with a prompt, with the words that say so.
    static let promptOnly: [(argument: String, evidence: String)] = [
        ("music_length_ms", "Used only in conjunction with `prompt`"),
        ("force_instrumental", "Can only be used with `prompt`"),
        ("generation_mode", "Can only be used with `prompt`"),
    ]

    /// Arguments the spec's descriptions allow only without one (with a composition plan).
    static let planOnly: [(argument: String, evidence: String)] = [
        ("seed", "Cannot be used in conjunction with prompt"),
        ("respect_sections_durations", "Only used with `composition_plan`"),
    ]

    func composeArguments() -> [String: JSONValue] {
        let id = composeOperationID
        var arguments: [String: JSONValue] = [:]
        // What goes with which way of composing is the spec's (`promptOnly`, `planOnly`).
        if usesPlan, let plan = planJSONValue {
            // A plan replaces the prompt, and the options that only go with a prompt.
            arguments["composition_plan"] = plan
            if CreativeSpec.has(id, "respect_sections_durations"), respectSectionsDurations != (CreativeSpec.defaultBool(id, "respect_sections_durations") ?? true) {
                arguments["respect_sections_durations"] = .bool(respectSectionsDurations)
            }
            if let seed { arguments["seed"] = .number(Double(seed)) }
        } else {
            arguments["prompt"] = .string(prompt)
            if usesLength { arguments["music_length_ms"] = .number((lengthSeconds * 1000).rounded()) }
            if forceInstrumental { arguments["force_instrumental"] = true }
            if !generationMode.isEmpty { arguments["generation_mode"] = .string(generationMode) }
        }
        if !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { arguments["lyrics_text"] = .string(lyrics) }
        if !modelID.isEmpty { arguments["model_id"] = .string(modelID) }
        if !finetuneID.isEmpty {
            arguments["finetune_id"] = .string(finetuneID)
            arguments["finetune_strength"] = .number(CreativeVoiceSettings.rounded(finetuneStrength))
        }
        if storeForInpainting { arguments["store_for_inpainting"] = true }
        if usePhoneticNames { arguments["use_phonetic_names"] = true }
        if signWithC2PA, CreativeSpec.has(id, "sign_with_c2pa") { arguments["sign_with_c2pa"] = true }
        if isDetailed {
            if withTimestamps { arguments["with_timestamps"] = true }
            if withWaveform { arguments["with_waveform_visual"] = true }
        }
        // The spec's default ("auto": always MP3) is left for ElevenLabs to apply, so a stream
        // is decoded as the MP3 it is rather than refused as a format named "auto".
        if let format = effectiveOutputFormat, format != CreativeSpec.defaultString(id, "output_format") {
            arguments["output_format"] = .string(format)
        }
        return arguments
    }

    func composeSong() async {
        guard busyRunner == nil, composeProblems.isEmpty else { return }
        let runner = composeRunner
        guard CreativeRunGate.isKnown(runner) else { return }
        runner.streamMode = streamMode
        lastRunner = runner
        // Named from what was sent: the prompt stays editable while it runs.
        let title = usesPlan ? "Song from a plan (\(plan?.sections.count ?? 0) sections)" : Self.excerpt(prompt)
        guard let result = await runner.perform(arguments: composeArguments()) else { return }
        if let take = CreativeTake(result: result, title: title, runner: runner) {
            takes.insert(take, at: 0)
            takeDetails[take.id] = MusicDetails(result: result)
        }
    }

    /// What the answer said about `take`, when it said anything.
    func details(of take: CreativeTake) -> MusicDetails? {
        takeDetails[take.id].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Opens the plan `take`'s answer carried under Plan, to edit and compose again.
    func editReturnedPlan(of take: CreativeTake) {
        guard let value = takeDetails[take.id]?.plan else { return }
        load(plan: value)
        tab = .plan
    }

    // MARK: - Plan

    var planOperationRunner: ElevenLabsRunner { runner(Self.plan) }

    var planProblems: [String] {
        var problems: [String] = []
        if planPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("Describe the song to plan.") }
        if let limit = CreativeSpec.maxLength(Self.plan, "prompt"), planPrompt.count > limit {
            problems.append("The prompt takes at most \(limit.formatted()) characters.")
        }
        return problems
    }

    func planArguments() -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["prompt": .string(planPrompt)]
        if planUsesLength { arguments["music_length_ms"] = .number((planLengthSeconds * 1000).rounded()) }
        if !planModelID.isEmpty { arguments["model_id"] = .string(planModelID) }
        if planFromCurrent, let current = planJSONValue { arguments["source_composition_plan"] = current }
        return arguments
    }

    func makePlan() async {
        guard planProblems.isEmpty, CreativeRunGate.isKnown(planOperationRunner) else { return }
        guard case .json(let value, _)? = await planOperationRunner.perform(arguments: planArguments()) else { return }
        load(plan: value)
    }

    /// Puts a plan in the editor: typed when it is the sections shape, JSON otherwise.
    func load(plan value: JSONValue) {
        if let typed = MusicPlan(json: value) {
            plan = typed
            planJSON = ""
        } else {
            plan = nil
            planJSON = value.jsonString(pretty: true)
        }
    }

    func composeFromPlan() {
        usesPlan = true
        tab = .compose
    }

    // MARK: - Stems

    var stemsRunner: ElevenLabsRunner { runner(Self.stems) }
    var stemVariations: [String] { CreativeSpec.choices(Self.stems, "stem_variation_id") }

    func stemsArguments() -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["stem_variation_id": .string(stemVariation)]
        if !stemsFormat.isEmpty { arguments["output_format"] = .string(stemsFormat) }
        if stemsC2PA { arguments["sign_with_c2pa"] = true }
        return arguments
    }

    func splitStems() async {
        guard let stemsSource, CreativeRunGate.isKnown(stemsRunner) else { return }
        lastOtherResult = await stemsRunner.perform(
            arguments: stemsArguments(), files: ["file": [ElevenLabsFile(url: stemsSource)]]
        )
    }

    // MARK: - Video

    var videoRunner: ElevenLabsRunner { runner(Self.videoToMusic) }

    var videoProblems: [String] {
        var problems: [String] = []
        if videos.isEmpty { problems.append("Add at least one video.") }
        if let limit = CreativeSpec.maxItems(Self.videoToMusic, "videos"), videos.count > limit {
            problems.append("At most \(limit) videos.")
        }
        if let limit = CreativeSpec.maxLength(Self.videoToMusic, "description"), videoDescription.count > limit {
            problems.append("The description takes at most \(limit.formatted()) characters.")
        }
        return problems
    }

    func videoArguments() -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [:]
        let description = videoDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { arguments["description"] = .string(description) }
        if !videoTags.isEmpty { arguments["tags"] = .array(videoTags.map(JSONValue.string)) }
        if !videoModelID.isEmpty { arguments["model_id"] = .string(videoModelID) }
        if !videoFormat.isEmpty { arguments["output_format"] = .string(videoFormat) }
        if videoC2PA { arguments["sign_with_c2pa"] = true }
        return arguments
    }

    func scoreVideo() async {
        guard videoProblems.isEmpty, CreativeRunGate.isKnown(videoRunner) else { return }
        let title = "Score for \(videos.map(\.lastPathComponent).joined(separator: ", "))"
        guard let result = await videoRunner.perform(
            arguments: videoArguments(), files: ["videos": videos.map { ElevenLabsFile(url: $0) }]
        ) else { return }
        if let take = CreativeTake(result: result, title: title, runner: videoRunner) {
            videoTakes.insert(take, at: 0)
            takeDetails[take.id] = MusicDetails(result: result)
        }
    }

    // MARK: - Upload

    var uploadRunner: ElevenLabsRunner { runner(Self.upload) }
    /// What `extract_composition_plan` takes besides true/false: the plan formats' models.
    var extractChoices: [String] { CreativeSpec.choices(Self.upload, "extract_composition_plan") }

    /// Uploading's price as the spec states it, with its words.
    static let uploadPrice: [(words: String, evidence: String)] = [
        ("Costs as much as generating a song this long", "Price for uploading is the same as the one for song generation."),
        ("half is still charged if copyrighted material is found", "If copyrighted content is detected, half of the request cost is still charged."),
    ]

    /// The note under Upload: what the upload costs, in the spec's terms.
    static var uploadCostNote: String {
        uploadPrice.map(\.words).joined(separator: "; ") + "."
    }

    func uploadArguments() -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [:]
        if !extractPlan.isEmpty { arguments["extract_composition_plan"] = .string(extractPlan) }
        if uploadTimestamps { arguments["with_timestamps"] = true }
        if uploadWaveform { arguments["with_waveform_visual"] = true }
        return arguments
    }

    func uploadSong() async {
        guard let uploadSource, CreativeRunGate.isKnown(uploadRunner) else { return }
        guard let result = await uploadRunner.perform(
            arguments: uploadArguments(), files: ["file": [ElevenLabsFile(url: uploadSource)]]
        ), let value = CreativeResults.json(in: result) else { return }
        uploadedSongID = value["song_id"].stringValue
        uploadDetails = MusicDetails(result: result)
        let plan = value["composition_plan"]
        if plan != .null { load(plan: plan) }
    }

    // MARK: - Fine-tunes

    var finetuneVisibilities: [String] { CreativeSpec.choices(Self.listFinetunes, "visibility") }
    var finetuneCreators: [String] { CreativeSpec.choices(Self.listFinetunes, "created_by") }
    var finetuneSorts: [String] { CreativeSpec.choices(Self.listFinetunes, "sort") }
    var finetuneSortDirections: [String] { CreativeSpec.choices(Self.listFinetunes, "sort_direction") }
    var settableVisibilities: [String] { CreativeSpec.choices(Self.createFinetune, "visibility") }

    func finetuneListArguments(cursor: String? = nil) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [:]
        if !finetuneVisibilityFilter.isEmpty { arguments["visibility"] = .string(finetuneVisibilityFilter) }
        if !finetuneCreatorFilter.isEmpty { arguments["created_by"] = .string(finetuneCreatorFilter) }
        if !finetuneSort.isEmpty { arguments["sort"] = .string(finetuneSort) }
        if !finetuneSortDirection.isEmpty { arguments["sort_direction"] = .string(finetuneSortDirection) }
        if let cursor {
            arguments["cursor"] = .string(cursor)
        }
        return arguments
    }

    func refreshFinetunes() async {
        await loadFinetunes(cursor: nil)
    }

    func loadMoreFinetunes() async {
        await loadFinetunes(cursor: finetuneCursor)
    }

    private func loadFinetunes(cursor: String?) async {
        let runner = runner(Self.listFinetunes)
        guard CreativeRunGate.isKnown(runner) else { return }
        guard case .json(let value, _)? = await runner.perform(arguments: finetuneListArguments(cursor: cursor)) else { return }
        let page = (value["finetunes"].arrayValue ?? []).compactMap(MusicFinetune.init(json:))
        finetunes = cursor == nil ? page : finetunes + page.filter { item in !finetunes.contains { $0.id == item.id } }
        finetuneCursor = value["next_cursor"].stringValue
        finetunesHaveMore = (value["has_more"].boolValue ?? false) && finetuneCursor != nil
    }

    /// Opens a fine-tune's details (free) and fills the edit fields.
    func select(_ finetune: MusicFinetune) async {
        selectedFinetune = finetune
        fillEdit(from: finetune)
        let runner = runner(Self.getFinetune)
        guard CreativeRunGate.isKnown(runner) else { return }
        if case .json(let value, _)? = await runner.perform(arguments: ["finetune_id": .string(finetune.id)]),
           let fresh = MusicFinetune(json: value), selectedFinetune?.id == fresh.id {
            selectedFinetune = fresh
            fillEdit(from: fresh)
            replace(fresh)
        }
    }

    private func fillEdit(from finetune: MusicFinetune) {
        editName = finetune.name
        editGenre = finetune.primaryGenre ?? ""
        editTags = finetune.tags
        editVisibility = finetune.visibility ?? ""
    }

    private func replace(_ finetune: MusicFinetune) {
        if let index = finetunes.firstIndex(where: { $0.id == finetune.id }) { finetunes[index] = finetune }
    }

    /// Only what changed is sent.
    func updateArguments() -> [String: JSONValue] {
        guard let current = selectedFinetune else { return [:] }
        var arguments: [String: JSONValue] = ["finetune_id": .string(current.id)]
        if editName != current.name { arguments["name"] = .string(editName) }
        if editGenre != (current.primaryGenre ?? "") { arguments["primary_genre"] = .string(editGenre) }
        if editTags != current.tags { arguments["tags"] = .array(editTags.map(JSONValue.string)) }
        if !editVisibility.isEmpty, editVisibility != current.visibility,
           settableVisibilities.contains(editVisibility) {
            arguments["visibility"] = .string(editVisibility)
        }
        return arguments
    }

    var editProblems: [String] {
        var problems: [String] = []
        if let min = CreativeSpec.minLength(Self.updateFinetune, "name"), editName.count < min {
            problems.append("The name needs at least \(min) characters.")
        }
        if let max = CreativeSpec.maxLength(Self.updateFinetune, "name"), editName.count > max {
            problems.append("The name takes at most \(max) characters.")
        }
        if let max = CreativeSpec.maxItems(Self.updateFinetune, "tags"), editTags.count > max {
            problems.append("At most \(max) tags.")
        }
        if updateArguments().count <= 1 { problems.append("Nothing has changed.") }
        return problems
    }

    func saveFinetune() async {
        let runner = runner(Self.updateFinetune)
        guard editProblems.isEmpty, CreativeRunGate.isKnown(runner) else { return }
        if case .json(let value, _)? = await runner.perform(arguments: updateArguments()),
           let updated = MusicFinetune(json: value) {
            selectedFinetune = updated
            replace(updated)
        }
    }

    func deleteSelectedFinetune() async {
        let runner = runner(Self.deleteFinetune)
        guard let finetune = selectedFinetune, CreativeRunGate.isKnown(runner) else { return }
        let done = await runner.perform(
            arguments: ["finetune_id": .string(finetune.id)],
            subject: "the fine-tune “\(finetune.name)”",
            consequence: "ElevenLabs will delete this fine-tune. Songs already made with it are kept; it cannot be used again."
        )
        guard done != nil else { return }
        finetunes.removeAll { $0.id == finetune.id }
        selectedFinetune = nil
        if finetuneID == finetune.id { finetuneID = "" }
    }

    var createProblems: [String] {
        var problems: [String] = []
        if let min = CreativeSpec.minLength(Self.createFinetune, "name"), newName.count < min {
            problems.append("The name needs at least \(min) characters.")
        }
        if let max = CreativeSpec.maxLength(Self.createFinetune, "name"), newName.count > max {
            problems.append("The name takes at most \(max) characters.")
        }
        if newGenre.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Name the primary genre.") }
        if newFiles.isEmpty { problems.append("Add the tracks to train on.") }
        if let max = CreativeSpec.maxItems(Self.createFinetune, "files"), newFiles.count > max {
            problems.append("At most \(max) tracks.")
        }
        return problems
    }

    func createArguments() -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            "name": .string(newName),
            "primary_genre": .string(newGenre.trimmingCharacters(in: .whitespaces)),
        ]
        if !newTags.isEmpty { arguments["tags"] = .array(newTags.map(JSONValue.string)) }
        if !newVisibility.isEmpty { arguments["visibility"] = .string(newVisibility) }
        if !newModelID.isEmpty { arguments["model_id"] = .string(newModelID) }
        return arguments
    }

    func createNewFinetune() async {
        let runner = runner(Self.createFinetune)
        guard createProblems.isEmpty, CreativeRunGate.isKnown(runner) else { return }
        guard case .json(let value, _)? = await runner.perform(
            arguments: createArguments(), files: ["files": newFiles.map { ElevenLabsFile(url: $0) }]
        ) else { return }
        if let created = MusicFinetune(json: value) {
            finetunes.insert(created, at: 0)
            selectedFinetune = created
            fillEdit(from: created)
        }
        newName = ""
        newGenre = ""
        newTags = []
        newFiles = []
    }

    func removeTake(_ take: CreativeTake) {
        takes.removeAll { $0.id == take.id }
        videoTakes.removeAll { $0.id == take.id }
        takeDetails[take.id] = nil
    }

    /// A music model in words, "(deprecated)" where the spec marks it so.
    static func modelTitle(_ id: String) -> String {
        CreativeSpec.choiceTitle(id, schemaTitle: "MusicModelID")
    }

    static func excerpt(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 60 ? String(flat.prefix(59)) + "…" : flat
    }
}

struct MusicScreen: View {
    @Bindable var screen: MusicScreenModel

    var body: some View {
        ElevenLabsSectionPage(.music) {
            CreativeTabs(selection: $screen.tab, tabs: MusicScreenModel.Tab.allCases, title: \.title)
            switch screen.tab {
            case .compose: MusicComposeTab(screen: screen)
            case .plan: MusicPlanTab(screen: screen)
            case .stems: MusicStemsTab(screen: screen)
            case .video: MusicVideoTab(screen: screen)
            case .finetunes: MusicFinetunesTab(screen: screen)
            case .upload: MusicUploadTab(screen: screen)
            }
        }
    }
}

private struct MusicComposeTab: View {
    @Bindable var screen: MusicScreenModel
    @State private var showsAdvanced = false

    var body: some View {
        CreativeCard("Song", systemImage: "music.note") {
            Picker("From", selection: $screen.usesPlan) {
                Text("A prompt").tag(false)
                Text("The plan").tag(true)
            }
            .pickerStyle(.segmented)
            if screen.usesPlan {
                if let plan = screen.plan {
                    Text("\(plan.sections.count) sections · \(ElevenLabsAudioPlayerView.clock(Double(plan.totalMs) / 1000)) · edit it under Plan")
                        .font(.callout).foregroundStyle(.secondary)
                } else if screen.planJSONValue != nil {
                    Text("A plan in JSON, from Plan.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Make a plan first") { screen.tab = .plan }
                }
            } else {
                ElevenLabsTextArea(text: $screen.prompt, prompt: "A warm lo-fi hip hop beat with soft piano, 80 bpm, for studying", minHeight: 80)
                Toggle("Instrumental only", isOn: $screen.forceInstrumental)
                Toggle("Set the length", isOn: $screen.usesLength)
                if screen.usesLength {
                    CreativeSlider(title: "Length", value: $screen.lengthSeconds, range: screen.lengthRange, step: 1,
                                   format: { ElevenLabsAudioPlayerView.clock($0) })
                }
                if !screen.generationModes.isEmpty {
                    Picker("Kind", selection: $screen.generationMode) {
                        Text("Let the model decide").tag("")
                        ForEach(screen.generationModes, id: \.self) { Text(ElevenLabsFormField.humanized($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Lyrics (optional)").font(.callout)
                ElevenLabsTextArea(text: $screen.lyrics, prompt: "Leave empty to let the model write them", minHeight: 60)
            }
        }
        CreativeCard("Model and output", systemImage: "waveform") {
            CreativeChoicePicker(title: "Model", selection: $screen.modelID, choices: screen.models,
                                 label: MusicScreenModel.modelTitle)
            Picker("Fine-tune", selection: $screen.finetuneID) {
                Text("None").tag("")
                ForEach(screen.finetunes.filter { $0.status == nil || $0.status == "completed" }) { Text($0.name).tag($0.id) }
                if !screen.finetuneID.isEmpty, !screen.finetunes.contains(where: { $0.id == screen.finetuneID }) {
                    Text(screen.finetuneID).tag(screen.finetuneID)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .task { if screen.finetunes.isEmpty { await screen.refreshFinetunes() } }
            if !screen.finetuneID.isEmpty {
                CreativeSlider(title: "Fine-tune strength", value: $screen.finetuneStrength, range: screen.strengthRange, step: 0.05,
                               defaultValue: CreativeSpec.defaultNumber(MusicScreenModel.compose, "finetune_strength"),
                               low: "Subtle", high: "Strong")
            }
            CreativeOutputFormatPicker(selection: $screen.outputFormat, choices: screen.outputFormats)
            Picker("Get", selection: $screen.delivery) {
                ForEach(MusicScreenModel.Delivery.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(screen.busyRunner != nil)
            if screen.isStreamed, !screen.streamsLive {
                Text("\(CreativeOutputFormat.title(screen.effectiveOutputFormat ?? "")) is not played as it arrives; the whole song is kept and plays when it is done.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if screen.isDetailed {
                Toggle("Lyrics timings", isOn: $screen.withTimestamps)
                Toggle("Waveform", isOn: $screen.withWaveform)
            }
        }
        CreativeCard {
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        CreativeOptionalIntegerField(title: "Seed", value: $screen.seed, range: CreativeSpec.range(MusicScreenModel.compose, "seed"))
                            .disabled(!screen.usesPlan)
                        Text("Only with a plan: ElevenLabs takes no seed with a prompt.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Keep each section's length exactly (music_v1 plans)", isOn: $screen.respectSectionsDurations)
                        .disabled(!screen.usesPlan)
                    Toggle("Spell names phonetically in the lyrics", isOn: $screen.usePhoneticNames)
                    Toggle("Keep the song for inpainting", isOn: $screen.storeForInpainting)
                    Toggle("Sign with C2PA (MP3 only)", isOn: $screen.signWithC2PA)
                }
                .padding(.top, 8)
            }
        }
        CreativeRunRow(runner: screen.activeComposeRunner, title: "Compose", estimatedSeconds: screen.estimatedSeconds, problems: screen.composeProblems) {
            Task { await screen.composeSong() }
        }
        MusicResultCard(screen: screen, runner: screen.busyRunner ?? screen.lastRunner, takes: screen.takes)
        CreativeTakesList(takes: Array(screen.takes.dropFirst())) { screen.removeTake($0) }
    }
}

private struct MusicResultCard: View {
    let screen: MusicScreenModel
    let runner: ElevenLabsRunner
    /// This tab's takes, newest first; the first is the one drawn.
    let takes: [CreativeTake]

    var body: some View {
        if runner.phase != .idle || takes.first != nil {
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
                if let take = takes.first {
                    let details = screen.details(of: take)
                    if let words = details?.words, !words.isEmpty {
                        CreativeTimedPlayer(url: take.file, words: words, title: take.title, showsSpeakers: false, contentType: take.contentType, outputFormat: take.outputFormat)
                            .id(take.file)
                    } else {
                        CreativeAudioResult(take: take)
                    }
                    if let waveform = details?.waveform, !waveform.isEmpty { MusicWaveform(samples: waveform) }
                    // The shell's meta line names the song of the run on screen; an older take's
                    // id is said here.
                    if let songID = details?.songID, runner.result?.meta.headers["song-id"] != songID {
                        Text("Song \(songID)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let metadata = details?.metadata {
                        DisclosureGroup("What the model used") {
                            ElevenLabsJSONTree(metadata, expandedDepth: 1)
                        }
                        .font(.callout)
                        if details?.plan != nil {
                            Button("Edit this plan") { screen.editReturnedPlan(of: take) }.controlSize(.small)
                        }
                    }
                    if let meta = runner.result?.meta { ElevenLabsMetaLine(meta: meta) }
                }
                ElevenLabsRunnerOutput(runner: runner, showsResult: false)
            }
        }
    }
}

private struct MusicPlanTab: View {
    @Bindable var screen: MusicScreenModel

    var body: some View {
        CreativeCard("Plan a song", systemImage: "list.bullet.rectangle") {
            ElevenLabsTextArea(text: $screen.planPrompt, prompt: "An upbeat pop song about a road trip, with a big final chorus", minHeight: 70)
            Toggle("Set the length", isOn: $screen.planUsesLength)
            if screen.planUsesLength {
                CreativeSlider(title: "Length", value: $screen.planLengthSeconds, range: screen.lengthRange, step: 1,
                               format: { ElevenLabsAudioPlayerView.clock($0) })
            }
            CreativeChoicePicker(title: "Model", selection: $screen.planModelID,
                                 choices: CreativeSpec.choices(MusicScreenModel.plan, "model_id"), label: MusicScreenModel.modelTitle)
            Toggle("Start from the plan below", isOn: $screen.planFromCurrent)
                .disabled(screen.planJSONValue == nil)
        }
        CreativeRunRow(runner: screen.planOperationRunner, title: "Make a plan", problems: screen.planProblems) {
            Task { await screen.makePlan() }
        }
        ElevenLabsRunnerOutput(runner: screen.planOperationRunner, showsResult: false)
        if screen.plan != nil || !screen.planJSON.isEmpty {
            CreativeCard("The plan", systemImage: "music.quarternote.3") {
                Button("Compose this") { screen.composeFromPlan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } content: {
                if screen.plan != nil {
                    MusicPlanEditor(
                        plan: Binding(get: { screen.plan ?? MusicPlan(positiveStyles: [], negativeStyles: [], sections: []) },
                                      set: { screen.plan = $0 }),
                        durationRange: CreativeSpec.range(MusicScreenModel.compose, "composition_plan.sections[].duration_ms") ?? 3000...120_000
                    )
                    let problems = screen.plan?.problems() ?? []
                    if !problems.isEmpty { ElevenLabsProblemList(problems: problems) }
                } else {
                    Text("This plan is in a shape edited as JSON.").font(.caption).foregroundStyle(.secondary)
                    ElevenLabsJSONEditor(text: $screen.planJSON, minHeight: 220)
                }
            }
        }
    }
}

private struct MusicStemsTab: View {
    @Bindable var screen: MusicScreenModel

    var body: some View {
        CreativeCard("Split a song into stems", systemImage: "square.3.layers.3d") {
            CreativeFileField(title: "Song", url: $screen.stemsSource, types: [.audio])
            CreativeChoicePicker(title: "Stems", selection: $screen.stemVariation, choices: screen.stemVariations) { id in
                id.hasPrefix("two") ? "Two — vocals and accompaniment" : id.hasPrefix("six") ? "Six — vocals, drums, bass, guitar, piano, other" : id
            }
            CreativeOutputFormatPicker(selection: $screen.stemsFormat, choices: CreativeSpec.choices(MusicScreenModel.stems, "output_format"))
            Toggle("Sign with C2PA (MP3 only)", isOn: $screen.stemsC2PA)
        }
        CreativeRunRow(runner: screen.stemsRunner, title: "Split", problems: screen.stemsSource == nil ? ["Choose a song."] : [],
                       note: "This can take a while for a long song. The stems arrive as one zip.") {
            Task { await screen.splitStems() }
        }
        ElevenLabsRunnerOutput(runner: screen.stemsRunner)
    }
}

private struct MusicVideoTab: View {
    @Bindable var screen: MusicScreenModel

    var body: some View {
        CreativeCard("Music for video", systemImage: "film") {
            CreativeFilesField(title: "Videos, in order", urls: $screen.videos, types: [.movie],
                               maxItems: CreativeSpec.maxItems(MusicScreenModel.videoToMusic, "videos"))
            ElevenLabsTextArea(text: $screen.videoDescription, prompt: "Optional: the mood you want", minHeight: 50)
            CreativeTagField(title: "Style tags", tags: $screen.videoTags, prompt: "upbeat, cinematic…",
                             maxItems: CreativeSpec.maxItems(MusicScreenModel.videoToMusic, "tags"))
            CreativeChoicePicker(title: "Model", selection: $screen.videoModelID,
                                 choices: CreativeSpec.choices(MusicScreenModel.videoToMusic, "model_id"), label: MusicScreenModel.modelTitle)
            CreativeOutputFormatPicker(selection: $screen.videoFormat, choices: CreativeSpec.choices(MusicScreenModel.videoToMusic, "output_format"))
            Toggle("Sign with C2PA (MP3 only)", isOn: $screen.videoC2PA)
        }
        CreativeRunRow(runner: screen.videoRunner, title: "Score it", problems: screen.videoProblems) {
            Task { await screen.scoreVideo() }
        }
        MusicResultCard(screen: screen, runner: screen.videoRunner, takes: screen.videoTakes)
        CreativeTakesList(takes: Array(screen.videoTakes.dropFirst())) { screen.removeTake($0) }
    }
}

private struct MusicUploadTab: View {
    @Bindable var screen: MusicScreenModel

    var body: some View {
        CreativeCard("Upload a song to build on", systemImage: "square.and.arrow.up") {
            CreativeFileField(title: "Song", url: $screen.uploadSource, types: [.audio])
            Picker("Extract its plan", selection: $screen.extractPlan) {
                Text("No").tag("")
                ForEach(screen.extractChoices, id: \.self) { Text("As \($0)").tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Toggle("Lyrics timings", isOn: $screen.uploadTimestamps)
            Toggle("Waveform", isOn: $screen.uploadWaveform)
        }
        CreativeRunRow(
            runner: screen.uploadRunner, title: "Upload",
            estimatedSeconds: screen.uploadSource.flatMap(CreativeMedia.duration(of:)),
            problems: screen.uploadSource == nil ? ["Choose a song."] : [], note: MusicScreenModel.uploadCostNote
        ) {
            Task { await screen.uploadSong() }
        }
        ElevenLabsRunnerOutput(runner: screen.uploadRunner, showsResult: false)
        if let songID = screen.uploadedSongID {
            CreativeCard("Uploaded", systemImage: "checkmark.circle") {
                LabeledContent("Song id") { Text(songID).textSelection(.enabled) }
                if let waveform = screen.uploadDetails?.waveform, !waveform.isEmpty { MusicWaveform(samples: waveform) }
                if let words = screen.uploadDetails?.words, !words.isEmpty {
                    Text(CreativeTimeline.join(words.map(\.text))).font(.callout).textSelection(.enabled).lineLimit(6)
                }
                if screen.plan != nil || !screen.planJSON.isEmpty {
                    Button("Open its plan") { screen.tab = .plan }.controlSize(.small)
                }
            }
        }
    }
}

private struct MusicFinetunesTab: View {
    @Bindable var screen: MusicScreenModel

    var body: some View {
        CreativeCard("Fine-tunes", systemImage: "dial.medium") {
            Button {
                Task { await screen.refreshFinetunes() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(screen.runner(MusicScreenModel.listFinetunes).isRunning)
        } content: {
            CreativeFlowLayout(spacing: 10) {
                filterPicker("Visibility", selection: $screen.finetuneVisibilityFilter, choices: screen.finetuneVisibilities)
                filterPicker("Made by", selection: $screen.finetuneCreatorFilter, choices: screen.finetuneCreators)
                Picker("Sort", selection: $screen.finetuneSort) {
                    ForEach(screen.finetuneSorts, id: \.self) { Text(ElevenLabsFormField.humanized($0)).tag($0) }
                }
                .fixedSize()
                Picker("Order", selection: $screen.finetuneSortDirection) {
                    ForEach(screen.finetuneSortDirections, id: \.self) { Text($0 == "asc" ? "Ascending" : "Descending").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .onChange(of: [screen.finetuneVisibilityFilter, screen.finetuneCreatorFilter, screen.finetuneSort, screen.finetuneSortDirection]) {
                Task { await screen.refreshFinetunes() }
            }
            ForEach(screen.finetunes) { finetune in
                Button {
                    Task { await screen.select(finetune) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: screen.selectedFinetune?.id == finetune.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(screen.selectedFinetune?.id == finetune.id ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(finetune.name)
                            Text([finetune.primaryGenre, finetune.modelID, finetune.visibility, finetune.createdBy].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        statusBadge(finetune)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if screen.finetunesHaveMore {
                Button("Load more") { Task { await screen.loadMoreFinetunes() } }.controlSize(.small)
            }
            ElevenLabsRunnerOutput(runner: screen.runner(MusicScreenModel.listFinetunes), showsResult: false)
        }
        .task { if screen.finetunes.isEmpty { await screen.refreshFinetunes() } }
        if let selected = screen.selectedFinetune { editCard(selected) }
        createCard
    }

    private func filterPicker(_ title: String, selection: Binding<String>, choices: [String]) -> some View {
        Picker(title, selection: selection) {
            Text("Any").tag("")
            ForEach(choices, id: \.self) { Text(ElevenLabsFormField.humanized($0)).tag($0) }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func statusBadge(_ finetune: MusicFinetune) -> some View {
        if let status = finetune.status {
            if status == "in_progress", let progress = finetune.progress {
                ProgressView(value: progress).frame(width: 60)
            }
            Text(ElevenLabsFormField.humanized(status))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((status == "completed" ? Color.green : status == "failed" || status == "blocked" ? .red : .orange).opacity(0.15), in: .capsule)
        }
    }

    private func editCard(_ finetune: MusicFinetune) -> some View {
        CreativeCard(finetune.name, systemImage: "pencil") {
            Button("Use to compose") {
                screen.finetuneID = finetune.id
                screen.tab = .compose
            }
            .controlSize(.small)
            .disabled(finetune.status != nil && finetune.status != "completed")
        } content: {
            if let reason = finetune.failureReason {
                Text(reason).font(.caption).foregroundStyle(.red)
            }
            if finetune.isOwn {
                LabeledContent("Name") {
                    TextField("Name", text: $screen.editName).textFieldStyle(.roundedBorder).labelsHidden()
                }
                LabeledContent("Primary genre") {
                    TextField("Primary genre", text: $screen.editGenre).textFieldStyle(.roundedBorder).labelsHidden()
                }
                CreativeTagField(title: "Tags", tags: $screen.editTags, maxItems: CreativeSpec.maxItems(MusicScreenModel.updateFinetune, "tags"))
                CreativeChoicePicker(title: "Visibility", selection: $screen.editVisibility, choices: screen.settableVisibilities)
                HStack {
                    CreativeRunRow(runner: screen.runner(MusicScreenModel.updateFinetune), title: "Save changes", problems: screen.editProblems) {
                        Task { await screen.saveFinetune() }
                    }
                    Spacer()
                    Button("Delete…", role: .destructive) { Task { await screen.deleteSelectedFinetune() } }
                        .disabled(screen.runner(MusicScreenModel.deleteFinetune).isRunning)
                }
                ElevenLabsRunnerOutput(runner: screen.runner(MusicScreenModel.updateFinetune), showsResult: false)
                ElevenLabsRunnerOutput(runner: screen.runner(MusicScreenModel.deleteFinetune), showsResult: false)
            } else {
                Text("Made by \(finetune.createdBy ?? "someone else"); only its owner can change it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var createCard: some View {
        CreativeCard("Train a new fine-tune", systemImage: "plus.circle") {
            LabeledContent("Name") {
                TextField("Name", text: $screen.newName, prompt: Text("At least \(CreativeSpec.minLength(MusicScreenModel.createFinetune, "name") ?? 5) characters"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
            }
            LabeledContent("Primary genre") {
                TextField("Primary genre", text: $screen.newGenre, prompt: Text("e.g. synthwave"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
            }
            CreativeFilesField(title: "Tracks to train on", urls: $screen.newFiles, types: [.audio],
                               maxItems: CreativeSpec.maxItems(MusicScreenModel.createFinetune, "files"))
            CreativeTagField(title: "Tags", tags: $screen.newTags)
            CreativeChoicePicker(title: "Visibility", selection: $screen.newVisibility, choices: screen.settableVisibilities)
            CreativeChoicePicker(title: "Base model", selection: $screen.newModelID,
                                 choices: CreativeSpec.choices(MusicScreenModel.createFinetune, "model_id"), label: MusicScreenModel.modelTitle)
            CreativeRunRow(runner: screen.runner(MusicScreenModel.createFinetune), title: "Train", problems: screen.createProblems) {
                Task { await screen.createNewFinetune() }
            }
            ElevenLabsRunnerOutput(runner: screen.runner(MusicScreenModel.createFinetune), showsResult: false)
        }
    }
}

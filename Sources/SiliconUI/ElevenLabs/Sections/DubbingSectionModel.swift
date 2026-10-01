import Foundation
import Observation
import SiliconElevenLabs

// MARK: - Data

/// A dub from `GET /v1/dubbing`.
struct DubbingDub: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var status: String
    var sourceLanguage: String?
    var targetLanguages: [String]
    var createdAt: String?
    var duration: Double?
    var mediaType: String?
    var error: String?
    var editable: Bool?

    init?(json: JSONValue) {
        guard let id = json["dubbing_id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? id
        status = json["status"].stringValue ?? "unknown"
        sourceLanguage = json["source_language"].stringValue
        targetLanguages = json["target_languages"].arrayValue?.compactMap(\.stringValue) ?? []
        createdAt = json["created_at"].stringValue
        duration = json["media_metadata"]["duration"].doubleValue
        mediaType = json["media_metadata"]["content_type"].stringValue
        error = json["error"].stringValue
        editable = json["editable"].boolValue
    }

    var isFinished: Bool { status == "dubbed" }
}

/// A dubbing project from the projects API.
struct DubbingProject: Identifiable, Hashable, Sendable {
    var id: String
    var status: String
    var reference: String?
    var sourceLanguage: String?
    var modelID: String?
    var fileName: String?
    var duration: Double?
    var hasVideo: Bool?
    var languageIDs: [String]
    var revision: Int?
    var error: String?
    var warnings: [String]
    var createdAt: String?

    init?(json: JSONValue) {
        guard let id = json["project_id"].stringValue else { return nil }
        self.id = id
        status = json["status"].stringValue ?? "unknown"
        reference = json["reference"].stringValue
        sourceLanguage = json["source_language"].stringValue
        modelID = json["model_id"].stringValue
        fileName = json["media"]["filename"].stringValue
        duration = json["media"]["duration_s"].doubleValue
        hasVideo = json["media"]["has_video"].boolValue
        languageIDs = json["language_ids"].arrayValue?.compactMap(\.stringValue) ?? []
        revision = json["revision"].intValue
        error = json["error"]["message"].stringValue
        warnings = (json["warnings"].arrayValue ?? []).compactMap { $0["message"].stringValue }
        createdAt = json["created_at"].stringValue
    }

    var title: String { reference.flatMap { $0.isEmpty ? nil : $0 } ?? fileName ?? id }
}

/// One language a project is dubbed into.
struct DubbingLanguage: Identifiable, Hashable, Sendable {
    var id: String
    var targetLanguage: String
    var status: String
    var cloningStrength: Int?
    /// A signed download link, valid for an hour after it was issued.
    var losslessAudio: URL?
    var error: String?

    init?(json: JSONValue) {
        guard let id = json["language_id"].stringValue else { return nil }
        self.id = id
        targetLanguage = json["target_language"].stringValue ?? "?"
        status = json["status"].stringValue ?? "unknown"
        cloningStrength = json["voice_settings"]["cloning_strength"].intValue
        losslessAudio = json["outputs"]["lossless_audio"].stringValue.flatMap(URL.init(string:)).flatMap {
            $0.scheme == "https" ? $0 : nil
        }
        error = json["error"]["message"].stringValue
    }
}

/// A transcript segment: the source's text, or a target's translation beside it.
struct DubbingSegment: Identifiable, Hashable, Sendable {
    var id: String
    var speakerID: String
    var start: Double
    var end: Double
    var text: String
    var translation: String?

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        speakerID = json["speaker_id"].stringValue ?? ""
        start = json["start_s"].doubleValue ?? 0
        end = json["end_s"].doubleValue ?? 0
        text = json["text"].stringValue ?? json["source_text"].stringValue ?? ""
        translation = json["translation"].stringValue
    }
}

// MARK: - Drafts

struct DubbingDraft: Hashable, Sendable {
    var name = ""
    var files: [URL] = []
    var sourceURL = ""
    var sourceLanguage = ""
    var targetLanguage = ""
    var speakers = ""
    var startTime = ""
    var endTime = ""
    var watermark = false
    var highestResolution = false
    var dropBackgroundAudio = false
    var profanityFilter = false
    var dubbingStudio = false
    var disableVoiceCloning = false
    var targetAccent = ""
    var mode = ""
    var csvFile: [URL] = []
    var csvFPS = ""
    var foregroundAudio: [URL] = []
    var backgroundAudio: [URL] = []
}

struct DubbingSegmentDraft: Hashable, Sendable {
    var speaker = ""
    var start = ""
    var end = ""
    var text = ""
}

struct DubbingProjectDraft: Hashable, Sendable {
    var files: [URL] = []
    var sourceURL = ""
    var sourceLanguage = ""
    var targetLanguage = ""
    var modelID = ""
    var keyterms = ""
    var reference = ""
    var webhookIDs = ""
    var transcript: [URL] = []
}

// MARK: - Model

/// Dubbing: dub a file or a link into another language and fetch the result, and the
/// dubbing-projects API with its per-language targets and editable transcripts.
@MainActor
@Observable
final class DubbingSectionModel {

    enum Mode: String, CaseIterable, Identifiable {
        case dubs, projects
        var id: String { rawValue }
        var title: String { self == .dubs ? "Dubs" : "Dubbing projects" }
    }

    let actions: VoicesStudioActions
    var mode: Mode = .dubs

    // Dubs
    var draft = DubbingDraft()
    var statusFilter = ""
    var creatorFilter = ""
    private(set) var dubs: [DubbingDub] = []
    private(set) var dubsHaveMore = false
    @ObservationIgnored private var dubsCursor: String?
    private(set) var loadedDubs = false
    private(set) var selectedDub: DubbingDub?
    var downloadLanguage = ""
    private(set) var downloads: [String: VoicesStudioFile] = [:]
    var transcriptLanguage = "source"
    var transcriptFormat = "srt"
    private(set) var transcript: String?
    private(set) var transcriptUtterances: [JSONValue] = []

    // Projects
    var projectDraft = DubbingProjectDraft()
    var projectStatusFilter = ""
    private(set) var projects: [DubbingProject] = []
    private(set) var projectsHaveMore = false
    @ObservationIgnored private var projectsCursor: String?
    private(set) var loadedProjects = false
    private(set) var selectedProject: DubbingProject?
    private(set) var languages: [DubbingLanguage] = []
    var newLanguage = ""
    var setsCloningStrength = false
    var cloningStrength: Double = 7
    private(set) var sourceSegments: [DubbingSegment] = []
    private(set) var selectedLanguageID: String?
    private(set) var targetSegments: [DubbingSegment] = []
    /// Unsaved edits: segment id → new text (source) or translation (target).
    var sourceEdits: [String: String] = [:]
    var targetEdits: [String: String] = [:]
    var newSegment = DubbingSegmentDraft()

    init(environment: VoicesStudioEnvironment) {
        actions = VoicesStudioActions(context: environment.context)
        actions.readsShownInPlace = ["list_dubs", "dubbing_project_list"]
        cloningStrength = VoicesStudioSchema.defaultNumber("dubbing_language_create", "voice_settings.cloning_strength") ?? 7
        // A dub, project, language or regeneration whose answer was lost: fetch the lists
        // again, so the owner can see whether it was started.
        actions.onUnknownOutcome = { [weak self] operationID in
            guard let self else { return }
            if operationID == "create_dubbing" {
                await refreshDubs()
            } else {
                await refreshProjects()
                if let id = selectedProject?.id { await selectProject(id) }
            }
        }
    }

    /// What the dubbing buttons say they cost — the spec's own words, nothing about length.
    enum CostNote {
        static let dub = "Uses credits from your ElevenLabs balance."
        static let project = "Charges for one language up front, before any output exists; "
            + "each further language is charged separately."
        static let language = "Billed per generation; the project's first language was paid for when it was created."
        static let regenerate = "Enterprise only. Re-synthesizes only the edited regions, charged like a "
            + "generation, less the free-regeneration allowance."
    }

    // MARK: Spec

    /// The project statuses `dubbing_project_list`'s `status` describes.
    static let projectStatuses = ["queued", "preparing", "ready", "failed"]

    static let controls: [VoicesStudioControl] = [
        .init("create_dubbing", "name"),
        .init("create_dubbing", "file"),
        .init("create_dubbing", "source_url"),
        .init("create_dubbing", "source_lang"),
        .init("create_dubbing", "target_lang"),
        .init("create_dubbing", "num_speakers"),
        .init("create_dubbing", "start_time"),
        .init("create_dubbing", "end_time"),
        .init("create_dubbing", "watermark"),
        .init("create_dubbing", "highest_resolution"),
        .init("create_dubbing", "drop_background_audio"),
        .init("create_dubbing", "use_profanity_filter"),
        .init("create_dubbing", "dubbing_studio"),
        .init("create_dubbing", "disable_voice_cloning"),
        .init("create_dubbing", "target_accent"),
        .init("create_dubbing", "mode", enumerated: true),
        .init("create_dubbing", "csv_file"),
        .init("create_dubbing", "csv_fps"),
        .init("create_dubbing", "foreground_audio_file"),
        .init("create_dubbing", "background_audio_file"),
        .init("list_dubs", "dubbing_status", enumerated: true),
        .init("list_dubs", "filter_by_creator", enumerated: true),
        .init("list_dubs", "cursor"),
        .init("list_dubs", "page_size"),
        .init("get_dubbed_metadata", "dubbing_id"),
        .init("get_dubbed_file", "language_code"),
        .init("get_dubbing_transcripts", "language_code", describedValues: ["source"]),
        .init("get_dubbing_transcripts", "format_type", enumerated: true),
        .init("delete_dubbing", "dubbing_id"),
        .init("dubbing_project_create", "file"),
        .init("dubbing_project_create", "source_url"),
        .init("dubbing_project_create", "source_language"),
        .init("dubbing_project_create", "target_language"),
        .init("dubbing_project_create", "model_id", enumerated: true),
        .init("dubbing_project_create", "keyterms"),
        .init("dubbing_project_create", "reference"),
        .init("dubbing_project_create", "webhook_ids"),
        .init("dubbing_project_create", "transcript"),
        .init("dubbing_project_list", "status", describedValues: projectStatuses),
        .init("dubbing_project_list", "cursor"),
        .init("dubbing_project_get", "project_id"),
        .init("dubbing_project_delete", "project_id"),
        .init("dubbing_language_create", "target_language"),
        .init("dubbing_language_create", "voice_settings.cloning_strength"),
        .init("dubbing_language_list", "project_id"),
        .init("dubbing_language_get", "language_id"),
        .init("dubbing_language_delete", "language_id"),
        .init("dubbing_transcript_get", "project_id"),
        .init("dubbing_transcript_segment_update", "text"),
        .init("dubbing_transcript_segments_update", "segments"),
        .init("dubbing_transcript_segment_add", "speaker_id"),
        .init("dubbing_transcript_segment_add", "start_s"),
        .init("dubbing_transcript_segment_add", "end_s"),
        .init("dubbing_transcript_segment_add", "text"),
        .init("dubbing_transcript_segment_delete", "segment_id"),
        .init("dubbing_target_transcript_get", "language_id"),
        .init("dubbing_target_transcript_segment_update", "translation"),
        .init("dubbing_target_transcript_segments_update", "segments"),
        .init("dubbing_target_transcript_regenerate", "language_id"),
    ]

    static let callsWithoutControls: Set<String> = []

    private static let resource = "Deprecated Dubbing Studio resource API; the dubbing-projects API the section uses replaces it."
    static let explorerOnly: [String: String] = [
        "get_dubbed_transcript_file": "Deprecated in the spec; the section fetches transcripts and subtitles with GET /v1/dubbing/{dubbing_id}/transcripts/{language_code}/format/{format_type}.",
        "get_dubbing_resource": resource,
        "add_language": resource,
        "create_clip": resource,
        "update_segment_language": resource,
        "migrate_segments": resource,
        "delete_segment": resource,
        "transcribe": resource,
        "translate": resource,
        "dub": resource,
        "update_speaker": resource,
        "create_speaker": resource,
        "get_similar_voices_for_speaker": resource,
        "render": resource,
    ]

    var dubStatuses: [String] { VoicesStudioSchema.choices("list_dubs", "dubbing_status") }
    var creatorFilters: [String] { VoicesStudioSchema.choices("list_dubs", "filter_by_creator") }
    var transcriptFormats: [String] { VoicesStudioSchema.choices("get_dubbing_transcripts", "format_type") }
    var dubModes: [String] { VoicesStudioSchema.choices("create_dubbing", "mode") }
    var projectModels: [String] { VoicesStudioSchema.choices("dubbing_project_create", "model_id") }
    static var cloningRange: ClosedRange<Double> {
        VoicesStudioSchema.range("dubbing_language_create", "voice_settings.cloning_strength") ?? 0...10
    }

    // MARK: Dubs

    nonisolated static func dubArguments(_ draft: DubbingDraft) -> ([String: JSONValue], [String: [ElevenLabsFile]], [String]) {
        var arguments: [String: JSONValue] = [:]
        var files: [String: [ElevenLabsFile]] = [:]
        var problems: [String] = []
        let url = draft.sourceURL.trimmingCharacters(in: .whitespaces)
        if draft.files.isEmpty, url.isEmpty { problems.append("Choose a file or give a link to dub.") }
        if !draft.files.isEmpty, !url.isEmpty { problems.append("Dub a file or a link, not both.") }
        if draft.targetLanguage.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("Say which language to dub into.")
        }
        if let file = draft.files.first { files["file"] = [ElevenLabsFile(url: file)] }
        arguments.voicesStudioSet("source_url", VoicesStudioFormat.text(url))
        arguments.voicesStudioSet("name", VoicesStudioFormat.text(draft.name))
        arguments.voicesStudioSet("source_lang", VoicesStudioFormat.text(draft.sourceLanguage))
        arguments.voicesStudioSet("target_lang", VoicesStudioFormat.text(draft.targetLanguage))
        arguments.voicesStudioSet("target_accent", VoicesStudioFormat.text(draft.targetAccent))
        for (key, text) in [("num_speakers", draft.speakers), ("start_time", draft.startTime), ("end_time", draft.endTime)] {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let number = Int(trimmed) { arguments[key] = .number(Double(number)) } else {
                problems.append("\(VoicesStudioFormat.words(key)) must be a whole number.")
            }
        }
        for (key, flag) in [("watermark", draft.watermark), ("highest_resolution", draft.highestResolution),
                            ("drop_background_audio", draft.dropBackgroundAudio),
                            ("use_profanity_filter", draft.profanityFilter), ("dubbing_studio", draft.dubbingStudio),
                            ("disable_voice_cloning", draft.disableVoiceCloning)] where flag {
            arguments[key] = true
        }
        arguments.voicesStudioSet("mode", VoicesStudioFormat.text(draft.mode))
        if draft.mode == "manual" {
            if let csv = draft.csvFile.first { files["csv_file"] = [ElevenLabsFile(url: csv)] }
            if let fps = Double(draft.csvFPS.trimmingCharacters(in: .whitespaces)) { arguments["csv_fps"] = .number(fps) }
            if let foreground = draft.foregroundAudio.first { files["foreground_audio_file"] = [ElevenLabsFile(url: foreground)] }
            if let background = draft.backgroundAudio.first { files["background_audio_file"] = [ElevenLabsFile(url: background)] }
        }
        return (arguments, files, problems)
    }

    private(set) var draftProblems: [String] = []

    func createDub() async {
        let (arguments, files, problems) = Self.dubArguments(draft)
        draftProblems = problems
        guard problems.isEmpty,
              let json = await actions.perform("create_dubbing", arguments, files: files, title: "Dub \(draft.name)")?
                .voicesStudioJSON, let id = json["dubbing_id"].stringValue
        else { return }
        draft = DubbingDraft()
        let chosen = wantedDub
        await refreshDubs()
        // The new dub is opened unless the owner opened another meanwhile.
        guard wantedDub == chosen else { return }
        await selectDub(id)
    }

    func dubListArguments(cursor: String?) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["page_size": 50]
        arguments.voicesStudioSet("dubbing_status", VoicesStudioFormat.text(statusFilter))
        arguments.voicesStudioSet("filter_by_creator", VoicesStudioFormat.text(creatorFilter))
        arguments.voicesStudioSet("cursor", cursor.map(JSONValue.string))
        return arguments
    }

    var dubsProblem: String? { actions.problem("list_dubs") }
    var listingDubs: Bool { actions.isRunning("list_dubs") }

    func refreshDubs() async {
        guard let json = await actions.perform("list_dubs", dubListArguments(cursor: nil), quietly: true)?
            .voicesStudioJSON else { return }
        dubs = (json["dubs"].arrayValue ?? []).compactMap(DubbingDub.init(json:))
        dubsCursor = json["next_cursor"].stringValue
        dubsHaveMore = json["has_more"].boolValue == true && dubsCursor != nil
        loadedDubs = true
    }

    func moreDubs() async {
        guard dubsHaveMore, let cursor = dubsCursor,
              let json = await actions.perform("list_dubs", dubListArguments(cursor: cursor), quietly: true)?
                .voicesStudioJSON else { return }
        let known = Set(dubs.map(\.id))
        dubs += (json["dubs"].arrayValue ?? []).compactMap(DubbingDub.init(json:)).filter { !known.contains($0.id) }
        dubsCursor = json["next_cursor"].stringValue
        dubsHaveMore = json["has_more"].boolValue == true && dubsCursor != nil
    }

    /// The dub and project last asked for: an answer that arrives after another was chosen is
    /// dropped, so a slow fetch never puts an old choice back on screen.
    @ObservationIgnored private var wantedDub: String?
    @ObservationIgnored private var wantedProject: String?

    func selectDub(_ id: String?) async {
        wantedDub = id
        guard let id else {
            selectedDub = nil
            return
        }
        if selectedDub?.id != id {
            selectedDub = dubs.first { $0.id == id }
            downloads = [:]
            transcript = nil
            transcriptUtterances = []
            downloadLanguage = selectedDub?.targetLanguages.first ?? ""
        }
        guard let json = await actions.perform("get_dubbed_metadata", ["dubbing_id": .string(id)], quietly: true)?
            .voicesStudioJSON, let dub = DubbingDub(json: json) else { return }
        if let index = dubs.firstIndex(where: { $0.id == id }) { dubs[index] = dub } else { dubs.insert(dub, at: 0) }
        guard wantedDub == id else { return }
        selectedDub = dub
        if downloadLanguage.isEmpty { downloadLanguage = dub.targetLanguages.first ?? "" }
    }

    /// Downloaded files, by dub and language — a download that finishes after another dub was
    /// chosen stays with its own dub.
    func downloaded(_ dubID: String?, _ language: String) -> VoicesStudioFile? {
        dubID.flatMap { downloads["\($0)|\(language)"] }
    }

    func download() async {
        let language = downloadLanguage
        guard let dub = selectedDub, !language.isEmpty,
              let file = await actions.perform(
                "get_dubbed_file", ["dubbing_id": .string(dub.id), "language_code": .string(language)],
                title: "\(dub.name) in \(language)"
              )?.voicesStudioFiles.first else { return }
        downloads["\(dub.id)|\(language)"] = file
    }

    func loadTranscript() async {
        guard let dub = selectedDub,
              let result = await actions.perform(
                "get_dubbing_transcripts",
                ["dubbing_id": .string(dub.id), "language_code": .string(transcriptLanguage),
                 "format_type": .string(transcriptFormat)],
                title: "Transcript of \(dub.name) (\(transcriptLanguage), \(transcriptFormat))"
              ) else { return }
        guard selectedDub?.id == dub.id else { return }
        if let json = result.voicesStudioJSON {
            transcript = json["srt"].stringValue ?? json["webvtt"].stringValue
            transcriptUtterances = json["json"]["utterances"].arrayValue ?? []
            if transcript == nil, transcriptUtterances.isEmpty { transcript = json.jsonString(pretty: true) }
        } else {
            transcript = result.voicesStudioText
        }
    }

    func deleteDub() async {
        guard let dub = selectedDub else { return }
        guard await actions.perform(
            "delete_dubbing", ["dubbing_id": .string(dub.id)], subject: "the dub “\(dub.name)”"
        ) != nil else { return }
        dubs.removeAll { $0.id == dub.id }
        // Clear the screen only if it still shows the deleted dub.
        if selectedDub?.id == dub.id {
            selectedDub = nil
            wantedDub = nil
        }
    }

    // MARK: Projects

    nonisolated static func projectArguments(_ draft: DubbingProjectDraft) -> ([String: JSONValue], [String: [ElevenLabsFile]], [String]) {
        var arguments: [String: JSONValue] = [:]
        var files: [String: [ElevenLabsFile]] = [:]
        var problems: [String] = []
        let url = draft.sourceURL.trimmingCharacters(in: .whitespaces)
        if draft.files.isEmpty, url.isEmpty { problems.append("Choose a file or give a link to dub.") }
        if !draft.files.isEmpty, !url.isEmpty { problems.append("Use a file or a link, not both.") }
        if let file = draft.files.first { files["file"] = [ElevenLabsFile(url: file)] }
        if let transcript = draft.transcript.first { files["transcript"] = [ElevenLabsFile(url: transcript)] }
        arguments.voicesStudioSet("source_url", VoicesStudioFormat.text(url))
        arguments.voicesStudioSet("source_language", VoicesStudioFormat.text(draft.sourceLanguage))
        arguments.voicesStudioSet("target_language", VoicesStudioFormat.text(draft.targetLanguage))
        arguments.voicesStudioSet("model_id", VoicesStudioFormat.text(draft.modelID))
        arguments.voicesStudioSet("reference", VoicesStudioFormat.text(draft.reference))
        let keyterms = VoicesStudioFormat.list(draft.keyterms)
        if !keyterms.isEmpty { arguments["keyterms"] = .array(keyterms.map(JSONValue.string)) }
        let webhooks = VoicesStudioFormat.list(draft.webhookIDs)
        if !webhooks.isEmpty { arguments["webhook_ids"] = .array(webhooks.map(JSONValue.string)) }
        return (arguments, files, problems)
    }

    private(set) var projectProblems: [String] = []

    func createProject() async {
        let (arguments, files, problems) = Self.projectArguments(projectDraft)
        projectProblems = problems
        let chosen = wantedProject
        guard problems.isEmpty,
              let json = await actions.perform("dubbing_project_create", arguments, files: files, title: "Dubbing project")?
                .voicesStudioJSON, let project = DubbingProject(json: json)
        else { return }
        projectDraft = DubbingProjectDraft()
        projects.insert(project, at: 0)
        guard wantedProject == chosen else { return }
        await selectProject(project.id)
    }

    var projectsProblem: String? { actions.problem("dubbing_project_list") }
    var listingProjects: Bool { actions.isRunning("dubbing_project_list") }

    func projectListArguments(cursor: String?) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["page_size": 50]
        arguments.voicesStudioSet("status", VoicesStudioFormat.text(projectStatusFilter))
        arguments.voicesStudioSet("cursor", cursor.map(JSONValue.string))
        return arguments
    }

    func refreshProjects() async {
        guard let json = await actions.perform("dubbing_project_list", projectListArguments(cursor: nil), quietly: true)?
            .voicesStudioJSON else { return }
        projects = (json["projects"].arrayValue ?? []).compactMap(DubbingProject.init(json:))
        projectsCursor = json["next_cursor"].stringValue
        projectsHaveMore = projectsCursor != nil
        loadedProjects = true
    }

    func moreProjects() async {
        guard let cursor = projectsCursor,
              let json = await actions.perform("dubbing_project_list", projectListArguments(cursor: cursor), quietly: true)?
                .voicesStudioJSON else { return }
        let known = Set(projects.map(\.id))
        projects += (json["projects"].arrayValue ?? []).compactMap(DubbingProject.init(json:)).filter { !known.contains($0.id) }
        projectsCursor = json["next_cursor"].stringValue
        projectsHaveMore = projectsCursor != nil
    }

    func selectProject(_ id: String?) async {
        wantedProject = id
        guard let id else {
            selectedProject = nil
            return
        }
        if selectedProject?.id != id {
            selectedProject = projects.first { $0.id == id }
            languages = []
            sourceSegments = []
            targetSegments = []
            selectedLanguageID = nil
            sourceEdits = [:]
            targetEdits = [:]
            newSegment = DubbingSegmentDraft()   // its speaker and times belong to the previous project
            lastRegeneration = nil
        }
        if let json = await actions.perform("dubbing_project_get", ["project_id": .string(id)], quietly: true)?
            .voicesStudioJSON, let project = DubbingProject(json: json) {
            if let index = projects.firstIndex(where: { $0.id == id }) { projects[index] = project }
            guard wantedProject == id else { return }
            selectedProject = project
        }
        guard wantedProject == id else { return }
        await loadLanguages()
    }

    func loadLanguages() async {
        guard let project = selectedProject,
              let json = await actions.perform(
                "dubbing_language_list", ["project_id": .string(project.id), "page_size": 100], quietly: true
              )?.voicesStudioJSON, selectedProject?.id == project.id else { return }
        languages = (json["languages"].arrayValue ?? []).compactMap(DubbingLanguage.init(json:))
    }

    func refreshLanguage(_ language: DubbingLanguage) async {
        guard let project = selectedProject,
              let json = await actions.perform(
                "dubbing_language_get", ["project_id": .string(project.id), "language_id": .string(language.id)],
                quietly: true
              )?.voicesStudioJSON, let fresh = DubbingLanguage(json: json), selectedProject?.id == project.id,
              let index = languages.firstIndex(where: { $0.id == language.id })
        else { return }
        languages[index] = fresh
    }

    func addLanguageArguments() -> [String: JSONValue]? {
        guard let project = selectedProject else { return nil }
        var arguments: [String: JSONValue] = [
            "project_id": .string(project.id),
            "target_language": .string(newLanguage.trimmingCharacters(in: .whitespaces)),
        ]
        if setsCloningStrength {
            arguments["voice_settings"] = ["cloning_strength": .number(cloningStrength.rounded())]
        }
        return arguments
    }

    /// Whether `projectID` is still the project the owner has open — the only one whose list
    /// and typing a finished change may reload or clear.
    private func isOpen(_ projectID: String) -> Bool { wantedProject == projectID && selectedProject?.id == projectID }

    func addLanguage() async {
        guard let arguments = addLanguageArguments(), let projectID = selectedProject?.id,
              await actions.perform("dubbing_language_create", arguments, title: "Dub into \(newLanguage)") != nil,
              isOpen(projectID)
        else { return }
        newLanguage = ""
        await loadLanguages()
    }

    func deleteLanguage(_ language: DubbingLanguage) async {
        guard let project = selectedProject,
              await actions.perform(
                "dubbing_language_delete", ["project_id": .string(project.id), "language_id": .string(language.id)],
                subject: "the \(language.targetLanguage) dub of “\(project.title)”"
              ) != nil else { return }
        languages.removeAll { $0.id == language.id }
        if selectedLanguageID == language.id {
            selectedLanguageID = nil
            targetSegments = []
        }
    }

    func deleteProject() async {
        guard let project = selectedProject,
              await actions.perform(
                "dubbing_project_delete", ["project_id": .string(project.id)],
                subject: "the dubbing project “\(project.title)”",
                consequence: "The project, every language dubbed from it and their transcripts are deleted."
              ) != nil else { return }
        projects.removeAll { $0.id == project.id }
        if selectedProject?.id == project.id {
            selectedProject = nil
            wantedProject = nil
        }
    }

    // MARK: Transcripts

    /// Loads the source transcript. The owner's own "Load the original" (`sent` nil) drops every
    /// unsaved edit. After a change (`sent` is what that change sent, empty for one that sent no
    /// edits) the edits typed since stay over the fresh segments; an edit that was sent, whose
    /// segment is gone, or that the fresh text now matches is dropped.
    func loadSourceTranscript(keepingEditsBut sent: [String: String]? = nil) async {
        guard let project = selectedProject,
              let json = await actions.perform("dubbing_transcript_get", ["project_id": .string(project.id)], quietly: true)?
                .voicesStudioJSON, selectedProject?.id == project.id else { return }
        sourceSegments = (json["segments"].arrayValue ?? []).compactMap(DubbingSegment.init(json:))
        sourceEdits = sent.map { Self.unsaved(sourceEdits, sent: $0, over: sourceSegments) { $0.text } } ?? [:]
    }

    /// The target transcript of `languageID`; `sent` as for `loadSourceTranscript`.
    func loadTargetTranscript(_ languageID: String, keepingEditsBut sent: [String: String]? = nil) async {
        guard let project = selectedProject,
              let json = await actions.perform(
                "dubbing_target_transcript_get",
                ["project_id": .string(project.id), "language_id": .string(languageID)], quietly: true
              )?.voicesStudioJSON, selectedProject?.id == project.id else { return }
        let sameLanguage = selectedLanguageID == languageID
        selectedLanguageID = languageID
        targetSegments = (json["segments"].arrayValue ?? []).compactMap(DubbingSegment.init(json:))
        targetEdits = sameLanguage
            ? sent.map { Self.unsaved(targetEdits, sent: $0, over: targetSegments) { $0.translation ?? "" } } ?? [:]
            : [:]
    }

    /// `edits` less those `sent` carried, those whose segment is gone and those `text` of the
    /// fresh segment now matches: what the owner typed that is still unsaved.
    static func unsaved(
        _ edits: [String: String], sent: [String: String], over segments: [DubbingSegment],
        text: (DubbingSegment) -> String
    ) -> [String: String] {
        let fresh = Dictionary(segments.map { ($0.id, text($0)) }, uniquingKeysWith: { first, _ in first })
        return edits.filter { id, edit in sent[id] != edit && fresh[id].map { $0 != edit } == true }
    }

    /// One edit goes through the single-segment route; several go in one request.
    func sourceSaveCall() -> (operationID: String, arguments: [String: JSONValue])? {
        guard let project = selectedProject, !sourceEdits.isEmpty else { return nil }
        if sourceEdits.count == 1, let (id, text) = sourceEdits.first {
            return ("dubbing_transcript_segment_update",
                    ["project_id": .string(project.id), "segment_id": .string(id), "text": .string(text)])
        }
        let segments = sourceEdits.mapValues { JSONValue.object(["text": .string($0)]) }
        return ("dubbing_transcript_segments_update", ["project_id": .string(project.id), "segments": .object(segments)])
    }

    func targetSaveCall() -> (operationID: String, arguments: [String: JSONValue])? {
        guard let project = selectedProject, let languageID = selectedLanguageID, !targetEdits.isEmpty else { return nil }
        if targetEdits.count == 1, let (id, text) = targetEdits.first {
            return ("dubbing_target_transcript_segment_update",
                    ["project_id": .string(project.id), "language_id": .string(languageID),
                     "segment_id": .string(id), "translation": .string(text)])
        }
        let segments = targetEdits.mapValues { JSONValue.object(["translation": .string($0)]) }
        return ("dubbing_target_transcript_segments_update",
                ["project_id": .string(project.id), "language_id": .string(languageID), "segments": .object(segments)])
    }

    func saveSourceEdits() async {
        let sent = sourceEdits
        guard let call = sourceSaveCall(), let projectID = selectedProject?.id,
              await actions.perform(call.operationID, call.arguments, title: "Transcript edits") != nil,
              isOpen(projectID) else { return }
        // Edits typed while the save was on its way are not part of it, and stay.
        await loadSourceTranscript(keepingEditsBut: sent)
    }

    func saveTargetEdits() async {
        let sent = targetEdits
        guard let call = targetSaveCall(), let languageID = selectedLanguageID, let projectID = selectedProject?.id,
              await actions.perform(call.operationID, call.arguments, title: "Translation edits") != nil else { return }
        // Reload only while the same project and language are open.
        guard isOpen(projectID), selectedLanguageID == languageID else { return }
        await loadTargetTranscript(languageID, keepingEditsBut: sent)
    }

    func deleteSegment(_ segment: DubbingSegment) async {
        guard let project = selectedProject,
              await actions.perform(
                "dubbing_transcript_segment_delete",
                ["project_id": .string(project.id), "segment_id": .string(segment.id)],
                subject: "the segment “\(segment.text.prefix(40))”"
              ) != nil, isOpen(project.id) else { return }
        await loadSourceTranscript(keepingEditsBut: [:])
    }

    func addSegmentArguments() -> [String: JSONValue]? {
        guard let project = selectedProject,
              let start = Double(newSegment.start.trimmingCharacters(in: .whitespaces)),
              let end = Double(newSegment.end.trimmingCharacters(in: .whitespaces)),
              !newSegment.speaker.isEmpty, !newSegment.text.isEmpty
        else { return nil }
        return ["project_id": .string(project.id), "speaker_id": .string(newSegment.speaker),
                "start_s": .number(start), "end_s": .number(end), "text": .string(newSegment.text)]
    }

    func addSegment() async {
        guard let arguments = addSegmentArguments(), let projectID = selectedProject?.id,
              await actions.perform("dubbing_transcript_segment_add", arguments, title: "New segment") != nil,
              isOpen(projectID)
        else { return }
        newSegment = DubbingSegmentDraft()
        await loadSourceTranscript(keepingEditsBut: [:])
    }

    /// What the last regeneration charged, as its answer says: seconds charged and the free
    /// regeneration seconds left.
    private(set) var lastRegeneration: (charged: Double, freeLeft: Double)?

    /// Why Regenerate is held: it re-dubs from the translation ElevenLabs holds, and "returns a
    /// conflict when the target has no edits to apply".
    var regenerateHold: String? {
        targetEdits.isEmpty ? nil : "Save the edits first: regenerating re-dubs the translation ElevenLabs holds."
    }

    func regenerate() async {
        guard let project = selectedProject, let languageID = selectedLanguageID,
              let language = languages.first(where: { $0.id == languageID }),
              let json = await actions.perform(
                "dubbing_target_transcript_regenerate",
                ["project_id": .string(project.id), "language_id": .string(languageID)],
                title: "Regenerate \(language.targetLanguage)"
              )?.voicesStudioJSON, isOpen(project.id) else { return }
        if let charged = json["charged_seconds"].doubleValue {
            lastRegeneration = (charged, json["free_regeneration_seconds_remaining"].doubleValue ?? 0)
        }
        await refreshLanguage(language)
    }

    // MARK: Test support

    func load(dubs: [DubbingDub], selected: DubbingDub? = nil) {
        self.dubs = dubs
        selectedDub = selected
        wantedDub = selected?.id
        loadedDubs = true
    }

    func load(projects: [DubbingProject], selected: DubbingProject? = nil, languages: [DubbingLanguage] = [],
              source: [DubbingSegment] = [], target: [DubbingSegment] = [], languageID: String? = nil) {
        self.projects = projects
        selectedProject = selected
        wantedProject = selected?.id
        self.languages = languages
        sourceSegments = source
        targetSegments = target
        selectedLanguageID = languageID
        loadedProjects = true
    }

    func load(transcript: String) {
        self.transcript = transcript
    }
}

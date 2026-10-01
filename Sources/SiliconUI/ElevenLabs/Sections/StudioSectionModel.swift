import Foundation
import Observation
import SiliconElevenLabs

// MARK: - Data

/// A Studio project, from the list or with its details.
struct StudioProject: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var title: String?
    var author: String?
    var description: String?
    var state: String
    var createdAt: Int?
    var lastConversion: Int?
    var canBeDownloaded: Bool
    var defaultTitleVoiceID: String?
    var defaultParagraphVoiceID: String?
    var defaultModelID: String?
    var language: String?
    var qualityPreset: String?
    var sourceType: String?
    var isbn: String?
    var volumeNormalization: Bool
    var chapters: [StudioChapter]
    /// Attached pronunciation dictionaries: id and version.
    var dictionaries: [StudioDictionaryLocator]

    init?(json: JSONValue) {
        guard let id = json["project_id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        title = json["title"].stringValue
        author = json["author"].stringValue
        description = json["description"].stringValue
        state = json["state"].stringValue ?? "default"
        createdAt = json["create_date_unix"].intValue
        lastConversion = json["last_conversion_date_unix"].intValue
        canBeDownloaded = json["can_be_downloaded"].boolValue ?? false
        defaultTitleVoiceID = json["default_title_voice_id"].stringValue
        defaultParagraphVoiceID = json["default_paragraph_voice_id"].stringValue
        defaultModelID = json["default_model_id"].stringValue
        language = json["language"].stringValue
        qualityPreset = json["quality_preset"].stringValue
        sourceType = json["source_type"].stringValue
        isbn = json["isbn_number"].stringValue
        volumeNormalization = json["volume_normalization"].boolValue ?? false
        chapters = (json["chapters"].arrayValue ?? []).compactMap(StudioChapter.init(json:))
        dictionaries = (json["pronunciation_dictionary_locators"].arrayValue ?? []).compactMap(StudioDictionaryLocator.init(json:))
    }

    /// Credits ElevenLabs says converting what is left will take, when every chapter says.
    var creditsToConvert: Int? {
        let known = chapters.compactMap(\.creditsToConvert)
        return known.isEmpty ? nil : known.reduce(0, +)
    }
}

struct StudioChapter: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var state: String
    var progress: Double?
    var canBeDownloaded: Bool
    var charactersConverted: Int?
    var charactersUnconverted: Int?
    var creditsToConvert: Int?
    var lastError: String?
    /// Paragraphs, when the chapter was fetched with its content.
    var blocks: [StudioBlock]

    init?(json: JSONValue) {
        guard let id = json["chapter_id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        state = json["state"].stringValue ?? "default"
        progress = json["conversion_progress"].doubleValue
        canBeDownloaded = json["can_be_downloaded"].boolValue ?? false
        charactersConverted = json["statistics"]["characters_converted"].intValue
        charactersUnconverted = json["statistics"]["characters_unconverted"].intValue
        creditsToConvert = json["statistics"]["credits_needed_to_convert"].intValue
        lastError = json["last_conversion_error"].stringValue
        blocks = (json["content"]["blocks"].arrayValue ?? []).compactMap(StudioBlock.init(json:))
    }
}

/// One paragraph of a chapter: its text-to-speech pieces, each with its voice.
struct StudioBlock: Identifiable, Hashable, Sendable {
    struct Node: Hashable, Sendable {
        var text: String
        var voiceID: String
    }

    var id: String
    var nodes: [Node]
    /// A block holding a kind of node the input model cannot write back.
    var hasOtherNodes: Bool

    init?(json: JSONValue) {
        guard let id = json["block_id"].stringValue else { return nil }
        self.id = id
        let all = json["nodes"].arrayValue ?? []
        nodes = all.compactMap { node in
            guard node["type"].stringValue == "tts_node" else { return nil }
            return Node(text: node["text"].stringValue ?? "", voiceID: node["voice_id"].stringValue ?? "")
        }
        hasOtherNodes = nodes.count != all.count
    }

    var text: String { nodes.map(\.text).joined() }
}

struct StudioDictionaryLocator: Hashable, Sendable {
    var id: String
    var versionID: String

    init(id: String, versionID: String) {
        self.id = id
        self.versionID = versionID
    }

    init?(json: JSONValue) {
        guard let id = json["pronunciation_dictionary_id"].stringValue,
              let version = json["version_id"].stringValue else { return nil }
        self.init(id: id, versionID: version)
    }

    var json: JSONValue { ["pronunciation_dictionary_id": .string(id), "version_id": .string(versionID)] }
}

/// A pronunciation dictionary the owner can attach.
struct StudioDictionary: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var latestVersionID: String
}

struct StudioSnapshot: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var createdAt: Int?
    var chapterID: String?

    init?(json: JSONValue) {
        guard let id = json["project_snapshot_id"].stringValue ?? json["chapter_snapshot_id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        createdAt = json["created_at_unix"].intValue
        chapterID = json["chapter_id"].stringValue
    }
}

// MARK: - Drafts

struct StudioProjectDraft: Hashable, Sendable {
    enum Source: String, CaseIterable, Identifiable, Sendable {
        case blank, url, document
        var id: String { rawValue }
        var title: String {
            switch self {
            case .blank: "Blank"
            case .url: "From a web page"
            case .document: "From a document"
            }
        }
    }

    var name = ""
    var source: Source = .blank
    var url = ""
    var document: [URL] = []
    var title = ""
    var author = ""
    var description = ""
    var language = ""
    var titleVoiceID = ""
    var paragraphVoiceID = ""
    var modelID = ""
    var qualityPreset = ""
    var sourceType = ""
    var targetAudience = ""
    var fiction = ""
    var genres = ""
    var isbn = ""
    var publicationDate = ""
    var matureContent = false
    var volumeNormalization = false
    var autoConvert = false
    var autoAssignVoices = false
    var textNormalization = ""
    var callbackURL = ""
    var dictionaries: [StudioDictionaryLocator] = []
}

struct StudioPodcastDraft: Hashable, Sendable {
    var conversation = true
    var hostVoiceID = ""
    var guestVoiceID = ""
    var fromURL = false
    var text = ""
    var url = ""
    var modelID = ""
    var qualityPreset = ""
    var durationScale = ""
    var language = ""
    var intro = ""
    var outro = ""
    var instructions = ""
    /// One highlight per line.
    var highlights = ""
    var callbackURL = ""
    var textNormalization = ""
}

struct StudioEditDraft: Hashable, Sendable {
    var name = ""
    var title = ""
    var author = ""
    var isbn = ""
    var titleVoiceID = ""
    var paragraphVoiceID = ""
    var volumeNormalization = false

    init() {}

    init(project: StudioProject) {
        name = project.name
        title = project.title ?? ""
        author = project.author ?? ""
        isbn = project.isbn ?? ""
        titleVoiceID = project.defaultTitleVoiceID ?? ""
        paragraphVoiceID = project.defaultParagraphVoiceID ?? ""
        volumeNormalization = project.volumeNormalization
    }

    /// `fresh`'s fields, except those the owner changed since the form held `base` — what it was
    /// filled with, or what a save sent: that typing is kept.
    func merged(over fresh: StudioEditDraft, base: StudioEditDraft) -> StudioEditDraft {
        var result = fresh
        if name != base.name { result.name = name }
        if title != base.title { result.title = title }
        if author != base.author { result.author = author }
        if isbn != base.isbn { result.isbn = isbn }
        if titleVoiceID != base.titleVoiceID { result.titleVoiceID = titleVoiceID }
        if paragraphVoiceID != base.paragraphVoiceID { result.paragraphVoiceID = paragraphVoiceID }
        if volumeNormalization != base.volumeNormalization { result.volumeNormalization = volumeNormalization }
        return result
    }
}

// MARK: - Model

/// Studio: long-form projects and their chapters, converting them to audio, snapshots to
/// play and download, pronunciation dictionaries, and podcasts made from text or a page.
@MainActor
@Observable
final class StudioSectionModel {

    enum Mode: String, CaseIterable, Identifiable {
        case projects, podcast
        var id: String { rawValue }
        var title: String { self == .projects ? "Projects" : "New podcast" }
    }

    let actions: VoicesStudioActions
    let directory: ElevenLabsVoiceDirectory
    var mode: Mode = .projects

    private(set) var projects: [StudioProject] = []
    private(set) var loadedOnce = false
    private(set) var selected: StudioProject?
    var editDraft = StudioEditDraft()
    /// What the settings form held when it was last filled from the project, or what a save
    /// sent: a field that differs from it is the owner's typing, kept when the project is
    /// fetched again.
    @ObservationIgnored private var editBase = StudioEditDraft()
    /// Counts the times the settings form was filled afresh (another project chosen): a save
    /// that went out before a refill does not speak for the form any more.
    @ObservationIgnored private var editFills = 0
    var draft = StudioProjectDraft()
    var showsNewProject = false
    private(set) var projectSnapshots: [StudioSnapshot] = []
    private(set) var mutedChapters: [String] = []
    private(set) var snapshotAudio: [String: VoicesStudioFile] = [:]
    private(set) var snapshotDurations: [String: Double] = [:]
    var contentURL = ""
    var contentDocument: [URL] = []
    var contentAutoConvert = false

    private(set) var chapter: StudioChapter?
    var chapterName = ""
    /// Edited paragraph text by block id.
    var blockEdits: [String: String] = [:]
    private(set) var chapterSnapshots: [StudioSnapshot] = []
    var newChapterName = ""
    var newChapterURL = ""

    private(set) var dictionaries: [StudioDictionary] = []
    var invalidateAffectedText = true
    private(set) var speechModels: [VoicesStudioSpeechModel] = []

    var podcast = StudioPodcastDraft()
    private(set) var problems: [String] = []

    init(environment: VoicesStudioEnvironment) {
        actions = VoicesStudioActions(context: environment.context)
        actions.readsShownInPlace = ["get_projects"]
        directory = environment.voices
        // A conversion, podcast or project whose answer was lost: fetch the projects (and the
        // open one) again, so the owner can see whether it was made.
        actions.onUnknownOutcome = { [weak self] _ in
            await self?.refresh()
            if let id = self?.selected?.id { await self?.reloadSelected(id) }
        }
    }

    // MARK: Spec

    static let controls: [VoicesStudioControl] = [
        .init("add_project", "name"),
        .init("add_project", "from_url"),
        .init("add_project", "from_document"),
        .init("add_project", "title"),
        .init("add_project", "author"),
        .init("add_project", "description"),
        .init("add_project", "language"),
        .init("add_project", "default_title_voice_id"),
        .init("add_project", "default_paragraph_voice_id"),
        .init("add_project", "default_model_id"),
        .init("add_project", "quality_preset", enumerated: true),
        .init("add_project", "source_type", enumerated: true),
        .init("add_project", "target_audience", enumerated: true),
        .init("add_project", "fiction", enumerated: true),
        .init("add_project", "genres"),
        .init("add_project", "isbn_number"),
        .init("add_project", "original_publication_date"),
        .init("add_project", "mature_content"),
        .init("add_project", "volume_normalization"),
        .init("add_project", "auto_convert"),
        .init("add_project", "auto_assign_voices"),
        .init("add_project", "apply_text_normalization", enumerated: true),
        .init("add_project", "callback_url"),
        .init("add_project", "pronunciation_dictionary_locators"),
        .init("get_project_by_id", "project_id"),
        .init("edit_project", "name"),
        .init("edit_project", "title"),
        .init("edit_project", "author"),
        .init("edit_project", "isbn_number"),
        .init("edit_project", "default_title_voice_id"),
        .init("edit_project", "default_paragraph_voice_id"),
        .init("edit_project", "volume_normalization"),
        .init("edit_project_content", "from_url"),
        .init("edit_project_content", "from_document"),
        .init("edit_project_content", "auto_convert"),
        .init("delete_project", "project_id"),
        .init("convert_project_endpoint", "project_id"),
        .init("get_project_snapshots", "project_id"),
        .init("get_project_snapshot_endpoint", "project_snapshot_id"),
        .init("stream_project_snapshot_audio_endpoint", "convert_to_mpeg"),
        .init("stream_project_snapshot_archive_endpoint", "project_snapshot_id"),
        .init("get_project_muted_tracks_endpoint", "project_id"),
        .init("get_chapters", "project_id"),
        .init("get_chapter_by_id_endpoint", "chapter_id"),
        .init("add_chapter", "name"),
        .init("add_chapter", "from_url"),
        .init("edit_chapter", "name"),
        .init("edit_chapter", "content.blocks[].block_id"),
        .init("edit_chapter", "content.blocks[].nodes"),
        .init("delete_chapter_endpoint", "chapter_id"),
        .init("convert_chapter_endpoint", "chapter_id"),
        .init("get_chapter_snapshots", "chapter_id"),
        .init("get_chapter_snapshot_endpoint", "chapter_snapshot_id"),
        .init("stream_chapter_snapshot_audio", "convert_to_mpeg"),
        .init("update_pronunciation_dictionaries", "pronunciation_dictionary_locators[].pronunciation_dictionary_id"),
        .init("update_pronunciation_dictionaries", "pronunciation_dictionary_locators[].version_id"),
        .init("update_pronunciation_dictionaries", "invalidate_affected_text"),
        .init("create_podcast", "model_id"),
        .init("create_podcast", "mode.conversation.host_voice_id"),
        .init("create_podcast", "mode.conversation.guest_voice_id"),
        .init("create_podcast", "mode.bulletin.host_voice_id"),
        .init("create_podcast", "source.text"),
        .init("create_podcast", "source.url"),
        .init("create_podcast", "quality_preset", enumerated: true),
        .init("create_podcast", "duration_scale", enumerated: true),
        .init("create_podcast", "language"),
        .init("create_podcast", "intro"),
        .init("create_podcast", "outro"),
        .init("create_podcast", "instructions_prompt"),
        .init("create_podcast", "highlights"),
        .init("create_podcast", "callback_url"),
        .init("create_podcast", "apply_text_normalization", enumerated: true),
    ]

    /// `get_models` for the model pickers and `get_pronunciation_dictionaries_metadata` for the
    /// dictionaries to attach; neither takes anything the owner sets here.
    static let callsWithoutControls: Set<String> = ["get_projects", "get_models", "get_pronunciation_dictionaries_metadata"]
    static let explorerOnly: [String: String] = [:]

    func choices(_ operationID: String, _ argument: String) -> [String] {
        VoicesStudioSchema.choices(operationID, argument)
    }

    // MARK: Projects

    var listProblem: String? { actions.problem("get_projects") }
    var isListing: Bool { actions.isRunning("get_projects") }

    func refresh() async {
        guard let json = await actions.perform("get_projects", quietly: true)?.voicesStudioJSON else { return }
        projects = (json["projects"].arrayValue ?? []).compactMap(StudioProject.init(json:))
        loadedOnce = true
    }

    func refreshIfNeeded() async {
        guard !loadedOnce else { return }
        await refresh()
        speechModels = await actions.speechModels()
        await loadDictionaries()
    }

    func loadDictionaries() async {
        guard let json = await actions.perform(
            "get_pronunciation_dictionaries_metadata", ["page_size": 100], quietly: true
        )?.voicesStudioJSON else { return }
        dictionaries = (json["pronunciation_dictionaries"].arrayValue ?? []).compactMap { entry in
            guard let id = entry["id"].stringValue, let version = entry["latest_version_id"].stringValue else { return nil }
            return StudioDictionary(id: id, name: entry["name"].stringValue ?? id, latestVersionID: version)
        }
    }

    nonisolated static func projectArguments(_ draft: StudioProjectDraft) -> ([String: JSONValue], [String: [ElevenLabsFile]], [String]) {
        var arguments: [String: JSONValue] = [:]
        var files: [String: [ElevenLabsFile]] = [:]
        var problems: [String] = []
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { problems.append("Give the project a name.") }
        arguments["name"] = .string(name)
        switch draft.source {
        case .blank: break
        case .url:
            if let url = VoicesStudioFormat.text(draft.url) { arguments["from_url"] = url } else {
                problems.append("Give the page to read from.")
            }
        case .document:
            if let document = draft.document.first { files["from_document"] = [ElevenLabsFile(url: document)] } else {
                problems.append("Choose the document to read from.")
            }
        }
        for (key, value) in [
            ("title", draft.title), ("author", draft.author), ("description", draft.description),
            ("language", draft.language), ("default_title_voice_id", draft.titleVoiceID),
            ("default_paragraph_voice_id", draft.paragraphVoiceID), ("default_model_id", draft.modelID),
            ("quality_preset", draft.qualityPreset), ("source_type", draft.sourceType),
            ("target_audience", draft.targetAudience), ("fiction", draft.fiction), ("isbn_number", draft.isbn),
            ("original_publication_date", draft.publicationDate), ("apply_text_normalization", draft.textNormalization),
            ("callback_url", draft.callbackURL),
        ] {
            arguments.voicesStudioSet(key, VoicesStudioFormat.text(value))
        }
        let genres = VoicesStudioFormat.list(draft.genres)
        if !genres.isEmpty { arguments["genres"] = .array(genres.map(JSONValue.string)) }
        for (key, flag) in [("mature_content", draft.matureContent), ("volume_normalization", draft.volumeNormalization),
                            ("auto_convert", draft.autoConvert), ("auto_assign_voices", draft.autoAssignVoices)] where flag {
            arguments[key] = true
        }
        // A multipart form: each locator goes as its own JSON text, as the spec describes.
        if !draft.dictionaries.isEmpty {
            arguments["pronunciation_dictionary_locators"] = .array(draft.dictionaries.map { .string($0.json.jsonString()) })
        }
        return (arguments, files, problems)
    }

    func createProject() async {
        let (arguments, files, problems) = Self.projectArguments(draft)
        self.problems = problems
        let chosen = wantedProject
        guard problems.isEmpty,
              let json = await actions.perform(
                "add_project", arguments, files: files, title: "Studio project \(draft.name)",
                // "Convert now" starts a conversion: this create spends credits, and waits like one.
                spends: draft.autoConvert
              )?.voicesStudioJSON, let project = StudioProject(json: json["project"])
        else { return }
        draft = StudioProjectDraft()
        showsNewProject = false
        projects.insert(project, at: 0)
        // The new project is opened unless the owner opened another meanwhile.
        guard wantedProject == chosen else { return }
        await select(project.id)
    }

    /// The project and chapter last chosen: an answer that arrives after another was chosen is
    /// dropped.
    @ObservationIgnored private var wantedProject: String?
    @ObservationIgnored private var wantedChapter: String?

    /// Changes to each project that have answered, by project id. A read asked before one of
    /// them answered is older than it — even when it answers later, on another runner — and is
    /// dropped whole: the fetch after the change brings the newer project.
    @ObservationIgnored private var landed: [String: Int] = [:]

    /// The project whose own details the settings form and the dictionary switches show: until
    /// they arrive, they show the list row's values, which may be older than ElevenLabs'.
    private(set) var detailsIn: String?

    /// Whether the open project's details are in, so its settings and dictionaries may be saved:
    /// those calls send every field (every attached dictionary), and before then the untouched
    /// ones would be the list row's.
    var detailsAreIn: Bool {
        guard let id = selected?.id else { return false }
        return detailsIn == id && wantedProject == id
    }

    /// Why the open project's settings cannot be saved yet, when they cannot.
    var waitingForDetails: String? {
        guard selected != nil, !detailsAreIn else { return nil }
        return actions.problem("get_project_by_id") == nil
            ? "Waiting for this project's details." : "Its details could not be read — open it again."
    }

    func select(_ projectID: String?) async {
        wantedProject = projectID
        guard let projectID else {
            selected = nil
            return
        }
        if selected?.id != projectID {
            selected = projects.first { $0.id == projectID }
            detailsIn = nil
            if let selected { fillEdit(from: selected) }
            chapter = nil
            projectSnapshots = []
            chapterSnapshots = []
            snapshotAudio = [:]
            mutedChapters = []
        }
        await reloadSelected(projectID)
        guard wantedProject == projectID else { return }
        await loadSnapshots()
        await loadMutedTracks()
    }

    func reloadSelected(_ projectID: String? = nil, slot: String? = nil) async {
        guard let projectID = projectID ?? selected?.id else { return }
        let changesBefore = landed[projectID, default: 0]
        guard let json = await actions.perform("get_project_by_id", ["project_id": .string(projectID)], quietly: true,
                                               slot: slot)?
                .voicesStudioJSON, let project = StudioProject(json: json),
              // Asked before a change to the project answered: older than it, dropped whole.
              landed[projectID, default: 0] == changesBefore
        else { return }
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        guard wantedProject == projectID else { return }
        selected = project
        // Field by field: what the owner typed since the form was filled (or since a save went
        // out, typing while it was on its way) stays; untouched fields take the fresh values.
        let fresh = StudioEditDraft(project: project)
        editDraft = editDraft.merged(over: fresh, base: editBase)
        editBase = fresh
        detailsIn = project.id
    }

    private func fillEdit(from project: StudioProject) {
        editDraft = StudioEditDraft(project: project)
        editBase = editDraft
        editFills += 1
    }

    /// After a change to `projectID`: fetch it again, onto the screen (and into its settings
    /// form) only while it is still the project open — its own runner, so the read of a project
    /// opened meanwhile is not abandoned.
    private func refetch(_ projectID: String) async {
        landed[projectID, default: 0] += 1
        await reloadSelected(projectID, slot: VoicesStudioActions.afterChange(of: projectID))
    }

    /// Whether `projectID` is still the project the owner has open — the only one whose chapter
    /// list a finished change reloads and whose typing it clears.
    private func isOpen(_ projectID: String) -> Bool { wantedProject == projectID && selected?.id == projectID }

    /// Reloads just the chapter list, as `GET …/chapters` gives it.
    func reloadChapters() async {
        guard let project = selected,
              let json = await actions.perform("get_chapters", ["project_id": .string(project.id)], quietly: true)?
                .voicesStudioJSON, selected?.id == project.id else { return }
        selected?.chapters = (json["chapters"].arrayValue ?? []).compactMap(StudioChapter.init(json:))
    }

    func loadMutedTracks() async {
        guard let project = selected,
              let json = await actions.perform(
                "get_project_muted_tracks_endpoint", ["project_id": .string(project.id)], quietly: true
              )?.voicesStudioJSON, selected?.id == project.id else { return }
        mutedChapters = json["chapter_ids"].arrayValue?.compactMap(\.stringValue) ?? []
    }

    func editArguments() -> [String: JSONValue]? {
        guard let project = selected else { return nil }
        var arguments: [String: JSONValue] = [
            "project_id": .string(project.id), "name": .string(editDraft.name),
            "default_title_voice_id": .string(editDraft.titleVoiceID),
            "default_paragraph_voice_id": .string(editDraft.paragraphVoiceID),
            "volume_normalization": .bool(editDraft.volumeNormalization),
        ]
        arguments.voicesStudioSet("title", VoicesStudioFormat.text(editDraft.title))
        arguments.voicesStudioSet("author", VoicesStudioFormat.text(editDraft.author))
        arguments.voicesStudioSet("isbn_number", VoicesStudioFormat.text(editDraft.isbn))
        return arguments
    }

    func saveEdit() async {
        guard detailsAreIn else { return }
        let sent = editDraft
        let fills = editFills
        guard let arguments = editArguments(), let projectID = arguments["project_id"]?.stringValue,
              await actions.perform("edit_project", arguments, title: "Edit \(editDraft.name)") != nil else { return }
        // The project now holds what was sent; anything else in the form was typed since.
        if isOpen(projectID), editFills == fills { editBase = sent }
        await refetch(projectID)
    }

    /// The question before the content is replaced: the spec initialises the project from the
    /// new page or document, so every chapter — and the owner's edits in them — goes.
    func replaceQuestion() -> VoicesStudioQuestion? {
        guard let project = selected else { return nil }
        let source = contentDocument.first.map { "“\($0.lastPathComponent)”" }
            ?? VoicesStudioFormat.text(contentURL)?.stringValue.map { "the page \($0)" } ?? "nothing"
        let chapters = project.chapters.count
        return VoicesStudioQuestion(
            "Replace everything in “\(project.name)” with \(source)?", button: "Replace content",
            consequence: "Its \(chapters == 1 ? "1 chapter" : "\(chapters) chapters") and your edits in them are replaced "
                + "by what ElevenLabs reads from \(source)."
                + (contentAutoConvert ? " It is then converted, which uses credits." : "")
        )
    }

    func updateContent() async {
        guard let project = selected, let question = replaceQuestion() else { return }
        var arguments: [String: JSONValue] = ["project_id": .string(project.id)]
        arguments.voicesStudioSet("from_url", VoicesStudioFormat.text(contentURL))
        if contentAutoConvert { arguments["auto_convert"] = true }
        let files = contentDocument.first.map { ["from_document": [ElevenLabsFile(url: $0)]] } ?? [:]
        guard await actions.perform(
            "edit_project_content", arguments, files: files, title: "New content for \(project.name)",
            spends: contentAutoConvert, question: question
        ) != nil else { return }
        if isOpen(project.id) {
            contentURL = ""
            contentDocument = []
        }
        await refetch(project.id)
    }

    func convert() async {
        guard let project = selected,
              await actions.perform("convert_project_endpoint", ["project_id": .string(project.id)],
                                    title: "Convert \(project.name)") != nil else { return }
        await refetch(project.id)
    }

    func delete() async {
        guard let project = selected,
              await actions.perform(
                "delete_project", ["project_id": .string(project.id)], subject: "the Studio project “\(project.name)”",
                consequence: "“\(project.name)”, its chapters, snapshots and converted audio are deleted."
              ) != nil else { return }
        projects.removeAll { $0.id == project.id }
        // Clear the screen only if it still shows the deleted project.
        if selected?.id == project.id {
            selected = nil
            wantedProject = nil
        }
    }

    // MARK: Dictionaries

    func attachArguments(_ locators: [StudioDictionaryLocator]) -> [String: JSONValue]? {
        guard let project = selected else { return nil }
        return ["project_id": .string(project.id),
                "pronunciation_dictionary_locators": .array(locators.map(\.json)),
                "invalidate_affected_text": .bool(invalidateAffectedText)]
    }

    func setDictionary(_ dictionary: StudioDictionary, attached: Bool) async {
        // The call replaces every attached dictionary: it starts from the project's own list.
        guard detailsAreIn, var locators = selected?.dictionaries else { return }
        locators.removeAll { $0.id == dictionary.id }
        if attached { locators.append(StudioDictionaryLocator(id: dictionary.id, versionID: dictionary.latestVersionID)) }
        guard let arguments = attachArguments(locators), let projectID = arguments["project_id"]?.stringValue,
              await actions.perform("update_pronunciation_dictionaries", arguments,
                                    title: "Dictionaries of \(selected?.name ?? "")") != nil else { return }
        // ElevenLabs now holds exactly the list just sent. Until the fetch below lands, the list on
        // screen would be the one before this change — and the next switch, which sends the whole
        // list, would undo it — so the project takes the list sent at once.
        if isOpen(projectID) { selected?.dictionaries = locators }
        await refetch(projectID)
    }

    // MARK: Snapshots

    func loadSnapshots() async {
        guard let project = selected,
              let json = await actions.perform("get_project_snapshots", ["project_id": .string(project.id)], quietly: true)?
                .voicesStudioJSON, selected?.id == project.id else { return }
        projectSnapshots = (json["snapshots"].arrayValue ?? []).compactMap(StudioSnapshot.init(json:))
    }

    func playSnapshot(_ snapshot: StudioSnapshot) async {
        guard let project = selected,
              let file = await actions.perform(
                "stream_project_snapshot_audio_endpoint",
                ["project_id": .string(project.id), "project_snapshot_id": .string(snapshot.id), "convert_to_mpeg": true],
                title: "\(project.name) — \(snapshot.name)"
              )?.voicesStudioFiles.first else { return }
        snapshotAudio[snapshot.id] = file
    }

    func downloadArchive(_ snapshot: StudioSnapshot) async {
        guard let project = selected,
              let file = await actions.perform(
                "stream_project_snapshot_archive_endpoint",
                ["project_id": .string(project.id), "project_snapshot_id": .string(snapshot.id)],
                title: "\(project.name) — \(snapshot.name).zip"
              )?.voicesStudioFiles.first else { return }
        snapshotAudio[snapshot.id + "/zip"] = file
    }

    func loadSnapshotDetails(_ snapshot: StudioSnapshot) async {
        guard let project = selected else { return }
        let json: JSONValue?
        if let chapterID = snapshot.chapterID {
            json = await actions.perform(
                "get_chapter_snapshot_endpoint",
                ["project_id": .string(project.id), "chapter_id": .string(chapterID),
                 "chapter_snapshot_id": .string(snapshot.id)], quietly: true
            )?.voicesStudioJSON
        } else {
            json = await actions.perform(
                "get_project_snapshot_endpoint",
                ["project_id": .string(project.id), "project_snapshot_id": .string(snapshot.id)], quietly: true
            )?.voicesStudioJSON
        }
        guard let json else { return }
        if let duration = json["audio_duration_secs"].doubleValue {
            snapshotDurations[snapshot.id] = duration
        } else if let ends = json["character_alignments"].arrayValue?.last?["character_end_times_seconds"].arrayValue?.last?.doubleValue {
            snapshotDurations[snapshot.id] = ends
        }
    }

    // MARK: Chapters

    func openChapter(_ chapterID: String) async {
        wantedChapter = chapterID
        guard let project = selected,
              let json = await actions.perform(
                "get_chapter_by_id_endpoint", ["project_id": .string(project.id), "chapter_id": .string(chapterID)],
                quietly: true
              )?.voicesStudioJSON, let chapter = StudioChapter(json: json),
              selected?.id == project.id, wantedChapter == chapterID
        else { return }
        self.chapter = chapter
        chapterName = chapter.name
        blockEdits = [:]
        await loadChapterSnapshots()
    }

    func loadChapterSnapshots() async {
        guard let project = selected, let chapter,
              let json = await actions.perform(
                "get_chapter_snapshots", ["project_id": .string(project.id), "chapter_id": .string(chapter.id)],
                quietly: true
              )?.voicesStudioJSON, selected?.id == project.id, self.chapter?.id == chapter.id else { return }
        chapterSnapshots = (json["snapshots"].arrayValue ?? []).compactMap(StudioSnapshot.init(json:))
    }

    /// Whether the chapter's content can be written back: only text-to-speech paragraphs can.
    var chapterIsEditable: Bool { chapter.map { !$0.blocks.contains(where: \.hasOtherNodes) } ?? false }

    /// The chapter's new name and, when a paragraph changed, its whole content — each edited
    /// paragraph as one piece in its first voice.
    func chapterArguments() -> [String: JSONValue]? {
        guard let project = selected, let chapter else { return nil }
        var arguments: [String: JSONValue] = ["project_id": .string(project.id), "chapter_id": .string(chapter.id)]
        if chapterName != chapter.name { arguments["name"] = .string(chapterName) }
        if !blockEdits.isEmpty, chapterIsEditable {
            let blocks: [JSONValue] = chapter.blocks.map { block in
                let nodes: [StudioBlock.Node] = if let edited = blockEdits[block.id] {
                    [StudioBlock.Node(text: edited, voiceID: block.nodes.first?.voiceID ?? project.defaultParagraphVoiceID ?? "")]
                } else {
                    block.nodes
                }
                return ["block_id": .string(block.id), "nodes": .array(nodes.map {
                    ["type": "tts_node", "text": .string($0.text), "voice_id": .string($0.voiceID)]
                })]
            }
            arguments["content"] = ["blocks": .array(blocks)]
        }
        return arguments
    }

    /// Whether Save chapter has anything to send: a new name, or paragraphs edited in a chapter
    /// whose content can be written back. Without either the call would carry only its ids.
    var chapterHasChanges: Bool {
        guard let arguments = chapterArguments() else { return false }
        return arguments["name"] != nil || arguments["content"] != nil
    }

    func saveChapter() async {
        guard chapterHasChanges, let arguments = chapterArguments(), let chapter, let projectID = selected?.id,
              await actions.perform("edit_chapter", arguments, title: "Edit \(chapter.name)") != nil else { return }
        // Another project or chapter may be open by now: reopen this one only if it still is.
        guard isOpen(projectID) else { return }
        if self.chapter?.id == chapter.id { await openChapter(chapter.id) }
        await reloadChapters()
    }

    func convertChapter(_ chapter: StudioChapter) async {
        guard let project = selected,
              await actions.perform(
                "convert_chapter_endpoint", ["project_id": .string(project.id), "chapter_id": .string(chapter.id)],
                title: "Convert \(chapter.name)"
              ) != nil, isOpen(project.id) else { return }
        await reloadChapters()
    }

    func deleteChapter(_ chapter: StudioChapter) async {
        guard let project = selected,
              await actions.perform(
                "delete_chapter_endpoint", ["project_id": .string(project.id), "chapter_id": .string(chapter.id)],
                subject: "the chapter “\(chapter.name)” of “\(project.name)”"
              ) != nil, isOpen(project.id) else { return }
        if self.chapter?.id == chapter.id { self.chapter = nil }
        await reloadChapters()
    }

    func addChapter() async {
        guard let project = selected else { return }
        var arguments: [String: JSONValue] = ["project_id": .string(project.id), "name": .string(newChapterName)]
        arguments.voicesStudioSet("from_url", VoicesStudioFormat.text(newChapterURL))
        guard await actions.perform("add_chapter", arguments, title: "New chapter \(newChapterName)") != nil,
              isOpen(project.id) else { return }
        newChapterName = ""
        newChapterURL = ""
        await reloadChapters()
    }

    func playChapterSnapshot(_ snapshot: StudioSnapshot) async {
        guard let project = selected, let chapter,
              let file = await actions.perform(
                "stream_chapter_snapshot_audio",
                ["project_id": .string(project.id), "chapter_id": .string(chapter.id),
                 "chapter_snapshot_id": .string(snapshot.id), "convert_to_mpeg": true],
                title: "\(chapter.name) — \(snapshot.name)"
              )?.voicesStudioFiles.first else { return }
        snapshotAudio[snapshot.id] = file
    }

    // MARK: Podcast

    nonisolated static func podcastArguments(_ draft: StudioPodcastDraft) -> ([String: JSONValue], [String]) {
        var arguments: [String: JSONValue] = [:]
        var problems: [String] = []
        if draft.modelID.isEmpty { problems.append("Choose the model to speak with.") }
        arguments["model_id"] = .string(draft.modelID)
        if draft.hostVoiceID.isEmpty { problems.append("Choose the host's voice.") }
        if draft.conversation {
            if draft.guestVoiceID.isEmpty { problems.append("Choose the guest's voice.") }
            arguments["mode"] = ["type": "conversation", "conversation": [
                "host_voice_id": .string(draft.hostVoiceID), "guest_voice_id": .string(draft.guestVoiceID),
            ]]
        } else {
            arguments["mode"] = ["type": "bulletin", "bulletin": ["host_voice_id": .string(draft.hostVoiceID)]]
        }
        if draft.fromURL {
            let url = draft.url.trimmingCharacters(in: .whitespaces)
            if url.isEmpty { problems.append("Give the page to make the podcast from.") }
            arguments["source"] = ["type": "url", "url": .string(url)]
        } else {
            if draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("Give the text to make the podcast from.")
            }
            arguments["source"] = ["type": "text", "text": .string(draft.text)]
        }
        for (key, value) in [("quality_preset", draft.qualityPreset), ("duration_scale", draft.durationScale),
                             ("language", draft.language), ("intro", draft.intro), ("outro", draft.outro),
                             ("instructions_prompt", draft.instructions), ("callback_url", draft.callbackURL),
                             ("apply_text_normalization", draft.textNormalization)] {
            arguments.voicesStudioSet(key, VoicesStudioFormat.text(value))
        }
        let highlights = draft.highlights.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !highlights.isEmpty { arguments["highlights"] = .array(highlights.map(JSONValue.string)) }
        return (arguments, problems)
    }


    func createPodcast() async {
        let (arguments, problems) = Self.podcastArguments(podcast)
        self.problems = problems
        let chosen = wantedProject
        guard problems.isEmpty,
              let json = await actions.perform("create_podcast", arguments, title: "Podcast")?.voicesStudioJSON,
              let project = StudioProject(json: json["project"])
        else { return }
        podcast = StudioPodcastDraft()
        projects.insert(project, at: 0)
        guard mode == .podcast, wantedProject == chosen else { return }
        mode = .projects
        await select(project.id)
    }

    // MARK: Test support

    func load(projects: [StudioProject], selected: StudioProject? = nil, snapshots: [StudioSnapshot] = [],
              chapter: StudioChapter? = nil, dictionaries: [StudioDictionary] = [],
              models: [VoicesStudioSpeechModel] = []) {
        self.projects = projects
        self.selected = selected
        wantedProject = selected?.id
        detailsIn = selected?.id
        if let selected { fillEdit(from: selected) }
        projectSnapshots = snapshots
        self.chapter = chapter
        chapterName = chapter?.name ?? ""
        self.dictionaries = dictionaries
        speechModels = models
        loadedOnce = true
    }
}

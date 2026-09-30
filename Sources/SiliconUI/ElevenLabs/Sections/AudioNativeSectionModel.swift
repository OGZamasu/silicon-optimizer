import Foundation
import Observation
import SiliconElevenLabs

/// An Audio Native player's settings, as `GET /v1/audio-native/{project_id}/settings` gives them.
struct AudioNativeSettings: Hashable, Sendable {
    var enabled: Bool
    var snapshotID: String?
    var title: String?
    var author: String?
    var textColor: String?
    var backgroundColor: String?
    var status: String?
    var audioURL: URL?

    init(json: JSONValue) {
        enabled = json["enabled"].boolValue ?? false
        snapshotID = json["snapshot_id"].stringValue
        let settings = json["settings"]
        title = settings["title"].stringValue
        author = settings["author"].stringValue
        textColor = settings["text_color"].stringValue
        backgroundColor = settings["background_color"].stringValue
        status = settings["status"].stringValue
        audioURL = settings["audio_url"].stringValue.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
    }
}

struct AudioNativeDraft: Hashable, Sendable {
    var name = ""
    var file: [URL] = []
    var title = ""
    var author = ""
    var voiceID = ""
    var modelID = ""
    var textColor = ""
    var backgroundColor = ""
    var autoConvert = true
    var textNormalization = ""
    var dictionaries: [StudioDictionaryLocator] = []
}

/// Audio Native: the embeddable player that reads an article aloud — a project made from the
/// article, its embed snippet, its settings, and new content from a file or a page.
@MainActor
@Observable
final class AudioNativeSectionModel {
    let actions: VoicesStudioActions
    let directory: ElevenLabsVoiceDirectory

    var draft = AudioNativeDraft()
    private(set) var problems: [String] = []
    /// The embed snippet of the last project made or updated, and whether it is converting.
    private(set) var snippet: String?
    private(set) var converting = false

    /// The project whose player is on screen.
    var projectID = ""
    private(set) var settings: AudioNativeSettings?
    /// Studio projects, as candidates for the project id.
    private(set) var projects: [StudioProject] = []
    private(set) var speechModels: [VoicesStudioSpeechModel] = []
    private(set) var dictionaries: [StudioDictionary] = []

    var contentFile: [URL] = []
    var contentAutoConvert = true
    /// Off unless asked: publishing changes the player live on the owner's site.
    var contentAutoPublish = false
    var pageURL = ""
    var pageTitle = ""
    var pageAuthor = ""

    init(environment: VoicesStudioEnvironment) {
        actions = VoicesStudioActions(context: environment.context)
        directory = environment.voices
        // A player made or updated whose answer was lost: list the projects again and read the
        // player's settings, so the owner can see whether it happened.
        actions.onUnknownOutcome = { [weak self] _ in
            guard let self else { return }
            if let json = await actions.perform("get_projects", quietly: true)?.voicesStudioJSON {
                projects = (json["projects"].arrayValue ?? []).compactMap(StudioProject.init(json:))
            }
            await loadSettings()
        }
    }

    // MARK: Spec

    static let controls: [VoicesStudioControl] = [
        .init("create_audio_native_project", "name"),
        .init("create_audio_native_project", "file"),
        .init("create_audio_native_project", "title"),
        .init("create_audio_native_project", "author"),
        .init("create_audio_native_project", "voice_id"),
        .init("create_audio_native_project", "model_id"),
        .init("create_audio_native_project", "text_color"),
        .init("create_audio_native_project", "background_color"),
        .init("create_audio_native_project", "auto_convert"),
        .init("create_audio_native_project", "apply_text_normalization", enumerated: true),
        .init("create_audio_native_project", "pronunciation_dictionary_locators"),
        .init("get_audio_native_project_settings_endpoint", "project_id"),
        .init("audio_native_project_update_content_endpoint", "file"),
        .init("audio_native_project_update_content_endpoint", "auto_convert"),
        .init("audio_native_project_update_content_endpoint", "auto_publish"),
        .init("audio_native_update_content_from_url", "url"),
        .init("audio_native_update_content_from_url", "title"),
        .init("audio_native_update_content_from_url", "author"),
    ]

    /// Studio projects, models and dictionaries feed the pickers.
    static let callsWithoutControls: Set<String> = ["get_projects", "get_models", "get_pronunciation_dictionaries_metadata"]
    static let explorerOnly: [String: String] = [:]

    var normalizations: [String] { VoicesStudioSchema.choices("create_audio_native_project", "apply_text_normalization") }

    func loadPickers() async {
        guard projects.isEmpty, speechModels.isEmpty else { return }
        if let json = await actions.perform("get_projects", quietly: true)?.voicesStudioJSON {
            projects = (json["projects"].arrayValue ?? []).compactMap(StudioProject.init(json:))
        }
        speechModels = await actions.speechModels()
        if let json = await actions.perform("get_pronunciation_dictionaries_metadata", ["page_size": 100], quietly: true)?
            .voicesStudioJSON {
            dictionaries = (json["pronunciation_dictionaries"].arrayValue ?? []).compactMap { entry in
                guard let id = entry["id"].stringValue, let version = entry["latest_version_id"].stringValue else { return nil }
                return StudioDictionary(id: id, name: entry["name"].stringValue ?? id, latestVersionID: version)
            }
        }
    }

    // MARK: Create

    nonisolated static func createArguments(_ draft: AudioNativeDraft) -> ([String: JSONValue], [String: [ElevenLabsFile]], [String]) {
        var problems: [String] = []
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { problems.append("Give the project a name.") }
        var arguments: [String: JSONValue] = ["name": .string(name)]
        for (key, value) in [("title", draft.title), ("author", draft.author), ("voice_id", draft.voiceID),
                             ("model_id", draft.modelID), ("text_color", draft.textColor),
                             ("background_color", draft.backgroundColor),
                             ("apply_text_normalization", draft.textNormalization)] {
            arguments.voicesStudioSet(key, VoicesStudioFormat.text(value))
        }
        if draft.autoConvert { arguments["auto_convert"] = true }
        if !draft.dictionaries.isEmpty {
            arguments["pronunciation_dictionary_locators"] = .array(draft.dictionaries.map { .string($0.json.jsonString()) })
        }
        let files = draft.file.first.map { ["file": [ElevenLabsFile(url: $0)]] } ?? [:]
        if files.isEmpty { problems.append("Choose the article: a .txt or .html file.") }
        return (arguments, files, problems)
    }

    func create() async {
        let (arguments, files, problems) = Self.createArguments(draft)
        self.problems = problems
        guard problems.isEmpty,
              let json = await actions.perform("create_audio_native_project", arguments, files: files,
                                               title: "Audio Native \(draft.name)")?.voicesStudioJSON
        else { return }
        take(json)
        if let id = json["project_id"].stringValue {
            projectID = id
            await loadSettings()
        }
        draft = AudioNativeDraft()
    }

    private func take(_ json: JSONValue) {
        snippet = json["html_snippet"].stringValue
        converting = json["converting"].boolValue ?? false
    }

    // MARK: A project

    func loadSettings() async {
        let id = projectID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty,
              let json = await actions.perform(
                "get_audio_native_project_settings_endpoint", ["project_id": .string(id)], quietly: true
              )?.voicesStudioJSON else { return }
        settings = AudioNativeSettings(json: json)
    }

    func updateContent() async {
        let id = projectID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, let file = contentFile.first,
              let json = await actions.perform(
                "audio_native_project_update_content_endpoint",
                ["project_id": .string(id), "auto_convert": .bool(contentAutoConvert), "auto_publish": .bool(contentAutoPublish)],
                files: ["file": [ElevenLabsFile(url: file)]], title: "New content for \(id)"
              )?.voicesStudioJSON else { return }
        take(json)
        contentFile = []
        await loadSettings()
    }

    func updateFromPage() async {
        let url = pageURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        var arguments: [String: JSONValue] = ["url": .string(url)]
        arguments.voicesStudioSet("title", VoicesStudioFormat.text(pageTitle))
        arguments.voicesStudioSet("author", VoicesStudioFormat.text(pageAuthor))
        guard let json = await actions.perform("audio_native_update_content_from_url", arguments, title: "Content from \(url)")?
            .voicesStudioJSON else { return }
        take(json)
        if let id = json["project_id"].stringValue {
            projectID = id
            await loadSettings()
        }
    }

    // MARK: Test support

    func load(snippet: String?, projectID: String, settings: AudioNativeSettings?, projects: [StudioProject] = []) {
        self.snippet = snippet
        self.projectID = projectID
        self.settings = settings
        self.projects = projects
    }
}

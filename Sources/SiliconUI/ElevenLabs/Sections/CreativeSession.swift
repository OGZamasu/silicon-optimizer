import Foundation
import Observation
import SiliconElevenLabs

/// What the creative screens share for as long as the app runs: how they reach the account,
/// the voices and models lists, and each screen's state.
///
/// The pane shows one section at a time behind a `switch`, so a screen's SwiftUI state would
/// be thrown away on every trip to another section — a half-written script, the transcript on
/// screen, the history page loaded. Each screen's model lives here instead, one session per
/// account, kept in the pane's section store and made the first time a creative screen appears.
@MainActor
final class CreativeSession {
    /// How runners reach the account.
    let context: ElevenLabsRunner.Context
    /// Every voice the account can use; the pane's own list in the app, shared with its pickers.
    let voices: ElevenLabsVoiceDirectory
    /// Every model the account can use, fetched once.
    let models: CreativeModelsDirectory
    /// The pane, for moving between sections ("Use in Speech"). Nil under a test.
    let pane: ElevenLabsPaneState?

    init(context: ElevenLabsRunner.Context, voices: ElevenLabsVoiceDirectory, pane: ElevenLabsPaneState? = nil) {
        self.context = context
        self.voices = voices
        self.pane = pane
        models = CreativeModelsDirectory(runner: Self.runner("get_models", context: context, records: false))
    }

    lazy var speech = SpeechScreenModel(session: self)
    lazy var dialogue = DialogueScreenModel(session: self)
    lazy var voiceChanger = VoiceChangerScreenModel(session: self)
    lazy var soundEffects = SoundEffectsScreenModel(session: self)
    lazy var music = MusicScreenModel(session: self)
    lazy var isolation = IsolationScreenModel(session: self)
    lazy var transcription = TranscriptionScreenModel(session: self)
    lazy var alignment = AlignmentScreenModel(session: self)
    lazy var history = HistoryScreenModel(session: self)
    lazy var modelsScreen = ModelsScreenModel(session: self)
    /// Pronunciation dictionaries, for Speech and Dialogue to attach.
    lazy var dictionaries = CreativeDictionaryDirectory(
        runner: Self.runner("get_pronunciation_dictionaries_metadata", context: context, records: false)
    )

    /// A runner for `operationID` in this session.
    ///
    /// - Parameter records: Off for background reads (a list refresh) that would only clutter
    ///   the pane's recent list.
    func runner(_ operationID: String, title: String? = nil, records: Bool = true) -> ElevenLabsRunner {
        let runner = Self.runner(operationID, context: context, records: records)
        runner.title = title
        return runner
    }

    static func runner(_ operationID: String, context: ElevenLabsRunner.Context, records: Bool) -> ElevenLabsRunner {
        let runner = ElevenLabsRunner(
            operation: ElevenLabsCatalog.operation(operationID) ?? missingOperation(operationID),
            context: context
        )
        runner.recordsResults = records
        return runner
    }

    /// Stands in for an operation this build's catalog lacks, so a screen still draws. It is
    /// never run: `CreativeRunGate` refuses operations the catalog does not know, and a test
    /// holds every creative screen to operations the catalog has.
    static func missingOperation(_ id: String) -> ElevenLabsOperation {
        ElevenLabsOperation(
            id: id, method: "POST", path: "/missing/\(id)", group: "Missing", summary: id,
            details: "", deprecated: false, parameters: [], body: nil, response: .json,
            risk: .destructive, billable: false, returnsCredential: false, supportsStreaming: false
        )
    }

    /// Shows another section of the pane.
    func open(_ section: ElevenLabsSection) {
        pane?.open(section)
    }

    // MARK: - One per account, in the pane's section store

    /// The key the session is kept under in the pane's section store.
    static let stateKey = "creative.session"

    /// The running app's session for `model`: made on first use, kept by the pane, and dropped
    /// with every other section's state when the account's client changes (a disconnect, a
    /// new key, a region change) — its takes, transcripts and lists start over.
    static func shared(for model: AppModel) -> CreativeSession {
        shared(in: model.elevenLabsPane, context: .app(model))
    }

    /// The session `pane` keeps, made with `context` the first time.
    static func shared(in pane: ElevenLabsPaneState, context: @autoclosure () -> ElevenLabsRunner.Context) -> CreativeSession {
        pane.state(key: stateKey) { CreativeSession(context: context(), voices: pane.voices, pane: pane) }
    }
}

/// Whether a creative screen may run an operation: only one the catalog knows.
enum CreativeRunGate {
    static func isKnown(_ runner: ElevenLabsRunner) -> Bool {
        ElevenLabsCatalog.operation(runner.operation.id) != nil
    }
}

// MARK: - Models

/// A model the account can use, as `GET /v1/models` describes it.
struct CreativeModel: Identifiable, Hashable, Sendable {
    struct Language: Hashable, Sendable {
        var id: String
        var name: String
    }

    var id: String
    var name: String
    var description: String
    var canDoTextToSpeech: Bool
    var canDoVoiceConversion: Bool
    var canUseStyle: Bool
    var canUseSpeakerBoost: Bool
    var canBeFinetuned: Bool
    var servesProVoices: Bool
    var requiresAlphaAccess: Bool
    var tokenCostFactor: Double?
    /// Characters billed per character of text (`model_rates.character_cost_multiplier`).
    var characterCostMultiplier: Double?
    var maxCharactersFreeUser: Int?
    var maxCharactersSubscribedUser: Int?
    var maximumTextLengthPerRequest: Int?
    var languages: [Language]
    var concurrencyGroup: String?

    init(
        id: String, name: String, description: String = "", canDoTextToSpeech: Bool = false,
        canDoVoiceConversion: Bool = false, canUseStyle: Bool = false, canUseSpeakerBoost: Bool = false,
        canBeFinetuned: Bool = false, servesProVoices: Bool = false, requiresAlphaAccess: Bool = false,
        tokenCostFactor: Double? = nil, characterCostMultiplier: Double? = nil,
        maxCharactersFreeUser: Int? = nil, maxCharactersSubscribedUser: Int? = nil,
        maximumTextLengthPerRequest: Int? = nil, languages: [Language] = [], concurrencyGroup: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.canDoTextToSpeech = canDoTextToSpeech
        self.canDoVoiceConversion = canDoVoiceConversion
        self.canUseStyle = canUseStyle
        self.canUseSpeakerBoost = canUseSpeakerBoost
        self.canBeFinetuned = canBeFinetuned
        self.servesProVoices = servesProVoices
        self.requiresAlphaAccess = requiresAlphaAccess
        self.tokenCostFactor = tokenCostFactor
        self.characterCostMultiplier = characterCostMultiplier
        self.maxCharactersFreeUser = maxCharactersFreeUser
        self.maxCharactersSubscribedUser = maxCharactersSubscribedUser
        self.maximumTextLengthPerRequest = maximumTextLengthPerRequest
        self.languages = languages
        self.concurrencyGroup = concurrencyGroup
    }

    /// From a `ModelResponseModel`; nil without an id.
    init?(json: JSONValue) {
        guard let id = json["model_id"].stringValue, !id.isEmpty else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        description = json["description"].stringValue ?? ""
        canDoTextToSpeech = json["can_do_text_to_speech"].boolValue ?? false
        canDoVoiceConversion = json["can_do_voice_conversion"].boolValue ?? false
        canUseStyle = json["can_use_style"].boolValue ?? false
        canUseSpeakerBoost = json["can_use_speaker_boost"].boolValue ?? false
        canBeFinetuned = json["can_be_finetuned"].boolValue ?? false
        servesProVoices = json["serves_pro_voices"].boolValue ?? false
        requiresAlphaAccess = json["requires_alpha_access"].boolValue ?? false
        tokenCostFactor = json["token_cost_factor"].doubleValue
        characterCostMultiplier = json["model_rates"]["character_cost_multiplier"].doubleValue
        maxCharactersFreeUser = json["max_characters_request_free_user"].intValue
        maxCharactersSubscribedUser = json["max_characters_request_subscribed_user"].intValue
        maximumTextLengthPerRequest = json["maximum_text_length_per_request"].intValue
        languages = (json["languages"].arrayValue ?? []).compactMap { language in
            guard let id = language["language_id"].stringValue else { return nil }
            return Language(id: id, name: language["name"].stringValue ?? id)
        }
        concurrencyGroup = json["concurrency_group"].stringValue
    }

    /// What `characters` of text are likely to cost, by the model's rate.
    func estimatedCost(characters: Int) -> Int {
        Int((Double(characters) * (characterCostMultiplier ?? 1)).rounded(.up))
    }

    /// "English, Spanish and 27 more".
    var languageSummary: String {
        let names = languages.map(\.name)
        switch names.count {
        case 0: return "No languages listed"
        case 1...3: return ListFormatter.localizedString(byJoining: names)
        default: return "\(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more"
        }
    }
}

/// Every model the account can use, fetched once per session and shared by every picker and
/// the Models screen.
@MainActor
@Observable
final class CreativeModelsDirectory {
    private(set) var models: [CreativeModel] = []
    private(set) var loaded = false
    /// The runner the list is fetched through: its errors and "Show API call" are the Models
    /// screen's.
    let runner: ElevenLabsRunner

    init(runner: ElevenLabsRunner) {
        self.runner = runner
    }

    var loading: Bool { runner.isRunning }

    func model(id: String) -> CreativeModel? {
        models.first { $0.id == id }
    }

    func loadIfNeeded() async {
        guard !loaded, !runner.isRunning else { return }
        await refresh()
    }

    func refresh() async {
        guard CreativeRunGate.isKnown(runner), !runner.isRunning else { return }
        guard case .json(let value, _)? = await runner.perform(arguments: [:]) else { return }
        set((value.arrayValue ?? []).compactMap(CreativeModel.init(json:)))
    }

    /// Replaces the list: after a fetch, and for tests and previews.
    func set(_ models: [CreativeModel]) {
        self.models = models
        loaded = true
    }
}

// MARK: - Pronunciation dictionaries

/// A pronunciation dictionary to attach to a generation, and the version to use.
struct CreativeDictionary: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var latestVersionID: String?
    var rules: Int?

    init(id: String, name: String, latestVersionID: String? = nil, rules: Int? = nil) {
        self.id = id
        self.name = name
        self.latestVersionID = latestVersionID
        self.rules = rules
    }

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        latestVersionID = json["latest_version_id"].stringValue
        rules = json["latest_version_rules_num"].intValue
    }
}

/// The account's pronunciation dictionaries, fetched once when a screen offers to attach one.
@MainActor
@Observable
final class CreativeDictionaryDirectory {
    private(set) var dictionaries: [CreativeDictionary] = []
    private(set) var loaded = false
    let runner: ElevenLabsRunner

    init(runner: ElevenLabsRunner) {
        self.runner = runner
    }

    func loadIfNeeded() async {
        guard !loaded, !runner.isRunning, CreativeRunGate.isKnown(runner) else { return }
        guard case .json(let value, _)? = await runner.perform(arguments: ["page_size": 100]) else { return }
        set((value["pronunciation_dictionaries"].arrayValue ?? []).compactMap(CreativeDictionary.init(json:)))
    }

    func set(_ dictionaries: [CreativeDictionary]) {
        self.dictionaries = dictionaries
        loaded = true
    }
}

/// The dictionaries a generation applies, in order: the `pronunciation_dictionary_locators`
/// argument.
struct CreativeDictionaryLocator: Identifiable, Hashable, Sendable {
    var id: String { dictionaryID + "@" + (versionID ?? "latest") }
    var dictionaryID: String
    var versionID: String?
    var name: String

    var json: JSONValue {
        var object: [String: JSONValue] = ["pronunciation_dictionary_id": .string(dictionaryID)]
        if let versionID, !versionID.isEmpty { object["version_id"] = .string(versionID) }
        return .object(object)
    }
}

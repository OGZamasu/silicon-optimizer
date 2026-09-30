import Foundation
import Observation
import SiliconElevenLabs

/// A voice in the shared library.
struct VoiceLibraryVoice: Identifiable, Hashable, Sendable {
    var voiceID: String
    var publicOwnerID: String
    var name: String
    var description: String?
    var accent: String?
    var gender: String?
    var age: String?
    var useCase: String?
    var descriptive: String?
    var language: String?
    var category: String?
    var previewURL: URL?
    var clonedByCount: Int?
    var usageLastYear: Int?
    var noticePeriodDays: Int?
    var rate: Double?
    var freeUsersAllowed: Bool?
    var featured: Bool
    var isAdded: Bool
    var id: String { "\(publicOwnerID)/\(voiceID)" }

    init?(json: JSONValue) {
        guard let voiceID = json["voice_id"].stringValue, let owner = json["public_owner_id"].stringValue
        else { return nil }
        self.voiceID = voiceID
        publicOwnerID = owner
        name = json["name"].stringValue ?? voiceID
        description = json["description"].stringValue
        accent = json["accent"].stringValue
        gender = json["gender"].stringValue
        age = json["age"].stringValue
        useCase = json["use_case"].stringValue
        descriptive = json["descriptive"].stringValue
        language = json["language"].stringValue
        category = json["category"].stringValue
        previewURL = json["preview_url"].stringValue.flatMap(URL.init(string:)).flatMap {
            $0.scheme == "https" ? $0 : nil
        }
        clonedByCount = json["cloned_by_count"].intValue
        usageLastYear = json["usage_character_count_1y"].intValue
        noticePeriodDays = json["notice_period"].intValue
        rate = json["rate"].doubleValue
        freeUsersAllowed = json["free_users_allowed"].boolValue
        featured = json["featured"].boolValue ?? false
        isAdded = json["is_added_by_user"].boolValue ?? false
    }

    /// "British · female · young · narration".
    var summary: String {
        [accent, gender, age, useCase, descriptive]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "_", with: " ") }
            .joined(separator: " · ")
    }

    var directoryEntry: ElevenLabsVoice {
        ElevenLabsVoice(id: voiceID, name: name, category: category, description: description,
                        labels: [:], previewURL: previewURL)
    }
}

/// The shared voice library: search with filters, listen, and add a voice to the account.
@MainActor
@Observable
final class VoiceLibrarySectionModel {
    let actions: VoicesStudioActions
    let directory: ElevenLabsVoiceDirectory

    var search = ""
    var gender = ""
    var age = ""
    var accent = ""
    var language = ""
    var useCase = ""
    var sort = ""
    var featuredOnly = false
    private(set) var rows: [VoiceLibraryVoice] = []
    private(set) var hasMore = false
    private(set) var totalCount: Int?
    private(set) var loadedOnce = false
    @ObservationIgnored private var page = 0
    /// Every value seen for each filterable field, so the filters offer what the library has.
    private(set) var facets: [String: Set<String>] = [:]
    /// Accents ElevenLabs knows, from `GET /v1/voices/accents`.
    private(set) var knownAccents: [String] = []
    var names: [String: String] = [:]
    /// Voices added in this session, by library id.
    private(set) var added: Set<String> = []

    static let pageSize = 30
    /// The sort orders the spec lists in `sort`'s description.
    static let sorts = ["created_date", "usage_character_count_1y", "trending", "cloned_by_count"]

    static let controls: [VoicesStudioControl] = [
        .init("get_library_voices", "search"),
        .init("get_library_voices", "gender"),
        .init("get_library_voices", "age"),
        .init("get_library_voices", "accent"),
        .init("get_library_voices", "language"),
        .init("get_library_voices", "use_cases"),
        .init("get_library_voices", "featured"),
        .init("get_library_voices", "sort", describedValues: sorts),
        .init("get_library_voices", "page"),
        .init("get_library_voices", "page_size"),
        .init("add_sharing_voice", "public_user_id"),
        .init("add_sharing_voice", "voice_id"),
        .init("add_sharing_voice", "new_name"),
        .init("add_sharing_voice", "bookmarked"),
    ]

    static let callsWithoutControls: Set<String> = ["get_voice_accents"]
    static let explorerOnly: [String: String] = [:]

    init(environment: VoicesStudioEnvironment) {
        actions = VoicesStudioActions(context: environment.context)
        directory = environment.voices
    }

    func arguments(page: Int) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["page_size": .number(Double(Self.pageSize)), "page": .number(Double(page))]
        arguments.voicesStudioSet("search", VoicesStudioFormat.text(search))
        arguments.voicesStudioSet("gender", VoicesStudioFormat.text(gender))
        arguments.voicesStudioSet("age", VoicesStudioFormat.text(age))
        arguments.voicesStudioSet("accent", VoicesStudioFormat.text(accent))
        arguments.voicesStudioSet("language", VoicesStudioFormat.text(language))
        arguments.voicesStudioSet("sort", VoicesStudioFormat.text(sort))
        if !useCase.isEmpty { arguments["use_cases"] = [.string(useCase)] }
        if featuredOnly { arguments["featured"] = true }
        return arguments
    }

    var listRunner: ElevenLabsRunner? { actions.runner("get_library_voices") }
    var listProblem: String? { actions.problem("get_library_voices") }
    var isListing: Bool { actions.isRunning("get_library_voices") }

    func refresh() async {
        guard let json = await actions.perform("get_library_voices", arguments(page: 0), quietly: true)?
            .voicesStudioJSON else { return }
        page = 0
        rows = Self.voices(in: json)
        take(json)
    }

    func loadMore() async {
        guard hasMore,
              let json = await actions.perform("get_library_voices", arguments(page: page + 1), quietly: true)?
                .voicesStudioJSON else { return }
        page += 1
        let known = Set(rows.map(\.id))
        rows += Self.voices(in: json).filter { !known.contains($0.id) }
        take(json)
    }

    func refreshIfNeeded() async {
        guard !loadedOnce else { return }
        await refresh()
        await loadAccents()
    }

    private func take(_ json: JSONValue) {
        hasMore = json["has_more"].boolValue == true
        totalCount = json["total_count"].intValue
        loadedOnce = true
        note(rows)
    }

    private func note(_ voices: [VoiceLibraryVoice]) {
        for voice in voices {
            for (field, value) in [("gender", voice.gender), ("age", voice.age), ("accent", voice.accent),
                                   ("language", voice.language), ("use_case", voice.useCase)] {
                if let value, !value.isEmpty { facets[field, default: []].insert(value) }
            }
        }
    }

    /// The values to offer for a filter: what the library has shown so far (and, for accents,
    /// what ElevenLabs lists), sorted, with the current choice kept.
    func options(_ field: String, current: String) -> [String] {
        var values = facets[field] ?? []
        if field == "accent" { values.formUnion(knownAccents) }
        if !current.isEmpty { values.insert(current) }
        return values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func loadAccents() async {
        guard let json = await actions.perform("get_voice_accents", quietly: true)?.voicesStudioJSON else { return }
        knownAccents = Array(Set((json["accents"].arrayValue ?? []).compactMap { $0["accent"].stringValue })).sorted()
    }

    nonisolated static func voices(in json: JSONValue) -> [VoiceLibraryVoice] {
        (json["voices"].arrayValue ?? []).compactMap(VoiceLibraryVoice.init(json:))
    }

    func addArguments(_ voice: VoiceLibraryVoice) -> [String: JSONValue] {
        let name = (names[voice.id] ?? voice.name).trimmingCharacters(in: .whitespaces)
        return ["public_user_id": .string(voice.publicOwnerID), "voice_id": .string(voice.voiceID),
                "new_name": .string(name.isEmpty ? voice.name : name), "bookmarked": true]
    }

    func add(_ voice: VoiceLibraryVoice) async {
        guard await actions.perform("add_sharing_voice", addArguments(voice), title: "Add \(voice.name)") != nil
        else { return }
        added.insert(voice.id)
        await directory.refresh()
    }

    func isAdded(_ voice: VoiceLibraryVoice) -> Bool { voice.isAdded || added.contains(voice.id) }

    // MARK: Test support

    func load(rows: [VoiceLibraryVoice], hasMore: Bool = false, total: Int? = nil) {
        self.rows = rows
        self.hasMore = hasMore
        totalCount = total
        loadedOnce = true
        note(rows)
    }
}

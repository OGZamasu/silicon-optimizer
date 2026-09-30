import Foundation
import Observation
import SiliconElevenLabs

// MARK: - Data

/// What a Flows generation makes, and the three routes each kind has.
enum FlowsKind: String, CaseIterable, Identifiable, Sendable {
    case speech, image, video

    var id: String { rawValue }
    var title: String {
        switch self {
        case .speech: "Speech"
        case .image: "Images"
        case .video: "Video"
        }
    }

    var createID: String {
        switch self {
        case .speech: "create_text_to_speech_generation"
        case .image: "create_image_generation"
        case .video: "create_video_generation"
        }
    }

    var listID: String {
        switch self {
        case .speech: "list_text_to_speech_generations"
        case .image: "list_image_generations"
        case .video: "list_video_generations"
        }
    }

    var getID: String {
        switch self {
        case .speech: "get_text_to_speech_generation"
        case .image: "get_image_generation"
        case .video: "get_video_generation"
        }
    }
}

/// One model a generation can use: a shape of the create body's union, told apart by its
/// `model_id` constant.
struct FlowsModelVariant: Identifiable, Hashable, Sendable {
    var modelID: String
    /// The spec's description of the request, e.g. "Request body for the OpenAI GPT Image 1 model."
    var summary: String
    var schema: JSONValue
    var id: String { modelID }

    /// "Request body for the Creatify Aurora lipsync video model." → "Creatify Aurora lipsync video".
    var name: String {
        var text = summary
        for prefix in ["Request body for the ", "Request body for "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        for suffix in [" model.", " model", "."] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        return text.isEmpty ? modelID : text
    }

    /// Every model of a create operation, in spec order.
    static func variants(of operationID: String) -> [FlowsModelVariant] {
        guard let body = ElevenLabsCatalog.operation(operationID)?.body else { return [] }
        return (body.schema["oneOf"].arrayValue ?? body.schema["anyOf"].arrayValue ?? []).compactMap { variant in
            guard let model = variant["properties"]["model_id"]["const"].stringValue else { return nil }
            return FlowsModelVariant(modelID: model, summary: variant["description"].stringValue ?? model, schema: variant)
        }
    }

    /// The create operation narrowed to this model, so the generated form shows this model's
    /// fields one by one instead of one union editor.
    func operation(from base: ElevenLabsOperation) -> ElevenLabsOperation {
        var narrowed = base
        narrowed.body = ElevenLabsBody(contentType: .json, required: true, schema: schema, fileFields: [])
        return narrowed
    }
}

/// A generation, as the list and the status route describe it.
struct FlowsGeneration: Identifiable, Hashable, Sendable {
    var id: String
    var status: String
    var contentURL: URL?
    var contentType: String?
    var failure: String?

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        status = json["status"].stringValue ?? "pending"
        contentURL = json["content_url"].stringValue.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        contentType = json["content_mime_type"].stringValue
        failure = json["error_message"].stringValue ?? json["failure_reason"].stringValue
    }
}

struct FlowsTemplate: Identifiable, Hashable, Sendable {
    struct Version: Identifiable, Hashable, Sendable {
        var id: String
        var publishedAt: Int?
        var isLatest: Bool
        var inputs: [Port]
        var outputs: [Port]
    }

    struct Port: Identifiable, Hashable, Sendable {
        var id: String
        var schema: JSONValue
        var isText: Bool { schema["type"].stringValue == "string" }
    }

    var id: String
    var name: String
    var description: String?
    var versions: [Version]
    var hasMoreVersions: Bool

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        description = json["description"].stringValue
        hasMoreVersions = json["has_more_versions"].boolValue ?? false
        versions = (json["versions"].arrayValue ?? []).compactMap { version in
            guard let versionID = version["version_id"].stringValue else { return nil }
            func ports(_ key: String) -> [Port] {
                (version[key].arrayValue ?? []).compactMap { port in
                    port["id"].stringValue.map { Port(id: $0, schema: port["content_schema"]) }
                }
            }
            return Version(id: versionID, publishedAt: version["published_at_unix"].intValue,
                           isLatest: version["is_latest"].boolValue ?? false, inputs: ports("inputs"), outputs: ports("outputs"))
        }
    }
}

struct FlowsRun: Identifiable, Hashable, Sendable {
    var id: String
    var versionID: String?
    var status: String
    var outputs: JSONValue

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        versionID = json["version_id"].stringValue
        status = json["status"].stringValue ?? "pending"
        outputs = json["outputs"]
    }
}

// MARK: - Model

/// Flows: speech, image and video generations with any model the spec lists, their status and
/// results; and published templates run with their inputs.
@MainActor
@Observable
final class FlowsSectionModel {

    enum Mode: String, CaseIterable, Identifiable {
        case speech, image, video, templates
        var id: String { rawValue }
        var kind: FlowsKind? { FlowsKind(rawValue: rawValue) }
        var title: String { kind?.title ?? "Templates" }
    }

    let actions: VoicesStudioActions
    let directory: ElevenLabsVoiceDirectory
    var mode: Mode = .speech
    /// Speech generations take their voice from the pane's voice picker rather than a text field.
    var speechVoiceID = ""

    // Generations
    private(set) var chosenModel: [FlowsKind: String] = [:]
    /// The form for the chosen model of each kind, kept while the section lives.
    @ObservationIgnored private var forms: [String: ElevenLabsFormModel] = [:]
    var statusFilter: [FlowsKind: String] = [:]
    private(set) var generations: [FlowsKind: [FlowsGeneration]] = [:]
    private(set) var cursors: [FlowsKind: String] = [:]
    private(set) var loaded: Set<FlowsKind> = []

    // Templates
    var templateSearch = ""
    private(set) var templates: [FlowsTemplate] = []
    private(set) var templatesCursor: String?
    private(set) var loadedTemplates = false
    private(set) var template: FlowsTemplate?
    var versionID = "latest"
    var inputs: [String: String] = [:]
    var notifyWebhooks = false
    private(set) var runs: [FlowsRun] = []
    private(set) var inputProblems: [String] = []

    init(environment: VoicesStudioEnvironment) {
        actions = VoicesStudioActions(context: environment.context)
        directory = environment.voices
        // A generation or run whose answer was lost: list them again, so the owner can see
        // whether it was started.
        actions.onUnknownOutcome = { [weak self] operationID in
            guard let self else { return }
            if let kind = FlowsKind.allCases.first(where: { $0.createID == operationID }) {
                await refresh(kind)
            } else {
                await loadRuns()
            }
        }
    }

    // MARK: Spec

    static let controls: [VoicesStudioControl] = [
        .init("create_text_to_speech_generation", "model_id"),
        .init("create_text_to_speech_generation", "text"),
        .init("create_text_to_speech_generation", "voice"),
        .init("create_image_generation", "model_id"),
        .init("create_image_generation", "prompt"),
        .init("create_video_generation", "model_id"),
        .init("create_video_generation", "prompt"),
        .init("list_text_to_speech_generations", "status", enumerated: true),
        .init("list_text_to_speech_generations", "cursor"),
        .init("list_image_generations", "status", enumerated: true),
        .init("list_image_generations", "cursor"),
        .init("list_video_generations", "status", enumerated: true),
        .init("list_video_generations", "cursor"),
        .init("get_text_to_speech_generation", "generation_id"),
        .init("get_image_generation", "generation_id"),
        .init("get_video_generation", "generation_id"),
        .init("list_public_templates", "search"),
        .init("list_public_templates", "cursor"),
        .init("get_public_template", "template_id"),
        .init("create_public_template_run", "inputs"),
        .init("create_public_template_run", "version_id"),
        .init("create_public_template_run", "webhook"),
        .init("list_public_template_runs", "template_id"),
        .init("get_public_template_run", "run_id"),
    ]

    static let callsWithoutControls: Set<String> = []
    static let explorerOnly: [String: String] = [:]

    func statuses(_ kind: FlowsKind) -> [String] { VoicesStudioSchema.choices(kind.listID, "status") }

    // MARK: Generations

    func variants(_ kind: FlowsKind) -> [FlowsModelVariant] { FlowsModelVariant.variants(of: kind.createID) }

    func model(_ kind: FlowsKind) -> String { chosenModel[kind] ?? variants(kind).first?.modelID ?? "" }

    func choose(_ modelID: String, for kind: FlowsKind) { chosenModel[kind] = modelID }

    /// The form for a kind's chosen model; made on first use and kept, so switching models
    /// back and forth keeps what was typed.
    func form(_ kind: FlowsKind) -> ElevenLabsFormModel? {
        let modelID = model(kind)
        let key = "\(kind.rawValue)/\(modelID)"
        if let existing = forms[key] { return existing }
        guard let base = ElevenLabsCatalog.operation(kind.createID),
              let variant = variants(kind).first(where: { $0.modelID == modelID }) else { return nil }
        let operation = variant.operation(from: base)
        // The model is the picker above the form, and a speech model's `voice` is the voice
        // picker; the form holds the rest.
        let names = Set(ElevenLabsFormField.fields(for: operation).map(\.name))
            .subtracting(kind == .speech ? ["model_id", "voice"] : ["model_id"])
        let made = ElevenLabsFormModel(operation: operation, only: names)
        forms[key] = made
        return made
    }

    /// Roughly what a speech generation costs: its text.
    func estimatedCharacters(_ kind: FlowsKind) -> Int? {
        guard kind == .speech, let form = form(kind) else { return nil }
        return form.nodes.first { $0.field.name == "text" }.map(\.text.count).flatMap { $0 > 0 ? $0 : nil }
    }

    /// The arguments a generation sends, and every problem with them.
    func createArguments(_ kind: FlowsKind) -> (arguments: [String: JSONValue], files: [String: [ElevenLabsFile]], problems: [String])? {
        guard let form = form(kind) else { return nil }
        var built = form.arguments()
        built.arguments["model_id"] = .string(model(kind))
        if kind == .speech {
            if speechVoiceID.isEmpty { built.problems.append("Choose the voice to speak with.") }
            built.arguments["voice"] = .string(speechVoiceID)
        }
        return built
    }

    func create(_ kind: FlowsKind) async {
        guard let form = form(kind), let built = createArguments(kind) else { return }
        form.setProblems(built.problems)
        guard built.problems.isEmpty,
              let json = await actions.perform(kind.createID, built.arguments, files: built.files,
                                               title: "\(kind.title) with \(model(kind))")?.voicesStudioJSON,
              let generation = FlowsGeneration(json: json)
        else {
            if let problems = actions.runner(kind.createID)?.problems, !problems.isEmpty { form.setProblems(problems) }
            return
        }
        generations[kind, default: []].insert(generation, at: 0)
    }

    func listArguments(_ kind: FlowsKind, cursor: String?) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["page_size": 30]
        arguments.voicesStudioSet("status", VoicesStudioFormat.text(statusFilter[kind] ?? ""))
        arguments.voicesStudioSet("cursor", cursor.map(JSONValue.string))
        return arguments
    }

    func refresh(_ kind: FlowsKind) async {
        guard let json = await actions.perform(kind.listID, listArguments(kind, cursor: nil), quietly: true)?
            .voicesStudioJSON else { return }
        generations[kind] = (json["generations"].arrayValue ?? []).compactMap(FlowsGeneration.init(json:))
        cursors[kind] = json["has_more"].boolValue == true ? json["next_cursor"].stringValue : nil
        loaded.insert(kind)
    }

    func loadMore(_ kind: FlowsKind) async {
        guard let cursor = cursors[kind],
              let json = await actions.perform(kind.listID, listArguments(kind, cursor: cursor), quietly: true)?
                .voicesStudioJSON else { return }
        let known = Set((generations[kind] ?? []).map(\.id))
        generations[kind, default: []] += (json["generations"].arrayValue ?? []).compactMap(FlowsGeneration.init(json:))
            .filter { !known.contains($0.id) }
        cursors[kind] = json["has_more"].boolValue == true ? json["next_cursor"].stringValue : nil
    }

    func check(_ generation: FlowsGeneration, kind: FlowsKind) async {
        guard let json = await actions.perform(kind.getID, ["generation_id": .string(generation.id)], quietly: true)?
            .voicesStudioJSON, let fresh = FlowsGeneration(json: json),
              let index = generations[kind]?.firstIndex(where: { $0.id == generation.id })
        else { return }
        generations[kind]?[index] = fresh
    }

    // MARK: Templates

    func refreshTemplates() async {
        var arguments: [String: JSONValue] = ["page_size": 25]
        arguments.voicesStudioSet("search", VoicesStudioFormat.text(templateSearch))
        guard let json = await actions.perform("list_public_templates", arguments, quietly: true)?.voicesStudioJSON
        else { return }
        templates = (json["templates"].arrayValue ?? []).compactMap(FlowsTemplate.init(json:))
        templatesCursor = json["has_more"].boolValue == true ? json["next_cursor"].stringValue : nil
        loadedTemplates = true
    }

    func moreTemplates() async {
        guard let cursor = templatesCursor else { return }
        var arguments: [String: JSONValue] = ["page_size": 25, "cursor": .string(cursor)]
        arguments.voicesStudioSet("search", VoicesStudioFormat.text(templateSearch))
        guard let json = await actions.perform("list_public_templates", arguments, quietly: true)?.voicesStudioJSON
        else { return }
        let known = Set(templates.map(\.id))
        templates += (json["templates"].arrayValue ?? []).compactMap(FlowsTemplate.init(json:)).filter { !known.contains($0.id) }
        templatesCursor = json["has_more"].boolValue == true ? json["next_cursor"].stringValue : nil
    }

    func open(_ templateID: String) async {
        guard let json = await actions.perform("get_public_template", ["template_id": .string(templateID)], quietly: true)?
            .voicesStudioJSON, let fresh = FlowsTemplate(json: json) else { return }
        template = fresh
        versionID = "latest"
        inputs = [:]
        runs = []
        await loadRuns()
    }

    /// The version a run will use: the latest published one unless another was picked.
    var chosenVersion: FlowsTemplate.Version? {
        guard let template else { return nil }
        return versionID == "latest"
            ? template.versions.first(where: \.isLatest) ?? template.versions.first
            : template.versions.first { $0.id == versionID }
    }

    /// The inputs keyed by port id: text ports as text, the others parsed as JSON.
    func runArguments() -> ([String: JSONValue], [String])? {
        guard let template, let version = chosenVersion else { return nil }
        var problems: [String] = []
        var values: [String: JSONValue] = [:]
        for port in version.inputs {
            let text = inputs[port.id] ?? ""
            if port.isText {
                values[port.id] = .string(text)
            } else if let value = try? JSONValue(data: Data(text.utf8)) {
                values[port.id] = value
            } else {
                problems.append("The input “\(port.id)” is not valid JSON.")
            }
        }
        var arguments: [String: JSONValue] = [
            "template_id": .string(template.id), "inputs": .object(values), "version_id": .string(versionID),
        ]
        if notifyWebhooks { arguments["webhook"] = ["type": "all"] }
        return (arguments, problems)
    }

    func run() async {
        guard let (arguments, problems) = runArguments(), let template else { return }
        inputProblems = problems
        guard problems.isEmpty,
              let json = await actions.perform("create_public_template_run", arguments, title: "Run \(template.name)")?
                .voicesStudioJSON, let run = FlowsRun(json: json) else { return }
        runs.insert(run, at: 0)
    }

    func loadRuns() async {
        guard let template,
              let json = await actions.perform(
                "list_public_template_runs", ["template_id": .string(template.id), "page_size": 30], quietly: true
              )?.voicesStudioJSON else { return }
        runs = (json["runs"].arrayValue ?? []).compactMap(FlowsRun.init(json:))
    }

    func check(_ run: FlowsRun) async {
        guard let template,
              let json = await actions.perform(
                "get_public_template_run", ["template_id": .string(template.id), "run_id": .string(run.id)], quietly: true
              )?.voicesStudioJSON, let fresh = FlowsRun(json: json),
              let index = runs.firstIndex(where: { $0.id == run.id })
        else { return }
        runs[index] = fresh
    }

    // MARK: Test support

    func load(generations: [FlowsGeneration], for kind: FlowsKind) {
        self.generations[kind] = generations
        loaded.insert(kind)
    }

    func load(templates: [FlowsTemplate], open: FlowsTemplate? = nil, runs: [FlowsRun] = []) {
        self.templates = templates
        template = open
        self.runs = runs
        loadedTemplates = true
    }
}

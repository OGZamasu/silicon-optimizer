import AppKit
import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

// The parts the voices-and-studio sections share: how a section's model reaches the account,
// where it is kept between visits, the runners it calls through, what it reads from the
// catalog, and a few small views. Everything here is prefixed `VoicesStudio` so it cannot
// collide with the other section builders' helpers in this folder.

// MARK: - Environment

/// What a section model is built from: how its runners reach the account, and the voices list
/// every picker in the pane shares.
@MainActor
struct VoicesStudioEnvironment {
    var context: ElevenLabsRunner.Context
    var voices: ElevenLabsVoiceDirectory

    init(context: ElevenLabsRunner.Context, voices: ElevenLabsVoiceDirectory) {
        self.context = context
        self.voices = voices
    }

    /// The running app's: the linked client, the output folder, the pane's shared state.
    static func app(_ model: AppModel) -> VoicesStudioEnvironment {
        VoicesStudioEnvironment(context: .app(model), voices: model.elevenLabsPane.voices)
    }
}

/// Section models kept in the pane's section state, so work in progress — voice previews that
/// already cost credits, a half-filled form, the project on screen — survives a trip to another
/// section and back (the main window draws one section at a time behind a `switch`), and is
/// dropped with the rest of the pane's state when the account's client changes.
@MainActor
enum VoicesStudioModels {
    static func model<Model: AnyObject>(
        _ type: Model.Type, for app: AppModel, make: (VoicesStudioEnvironment) -> Model
    ) -> Model {
        app.elevenLabsPane.state(key: "voices-studio." + String(describing: type)) { make(.app(app)) }
    }
}

// MARK: - Runners

/// A question the section words itself — for money, keys and access, where the generic
/// "<Summary>: …?" with a "Run" button says too little.
struct VoicesStudioQuestion: Equatable, Sendable {
    var title: String
    var confirmLabel: String
    var consequence: String
    /// One more line, set apart: money, what else stops working.
    var warning: String?

    init(_ title: String, button confirmLabel: String, consequence: String, warning: String? = nil) {
        self.title = title
        self.confirmLabel = confirmLabel
        self.consequence = consequence
        self.warning = warning
    }
}

/// One runner per operation a section uses, made when first needed, and the action whose
/// outcome the section shows at its foot.
///
/// Lists and lookups run "quietly": their failures show where the list is, and they stay out
/// of the pane's recent results. Everything the owner asked for — create, edit, delete,
/// generate, download — becomes `last`, so its errors, a credential shown once, and "Show API
/// call" appear in one predictable place.
///
/// Money: a screen runs one spending call at a time (`billableInFlight`), and a spending call
/// that was cancelled or lost after it was sent leaves an *unknown outcome* — it may have
/// started and been billed — which holds every further spending call on the screen until the
/// owner has checked (`acknowledgeUnknownOutcomes`). The screen's list is fetched again at once
/// (`onUnknownOutcome`) so there is something to check.
@MainActor
@Observable
final class VoicesStudioActions {
    /// Spending calls that leave nothing lasting behind when their answer is lost (voice design
    /// previews), so a repeat after a cancel needs no check.
    static let passingSpends: Set<String> = [
        "text_to_voice_design", "text_to_voice_remix", "text_to_voice_preview_stream",
    ]

    @ObservationIgnored let context: ElevenLabsRunner.Context
    @ObservationIgnored private var runners: [String: ElevenLabsRunner] = [:]
    /// Operations performing now with a spending override (`perform(…, spends: true)`).
    private var spendingOverrides: Set<String> = []
    /// The last action the owner started.
    private(set) var last: ElevenLabsRunner?
    /// An operation this build's catalog does not have — a spec refresh renamed it. The
    /// section says so rather than failing silently.
    private(set) var missingOperation: String?
    /// Why the last attempt was refused without sending anything.
    private(set) var refusal: String?
    /// A question for an operation that does not ask by itself (an edit that replaces a
    /// project's content), waiting for its answer.
    private(set) var pendingQuestion: ElevenLabsConfirmationRequest?
    @ObservationIgnored private var pendingAnswer: CheckedContinuation<Bool, Never>?
    /// Spending calls whose outcome is unknown — cancelled or lost after they were sent — by
    /// operation, with what they were.
    private(set) var unknownOutcomes: [String: String] = [:]
    /// Fetches the section's list again after an unknown outcome, so the owner can see whether
    /// the thing was made.
    @ObservationIgnored var onUnknownOutcome: (@MainActor (String) async -> Void)?
    /// The runners (operation, or operation and slot) whose last `perform` gave no answer though
    /// what it sent may have been carried out — spending or not. See `outcomeWasUnknown`.
    @ObservationIgnored private var lastRunUnknown: Set<String> = []
    /// Lists and lookups that failed, by operation, with why — until that read runs again.
    private(set) var readFailures: [String: String] = [:]
    /// The reads whose failure the section draws where their content goes (its lists, a voice's
    /// settings). The foot names every other failed read, so a detail that could not be fetched
    /// says why instead of staying empty or stale.
    @ObservationIgnored var readsShownInPlace: Set<String> = []

    /// The failed reads the foot names: those not drawn in place, and not `except` (the foot's
    /// own fallback runner, which it describes already).
    func readProblems(except: String? = nil) -> [(operationID: String, text: String)] {
        readFailures.keys.sorted()
            .filter { !readsShownInPlace.contains($0) && $0 != except }
            .map { id in
                let what = runners[id].map { $0.operation.summary } ?? id
                return (id, "“\(what)” could not be read: \(readFailures[id] ?? "")")
            }
    }

    init(context: ElevenLabsRunner.Context) {
        self.context = context
    }

    /// The runner for `operationID`, made on first use; nil when the catalog has no such
    /// operation. A `slot` gives the operation a runner of its own for that purpose.
    func runner(_ operationID: String, slot: String? = nil) -> ElevenLabsRunner? {
        let key = Self.key(operationID, slot)
        if let existing = runners[key] { return existing }
        guard let made = ElevenLabsRunner(operationID: operationID, context: context) else { return nil }
        runners[key] = made
        return made
    }

    /// The slot for fetching an item again after a change to it. A runner abandons a read in
    /// flight when it is asked again, so this fetch has a runner of its own: it never abandons
    /// the read of an item the owner opened meanwhile, nor is abandoned by it.
    static let afterChange = "after-change"

    /// `afterChange` for one item: a runner per item, so two changes to two items that finish
    /// close together each fetch their own item again — the second never abandons the first's
    /// read. A newer refetch of the same item still replaces an older one.
    static func afterChange(of id: String) -> String { "\(afterChange)/\(id)" }

    private static func key(_ operationID: String, _ slot: String?) -> String {
        slot.map { "\(operationID)#\($0)" } ?? operationID
    }

    /// Whether `operationID` (on `slot`'s runner, when one is given) is running right now.
    func isRunning(_ operationID: String, slot: String? = nil) -> Bool {
        runners[Self.key(operationID, slot)]?.isRunning ?? false
    }

    /// Every runner of this screen that is running or waiting for its question to be answered.
    var active: [ElevenLabsRunner] {
        runners.values.filter { $0.isRunning || $0.isAwaitingConfirmation }
            .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    /// Whether a run of `runner` spends credits or money: its operation is billable, or the
    /// section said so for this run (a Studio project created with "convert now").
    func spends(_ runner: ElevenLabsRunner) -> Bool {
        runner.operation.billable || spendingOverrides.contains(runner.operation.id)
    }

    /// The spending call under way on this screen, if one is. A screen holds several runners —
    /// one per operation, and switching a mode or a model swaps the one its Run button watches
    /// — so a second spending call is refused here rather than by the button alone.
    var billableInFlight: ElevenLabsRunner? {
        runners.values.first { ($0.isRunning || $0.isAwaitingConfirmation) && spends($0) }
    }

    /// Why a spending run of `runner` may not start now; nil when it may. Free runs are never
    /// held.
    func blockReason(_ runner: ElevenLabsRunner, spends override: Bool? = nil) -> String? {
        guard override ?? runner.operation.billable else { return nil }
        if let busy = billableInFlight {
            return "“\(busy.title ?? busy.operation.summary)” is still running and spending credits; "
                + "wait for it or cancel it before starting another."
        }
        if let title = unknownOutcomes.values.sorted().first {
            return "“\(title)” was stopped after it was sent and may already have been started and billed. "
                + "Check the list above, then press “I have checked” before starting another."
        }
        return nil
    }

    /// Whether a spending run of `runner` may not start now.
    func isBlocked(_ runner: ElevenLabsRunner, spends override: Bool? = nil) -> Bool {
        blockReason(runner, spends: override) != nil
    }

    /// The owner has looked: spending calls may start again.
    func acknowledgeUnknownOutcomes() {
        unknownOutcomes = [:]
        refusal = nil
    }

    /// Runs an operation through its runner. See `ElevenLabsRunner.perform`.
    ///
    /// - Parameters:
    ///   - quietly: For lists and lookups: not shown at the foot, not recorded in the pane's
    ///     recent results.
    ///   - spends: Overrides whether this run spends (nil: the operation's `billable`).
    ///   - question: The section's own question. For an operation that asks by itself it is
    ///     the runner's question, whole (the shell's `title:`/`confirmLabel:`/`warning:`); for one
    ///     that does not, it is asked first and nothing is sent on a no.
    @discardableResult
    func perform(
        _ operationID: String, _ arguments: [String: JSONValue] = [:],
        files: [String: [ElevenLabsFile]] = [:], subject: String? = nil,
        consequence: String? = nil, title: String? = nil, quietly: Bool = false,
        spends: Bool? = nil, question: VoicesStudioQuestion? = nil, slot: String? = nil
    ) async -> ElevenLabsResult? {
        let key = Self.key(operationID, slot)
        // Only a run that is sent below can leave an unknown outcome: one refused, declined or
        // not sent says nothing about an earlier one (whose phase the runner may still show).
        lastRunUnknown.remove(key)
        guard let runner = runner(operationID, slot: slot) else {
            missingOperation = operationID
            return nil
        }
        let spendsNow = spends ?? runner.operation.billable
        if let reason = blockReason(runner, spends: spendsNow) {
            refusal = reason
            return nil
        }
        refusal = nil
        runner.title = title
        runner.recordsResults = !quietly
        if !quietly { last = runner } else { readFailures[key] = nil }
        if let question, !runner.operation.requiresConfirmation {
            guard await ask(question, for: runner.operation) else { return nil }
        }
        if spendsNow { spendingOverrides.insert(operationID) }
        let asks = question != nil && runner.operation.requiresConfirmation
        let result = await runner.perform(
            arguments: arguments, files: files, subject: subject,
            consequence: asks ? question?.consequence : consequence,
            title: asks ? question?.title : nil, confirmLabel: asks ? question?.confirmLabel : nil,
            warning: asks ? question?.warning : nil
        )
        spendingOverrides.remove(operationID)
        if result == nil, Self.outcomeIsUnknown(runner) { lastRunUnknown.insert(key) }
        if quietly {
            // A read replaced by a newer one of the same operation leaves the runner to it.
            readFailures[key] = runner.phase == .failed ? (runner.errorMessage ?? "it failed.") : nil
        }
        if spendsNow, result == nil, !Self.passingSpends.contains(operationID), Self.outcomeIsUnknown(runner) {
            unknownOutcomes[operationID] = title ?? runner.operation.summary
            await onUnknownOutcome?(operationID)
        }
        return result
    }

    /// Whether the last `perform` of `operationID` (on `slot`) gave no answer, yet what it sent may
    /// have been carried out: cancelled after it was sent, or its answer lost (a 5xx, a timeout,
    /// no connection). A refusal ElevenLabs gave, a question answered no, or a run refused before
    /// sending is not. Read straight after the `perform` that returned nil.
    ///
    /// A section treats a change with an unknown outcome as one that may have landed: it reads
    /// the item again, and its editor waits for that read rather than starting from a row the
    /// change may have made stale.
    func outcomeWasUnknown(_ operationID: String, slot: String? = nil) -> Bool {
        lastRunUnknown.contains(Self.key(operationID, slot))
    }

    /// Whether a failed or stopped run may still have been carried out: cancelled after it
    /// started, or lost on the way back (no connection, a timeout, a 408, a server error). A
    /// refusal ElevenLabs gave (another 4xx, a 429 included) or arguments refused before sending
    /// are known outcomes — read off the failure's HTTP status (`provesNothingWasDone`), not its
    /// words.
    static func outcomeIsUnknown(_ runner: ElevenLabsRunner) -> Bool {
        switch runner.phase {
        case .cancelled:
            return true
        case .failed:
            // A question confirmed after the account changed sent nothing: `provesNothingWasDone`.
            guard let failure = runner.failure else { return false }
            return !failure.provesNothingWasDone
        default:
            return false
        }
    }

    // MARK: Questions

    /// The question on screen for this section, if one is waiting: one for an operation that
    /// does not ask by itself, or a runner's own when no pane asks for it (a test's, a preview's).
    /// In the app the pane asks every runner's question.
    var presentedQuestion: ElevenLabsConfirmationRequest? {
        if let pendingQuestion { return pendingQuestion }
        return runners.values.first { $0.presentsOwnConfirmation && $0.isAwaitingConfirmation }?.confirmation
    }

    /// Answers the question on screen. A yes to the section's own question given after the
    /// account or region changed sends nothing; a runner's question checks that itself (the
    /// shell's runner refuses a confirmed question whose account changed).
    func answer(_ yes: Bool) {
        if let continuation = pendingAnswer {
            let changed = accountMark() != pendingMark
            pendingAnswer = nil
            pendingQuestion = nil
            if yes, changed { refusal = ElevenLabsRunner.accountChangedMessage }
            continuation.resume(returning: yes && !changed)
            return
        }
        guard let runner = runners.values.first(where: { $0.presentsOwnConfirmation && $0.isAwaitingConfirmation })
        else { return }
        if yes { runner.confirm() } else { runner.decline() }
    }

    /// Which account a question is asked under: the pane's session epoch — which moves on a
    /// disconnect, a new key or another region — and, where there is no pane (a test's
    /// context), the client itself.
    private func accountMark() -> String {
        if let epoch = context.pane?.epoch { return "epoch \(epoch)" }
        return context.client().map { "client \(ObjectIdentifier($0).hashValue)" } ?? "none"
    }

    @ObservationIgnored private var pendingMark: String?

    private func ask(_ question: VoicesStudioQuestion, for operation: ElevenLabsOperation) async -> Bool {
        pendingAnswer?.resume(returning: false)
        pendingMark = accountMark()
        pendingQuestion = ElevenLabsConfirmationRequest(
            operationID: operation.id, risk: .destructive, title: question.title,
            consequence: question.consequence, call: "\(operation.method) \(operation.path)",
            confirmLabel: question.confirmLabel
        )
        return await withCheckedContinuation { pendingAnswer = $0 }
    }

    // MARK: Credentials

    /// Forgets every credential shown once on this screen: when the owner selects something
    /// else, or leaves the section.
    func dismissCredentials() {
        for runner in runners.values where runner.credential != nil { runner.dismissCredential() }
    }

    /// The failure of a quiet run, in words, for the place its list is drawn.
    func problem(_ operationID: String, slot: String? = nil) -> String? {
        guard let runner = runners[Self.key(operationID, slot)], runner.phase == .failed else { return nil }
        return runner.errorMessage
    }

    /// Forgets the last action shown at the foot.
    func clearLast() {
        last = nil
    }
}

/// A model that speaks text, as `GET /v1/models` lists it — for the sections whose projects
/// name a speech model (Studio, podcasts, Audio Native).
struct VoicesStudioSpeechModel: Identifiable, Hashable, Sendable {
    var id: String
    var name: String

    /// The speech models in a `GET /v1/models` answer, in its order.
    static func speechModels(in json: JSONValue) -> [VoicesStudioSpeechModel] {
        (json.arrayValue ?? []).compactMap { entry in
            guard let id = entry["model_id"].stringValue, entry["can_do_text_to_speech"].boolValue != false
            else { return nil }
            return VoicesStudioSpeechModel(id: id, name: entry["name"].stringValue ?? id)
        }
    }
}

extension VoicesStudioActions {
    /// The account's speech models; empty when they could not be fetched (the picker then
    /// leaves the model to ElevenLabs' default).
    func speechModels() async -> [VoicesStudioSpeechModel] {
        guard let json = await perform("get_models", quietly: true)?.voicesStudioJSON else { return [] }
        return VoicesStudioSpeechModel.speechModels(in: json)
    }
}

// MARK: - Results

extension ElevenLabsResult {
    /// The JSON body: `.json`'s value, or the first JSON part of `.parts` — where the client
    /// puts an answer whose base64 audio it moved into files.
    var voicesStudioJSON: JSONValue? {
        switch self {
        case .json(let value, _): return value
        case .parts(let parts, _):
            for part in parts { if case .json(let value) = part { return value } }
            return nil
        case .file, .text, .events: return nil
        }
    }

    /// Every file the answer wrote, with its type, in the order the answer carried them.
    var voicesStudioFiles: [VoicesStudioFile] {
        switch self {
        case .file(let url, let contentType, let bytes, _):
            return [VoicesStudioFile(url: url, contentType: contentType, bytes: bytes)]
        case .parts(let parts, _):
            return parts.compactMap {
                if case .file(let url, let contentType, let bytes) = $0 {
                    VoicesStudioFile(url: url, contentType: contentType, bytes: bytes)
                } else { nil }
            }
        case .json, .text, .events: return []
        }
    }

    /// An inline text answer (a PLS lexicon, subtitles), if that is what came back.
    var voicesStudioText: String? {
        if case .text(let text, _) = self { return text }
        return nil
    }
}

/// A file an answer wrote, where the section can play or show it.
struct VoicesStudioFile: Hashable, Sendable, Identifiable {
    var url: URL
    var contentType: String
    var bytes: Int
    var id: URL { url }

    var isAudio: Bool { contentType.lowercased().hasPrefix("audio/") }
    var isVideo: Bool { contentType.lowercased().hasPrefix("video/") }
}

// MARK: - Catalog

/// What a section reads from the pinned spec to build its controls — names, choices, ranges,
/// defaults — so a spec refresh that renames or narrows something shows up in a test rather
/// than as a 422 in the owner's hands.
enum VoicesStudioSchema {
    /// The schema of one argument: a path, query or header parameter, or a body property. A
    /// dotted name reaches into nested objects (`settings.webhook_url`); `[]` steps into an
    /// array's items (`rules[].alias`). Unions are searched shape by shape.
    static func schema(_ operationID: String, _ argument: String) -> JSONValue? {
        guard let operation = ElevenLabsCatalog.operation(operationID) else { return nil }
        let steps = argument.split(separator: ".").map(String.init)
        guard let first = steps.first else { return nil }
        var current: JSONValue
        if let parameter = operation.parameter(named: first.replacingOccurrences(of: "[]", with: "")) {
            current = parameter.schema
            if first.hasSuffix("[]") { current = items(of: current) ?? .null }
            return descend(current, through: Array(steps.dropFirst()))
        }
        guard let body = operation.body else { return nil }
        current = body.schema
        return descend(current, through: steps)
    }

    /// Whether the operation takes this argument at all.
    static func has(_ operationID: String, _ argument: String) -> Bool {
        schema(operationID, argument) != nil
    }

    /// The values an argument's `enum` lists, as strings, in spec order.
    static func choices(_ operationID: String, _ argument: String) -> [String] {
        guard let schema = schema(operationID, argument) else { return [] }
        return enumValues(schema)
    }

    /// The closed range an argument's `minimum`/`maximum` allow, when both are given.
    static func range(_ operationID: String, _ argument: String) -> ClosedRange<Double>? {
        guard let schema = schema(operationID, argument).map(concrete),
              let low = schema["minimum"].doubleValue, let high = schema["maximum"].doubleValue,
              low <= high
        else { return nil }
        return low...high
    }

    static func defaultValue(_ operationID: String, _ argument: String) -> JSONValue? {
        guard let raw = schema(operationID, argument) else { return nil }
        if raw["default"] != .null { return raw["default"] }
        let inner = concrete(raw)["default"]
        return inner == .null ? nil : inner
    }

    static func defaultNumber(_ operationID: String, _ argument: String) -> Double? {
        defaultValue(operationID, argument)?.doubleValue
    }

    static func maxLength(_ operationID: String, _ argument: String) -> Int? {
        schema(operationID, argument).flatMap { concrete($0)["maxLength"].intValue }
    }

    static func minLength(_ operationID: String, _ argument: String) -> Int? {
        schema(operationID, argument).flatMap { concrete($0)["minLength"].intValue }
    }

    /// The argument's description — vendor text, for help tags and the spec test.
    static func description(_ operationID: String, _ argument: String) -> String {
        guard let operation = ElevenLabsCatalog.operation(operationID) else { return "" }
        if !argument.contains("."), let parameter = operation.parameter(named: argument) {
            return parameter.description
        }
        guard let schema = schema(operationID, argument) else { return "" }
        return schema["description"].stringValue ?? concrete(schema)["description"].stringValue ?? ""
    }

    // MARK: Walking

    private static func descend(_ start: JSONValue, through steps: [String]) -> JSONValue? {
        var current = start
        for step in steps {
            let wantsItems = step.hasSuffix("[]")
            let name = wantsItems ? String(step.dropLast(2)) : step
            guard let next = property(name, of: current) else { return nil }
            current = next
            if wantsItems {
                guard let inner = items(of: current) else { return nil }
                current = inner
            }
        }
        return current
    }

    private static func property(_ name: String, of schema: JSONValue) -> JSONValue? {
        let shape = concrete(schema)
        if let found = shape["properties"].objectValue?[name] { return found }
        for variant in variants(of: shape) {
            if let found = property(name, of: variant) { return found }
        }
        return nil
    }

    private static func items(of schema: JSONValue) -> JSONValue? {
        let shape = concrete(schema)
        if shape["type"].stringValue == "array" { return shape["items"] }
        for variant in variants(of: shape) where concrete(variant)["type"].stringValue == "array" {
            return concrete(variant)["items"]
        }
        return nil
    }

    private static func variants(of schema: JSONValue) -> [JSONValue] {
        (schema["anyOf"].arrayValue ?? schema["oneOf"].arrayValue ?? [])
            .filter { $0["type"].stringValue != "null" }
    }

    /// The schema without its nullable wrapper and with a lone `allOf` merged in.
    static func concrete(_ schema: JSONValue) -> JSONValue {
        let unwrapped = JSONSchema.unwrapNullable(schema)
        if let parts = unwrapped["allOf"].arrayValue, parts.count == 1 { return concrete(parts[0]) }
        return unwrapped
    }

    private static func enumValues(_ schema: JSONValue) -> [String] {
        let shape = concrete(schema)
        if let values = shape["enum"].arrayValue {
            return values.compactMap(\.stringValue)
        }
        // A list of enum values (a multi-select filter): the items' values.
        if shape["type"].stringValue == "array" { return enumValues(shape["items"]) }
        // A union of enums (a field that takes a model id or a free string): the listed ones.
        var found: [String] = []
        for variant in variants(of: shape) {
            for value in enumValues(variant) where !found.contains(value) { found.append(value) }
        }
        return found
    }
}

/// One control a section draws, and the spec argument it sets — held to the catalog by a
/// test, so a renamed or removed argument fails the suite rather than the owner's call.
struct VoicesStudioControl: Hashable, Sendable, CustomStringConvertible {
    var operationID: String
    /// The argument, dotted for nested body fields (see `VoicesStudioSchema.schema`).
    var argument: String
    /// Values the screen offers that the spec lists only in prose — the argument's
    /// description — rather than as an `enum`. The test finds each of them there.
    var describedValues: [String]
    /// The control is a picker over the argument's `enum`, read from the catalog at run
    /// time; the test holds the spec to still listing values for it.
    var enumerated: Bool

    init(_ operationID: String, _ argument: String, describedValues: [String] = [], enumerated: Bool = false) {
        self.operationID = operationID
        self.argument = argument
        self.describedValues = describedValues
        self.enumerated = enumerated
    }

    var description: String { "\(operationID).\(argument)" }
}

// MARK: - Formatting

enum VoicesStudioFormat {
    static func date(unixSeconds: Int?) -> String? {
        guard let unixSeconds, unixSeconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(unixSeconds))
            .formatted(date: .abbreviated, time: .shortened)
    }

    static func date(unixMilliseconds: Int?) -> String? {
        guard let unixMilliseconds else { return nil }
        return date(unixSeconds: unixMilliseconds / 1000)
    }

    /// An ISO 8601 timestamp as the owner reads dates; the text itself when it does not parse.
    static func date(iso: String?) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = full.date(from: iso) ?? plain.date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let whole = Int(seconds.rounded())
        if whole >= 3600 { return String(format: "%d:%02d:%02d", whole / 3600, whole % 3600 / 60, whole % 60) }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    static func bytes(_ count: Int?) -> String? {
        guard let count else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// `fine_tuning` → "Fine tuning".
    static func words(_ identifier: String) -> String {
        ElevenLabsFormField.humanized(identifier)
    }

    /// Comma-separated text as a list, blanks dropped.
    static func list(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A string argument, or nothing when the field is blank — so ElevenLabs applies its own
    /// default instead of receiving "".
    static func text(_ value: String) -> JSONValue? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : .string(trimmed)
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    /// Sets `key` only when there is a value — the builders' way of leaving blanks out.
    mutating func voicesStudioSet(_ key: String, _ value: JSONValue?) {
        if let value { self[key] = value }
    }
}

// MARK: - Views

/// A state word as a coloured capsule: green when done, blue while working, red when failed.
struct VoicesStudioStatusBadge: View {
    let status: String

    var body: some View {
        // Studio calls an idle project "default"; to the owner it is ready.
        Badge(text: status == "default" ? "Ready" : VoicesStudioFormat.words(status), tint: Self.tint(status))
    }

    static func tint(_ status: String) -> Color {
        switch status.lowercased() {
        case "done", "ready", "completed", "complete", "dubbed", "fine_tuned", "active", "enabled",
             "accepted", "paid", "succeeded", "verified", "default":
            .green
        case "queued", "preparing", "processing", "dubbing", "converting", "fine_tuning", "generating",
             "pending", "in_queue", "creating", "submitted", "running", "cancelling", "delayed":
            .blue
        case "failed", "error", "rejected", "cancelled", "expired", "disabled", "stale":
            .red
        default:
            .secondary
        }
    }
}

/// What a list shows besides its rows: a spinner while it loads, why it failed, or a line
/// saying there is nothing yet.
struct VoicesStudioListState: View {
    let loading: Bool
    let problem: String?
    let isEmpty: Bool
    var emptyText: String

    var body: some View {
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if loading, isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            }
        } else if isEmpty {
            Text(emptyText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// A number with a slider over the range the spec allows, and the value beside it.
struct VoicesStudioSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var help: String = ""

    var body: some View {
        // Continuous: a stepped slider draws a tick per step, a comb of hundreds of them.
        // The value is rounded to `step` as it changes instead.
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 110, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { value = Self.rounded($0, step: step) }), in: range)
            Text(Self.format(value, step: step))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .help(help)
    }

    static func rounded(_ value: Double, step: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }

    static func format(_ value: Double, step: Double) -> String {
        step >= 1 ? String(Int(value.rounded())) : String(format: "%.2f", value)
    }
}

/// A picker over the values the spec's `enum` lists, with a "Default" choice that sends
/// nothing.
struct VoicesStudioChoicePicker: View {
    let title: String
    @Binding var selection: String
    let choices: [String]
    /// The label of the empty choice; nil when a value is required.
    var defaultLabel: String? = "Default"

    var body: some View {
        Picker(title, selection: $selection) {
            if let defaultLabel { Text(defaultLabel).tag("") }
            ForEach(choices, id: \.self) { choice in
                Text(VoicesStudioChoicePicker.label(choice)).tag(choice)
            }
        }
    }

    static func label(_ choice: String) -> String {
        choice.contains("_") && !choice.contains(" ") && choice.first?.isLowercase == true
            && !choice.hasPrefix("mp3") && !choice.hasPrefix("pcm") && !choice.hasPrefix("opus")
            && !choice.hasPrefix("ulaw") && !choice.hasPrefix("alaw") && !choice.hasPrefix("eleven")
            ? VoicesStudioFormat.words(choice) : choice
    }
}

/// An upload field: the shell's file picker under a label.
struct VoicesStudioFilePicker: View {
    let title: String
    @Binding var files: [URL]
    var multiple = false
    var help: String = ""

    var body: some View {
        LabeledContent(title) {
            ElevenLabsFilePickerField(files: $files, multiple: multiple)
        }
        .help(help)
    }
}

/// A row of label and value, the value selectable.
struct VoicesStudioFact: View {
    let label: String
    let value: String?

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value
    }

    var body: some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                Text(value)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }
}

/// The foot of every section: calls under way with Cancel, spending calls whose outcome is
/// unknown with "I have checked", the last action's errors, a credential shown once, its result
/// when asked, and "Show API call" — or, before any action, the list's API call. The questions
/// this section words itself are asked from here.
struct VoicesStudioActivity: View {
    let actions: VoicesStudioActions
    /// The runner to describe before any action runs — usually the section's main list.
    var fallback: ElevenLabsRunner?
    /// Whether the last action's result is drawn here too (off when the section draws it in
    /// its own way).
    var showsResult = false
    /// The section shows a credential where it was made (a new key, a webhook secret), so the
    /// foot does not show it a second time.
    var credentialsInline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let missing = actions.missingOperation {
                Label(
                    "This build's operations catalog has no “\(missing)”. The Explorer lists what it has.",
                    systemImage: "questionmark.diamond"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }
            ForEach(actions.active.filter(\.isRunning), id: \.id) { runner in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working: \(runner.title ?? runner.operation.summary)")
                        .font(.callout)
                        .lineLimit(1)
                    if actions.spends(runner) { ElevenLabsRiskBadge(risk: .generate) }
                    Spacer()
                    Button("Cancel") { runner.cancel() }
                        .controlSize(.small)
                }
            }
            if !actions.unknownOutcomes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(actions.unknownOutcomes.values.sorted(), id: \.self) { title in
                        Label("“\(title)” was stopped after it was sent. It may already have been started and billed.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Text("The list above has been fetched again. Check it before starting anything else that costs credits.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("I have checked") { actions.acknowledgeUnknownOutcomes() }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(.orange.opacity(0.08), in: .rect(cornerRadius: 8))
            }
            ForEach(actions.readProblems(except: fallback?.operation.id), id: \.operationID) { problem in
                Label(problem.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let refusal = actions.refusal {
                Label(refusal, systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let runner = actions.last ?? fallback {
                VoicesStudioRunnerOutput(
                    runner: runner, showsResult: showsResult && actions.last != nil,
                    showsCredential: !credentialsInline
                )
                .id(runner.id)
            }
        }
        .sheet(item: Binding(
            get: { actions.presentedQuestion },
            set: { if $0 == nil { actions.answer(false) } }
        )) { request in
            ElevenLabsRiskConfirmation(
                request: request, onConfirm: { actions.answer(true) }, onCancel: { actions.answer(false) }
            )
        }
    }
}

/// What a run leaves on screen — the shell's `ElevenLabsRunnerOutput` without its own question
/// sheet, which the foot asks instead (worded by the section where it chose to).
struct VoicesStudioRunnerOutput: View {
    let runner: ElevenLabsRunner
    var showsResult = true
    var showsCredential = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure = runner.failure {
                switch failure {
                case .invalidArguments(let problems):
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nothing was sent:").font(.caption.weight(.medium))
                        ElevenLabsProblemList(problems: problems)
                    }
                default:
                    Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let refusal = runner.refusal {
                Label(refusal, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if runner.phase == .cancelled, let note = runner.cancellationNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if showsCredential, let credential = runner.credential {
                ElevenLabsCredentialReveal(credential: credential) { runner.dismissCredential() }
            }
            if showsResult, let result = runner.result {
                ElevenLabsResultView(
                    result: result, operation: runner.operation,
                    outputFormat: runner.arguments["output_format"]?.stringValue
                )
            }
            if runner.apiCall != nil || runner.phase != .idle {
                ElevenLabsAPICallDisclosure(runner: runner)
            }
        }
    }
}

/// The shell's Run button, held while another spending call on the same screen is under way
/// or one's outcome is unknown — the button alone watches only its own runner, and a screen
/// swaps runners when a mode or model changes. The call under way is named, with Cancel, in the
/// section's foot.
struct VoicesStudioRunButton: View {
    let actions: VoicesStudioActions
    let runner: ElevenLabsRunner
    var title = "Run"
    var estimatedCharacters: Int?
    var disabled = false
    var disabledReason: String?
    /// The section's words for what it costs, from the spec, in place of the generated note.
    var costNote: String?
    /// Overrides whether this run spends (a Studio create with "convert now").
    var spends: Bool?
    let action: () -> Void

    var body: some View {
        let blocked = runner.isRunning ? nil : actions.blockReason(runner, spends: spends)
        ElevenLabsRunButton(
            runner: runner, title: title, estimatedCharacters: estimatedCharacters,
            disabled: disabled || blocked != nil, disabledReason: blocked ?? disabledReason,
            costNote: costNote, action: action
        )
    }
}

/// "Load more" under a paged list.
struct VoicesStudioMoreButton: View {
    let hasMore: Bool
    let loading: Bool
    let action: () -> Void

    var body: some View {
        if hasMore {
            HStack {
                Button("Load more", action: action)
                    .disabled(loading)
                if loading { ProgressView().controlSize(.small) }
            }
        }
    }
}

/// A text field with a character count against the spec's limits.
struct VoicesStudioCountedEditor: View {
    let title: String
    @Binding var text: String
    var minimum: Int?
    var maximum: Int?
    var height: CGFloat = 80
    var prompt: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(countText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isOutOfRange ? .red : .secondary)
            }
            ElevenLabsTextArea(text: $text, prompt: prompt.isEmpty ? nil : prompt, minHeight: height)
        }
    }

    private var isOutOfRange: Bool {
        guard !text.isEmpty else { return false }
        if let minimum, text.count < minimum { return true }
        if let maximum, text.count > maximum { return true }
        return false
    }

    private var countText: String {
        switch (minimum, maximum) {
        case (let low?, let high?): "\(text.count) / \(low)–\(high)"
        case (nil, let high?): "\(text.count) / \(high)"
        case (let low?, nil): "\(text.count) (at least \(low))"
        case (nil, nil): "\(text.count)"
        }
    }
}

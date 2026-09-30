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

/// Section models kept for as long as the app model lives, so work in progress — voice
/// previews that already cost credits, a half-filled form, the project on screen — survives a
/// trip to another section and back. The main window draws one section at a time behind a
/// `switch`, so a model held in the view's `@State` would be thrown away on every trip.
///
/// Dropped when the link changes (disconnect, another region), so one account's projects are
/// never shown under another's.
@MainActor
enum VoicesStudioModels {
    final class Box {
        var signature: String
        var models: [ObjectIdentifier: AnyObject] = [:]
        init(signature: String) { self.signature = signature }
    }

    private static let table = NSMapTable<AppModel, Box>.weakToStrongObjects()

    static func model<Model: AnyObject>(
        _ type: Model.Type, for app: AppModel, make: (VoicesStudioEnvironment) -> Model
    ) -> Model {
        let signature = "\(app.elevenLabsLinked)|\(app.elevenLabsRegion.rawValue)"
        let box: Box
        if let existing = table.object(forKey: app), existing.signature == signature {
            box = existing
        } else {
            box = Box(signature: signature)
            table.setObject(box, forKey: app)
        }
        if let existing = box.models[ObjectIdentifier(type)] as? Model { return existing }
        let made = make(.app(app))
        box.models[ObjectIdentifier(type)] = made
        return made
    }
}

// MARK: - Runners

/// One runner per operation a section uses, made when first needed, and the action whose
/// outcome the section shows at its foot.
///
/// Lists and lookups run "quietly": their failures show where the list is, and they stay out
/// of the pane's recent results. Everything the owner asked for — create, edit, delete,
/// generate, download — becomes `last`, so its errors, a credential shown once, and "Show API
/// call" appear in one predictable place, which is also where a risky operation's
/// confirmation sheet hangs.
@MainActor
@Observable
final class VoicesStudioActions {
    @ObservationIgnored let context: ElevenLabsRunner.Context
    @ObservationIgnored private var runners: [String: ElevenLabsRunner] = [:]
    /// The last action the owner started.
    private(set) var last: ElevenLabsRunner?
    /// An operation this build's catalog does not have — a spec refresh renamed it. The
    /// section says so rather than failing silently.
    private(set) var missingOperation: String?

    init(context: ElevenLabsRunner.Context) {
        self.context = context
    }

    /// The runner for `operationID`, made on first use; nil when the catalog has no such
    /// operation.
    func runner(_ operationID: String) -> ElevenLabsRunner? {
        if let existing = runners[operationID] { return existing }
        guard let made = ElevenLabsRunner(operationID: operationID, context: context) else { return nil }
        runners[operationID] = made
        return made
    }

    /// Whether `operationID` is running right now.
    func isRunning(_ operationID: String) -> Bool {
        runners[operationID]?.isRunning ?? false
    }

    /// Runs an operation through its runner. See `ElevenLabsRunner.perform`.
    ///
    /// - Parameter quietly: For lists and lookups: not shown at the foot, not recorded in the
    ///   pane's recent results.
    @discardableResult
    func perform(
        _ operationID: String, _ arguments: [String: JSONValue] = [:],
        files: [String: [ElevenLabsFile]] = [:], subject: String? = nil,
        consequence: String? = nil, title: String? = nil, quietly: Bool = false
    ) async -> ElevenLabsResult? {
        guard let runner = runner(operationID) else {
            missingOperation = operationID
            return nil
        }
        runner.title = title
        runner.recordsResults = !quietly
        if !quietly { last = runner }
        return await runner.perform(
            arguments: arguments, files: files, subject: subject, consequence: consequence
        )
    }

    /// The failure of a quiet run, in words, for the place its list is drawn.
    func problem(_ operationID: String) -> String? {
        guard let runner = runners[operationID], runner.phase == .failed else { return nil }
        return runner.errorMessage
    }

    /// Forgets the last action shown at the foot.
    func clearLast() {
        last = nil
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
        Badge(text: VoicesStudioFormat.words(status), tint: Self.tint(status))
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

/// The foot of every section: the last action's errors, a credential shown once, its result
/// when asked, and "Show API call" — or, before any action, the list's API call.
struct VoicesStudioActivity: View {
    let actions: VoicesStudioActions
    /// The runner to describe before any action runs — usually the section's main list.
    var fallback: ElevenLabsRunner?
    /// Whether the last action's result is drawn here too (off when the section draws it in
    /// its own way).
    var showsResult = false

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
            if let runner = actions.last ?? fallback {
                ElevenLabsRunnerOutput(runner: runner, showsResult: showsResult && actions.last != nil)
                    .id(runner.id)
            }
        }
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

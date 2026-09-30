import Foundation
import Observation
import SiliconElevenLabs

/// The values of an operation's generated form, and the arguments they make.
///
/// `ElevenLabsOperationForm` draws it; the Explorer builds one per operation; a section can
/// build one for a subset of an operation's fields (`only:`) — its advanced options, say —
/// and merge `arguments()` into what its own controls produce.
@MainActor
@Observable
final class ElevenLabsFormModel {
    let operation: ElevenLabsOperation
    let fields: [ElevenLabsFormField]
    let nodes: [ElevenLabsFormNode]
    /// The body edited as one JSON object instead of field by field.
    private(set) var editsBodyAsJSON = false
    var bodyJSON = ""
    /// The problems found by the last `check()`, plus any the client reported afterwards.
    private(set) var problems: [String] = []

    /// - Parameter only: Argument names to include; nil for every field.
    init(operation: ElevenLabsOperation, only: Set<String>? = nil) {
        self.operation = operation
        let fields = ElevenLabsFormField.fields(for: operation)
            .filter { only?.contains($0.name) ?? true }
        self.fields = fields
        nodes = fields.map { ElevenLabsFormNode(field: $0) }
    }

    func nodes(in location: ElevenLabsFormField.Location) -> [ElevenLabsFormNode] {
        nodes.filter { $0.field.location == location }
    }

    /// Whether any field is required.
    var hasRequiredFields: Bool { fields.contains(where: \.required) }

    /// The arguments and files these values make, and every problem with them. Blank
    /// optional fields are left out, so ElevenLabs applies its own defaults.
    func arguments() -> (arguments: [String: JSONValue], files: [String: [ElevenLabsFile]], problems: [String]) {
        var arguments: [String: JSONValue] = [:]
        var files: [String: [ElevenLabsFile]] = [:]
        var problems: [String] = []

        for node in nodes {
            if case .file = node.field.kind {
                if !node.files.isEmpty {
                    files[node.field.name] = node.files.map { ElevenLabsFile(url: $0) }
                } else if node.field.required {
                    problems.append("\(node.field.name) needs a file.")
                }
                continue
            }
            if editsBodyAsJSON, node.field.location == .body { continue }
            if let value = node.value(path: node.field.name, problems: &problems) {
                arguments[node.field.name] = value
            }
        }

        if editsBodyAsJSON {
            let text = bodyJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                switch try? JSONValue(data: Data(text.utf8)) {
                case .object(let object) where operation.body?.contentType == .multipart:
                    arguments.merge(object) { _, typed in typed }
                case .some(let value):
                    arguments["body"] = value
                case .none:
                    problems.append("The body is not valid JSON.")
                }
            } else if operation.body?.required == true {
                problems.append("The body is required.")
            }
        }
        return (arguments, files, problems)
    }

    /// Runs `arguments()` and keeps its problems for display. True when there are none.
    @discardableResult
    func check() -> Bool {
        problems = arguments().problems
        return problems.isEmpty
    }

    /// Shows problems found elsewhere — the client's `invalidArguments`, from the runner.
    func setProblems(_ problems: [String]) {
        self.problems = problems
    }

    /// The problems that name `node`'s field — its own name, or a path inside it
    /// (`voice_settings.stability`, `files[0]`), bare at the start or quoted anywhere, as the
    /// form and the client word them.
    func problems(for node: ElevenLabsFormNode) -> [String] {
        let name = node.field.name
        return problems.filter { problem in
            for suffix in [" ", ".", ":", "["] where problem.hasPrefix(name + suffix) { return true }
            for (open, close) in [("`", "`"), ("\"", "\""), ("“", "”"), ("'", "'")] {
                for end in [close, ".", "["] where problem.contains(open + name + end) { return true }
            }
            return false
        }
    }

    /// Whether any secret field holds something typed — the whole-body JSON view shows it.
    var hasTypedSecrets: Bool {
        nodes.contains { $0.holdsTypedSecret }
    }

    /// Switches the body to one JSON editor, starting from what the fields hold now.
    func editBodyAsJSON() {
        guard !editsBodyAsJSON else { return }
        var ignored: [String] = []
        var object: [String: JSONValue] = [:]
        for node in nodes(in: .body) {
            if case .file = node.field.kind { continue }
            if let value = node.value(path: node.field.name, problems: &ignored) {
                object[node.field.name] = value
            }
        }
        let whole = object.count == 1 && object["body"] != nil ? object["body"]! : .object(object)
        bodyJSON = whole.jsonString(pretty: true)
        editsBodyAsJSON = true
    }

    /// Back to field-by-field editing, carrying over what the JSON says. False, and still
    /// JSON, when the text does not parse — nothing typed is thrown away.
    @discardableResult
    func editBodyAsFields() -> Bool {
        guard editsBodyAsJSON else { return true }
        let text = bodyJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            guard let value = try? JSONValue(data: Data(text.utf8)) else { return false }
            let bodyNodes = nodes(in: .body)
            if bodyNodes.count == 1, bodyNodes[0].field.name == "body" {
                bodyNodes[0].load(value)
            } else if let object = value.objectValue {
                for node in bodyNodes { node.load(object[node.field.name] ?? .null) }
            } else {
                return false
            }
        }
        editsBodyAsJSON = false
        return true
    }

    /// Fills the fields from arguments — from "Open in Explorer", or a recent call.
    func load(arguments: [String: JSONValue]) {
        for node in nodes {
            if let value = arguments[node.field.name] { node.load(value) }
        }
    }

    /// Every field back to its starting value.
    func reset() {
        for node in nodes { node.reset() }
        editsBodyAsJSON = false
        bodyJSON = ""
        problems = []
    }
}

/// The editing state of one field, and of its children when it has any.
@MainActor
@Observable
final class ElevenLabsFormNode: Identifiable {
    let field: ElevenLabsFormField
    nonisolated var id: String { field.id }

    /// Text, integer, number and JSON fields.
    var text = ""
    /// Boolean fields' value, when `flagSet`.
    var flag = false
    /// Whether an optional boolean is sent at all.
    var flagSet = false
    /// The chosen `choice` value's index; nil sends nothing.
    var choice: Int?
    /// Whether an optional object, list or union is sent at all.
    var included = false
    private(set) var children: [ElevenLabsFormNode] = []
    private(set) var items: [ElevenLabsFormNode] = []
    /// The chosen shape of a union.
    var variant = 0
    private(set) var variantNodes: [ElevenLabsFormNode] = []
    /// Chosen files, for upload fields.
    var files: [URL] = []
    /// Rows of a header map.
    var headerEntries: [ElevenLabsHeaderEntry] = []
    /// An object, list or union edited as JSON text instead (the raw fallback).
    private(set) var editsAsJSON = false

    init(field: ElevenLabsFormField) {
        self.field = field
        build()
        reset()
    }

    private func build() {
        switch field.kind {
        case .object(let properties):
            children = properties.map { ElevenLabsFormNode(field: $0) }
        case .variants(let variants):
            variantNodes = variants.map { ElevenLabsFormNode(field: $0.field) }
        case .text, .integer, .number, .boolean, .choice, .constant, .list, .file, .json, .headerMap:
            break
        }
    }

    /// Starting values: a required field with a default starts at it; everything optional
    /// starts unset, its default shown as a hint rather than sent.
    func reset() {
        text = ""
        flag = false
        flagSet = false
        choice = nil
        included = field.required
        items = []
        variant = 0
        files = []
        headerEntries = []
        editsAsJSON = field.kind == .json
        for child in children { child.reset() }
        for node in variantNodes { node.reset() }
        if field.required, let value = field.defaultValue, value != .null { load(value) }
        if field.required, case .choice(let values) = field.kind, choice == nil, values.count == 1 {
            choice = 0
        }
    }

    // MARK: - Header maps

    func addHeader() {
        headerEntries.append(ElevenLabsHeaderEntry())
        included = true
    }

    func removeHeader(_ id: ElevenLabsHeaderEntry.ID) {
        headerEntries.removeAll { $0.id == id }
    }

    /// Whether this field, or one inside it, is a secret with something typed into it.
    var holdsTypedSecret: Bool {
        if field.isSecret, !text.isEmpty || headerEntries.contains(where: { !$0.value.isEmpty }) { return true }
        return children.contains { $0.holdsTypedSecret } || items.contains { $0.holdsTypedSecret }
            || variantNodes.contains { $0.holdsTypedSecret }
    }

    // MARK: - Lists

    func addItem() {
        guard case .list(let template) = field.kind else { return }
        items.append(ElevenLabsFormNode(field: template))
        included = true
    }

    func removeItem(_ item: ElevenLabsFormNode) {
        items.removeAll { $0 === item }
    }

    // MARK: - Raw JSON fallback

    /// Switches this field to JSON text, starting from what it holds.
    func editAsJSON() {
        guard !editsAsJSON else { return }
        var ignored: [String] = []
        text = typedValue(path: field.name, problems: &ignored)?.jsonString(pretty: true) ?? ""
        editsAsJSON = true
    }

    /// Back to the typed editor, if the JSON parses; false (and still JSON) when it does not.
    @discardableResult
    func editTyped() -> Bool {
        guard editsAsJSON, field.kind != .json else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            editsAsJSON = false
            text = ""
            return true
        }
        guard let value = try? JSONValue(data: Data(trimmed.utf8)) else { return false }
        editsAsJSON = false
        text = ""
        load(value)
        return true
    }

    // MARK: - Values

    /// The JSON this field sends, nil when it sends nothing; problems appended with `path`
    /// (the dotted argument name) so the owner can find the field.
    func value(path: String, problems: inout [String]) -> JSONValue? {
        if editsAsJSON { return jsonTextValue(path: path, problems: &problems) }
        return typedValue(path: path, problems: &problems)
    }

    private func jsonTextValue(path: String, problems: inout [String]) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if field.required { problems.append("\(path) is required.") }
            return nil
        }
        guard let value = try? JSONValue(data: Data(trimmed.utf8)) else {
            problems.append("\(path) is not valid JSON.")
            return nil
        }
        return value
    }

    private func typedValue(path: String, problems: inout [String]) -> JSONValue? {
        switch field.kind {
        case .text:
            guard !text.isEmpty else { return missing(path, &problems) }
            if field.location == .path, text == "." || text == ".." || text.contains(where: { "/\\\u{0}".contains($0) }) {
                problems.append("\(path) is an id: it may not contain “/”, “\\” or a NUL, or be “.” or “..”.")
            }
            if text.contains(ElevenLabsRedaction.placeholder) {
                problems.append("\(path) still holds “\(ElevenLabsRedaction.placeholder)”, the mask an answer showed — type the real value.")
            }
            if let min = field.constraints.minLength, text.count < min {
                problems.append("\(path) needs at least \(min) characters.")
            }
            if let max = field.constraints.maxLength, text.count > max {
                problems.append("\(path) takes at most \(max) characters (it has \(text.count)).")
            }
            return .string(text)
        case .integer:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return missing(path, &problems) }
            guard let number = Int(trimmed) else {
                problems.append("\(path) must be a whole number.")
                return nil
            }
            checkRange(Double(number), path: path, problems: &problems)
            return .number(Double(number))
        case .number:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return missing(path, &problems) }
            guard let number = Double(trimmed), number.isFinite else {
                problems.append("\(path) must be a number.")
                return nil
            }
            checkRange(number, path: path, problems: &problems)
            return .number(number)
        case .boolean:
            guard flagSet || field.required else { return nil }
            return .bool(flag)
        case .choice(let values):
            guard let choice, values.indices.contains(choice) else { return missing(path, &problems) }
            return values[choice]
        case .constant(let value):
            // Not `required ? value : nil`: JSONValue takes `nil` as a literal, so that ternary
            // would send an explicit null instead of leaving the field out.
            guard field.required else { return nil }
            return value
        case .list:
            guard included || field.required else { return nil }
            if items.isEmpty {
                if field.required, (field.constraints.minItems ?? 1) > 0 {
                    problems.append("\(path) needs at least one item.")
                }
                guard field.required else { return nil }
                return .array([])
            }
            if let max = field.constraints.maxItems, items.count > max {
                problems.append("\(path) takes at most \(max) items.")
            }
            return .array(items.enumerated().map { index, item in
                item.value(path: "\(path)[\(index)]", problems: &problems) ?? .null
            })
        case .object:
            guard included || field.required else { return nil }
            var object: [String: JSONValue] = [:]
            for child in children {
                if let value = child.value(path: "\(path).\(child.field.name)", problems: &problems) {
                    object[child.field.name] = value
                }
            }
            return .object(object)
        case .variants:
            guard included || field.required, variantNodes.indices.contains(variant) else { return nil }
            let node = variantNodes[variant]
            if case .object = node.field.kind { node.included = true }
            return node.value(path: path, problems: &problems)
        case .file:
            return nil
        case .headerMap:
            let named = headerEntries.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            guard included || field.required || !named.isEmpty else { return nil }
            if named.isEmpty, !field.required { return nil }
            var map: [String: JSONValue] = [:]
            for entry in named {
                let name = entry.name.trimmingCharacters(in: .whitespaces)
                if map[name] != nil { problems.append("\(path) has the header “\(name)” twice.") }
                if entry.value.contains(ElevenLabsRedaction.placeholder) {
                    problems.append("\(path).\(name) still holds “\(ElevenLabsRedaction.placeholder)” — type the real value.")
                }
                map[name] = .string(entry.value)
            }
            return .object(map)
        case .json:
            return jsonTextValue(path: path, problems: &problems)
        }
    }

    private func missing(_ path: String, _ problems: inout [String]) -> JSONValue? {
        if field.required { problems.append("\(path) is required.") }
        return nil
    }

    private func checkRange(_ number: Double, path: String, problems: inout [String]) {
        let limits = field.constraints
        if let min = limits.minimum, number < min {
            problems.append("\(path) must be at least \(Self.format(min)).")
        }
        if let max = limits.maximum, number > max {
            problems.append("\(path) must be at most \(Self.format(max)).")
        }
        if let min = limits.exclusiveMinimum, number <= min {
            problems.append("\(path) must be more than \(Self.format(min)).")
        }
        if let max = limits.exclusiveMaximum, number >= max {
            problems.append("\(path) must be less than \(Self.format(max)).")
        }
    }

    static func format(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }

    /// Puts `value` into the editor: typed where it fits, JSON text where it does not.
    func load(_ value: JSONValue) {
        guard value != .null else {
            reset()
            return
        }
        switch (field.kind, value) {
        case (.text, .string(let string)):
            text = string
        case (.integer, .number(let number)), (.number, .number(let number)):
            text = Self.format(number)
        case (.boolean, .bool(let bool)):
            flag = bool
            flagSet = true
        case (.choice(let values), _):
            choice = values.firstIndex(of: value)
        case (.constant, _):
            break
        case (.headerMap, .object(let map)) where map.values.allSatisfy({ $0.stringValue != nil }):
            headerEntries = map.keys.sorted().map { ElevenLabsHeaderEntry(name: $0, value: map[$0]?.stringValue ?? "") }
            included = true
        case (.list(let template), .array(let array)):
            items = array.map { element in
                let item = ElevenLabsFormNode(field: template)
                item.load(element)
                return item
            }
            included = true
        case (.object, .object(let object)):
            for child in children { child.load(object[child.field.name] ?? .null) }
            included = true
        case (.variants, _):
            // The first shape whose typed editor takes the value without problems.
            included = true
            for (index, node) in variantNodes.enumerated() {
                node.load(value)
                var problems: [String] = []
                if node.value(path: "", problems: &problems) != nil, problems.isEmpty {
                    variant = index
                    return
                }
            }
            text = value.jsonString(pretty: true)
            editsAsJSON = true
        case (.json, _):
            text = value.jsonString(pretty: true)
        default:
            text = value.jsonString(pretty: true)
            editsAsJSON = true
        }
    }
}

/// One header of a header map: a name, and a value typed into a secure field.
struct ElevenLabsHeaderEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    var name = ""
    var value = ""
}

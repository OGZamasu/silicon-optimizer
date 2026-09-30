import AppKit
import SiliconElevenLabs
import SwiftUI
import UniformTypeIdentifiers

/// An operation's form, generated from its schema: path, query and header parameters, then
/// the body — typed editors for text, numbers, choices, switches, lists, nested objects and
/// unions, file pickers for uploads, and JSON text wherever a typed editor does not fit.
/// Required fields are marked; defaults are shown as hints; problems appear under the field
/// they name.
struct ElevenLabsOperationForm: View {
    @Bindable var form: ElevenLabsFormModel
    /// Location headings ("Path", "Query", "Body"). Off when a section embeds a few fields.
    var showsHeadings = true

    init(form: ElevenLabsFormModel, showsHeadings: Bool = true) {
        self.form = form
        self.showsHeadings = showsHeadings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if form.fields.isEmpty {
                Text("This operation takes no arguments.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(ElevenLabsFormField.Location.allCases, id: \.self) { location in
                let nodes = form.nodes(in: location)
                if !nodes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        if showsHeadings { heading(location) }
                        if location == .body, form.editsBodyAsJSON {
                            if form.hasTypedSecrets {
                                Label("This JSON shows what was typed into secret fields. Show API call and curl never do.",
                                      systemImage: "eye.trianglebadge.exclamationmark")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            ElevenLabsJSONEditor(text: $form.bodyJSON, minHeight: 180)
                            // Upload fields stay pickers even while the rest is JSON.
                            ForEach(nodes.filter { if case .file = $0.field.kind { true } else { false } }) { node in
                                ElevenLabsFormNodeView(node: node, form: form, depth: 0)
                            }
                        } else {
                            ForEach(nodes) { node in
                                ElevenLabsFormNodeView(node: node, form: form, depth: 0)
                            }
                        }
                    }
                }
            }
            let unplaced = form.problems.filter { problem in
                !form.nodes.contains { !form.problems(for: $0).isEmpty && form.problems(for: $0).contains(problem) }
            }
            if !unplaced.isEmpty {
                ElevenLabsProblemList(problems: unplaced)
            }
        }
    }

    @ViewBuilder
    private func heading(_ location: ElevenLabsFormField.Location) -> some View {
        HStack {
            Text(location == .body ? bodyTitle : location.title)
                .font(.headline)
            Spacer()
            if location == .body, hasTypedBody {
                Button(form.editsBodyAsJSON ? "Edit as fields" : "Edit as JSON") {
                    if form.editsBodyAsJSON { form.editBodyAsFields() } else { form.editBodyAsJSON() }
                }
                .controlSize(.small)
                .help(form.editsBodyAsJSON
                      ? "Back to one editor per field (the JSON must parse)"
                      : "Edit the whole body as one JSON object")
            }
        }
    }

    private var bodyTitle: String {
        form.operation.body?.contentType == .multipart ? "Upload" : "Body"
    }

    private var hasTypedBody: Bool {
        form.nodes(in: .body).contains { node in
            if case .file = node.field.kind { return false }
            return true
        }
    }
}

/// One field and, for objects, lists and unions, the fields inside it.
struct ElevenLabsFormNodeView: View {
    @Bindable var node: ElevenLabsFormNode
    let form: ElevenLabsFormModel
    let depth: Int
    /// A list item's remove button sits in its header.
    var onRemove: (() -> Void)?
    /// Why a key or certificate file was not loaded.
    @State private var fileProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            if node.editsAsJSON {
                if ElevenLabsFormField.containsSecret(node.field), !node.text.isEmpty {
                    Label("This JSON shows secrets as typed. Show API call and curl never do.",
                          systemImage: "eye.trianglebadge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ElevenLabsJSONEditor(text: $node.text, minHeight: 80)
            } else {
                control
            }
            if !node.field.description.isEmpty {
                Text(node.field.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if depth == 0 {
                ForEach(form.problems(for: node), id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(node.field.title)
                .font(depth == 0 ? .callout.weight(.medium) : .callout)
            if node.field.required {
                Text("Required")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
                    .accessibilityLabel("required")
            }
            if node.field.title.caseInsensitiveCompare(ElevenLabsFormField.humanized(node.field.name)) != .orderedSame
                || depth == 0 {
                Text(node.field.name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            if node.field.isSecret {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("A secret: typed hidden, masked in Show API call and curl")
                    .accessibilityLabel("secret")
            }
            if node.field.deprecated {
                Text("Deprecated")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .background(.yellow.opacity(0.25), in: .capsule)
            }
            Spacer(minLength: 4)
            if canEditAsJSON {
                Button(node.editsAsJSON ? "Typed" : "JSON") {
                    if node.editsAsJSON { node.editTyped() } else { node.editAsJSON() }
                }
                .buttonStyle(.link)
                .font(.caption)
                .help(node.editsAsJSON ? "Back to the typed editor (the JSON must parse)" : "Edit this as JSON")
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this item")
                .accessibilityLabel("Remove item")
            }
        }
    }

    private var canEditAsJSON: Bool {
        switch node.field.kind {
        case .object, .list, .variants, .headerMap: true
        default: false
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var control: some View {
        switch node.field.kind {
        case .text(let multiline, let format):
            if node.field.isSecret {
                if let fileProblem {
                    Text(fileProblem).font(.caption).foregroundStyle(.red)
                }
                HStack(spacing: 6) {
                    SecureField(node.field.title, text: $node.text, prompt: Text("Hidden while typed"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    if ElevenLabsFormField.pemFieldNames.contains(node.field.name.lowercased()) {
                        // A pasted PEM loses its line breaks in a one-line field.
                        Button("Load from file…") { loadSecretFromFile() }
                            .controlSize(.small)
                    }
                }
            } else if multiline {
                ElevenLabsTextArea(text: $node.text, prompt: hint)
            } else {
                TextField(node.field.title, text: $node.text, prompt: Text(hint ?? format ?? ""))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                if node.field.location == .path, depth == 0 {
                    Text("An id, not a path: no “/”, “\\” or “..”.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        case .integer, .number:
            numberControl
        case .boolean:
            booleanControl
        case .choice(let values):
            Picker(node.field.title, selection: $node.choice) {
                Text(unsetLabel).tag(Int?.none)
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    Text(Self.label(value)).tag(Int?.some(index))
                }
            }
            .labelsHidden()
            .fixedSize()
        case .constant(let value):
            Text(Self.label(value))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        case .list:
            listControl
        case .object:
            objectControl
        case .variants(let variants):
            variantsControl(variants)
        case .file(let multiple):
            ElevenLabsFilePickerField(files: $node.files, multiple: multiple)
        case .headerMap:
            headerMapControl
        case .json:
            ElevenLabsJSONEditor(text: $node.text, minHeight: 80)
        }
    }

    private var numberControl: some View {
        HStack(spacing: 8) {
            TextField(node.field.title, text: $node.text, prompt: Text(hint ?? rangeHint ?? ""))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
            if case .number = node.field.kind,
               let low = node.field.constraints.minimum ?? node.field.constraints.exclusiveMinimum,
               let high = node.field.constraints.maximum ?? node.field.constraints.exclusiveMaximum,
               high > low, high - low <= 100 {
                Slider(
                    value: Binding(
                        get: { Double(node.text) ?? node.field.defaultValue?.doubleValue ?? low },
                        set: { node.text = ElevenLabsFormNode.format(($0 * 100).rounded() / 100) }
                    ),
                    in: low...high
                )
                .frame(maxWidth: 240)
            }
            if let rangeHint, hint != nil {
                Text(rangeHint).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var booleanControl: some View {
        if node.field.required {
            Toggle(node.field.title, isOn: $node.flag)
                .labelsHidden()
                .toggleStyle(.switch)
        } else {
            Picker(node.field.title, selection: Binding(
                get: { node.flagSet ? (node.flag ? 1 : 2) : 0 },
                set: { choice in
                    node.flagSet = choice != 0
                    node.flag = choice == 1
                }
            )) {
                Text(unsetLabel).tag(0)
                Text("Yes").tag(1)
                Text("No").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder
    private var listControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(node.items) { item in
                ElevenLabsFormNodeView(node: item, form: form, depth: depth + 1, onRemove: { node.removeItem(item) })
                    .padding(8)
                    .background(.background.secondary, in: .rect(cornerRadius: 6))
            }
            Button {
                node.addItem()
            } label: {
                Label(node.items.isEmpty ? "Add an item" : "Add another", systemImage: "plus")
            }
            .controlSize(.small)
            .disabled(node.field.constraints.maxItems.map { node.items.count >= $0 } ?? false)
        }
    }

    private var headerMapControl: some View {
        let environments = node.field.name == "values"
        return VStack(alignment: .leading, spacing: 6) {
            ForEach($node.headerEntries) { $entry in
                HStack(spacing: 6) {
                    TextField(environments ? "Environment" : "Header", text: $entry.name,
                              prompt: Text(environments ? "production" : "Authorization"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    SecureField("Value", text: $entry.value, prompt: Text("Hidden while typed"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Button {
                        node.removeHeader(entry.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove header")
                }
            }
            Button {
                node.addHeader()
            } label: {
                Label(node.headerEntries.isEmpty ? (environments ? "Add an environment" : "Add a header") : "Add another",
                      systemImage: "plus")
            }
            .controlSize(.small)
            Text("Values are typed hidden. A value that refers to a stored secret or connection needs the JSON editor.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var objectControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !node.field.required {
                Toggle("Send \(node.field.name)", isOn: $node.included)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            if node.included || node.field.required {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(node.children) { child in
                        ElevenLabsFormNodeView(node: child, form: form, depth: depth + 1)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.separator).frame(width: 1)
                }
            }
        }
    }

    @ViewBuilder
    private func variantsControl(_ variants: [ElevenLabsFormField.Variant]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if !node.field.required {
                    Toggle("Send", isOn: $node.included)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                Picker("Shape", selection: $node.variant) {
                    ForEach(Array(variants.enumerated()), id: \.offset) { index, variant in
                        Text(variant.title).tag(index)
                    }
                }
                .fixedSize()
                .disabled(!(node.included || node.field.required))
            }
            if (node.included || node.field.required), node.variantNodes.indices.contains(node.variant) {
                ElevenLabsFormNodeView(node: node.variantNodes[node.variant], form: form, depth: depth + 1)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.separator).frame(width: 1)
                    }
            }
        }
    }

    private func loadSecretFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let node = node
        Task {
            // Read off the main actor: even a capped file should not stall the window.
            let read = await Task.detached(priority: .userInitiated) { ElevenLabsSecretFile.read(url) }.value
            switch read {
            case .success(let text):
                node.text = text
                fileProblem = nil
            case .failure(let problem):
                fileProblem = problem.message
            }
        }
    }

    // MARK: Hints

    /// The default or an example, as a placeholder — shown, not sent.
    private var hint: String? {
        if let value = node.field.defaultValue { return "Default: \(Self.label(value))" }
        if let example = node.field.examples.first { return "e.g. \(Self.label(example))" }
        return nil
    }

    private var rangeHint: String? {
        let limits = node.field.constraints
        let low = limits.minimum ?? limits.exclusiveMinimum
        let high = limits.maximum ?? limits.exclusiveMaximum
        switch (low, high) {
        case (let low?, let high?): return "\(ElevenLabsFormNode.format(low)) – \(ElevenLabsFormNode.format(high))"
        case (let low?, nil): return "≥ \(ElevenLabsFormNode.format(low))"
        case (nil, let high?): return "≤ \(ElevenLabsFormNode.format(high))"
        case (nil, nil): return nil
        }
    }

    private var unsetLabel: String {
        if let value = node.field.defaultValue { return "Default (\(Self.label(value)))" }
        return node.field.required ? "Choose…" : "Not set"
    }

    static func label(_ value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        return value.jsonString()
    }
}

/// A multi-line text field with a placeholder.
struct ElevenLabsTextArea: View {
    @Binding var text: String
    var prompt: String?
    var minHeight: CGFloat = 72

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(minHeight: minHeight, maxHeight: 220)
            .background(.background, in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty, let prompt {
                    Text(prompt)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// JSON text, monospaced, with a line saying whether it parses.
struct ElevenLabsJSONEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: minHeight, maxHeight: 360)
                .background(.background, in: .rect(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 1)
                }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (try? JSONValue(data: Data(text.utf8))) == nil {
                Text("Not valid JSON yet.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// Chosen files for an upload field, with Choose… and a remove button per file.
struct ElevenLabsFilePickerField: View {
    @Binding var files: [URL]
    var multiple: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(files, id: \.self) { url in
                HStack(spacing: 6) {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        files.removeAll { $0 == url }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(url.lastPathComponent)")
                }
                .font(.callout)
            }
            Button(files.isEmpty ? (multiple ? "Choose files…" : "Choose a file…")
                   : (multiple ? "Add files…" : "Replace…")) {
                choose()
            }
            .controlSize(.small)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        guard panel.runModal() == .OK else { return }
        if multiple {
            files += panel.urls.filter { !files.contains($0) }
        } else {
            files = Array(panel.urls.prefix(1))
        }
    }
}

/// Problems that belong to no one field, as a list.
struct ElevenLabsProblemList: View {
    let problems: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Reads a key or certificate file for a secret field: a regular file (a named pipe would
/// block the read forever), small enough to be one (256 KB), and text.
enum ElevenLabsSecretFile {
    static let sizeLimit = 256 * 1024

    struct Problem: Error, Equatable {
        var message: String
    }

    static func read(_ url: URL) -> Result<String, Problem> {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return .failure(Problem(message: "\(url.lastPathComponent) is not a regular file."))
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= sizeLimit else {
            return .failure(Problem(message: "\(url.lastPathComponent) is too big for a key or certificate (over 256 KB)."))
        }
        guard let data = try? Data(contentsOf: url), data.count <= sizeLimit,
              let text = String(data: data, encoding: .utf8) else {
            return .failure(Problem(message: "\(url.lastPathComponent) could not be read as text."))
        }
        return .success(text)
    }
}

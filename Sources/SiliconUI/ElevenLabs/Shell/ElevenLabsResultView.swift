import AppKit
import AVKit
import SiliconElevenLabs
import SwiftUI
import UniformTypeIdentifiers

/// Any ElevenLabs answer, drawn for what it is: JSON as a tree, audio as a player, images and
/// video as previews, text as text, other files as a row with Save… and Reveal in Finder.
///
/// Vendor text inside a result is data: it is shown, selectable, never acted on.
struct ElevenLabsResultView: View {
    let result: ElevenLabsResult
    var operation: ElevenLabsOperation?
    /// Whether the status, request id and cost line is shown under the body.
    var showsMeta = true

    init(result: ElevenLabsResult, operation: ElevenLabsOperation? = nil, showsMeta: Bool = true) {
        self.result = result
        self.operation = operation
        self.showsMeta = showsMeta
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch result {
            case .json(let value, _):
                ElevenLabsJSONBlock(value: value)
            case .file(let url, let contentType, let bytes, _):
                ElevenLabsFileResult(url: url, contentType: contentType, bytes: bytes)
            case .text(let text, _):
                ElevenLabsTextBlock(text: text)
            case .events(let events, _):
                ElevenLabsJSONBlock(value: .array(events), label: "\(events.count) events")
            case .parts(let parts, _):
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .json(let value): ElevenLabsJSONBlock(value: value)
                    case .text(let text): ElevenLabsTextBlock(text: text)
                    case .file(let url, let contentType, let bytes):
                        ElevenLabsFileResult(url: url, contentType: contentType, bytes: bytes)
                    }
                }
            }
            if showsMeta {
                ElevenLabsMetaLine(meta: result.meta)
            }
        }
    }
}

/// Status, request id and what the call cost, in one quiet line.
struct ElevenLabsMetaLine: View {
    let meta: ElevenLabsMeta

    var body: some View {
        HStack(spacing: 12) {
            Text("HTTP \(meta.status)")
            if let cost = meta.characterCost {
                Label("\(cost.formatted()) characters", systemImage: "creditcard")
            }
            if let requestID = meta.requestID {
                Text("Request \(requestID)")
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - JSON

/// A JSON value with a tree, a raw view, and Copy.
struct ElevenLabsJSONBlock: View {
    let value: JSONValue
    var label: String?

    @State private var showsRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let label { Text(label).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Picker("View", selection: $showsRaw) {
                    Text("Tree").tag(false)
                    Text("JSON").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value.jsonString(pretty: true), forType: .string)
                }
            }
            .controlSize(.small)
            if showsRaw {
                ElevenLabsTextBlock(text: value.jsonString(pretty: true), monospaced: true)
            } else {
                ElevenLabsJSONTree(value)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: .rect(cornerRadius: 8))
            }
        }
    }
}

/// A JSON value as a tree of disclosure rows. Objects and arrays fold; the first
/// `expandedDepth` levels start open.
struct ElevenLabsJSONTree: View {
    let value: JSONValue
    var label: String?
    var expandedDepth: Int

    init(_ value: JSONValue, label: String? = nil, expandedDepth: Int = 1) {
        self.value = value
        self.label = label
        self.expandedDepth = expandedDepth
    }

    var body: some View {
        ElevenLabsJSONNode(value: value, label: label, depth: 0, expandedDepth: expandedDepth)
    }
}

private struct ElevenLabsJSONNode: View {
    let value: JSONValue
    let label: String?
    let depth: Int
    let expandedDepth: Int

    @State private var expanded: Bool?

    /// Past this many children a level shows the first ones and a count, so a 5,000-item
    /// history does not build 5,000 rows.
    static let childLimit = 200

    var body: some View {
        switch value {
        case .object(let object):
            container(summary: "{\(object.count)}", children: object.keys.sorted().map { ($0, object[$0] ?? .null) })
        case .array(let array):
            container(summary: "[\(array.count)]", children: array.enumerated().map { ("\($0.offset)", $0.element) })
        default:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let label { keyText(label) }
                Text(Self.scalar(value))
                    .foregroundStyle(Self.color(value))
                    .textSelection(.enabled)
                    .lineLimit(8)
            }
            .font(.callout.monospaced())
        }
    }

    @ViewBuilder
    private func container(summary: String, children: [(String, JSONValue)]) -> some View {
        let isExpanded = expanded ?? (depth < expandedDepth)
        VStack(alignment: .leading, spacing: 3) {
            Button {
                expanded = !isExpanded
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    if let label { keyText(label) }
                    Text(summary).foregroundStyle(.tertiary)
                }
                .font(.callout.monospaced())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(children.prefix(Self.childLimit), id: \.0) { key, child in
                        ElevenLabsJSONNode(value: child, label: key, depth: depth + 1, expandedDepth: expandedDepth)
                    }
                    if children.count > Self.childLimit {
                        Text("… \(children.count - Self.childLimit) more — switch to JSON to see all")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    private func keyText(_ key: String) -> some View {
        Text(key + ":").foregroundStyle(.secondary)
    }

    static func scalar(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let flag): flag ? "true" : "false"
        case .number: value.jsonString()
        case .string(let text): "\"\(text)\""
        case .array, .object: value.jsonString()
        }
    }

    static func color(_ value: JSONValue) -> Color {
        switch value {
        case .string: .primary
        case .number: .blue
        case .bool: .purple
        case .null: .secondary
        case .array, .object: .primary
        }
    }
}

// MARK: - Text

struct ElevenLabsTextBlock: View {
    let text: String
    var monospaced = false

    /// Inline text is capped for drawing; Copy takes all of it.
    static let displayLimit = 200_000

    var body: some View {
        ScrollView {
            Text(text.count > Self.displayLimit ? String(text.prefix(Self.displayLimit)) + "\n…" : text)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(minHeight: 60, maxHeight: 320)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }
}

// MARK: - Files

/// A written file, previewed by kind.
struct ElevenLabsFileResult: View {
    let url: URL
    let contentType: String
    let bytes: Int

    var body: some View {
        let type = contentType.lowercased()
        VStack(alignment: .leading, spacing: 6) {
            if type.hasPrefix("audio/") {
                ElevenLabsAudioPlayerView(url: url, title: url.lastPathComponent).id(url)
            } else if type.hasPrefix("image/"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 480, maxHeight: 360)
                    .clipShape(.rect(cornerRadius: 8))
                fileRow
            } else if type.hasPrefix("video/") {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(minHeight: 220, maxHeight: 360)
                    .clipShape(.rect(cornerRadius: 8))
                    .id(url)
                fileRow
            } else {
                fileRow
            }
        }
    }

    private var fileRow: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text("\(contentType) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            ElevenLabsFileActions(url: url)
        }
    }
}

/// Save… (a copy wherever the owner likes) and Reveal in Finder, for a file a call wrote.
struct ElevenLabsFileActions: View {
    let url: URL

    var body: some View {
        HStack(spacing: 6) {
            Button("Save…") { Self.saveCopy(of: url) }
            Button {
                Self.reveal(url)
            } label: {
                Image(systemName: "folder")
            }
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal in Finder")
        }
        .controlSize(.small)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Asks where, then copies. The original stays in the output folder.
    static func saveCopy(of url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: url.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: url, to: destination)
    }
}

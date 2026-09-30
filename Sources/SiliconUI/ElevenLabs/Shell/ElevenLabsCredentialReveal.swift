import AppKit
import SiliconElevenLabs
import SwiftUI

/// A key, secret, token or signed URL an answer carried: shown once, where it was asked for,
/// with a copy button and a dismiss — never written to disk, never in the recent list, never
/// in "Show API call".
struct ElevenLabsRevealedCredential: Identifiable, Equatable, Sendable {
    struct Field: Identifiable, Equatable, Sendable {
        var id: String { path }
        /// Where in the answer it was, e.g. `xi-api-key` or `webhook.secret`.
        var path: String
        var value: String
    }

    let id = UUID()
    var operationID: String
    var fields: [Field]

    /// The secret fields of a credential-returning answer. When none of the known names is
    /// there, the whole answer is treated as the secret rather than guessed about.
    init(operation: ElevenLabsOperation, result: ElevenLabsResult) {
        operationID = operation.id
        var found: [Field] = []
        switch result {
        case .json(let value, _):
            Self.collect(value, path: "", into: &found)
            if found.isEmpty, value != .null {
                found = [Field(path: "answer", value: value.jsonString(pretty: true))]
            }
        case .text(let text, _):
            found = [Field(path: "answer", value: text)]
        case .events, .file, .parts:
            break
        }
        fields = found
    }

    /// `result` with the secret fields masked: what the runner keeps and shows as the result.
    static func masked(_ result: ElevenLabsResult, for operation: ElevenLabsOperation) -> ElevenLabsResult {
        switch result {
        case .json(let value, let meta):
            return .json(ElevenLabsRedaction.redactCredentials(in: value, for: operation), meta)
        case .text(_, let meta):
            return .text(ElevenLabsRedaction.placeholder, meta)
        case .events, .file, .parts:
            return result
        }
    }

    private static func collect(_ value: JSONValue, path: String, into found: inout [Field]) {
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                let inner = object[key] ?? .null
                let innerPath = path.isEmpty ? key : "\(path).\(key)"
                if ElevenLabsRedaction.credentialFieldNames.contains(key.lowercased()),
                   let text = inner.stringValue, !text.isEmpty {
                    found.append(Field(path: innerPath, value: text))
                } else {
                    collect(inner, path: innerPath, into: &found)
                }
            }
        case .array(let array):
            for (index, inner) in array.enumerated() {
                collect(inner, path: "\(path)[\(index)]", into: &found)
            }
        case .null, .bool, .number, .string:
            break
        }
    }
}

/// The show-once display. The value is hidden until asked for, so a screen share does not
/// leak it by accident; Done forgets it.
struct ElevenLabsCredentialReveal: View {
    let credential: ElevenLabsRevealedCredential
    let onDismiss: () -> Void

    @State private var revealed: Set<String> = []
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Shown once", systemImage: "key.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(
                "Copy it now. It is not saved anywhere by this app, and ElevenLabs will not "
                + "show it again."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(credential.fields) { field in
                HStack(spacing: 8) {
                    Text(field.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 80, alignment: .leading)
                    Group {
                        if revealed.contains(field.id) {
                            Text(field.value).textSelection(.enabled)
                        } else {
                            Text(String(repeating: "•", count: min(24, max(8, field.value.count))))
                        }
                    }
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button(revealed.contains(field.id) ? "Hide" : "Show") {
                        if revealed.contains(field.id) { revealed.remove(field.id) } else { revealed.insert(field.id) }
                    }
                    Button(copied == field.id ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(field.value, forType: .string)
                        copied = field.id
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.4), lineWidth: 1)
        }
    }
}

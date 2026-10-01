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

    /// The secret fields of a credential-returning answer: exactly the ones the core's
    /// redaction masks for this operation (its reviewed field list), found by comparing the
    /// answer with its redacted copy — so what is shown once here is what MCP never sees.
    ///
    /// Header values (`Authorization` in a tool's `request_headers`) are left in, here and in
    /// `masked`: the owner's editor has to send the real config back, and a header value is not
    /// a credential ElevenLabs "will not show again", so it does not belong on this card.
    init(operation: ElevenLabsOperation, result: ElevenLabsResult) {
        operationID = operation.id
        var found: [Field] = []
        switch result {
        case .json(let value, _):
            Self.collect(value, masked: Self.redacted(value, for: operation), path: "", into: &found)
        case .text(let text, _):
            found = [Field(path: "answer", value: text)]
        case .events, .file, .parts:
            break
        }
        fields = found
    }

    /// `result` as the app keeps and shows it, for **every** operation: a credential
    /// operation's named fields masked, and in any answer the account's key preview and any
    /// `sk_…` key — header values left real. A credential operation's text answer is the
    /// secret itself and is masked whole; any other text answer loses keys, legacy ones
    /// included, but keeps its ids (`redactAnswerText`).
    static func masked(_ result: ElevenLabsResult, for operation: ElevenLabsOperation) -> ElevenLabsResult {
        switch result {
        case .json(let value, let meta):
            return .json(redacted(value, for: operation), meta)
        case .text(let text, let meta):
            return .text(
                operation.returnsCredential ? ElevenLabsRedaction.placeholder : ElevenLabsRedaction.redactAnswerText(text),
                meta
            )
        case .events(let events, let meta):
            return .events(events.map { redacted($0, for: operation) }, meta)
        case .parts(let parts, let meta):
            return .parts(parts.map { part in
                if case .json(let value) = part { .json(redacted(value, for: operation)) } else { part }
            }, meta)
        case .file:
            return result
        }
    }

    /// The core's redaction as the app uses it: credential fields masked, header values not.
    static func redacted(_ value: JSONValue, for operation: ElevenLabsOperation) -> JSONValue {
        ElevenLabsRedaction.redactCredentials(in: value, for: operation, maskingHeaderValues: false)
    }

    private static func collect(_ value: JSONValue, masked: JSONValue, path: String, into found: inout [Field]) {
        if value != masked, masked == .string(ElevenLabsRedaction.placeholder) {
            found.append(Field(path: path.isEmpty ? "answer" : path, value: value.stringValue ?? value.jsonString()))
            return
        }
        switch (value, masked) {
        case (.object(let object), .object(let maskedObject)):
            for key in object.keys.sorted() {
                collect(object[key] ?? .null, masked: maskedObject[key] ?? .null,
                        path: path.isEmpty ? key : "\(path).\(key)", into: &found)
            }
        case (.array(let array), .array(let maskedArray)) where array.count == maskedArray.count:
            for index in array.indices {
                collect(array[index], masked: maskedArray[index], path: "\(path)[\(index)]", into: &found)
            }
        default:
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

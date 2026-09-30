import SiliconElevenLabs
import SwiftUI

/// The question asked before a destructive or real-world operation runs: what it acts on,
/// what will happen, and the exact call — so "Delete" is never pressed on a guess.
struct ElevenLabsConfirmationRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    var operationID: String
    var risk: ElevenLabsRisk
    /// "Delete the voice “Rachel”?"
    var title: String
    /// What will happen, in a sentence or two.
    var consequence: String
    /// `METHOD URL` of the call, key left out; nil when it could not be described.
    var call: String?
    /// The confirming button's label: a verb, never "OK".
    var confirmLabel: String

    /// The question for `operation`, naming `subject` when the section knows it.
    static func make(
        for operation: ElevenLabsOperation, subject: String? = nil, consequence: String? = nil,
        call: ElevenLabsCallDescription? = nil
    ) -> ElevenLabsConfirmationRequest {
        let verb = confirmVerb(for: operation)
        let summary = operation.summary.isEmpty ? operation.id : operation.summary
        let title: String = if let subject, !subject.isEmpty {
            "\(verb) \(subject)?"
        } else {
            "\(summary)?"
        }
        return ElevenLabsConfirmationRequest(
            operationID: operation.id,
            risk: operation.risk,
            title: title,
            consequence: consequence ?? defaultConsequence(for: operation, summary: summary),
            call: call.map { "\($0.method) \($0.url)" } ?? "\(operation.method) \(operation.path)",
            confirmLabel: verb
        )
    }

    static func confirmVerb(for operation: ElevenLabsOperation) -> String {
        if operation.method == "DELETE" { return "Delete" }
        switch operation.risk {
        case .destructive: return "Run"
        case .realWorld:
            let words = (operation.summary + " " + operation.path).lowercased()
            if words.contains("call") { return "Place the call" }
            if words.contains("invite") { return "Send the invite" }
            if words.contains("message") { return "Send" }
            return "Run"
        case .read, .generate, .modify: return "Run"
        }
    }

    static func defaultConsequence(for operation: ElevenLabsOperation, summary: String) -> String {
        switch operation.risk {
        case .destructive:
            return "ElevenLabs will \(lowercasedFirst(summary)) on your account. "
                + "This cannot be undone from here."
        case .realWorld:
            return "ElevenLabs will \(lowercasedFirst(summary)). This reaches outside your "
                + "account — people, phone numbers, keys or other services may be affected."
        case .read, .generate, .modify:
            return "ElevenLabs will \(lowercasedFirst(summary))."
        }
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // Leave acronyms ("MCP", "PVC") alone: only a capital followed by a lower-case letter
        // is a sentence's capital.
        let rest = text.dropFirst()
        if let second = rest.first, second.isUppercase { return text }
        return first.lowercased() + rest
    }
}

/// The sheet that asks. Cancel is the default button: Return must never delete anything.
struct ElevenLabsRiskConfirmation: View {
    let request: ElevenLabsConfirmationRequest
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: request.risk == .realWorld
                      ? "exclamationmark.bubble.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(request.risk == .realWorld ? .orange : .red)
                    .font(.title2)
                Text(request.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(request.consequence)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let call = request.call {
                Text(call)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            HStack(spacing: 10) {
                ElevenLabsRiskBadge(risk: request.risk)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(request.confirmLabel, role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(request.risk == .realWorld ? .orange : .red)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 480)
    }
}

extension View {
    /// Presents `runner`'s confirmation while it waits for one.
    func elevenLabsConfirmation(for runner: ElevenLabsRunner) -> some View {
        sheet(item: Binding(
            get: { runner.confirmation },
            set: { if $0 == nil { runner.decline() } }
        )) { request in
            ElevenLabsRiskConfirmation(
                request: request, onConfirm: { runner.confirm() }, onCancel: { runner.decline() }
            )
        }
    }
}

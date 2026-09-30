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
    ///
    /// `subject` is a noun phrase: "the voice “Narrator”", "12 phone calls with “Front desk”".
    static func make(
        for operation: ElevenLabsOperation, subject: String? = nil, consequence: String? = nil,
        call: ElevenLabsCallDescription? = nil
    ) -> ElevenLabsConfirmationRequest {
        let action = Action(operation)
        let trimmed = operation.summary.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let summary = trimmed.isEmpty ? operation.id : sentenceCase(trimmed)
        let title: String = if let subject, !subject.isEmpty {
            action.titleVerb.map { "\($0) \(subject)?" } ?? "\(summary): \(subject)?"
        } else {
            "\(summary)?"
        }
        return ElevenLabsConfirmationRequest(
            operationID: operation.id,
            risk: operation.risk,
            title: title,
            consequence: consequence ?? defaultConsequence(for: operation, summary: summary),
            call: call.map { "\($0.method) \($0.url)" } ?? "\(operation.method) \(operation.path)",
            confirmLabel: action.buttonLabel
        )
    }

    /// What kind of thing the operation does, for the words on the question and its button.
    enum Action: Equatable {
        case delete, call, invite, message, other

        init(_ operation: ElevenLabsOperation) {
            let path = operation.path.lowercased()
            if operation.method == "DELETE" {
                self = .delete
            } else if path.contains("outbound-call") || path.contains("register-call")
                        || (path.contains("batch-calling") && (path.hasSuffix("/submit") || path.hasSuffix("/retry"))) {
                self = .call
            } else if path.contains("invite") {
                self = .invite
            } else if path.contains("outbound-message") {
                self = .message
            } else {
                self = .other
            }
        }

        /// The verb a title starts with before the subject; nil puts the summary first.
        var titleVerb: String? {
            switch self {
            case .delete: "Delete"
            case .call: "Place"
            case .invite, .message: "Send"
            case .other: nil
            }
        }

        /// The confirming button: a verb, never "OK".
        var buttonLabel: String {
            switch self {
            case .delete: "Delete"
            case .call: "Call now"
            case .invite: "Send invite"
            case .message: "Send message"
            case .other: "Run"
            }
        }
    }

    static func defaultConsequence(for operation: ElevenLabsOperation, summary: String) -> String {
        switch operation.risk {
        case .destructive:
            "“\(summary)” runs on your ElevenLabs account and cannot be undone from here."
        case .realWorld:
            "“\(summary)” reaches outside your account: people, phone numbers, keys or other "
                + "services may be affected, and it may cost money."
        case .read, .generate, .modify:
            "“\(summary)” runs on your ElevenLabs account."
        }
    }

    /// The spec's Title Case summaries ("Delete Voice") as a sentence ("Delete voice"),
    /// leaving acronyms, mixed-case names and a few proper nouns alone.
    static func sentenceCase(_ text: String) -> String {
        let keep: Set<String> = ["ElevenLabs", "Twilio", "Exotel", "WhatsApp", "Scribe", "Studio", "Audio", "Native"]
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return words.enumerated().map { index, word in
            guard index > 0, word.count > 1 || word == "A", !keep.contains(word),
                  let first = word.first, first.isUppercase,
                  word.dropFirst().allSatisfy({ !$0.isUppercase })
            else { return word }
            return word.lowercased()
        }.joined(separator: " ")
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

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
    /// One more line, set apart — "Charges $120.00 to your workspace", "Every agent using this
    /// secret stops working".
    var warning: String?

    /// The question for `operation`, naming `subject` when the section knows it.
    ///
    /// `subject` is a noun phrase: "the voice “Narrator”", "12 phone calls with “Front desk”".
    ///
    /// - Parameters:
    ///   - title: The whole question, when the section words it itself ("Stop the batch
    ///     “Monday”?"); otherwise built from the operation and `subject`.
    ///   - confirmLabel: The confirming button's verb ("Stop calls", "Submit order"); otherwise
    ///     chosen by what the operation does.
    ///   - warning: One more line, set apart — money, or what else stops working.
    static func make(
        for operation: ElevenLabsOperation, subject: String? = nil, consequence: String? = nil,
        call: ElevenLabsCallDescription? = nil, title: String? = nil, confirmLabel: String? = nil,
        warning: String? = nil
    ) -> ElevenLabsConfirmationRequest {
        let action = Action(operation)
        let trimmed = operation.summary.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let summary = trimmed.isEmpty ? operation.id : sentenceCase(trimmed)
        let built: String = if let subject, !subject.isEmpty {
            action.titleVerb.map { "\($0) \(subject)?" } ?? "\(summary): \(subject)?"
        } else {
            "\(summary)?"
        }
        return ElevenLabsConfirmationRequest(
            operationID: operation.id,
            risk: operation.risk,
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? built,
            consequence: consequence ?? defaultConsequence(for: operation, summary: summary),
            call: call.map { "\($0.method) \($0.url)" } ?? "\(operation.method) \(operation.path)",
            confirmLabel: confirmLabel.flatMap { $0.isEmpty ? nil : $0 } ?? action.buttonLabel,
            warning: warning.flatMap { $0.isEmpty ? nil : $0 }
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

    /// Words written one way whatever case the spec gives them ("Mcp" → "MCP").
    static let canonicalWords: [String: String] = Dictionary(uniqueKeysWithValues: [
        "MCP", "API", "URL", "SIP", "CSV", "PVC", "LLM", "RAG", "TTS", "STT", "SSE", "JSON", "PLS", "ID", "IDs",
        "WhatsApp", "ElevenLabs", "Twilio", "Exotel", "Scribe", "LiveKit", "OAuth", "mTLS",
    ].map { ($0.lowercased(), $0) })

    /// The spec's Title Case summaries ("Delete Voice") as a sentence ("Delete voice"),
    /// with acronyms and names as they are written ("Create Mcp Server" → "Create MCP
    /// server").
    static func sentenceCase(_ text: String) -> String {
        let keep: Set<String> = ["Studio", "Audio", "Native"]
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return words.enumerated().map { index, word in
            if let canonical = canonicalWords[word.lowercased()] { return canonical }
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
            if let warning = request.warning {
                Label(warning, systemImage: "exclamationmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
    /// Presents `runner`'s confirmation while it waits for one. The ElevenLabs pane already
    /// presents every runner made with its context (`.app(model)`); this is for a runner
    /// without one.
    ///
    /// - Parameter when: Off leaves presenting to someone else, so one question never gets
    ///   two sheets.
    func elevenLabsConfirmation(for runner: ElevenLabsRunner, when enabled: Bool = true) -> some View {
        sheet(item: Binding(
            get: { enabled ? runner.confirmation : nil },
            set: { if $0 == nil, enabled { runner.decline() } }
        )) { request in
            ElevenLabsRiskConfirmation(
                request: request, onConfirm: { runner.confirm() }, onCancel: { runner.decline() }
            )
        }
    }

    /// Presents whichever runner's confirmation the pane has on screen. The pane hangs this
    /// once, so every section's risky runs ask, whatever that section draws.
    func elevenLabsConfirmations(of pane: ElevenLabsPaneState) -> some View {
        sheet(item: Binding(
            get: { pane.confirming?.confirmation },
            set: { if $0 == nil { pane.confirming?.decline() } }
        )) { request in
            ElevenLabsRiskConfirmation(
                request: request,
                onConfirm: { pane.confirming?.confirm() },
                onCancel: { pane.confirming?.decline() }
            )
        }
    }
}

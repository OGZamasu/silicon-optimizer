import AppKit
import SiliconElevenLabs
import SwiftUI

/// The Run button for a runner: a verb, what it costs, why it cannot run yet, and Cancel
/// while it runs. A risky operation's question is shown by the pane (or, for a runner with no
/// pane, by `ElevenLabsRunnerOutput`), so nothing here has to host it.
struct ElevenLabsRunButton: View {
    let runner: ElevenLabsRunner
    var title: String
    /// What the input is likely to cost, when the section can tell (text length for speech).
    var estimatedCharacters: Int?
    /// The audio's length, for operations billed by it (transcription, isolation, music…).
    var estimatedSeconds: Double?
    var disabled = false
    /// Why the button is disabled, said beside it — "Choose a voice first".
    var disabledReason: String?
    let action: () -> Void

    init(
        runner: ElevenLabsRunner, title: String = "Run", estimatedCharacters: Int? = nil,
        estimatedSeconds: Double? = nil, disabled: Bool = false, disabledReason: String? = nil,
        action: @escaping () -> Void
    ) {
        self.runner = runner
        self.title = title
        self.estimatedCharacters = estimatedCharacters
        self.estimatedSeconds = estimatedSeconds
        self.disabled = disabled
        self.disabledReason = disabledReason
        self.action = action
    }

    /// What stops a run, in words: the section's reason while disabled, otherwise the first
    /// problem the last attempt was refused for.
    var blocker: String? {
        if disabled, let disabledReason, !disabledReason.isEmpty { return disabledReason }
        guard runner.phase == .failed, let first = runner.problems.first else { return nil }
        return runner.problems.count > 1 ? "\(first) (and \(runner.problems.count - 1) more)" : first
    }

    var body: some View {
        HStack(spacing: 10) {
            if runner.isRunning {
                ProgressView().controlSize(.small)
                Text(progressText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel") { runner.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(action: action) {
                    Text(title).frame(minWidth: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(runner.operation.requiresConfirmation ? .orange : .accentColor)
                .keyboardShortcut(.defaultAction)
                .disabled(disabled || runner.isAwaitingConfirmation)
                .help(blocker ?? "")
                if runner.operation.risk != .read {
                    ElevenLabsRiskBadge(risk: runner.operation.risk)
                }
                if let blocker {
                    Label(blocker, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(disabled ? .secondary : Color.red)
                        .lineLimit(2)
                } else if let note = ElevenLabsCostNote.text(
                    for: runner.operation, characters: estimatedCharacters, seconds: estimatedSeconds
                ) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var progressText: String {
        if runner.receivedBytes > 0 {
            return "Receiving… \(ByteCountFormatter.string(fromByteCount: Int64(runner.receivedBytes), countStyle: .file))"
        }
        return "Working…"
    }
}

/// A risk class as a small coloured capsule.
struct ElevenLabsRiskBadge: View {
    let risk: ElevenLabsRisk

    var body: some View {
        Text(Self.shortName(risk))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Self.color(risk))
            .background(Self.color(risk).opacity(0.14), in: .capsule)
            .help(risk.displayName)
            .accessibilityLabel(risk.displayName)
    }

    static func shortName(_ risk: ElevenLabsRisk) -> String {
        switch risk {
        case .read: "Read"
        case .generate: "Uses credits"
        case .modify: "Changes"
        case .destructive: "Destructive"
        case .realWorld: "Real world"
        }
    }

    static func color(_ risk: ElevenLabsRisk) -> Color {
        switch risk {
        case .read: .secondary
        case .generate: .blue
        case .modify: .teal
        case .destructive: .red
        case .realWorld: .orange
        }
    }
}

/// Everything a run leaves on screen: why it failed, the credential to copy once, the
/// result, and "Show API call". Also where the runner's confirmation sheet hangs.
struct ElevenLabsRunnerOutput: View {
    let runner: ElevenLabsRunner
    /// Off when the section draws the result its own way (a transcript, a voice card) and
    /// wants only the errors, the credential and the API call from here.
    var showsResult = true

    init(runner: ElevenLabsRunner, showsResult: Bool = true) {
        self.runner = runner
        self.showsResult = showsResult
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure = runner.failure {
                failureView(failure)
            }
            if let refusal = runner.refusal {
                Label(refusal, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if runner.phase == .cancelled, let note = runner.cancellationNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let credential = runner.credential {
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
        .elevenLabsConfirmation(for: runner, when: runner.presentsOwnConfirmation)
    }

    @ViewBuilder
    private func failureView(_ failure: ElevenLabsRunnerFailure) -> some View {
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
}

/// "Show API call": the operation, method, URL, headers and body the runner sent, with the
/// key shown as a placeholder — and Copy as curl, which leaves the key to the reader.
struct ElevenLabsAPICallDisclosure: View {
    let runner: ElevenLabsRunner
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Show API call", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let call = runner.apiCall {
                    Text("\(call.method) \(call.url)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    ForEach(call.headers.keys.sorted(), id: \.self) { name in
                        Text("\(name): \(call.headers[name] ?? "")")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if let body = call.body {
                        ElevenLabsTextBlock(text: body.jsonString(pretty: true), monospaced: true)
                    }
                    HStack {
                        Text("Operation \(runner.operation.id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy as curl") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                ElevenLabsCurl.command(for: call, files: runner.files), forType: .string
                            )
                        }
                        .controlSize(.small)
                    }
                } else {
                    Text("\(runner.operation.method) \(runner.operation.path) — operation \(runner.operation.id)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }
}

/// A curl command for a described call. The key is never in it: the header reads from
/// `$ELEVENLABS_API_KEY`, which the reader sets themselves.
enum ElevenLabsCurl {
    static let keyPlaceholder = "$ELEVENLABS_API_KEY"

    static func command(for call: ElevenLabsCallDescription, files: [String: [ElevenLabsFile]] = [:]) -> String {
        var lines = ["curl -X \(call.method) \(quoted(call.url))"]
        lines.append("  -H \(doubleQuoted("xi-api-key: \(keyPlaceholder)"))")
        for name in call.headers.keys.sorted() where name.lowercased() != "xi-api-key" {
            // Multipart's boundary is curl's to choose.
            if !files.isEmpty, name.lowercased() == "content-type" { continue }
            lines.append("  -H \(quoted("\(name): \(call.headers[name] ?? "")"))")
        }
        if files.isEmpty {
            if let body = call.body {
                lines.append("  --data-raw \(quoted(body.jsonString()))")
            }
        } else {
            for (key, value) in (call.body?.objectValue ?? [:]).sorted(by: { $0.key < $1.key })
            where files[key] == nil {
                let text = value.stringValue ?? value.jsonString()
                lines.append("  -F \(quoted("\(key)=\(text)"))")
            }
            for name in files.keys.sorted() {
                for file in files[name] ?? [] {
                    lines.append("  -F \(quoted("\(name)=@\(file.url.path)"))")
                }
            }
        }
        return ElevenLabsRedaction.redact(lines.joined(separator: " \\\n"))
    }

    /// Single-quoted for a POSIX shell.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Double-quoted so the shell expands the key's variable.
    static func doubleQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

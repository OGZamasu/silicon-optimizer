import AppKit
import SiliconControl
import SiliconRuntime
import SwiftUI

/// The Chat tab when the Codex engine is selected. Codex has no web UI to embed — its
/// app-server protocol expects the host application to render the conversation — so this
/// view is that host: streamed prose, commands with their output, file changes, approvals,
/// all native.
struct CodexChatView: View {
    @Environment(AppModel.self) private var model

    @State private var draft = ""

    var body: some View {
        Group {
            switch model.codexState {
            case .ready:
                conversation
            case .starting(let stage):
                startingView(stage: stage)
            case .idle:
                startingView(stage: "Starting…")
            case .stopping:
                startingView(stage: "Stopping…")
            case .failed(let message):
                failureView(message: message)
            }
        }
        .chatWindowExpansion(help: "Give Codex the whole window")
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.newCodexThread()
                } label: {
                    Label("New Thread", systemImage: "square.and.pencil")
                }
                .help("Start a fresh Codex thread")
                .disabled(model.codexItems.isEmpty)
                Button {
                    model.restartCodex()
                } label: {
                    Label("Restart Codex", systemImage: "arrow.clockwise")
                }
                .help("Restart the Codex process")
            }
        }
        .task { model.startCodexIfNeeded() }
    }

    // MARK: - Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            inputBar
        }
    }

    /// Model, folder, and safety choices — the three things that shape every turn.
    private var header: some View {
        HStack(spacing: 12) {
            modelPicker
            folderPicker
            Spacer(minLength: 0)
            if let usage = model.codexTokenLabel {
                Text(usage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            safetyPicker
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var modelPicker: some View {
        @Bindable var model = model
        let choices = model.codexModelChoices
        return Menu {
            ForEach(choices, id: \.id) { choice in
                Button {
                    model.settings.codexModel = choice.id
                    model.settings.save()
                } label: {
                    if choice.id == model.codexSelectedModel {
                        Label(menuTitle(for: choice), systemImage: "checkmark")
                    } else {
                        Text(menuTitle(for: choice))
                    }
                }
            }
            if choices.isEmpty {
                Text("No models installed — see the Models tab")
            }
        } label: {
            let current = choices.first { $0.id == model.codexSelectedModel }
            Label(
                current.map { $0.displayName } ?? "Pick a model",
                systemImage: "cpu"
            )
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The model answering this thread — local models and swarm nodes alike. "
            + "Picking one that isn't loaded loads it on first use.")
    }

    private func menuTitle(for choice: GatewayAPI.Model) -> String {
        choice.serving ? "\(choice.displayName) — serving now" : choice.displayName
    }

    private var folderPicker: some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = model.codexWorkingDirectory
            panel.message = "Choose the folder Codex works in"
            if panel.runModal() == .OK, let url = panel.url {
                model.settings.codexWorkingDirectory = url.path
                model.settings.save()
                // A restart, not just a fresh thread: the new folder must be written into
                // the Codex config as a trusted project before it can host a turn.
                model.restartCodex()
            }
        } label: {
            Label(model.codexWorkingDirectory.lastPathComponent, systemImage: "folder")
                .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .help("The folder Codex reads and edits. Changing it starts a fresh thread.")
    }

    private var safetyPicker: some View {
        @Bindable var model = model
        return Menu {
            Picker("Approvals", selection: Binding(
                get: {
                    AppModel.codexPolicyValue(
                        model.settings.codexApprovalPolicy,
                        allowed: ["untrusted", "on-request", "never"], fallback: "on-request"
                    )
                },
                set: { model.settings.codexApprovalPolicy = $0; model.settings.save() }
            )) {
                Text("Ask before commands").tag("on-request")
                Text("Ask for anything unusual").tag("untrusted")
                Text("Never ask").tag("never")
            }
            .pickerStyle(.inline)
            Picker("Sandbox", selection: Binding(
                get: {
                    AppModel.codexPolicyValue(
                        model.settings.codexSandbox,
                        allowed: ["read-only", "workspace-write", "danger-full-access"],
                        fallback: "workspace-write"
                    )
                },
                set: { model.settings.codexSandbox = $0; model.settings.save() }
            )) {
                Text("Read-only").tag("read-only")
                Text("Edit the working folder").tag("workspace-write")
                Text("Full access").tag("danger-full-access")
            }
            .pickerStyle(.inline)
            Text("Applies from the next new thread.")
        } label: {
            Label("Safety", systemImage: "shield")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("What Codex may touch, and when it must ask first")
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.codexItems.isEmpty {
                        EmptyStateView(
                            systemImage: "terminal",
                            title: "Codex is ready",
                            message: "An agent with a shell, working in "
                                + "\(model.codexWorkingDirectory.lastPathComponent). "
                                + "Ask it to inspect, explain, build, or fix something.",
                            actionTitle: nil, action: nil
                        )
                        .padding(.top, 60)
                    }
                    ForEach(model.codexItems) { item in
                        CodexItemRow(item: item)
                            .id(item.id)
                    }
                    ForEach(model.codexApprovals) { approval in
                        CodexApprovalCard(approval: approval)
                    }
                    if model.codexTurnActive && model.codexApprovals.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }
                    Color.clear.frame(height: 1).id("codex-end")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.codexItems) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("codex-end", anchor: .bottom)
                }
            }
            .onChange(of: model.codexApprovals.count) {
                proxy.scrollTo("codex-end", anchor: .bottom)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Ask Codex — it can read and change files, and run commands",
                text: $draft, axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .onSubmit(send)
            if model.codexTurnActive {
                Button {
                    model.interruptCodexTurn()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Stop this turn")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? Color.secondary : Color.accentColor)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
            }
        }
        .padding(12)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.codexTurnActive
        else { return }
        draft = ""
        model.sendCodexMessage(text)
    }

    // MARK: - Lifecycle states

    private func startingView(stage: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(stage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text("Codex could not start")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 480)
            HStack(spacing: 10) {
                Button("Try Again") { model.startCodexIfNeeded() }
                    .keyboardShortcut(.defaultAction)
                Button("Use DeepSeek Harness") {
                    model.settings.chatEngine = .harness
                    model.settings.save()
                    model.chatEngineDidChange()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Rows

/// One transcript row. User and assistant prose read as chat; everything else is a compact
/// card — commands fold their output, thinking folds entirely.
private struct CodexItemRow: View {
    let item: CodexChatItem
    @State private var isExpanded = false

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: .rect(cornerRadius: 12))
            }
        case .assistant(let text):
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringKey(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // A mentioned clip or picture is worth more played than pasted: any media
                // path in the reply gets a real card under it.
                ForEach(GatewayAPI.mediaPaths(in: text), id: \.self) { path in
                    MediaResultCard(path: path)
                }
            }
        case .reasoning(let text):
            foldCard(
                title: "Thinking", systemImage: "brain",
                detail: text, monospaced: false
            )
        case .command(let command, let output, let running):
            foldCard(
                title: command.isEmpty ? "Running a command" : command,
                systemImage: running ? "terminal" : "terminal.fill",
                detail: output.isEmpty ? "(no output yet)" : output,
                monospaced: true,
                busy: running
            )
        case .fileChange(let summary):
            Label(summary, systemImage: "pencil")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .toolCall(let title, let running):
            HStack(spacing: 6) {
                Label(title, systemImage: "wrench.and.screwdriver")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if running { ProgressView().controlSize(.mini) }
            }
        case .webSearch(let query):
            Label(query, systemImage: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .notice(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    private func foldCard(
        title: String, systemImage: String, detail: String,
        monospaced: Bool, busy: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if busy { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                ScrollView(.horizontal) {
                    Text(detail)
                        .font(monospaced ? .caption.monospaced() : .callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }
}

/// Codex asked before doing something. The card names it and waits.
private struct CodexApprovalCard: View {
    @Environment(AppModel.self) private var model
    let approval: CodexApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch approval.kind {
            case .command(let command):
                Label("Codex wants to run:", systemImage: "terminal")
                    .font(.callout.weight(.semibold))
                Text(command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: .rect(cornerRadius: 6))
            case .fileChange(let summary):
                Label("Codex wants to edit:", systemImage: "pencil")
                    .font(.callout.weight(.semibold))
                Text(summary)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Allow") { model.answerCodexApproval(approval, accept: true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Deny") { model.answerCodexApproval(approval, accept: false) }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.4), lineWidth: 1)
        }
    }
}

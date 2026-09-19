import SiliconControl
import SwiftUI

/// The Chat tab when the Pi engine is selected: a native transcript over Pi's RPC
/// mode. Media the tools produce — clips, images, meshes, audio — gets the same
/// embedded players and Finder buttons the other engines have, through the shared
/// MediaResultCard.
struct PiChatView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        Group {
            switch model.piState {
            case .ready:
                chat
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
        .chatWindowExpansion(help: "Give Pi the whole window")
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                modelMenu
                Button {
                    model.restartPi()
                } label: {
                    Label("Restart Pi", systemImage: "arrow.clockwise")
                }
                .help("Restart the Pi process — also refreshes its model list")
            }
        }
        .task { model.startPiIfNeeded() }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(model.piModelChoices, id: \.id) { choice in
                Button {
                    model.setPiModel(choice.id)
                } label: {
                    if choice.id == model.piCurrentModel {
                        Label(menuTitle(choice), systemImage: "checkmark")
                    } else {
                        Text(menuTitle(choice))
                    }
                }
            }
        } label: {
            Label(currentModelLabel, systemImage: "cpu")
        }
        .help("Which gateway model Pi drives")
    }

    private func menuTitle(_ choice: GatewayAPI.Model) -> String {
        choice.serving
            ? "\(choice.displayName) — serving now"
            : choice.displayName
    }

    private var currentModelLabel: String {
        guard let current = model.piCurrentModel,
              let match = model.piModelChoices.first(where: { $0.id == current })
        else { return "Model" }
        return match.displayName
    }

    // MARK: - Transcript

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.piItems.isEmpty {
                            emptyHint
                        }
                        ForEach(model.piItems) { item in
                            itemView(item)
                                .id(item.id)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.piItems.count) {
                    if let last = model.piItems.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            Divider()
            inputBar
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pi is ready.")
                .font(.headline)
            Text("It can read, edit and run things in its workspace, and the whole "
                 + "silicon toolbox is on board — ask for an image, a clip on the "
                 + "render node, a 3D mesh, or just chat with the model in the picker.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }

    @ViewBuilder
    private func itemView(_ item: AppModel.PiItem) -> some View {
        switch item.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 3) {
                HStack {
                    Spacer(minLength: 60)
                    Text(item.text)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                }
                // What the turn was pointed at, when it was pointed at anything. A line in
                // the system prompt that changed what the model reached for should be
                // visible to the person whose turn it was, not only in a log.
                if let suggestion = item.suggestion {
                    Label("Jev suggested \(suggestion)", systemImage: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 6) {
                    Text(item.text)
                        .textSelection(.enabled)
                    if item.running {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    }
                }
                // The full media treatment: any produced file becomes a playable,
                // revealable card — same component Codex uses.
                ForEach(GatewayAPI.mediaPaths(in: item.text), id: \.self) { path in
                    MediaResultCard(path: path)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            DisclosureGroup {
                Text(item.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            } label: {
                Label(item.running ? "Thinking…" : "Thought",
                      systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .tool(let name):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(.caption.weight(.semibold))
                    if item.running {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    }
                }
                if !item.text.isEmpty {
                    Text(item.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(item.running ? 3 : 12)
                }
                ForEach(GatewayAPI.mediaPaths(in: item.text), id: \.self) { path in
                    MediaResultCard(path: path)
                }
                if let screening = item.screening {
                    GuardrailVerdictLine(screening: screening)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        case .notice:
            Label(item.text, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.orange)
        case .approval(_, let tool):
            PiApprovalCard(item: item, tool: tool)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(
                model.piBusy ? "Steer Pi mid-run…" : "Ask Pi…",
                text: $draft, axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .focused($inputFocused)
            .onSubmit(send)
            if model.piBusy {
                Button {
                    model.abortPi()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Stop the current run")
            }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(10)
    }

    private func send() {
        let text = draft
        draft = ""
        model.sendPiMessage(text)
        inputFocused = true
    }

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
            Text("Pi could not start")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 480)
            HStack(spacing: 10) {
                Button("Try Again") { model.restartPi() }
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
/// One line saying what the guardrail made of a call: "Jev: safe", "Jev: review:
/// destructive, outside_working_tree", "Jev: block: exfiltrates".
///
/// Shared by the approval card below and by the tool rows that were screened and allowed,
/// so a person reading the transcript can see that every call went past the guardrail and
/// not only the ones it stopped.
struct GuardrailVerdictLine: View {
    let screening: GuardrailScreening

    var body: some View {
        Label(screening.summary, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(colour)
            .textSelection(.enabled)
    }

    /// Grey for a screening that did not happen. It says nothing was checked, and must not
    /// be mistaken for a pass.
    private var colour: Color {
        switch screening.verdict {
        case .act: .green
        case .confirm: .orange
        case .block: .red
        case nil: .secondary
        }
    }

    private var symbol: String {
        switch screening.verdict {
        case .act: "checkmark.shield"
        case .confirm: "exclamationmark.triangle"
        case .block: "hand.raised.slash"
        case nil: "questionmark.circle"
        }
    }
}

/// Pi wants to run a tool and the guardrail stopped to ask.
///
/// The call is really waiting: the extension's `tool_call` handler is blocked on the answer
/// these buttons send, so nothing runs until one of them is pressed. The card stays in the
/// transcript afterwards with the decision on it — what was refused is part of the history.
private struct PiApprovalCard: View {
    @Environment(AppModel.self) private var model
    let item: AppModel.PiItem
    let tool: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Pi wants to run: \(tool)", systemImage: "wrench.and.screwdriver")
                .font(.callout.weight(.semibold))
            if !item.text.isEmpty {
                Text(item.text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: .rect(cornerRadius: 6))
            }
            if let screening = item.screening {
                GuardrailVerdictLine(screening: screening)
            }
            if item.answered {
                Label(
                    item.allowed == true ? "Allowed." : "Denied.",
                    systemImage: item.allowed == true ? "play.circle" : "nosign"
                )
                .font(.caption)
                .foregroundStyle(item.allowed == true ? Color.secondary : Color.red)
            } else if item.running && item.screening == nil {
                // The card is up before the verdict is, so the wait is visible rather than
                // looking like a card that forgot to say anything.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("Screening…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    Button("Allow") { model.answerPiApproval(item, allow: true) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Deny") { model.answerPiApproval(item, allow: false) }
                        .controlSize(.small)
                }
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

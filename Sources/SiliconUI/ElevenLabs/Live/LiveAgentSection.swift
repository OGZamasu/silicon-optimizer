import AppKit
import SiliconElevenLabs
import SwiftUI
import UniformTypeIdentifiers

/// Talk to an agent: the section the pane shows.
struct LiveAgentSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LiveAgentScreen(screen: model.liveAgentScreen(), onOpenConversations: {
            model.elevenLabsPane.open(.agentConversations)
        })
    }
}

extension AppModel {
    /// The Talk to an agent screen's model, kept with the pane's other section state.
    func liveAgentScreen() -> LiveAgentModel {
        elevenLabsPane.state(for: .liveAgent) { LiveAgentModel(context: .app(self)) }
    }

    /// Opens Talk to an agent with `agentID` chosen — nothing starts until the owner presses Start.
    func openLiveAgent(agentID: String, name: String) {
        liveAgentScreen().choose(agentID: agentID, name: name)
        elevenLabsPane.open(.liveAgent)
    }
}

struct LiveAgentScreen: View {
    @Bindable var screen: LiveAgentModel
    var onOpenConversations: () -> Void = {}

    var body: some View {
        ElevenLabsSectionPage(.liveAgent) {
            VStack(alignment: .leading, spacing: 16) {
                setup
                if let question = screen.question { startQuestion(question) }
                ForEach(screen.approvals.filter { $0.state == .waiting || $0.state == .sending }) { approval in
                    LiveApprovalCard(approval: approval, now: screen.now) { approved in
                        Task { await screen.answer(approval.id, session: approval.session, approved: approved) }
                    }
                }
                conversation
            }
        }
        .task { if screen.agentsLoad == .idle { await screen.loadAgents() } }
        .onDisappear { screen.leave() }
    }

    private var setup: some View {
        LiveCard("Agent", subtitle: screen.isBusy ? "Locked while a conversation is starting or open." : nil) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Picker("Agent", selection: $screen.selectedAgentID) {
                        if screen.agents.isEmpty { Text("No agents").tag("") }
                        ForEach(screen.agents) { Text($0.name).tag($0.id) }
                    }
                    .frame(maxWidth: 360)
                    switch screen.agentsLoad {
                    case .loading:
                        ProgressView().controlSize(.small)
                    case .failed:
                        Button("Try again") { Task { await screen.loadAgents() } }
                    default:
                        Button {
                            Task { await screen.loadAgents() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Load the agents again")
                    }
                }
                if case .failed(let reason) = screen.agentsLoad {
                    Text("The agents could not be loaded: \(reason)").font(.caption).foregroundStyle(.red)
                }
                Toggle("Text only — no microphone, no voice (the agent must allow it)", isOn: $screen.textOnly)
            }
            .disabled(screen.isBusy)
        }
    }

    private func startQuestion(_ question: LiveAgentModel.StartQuestion) -> some View {
        LiveCard("Start a conversation with “\(question.agentName)”?") {
            VStack(alignment: .leading, spacing: 8) {
                Text("During it, this agent can — on ElevenLabs' side, without asking you each time:")
                    .font(.callout)
                ForEach(question.tools, id: \.self) { tool in
                    Label(tool, systemImage: "arrow.up.forward.app").font(.callout)
                }
                Text("Tools on MCP servers that need approval will ask you here. The conversation is billed by its length.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { screen.cancelStart() }
                    Button("Start conversation") { Task { await screen.confirmStart() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.6)))
    }

    private var conversation: some View {
        LiveCard("Conversation") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    LivePhaseLabel(text: phaseText, live: screen.phase == .live)
                    if let name = screen.sessionAgentName, screen.isOpen || screen.phase == .ended {
                        Text(name + (screen.sessionTextOnly ? " · text only" : " · voice")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    switch screen.phase {
                    case .idle, .ended:
                        // Never the default button: Return does not start a billed conversation.
                        Button {
                            Task { await screen.requestStart() }
                        } label: {
                            Label("Start", systemImage: screen.textOnly ? "text.bubble" : "mic.fill")
                        }
                        .disabled(screen.startBlocker != nil)
                        .help(screen.startBlocker ?? "The microphone stays off until you press this.")
                    case .preparing:
                        ProgressView().controlSize(.small)
                        Button("Cancel") { screen.cancelStart() }
                    case .asking:
                        EmptyView()
                    case .connecting:
                        Button("Cancel") { screen.cancelStart() }
                    case .live:
                        if !screen.sessionTextOnly {
                            Toggle("Mute", isOn: $screen.muted).toggleStyle(.button)
                                .help(LiveMicrophoneIndicator.muteHelp)
                            Button("Stop talking") { screen.interrupt() }
                                .help("Stops the agent's voice here; speaking over it does the same")
                        }
                        Button("End", role: .destructive) { Task { await screen.end() } }
                    case .ending:
                        Text("Ending…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    LiveMicrophoneIndicator(on: screen.microphoneOn, muted: screen.muted)
                    if screen.microphoneOn { LiveLevelMeter(level: screen.level) }
                }
                LiveUsageLine(
                    usage: screen.usage, now: screen.now,
                    billedBy: "ElevenLabs bills agent conversations by their length (and the agent's LLM use). Nothing reconnects on its own.",
                    showsAudioSent: !screen.sessionTextOnly, showsMessages: true
                )
                if let id = screen.conversationID {
                    HStack(spacing: 6) {
                        Text("Conversation \(id)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        if screen.phase == .ended { Button("Open Conversations", action: onOpenConversations).buttonStyle(.link) }
                    }
                }
                if let outcome = screen.outcome { LiveOutcomeBanner(outcome: outcome) }
                if let saved = screen.savedTranscript { LiveSavedFile(url: saved) }
                transcript
                if screen.phase == .live {
                    if !screen.attachments.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(screen.attachments) { file in
                                HStack(spacing: 4) {
                                    Image(systemName: "doc")
                                    Text(file.name).lineLimit(1).truncationMode(.middle)
                                    Button {
                                        Task { await screen.removeAttachment(file.id) }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Delete it from this conversation")
                                }
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            }
                            Text("Sent with the next message.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button {
                            chooseAttachment()
                        } label: {
                            Image(systemName: screen.uploading ? "hourglass" : "paperclip")
                        }
                        .disabled(screen.uploading || screen.attachments.count >= LiveAgentModel.maximumAttachments)
                        .help("Attach an image or PDF to the next message (at most \(LiveAgentModel.maximumAttachments))")
                        // Return sends a message in a conversation already open; it never starts one.
                        TextField("Type a message", text: $screen.message)
                            .onSubmit { Task { await screen.sendMessage() } }
                        Button("Send") { Task { await screen.sendMessage() } }
                            .disabled(screen.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(screen.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(label(line.role))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color(line.role))
                        .frame(width: 44, alignment: .leading)
                    Text(line.text + (line.interrupted ? " —" : ""))
                        .font(line.role == .tool || line.role == .system ? .callout : .body)
                        .foregroundStyle(line.tentative ? .secondary : (line.role == .system ? .secondary : .primary))
                        .italic(line.tentative)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if line.role == .agent, line.eventID != nil, screen.phase == .live {
                        Button { Task { await screen.rate(line.id, liked: line.liked == true ? nil : true) } } label: {
                            Image(systemName: line.liked == true ? "hand.thumbsup.fill" : "hand.thumbsup")
                        }
                        .buttonStyle(.borderless)
                        Button { Task { await screen.rate(line.id, liked: line.liked == false ? nil : false) } } label: {
                            Image(systemName: line.liked == false ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func chooseAttachment() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { Task { await screen.attach(url) } }
    }

    private func label(_ role: LiveAgentModel.Line.Role) -> String {
        switch role {
        case .user: "You"
        case .agent: "Agent"
        case .tool: "Tool"
        case .system: "Note"
        }
    }

    private func color(_ role: LiveAgentModel.Line.Role) -> Color {
        switch role {
        case .user: .blue
        case .agent: .green
        case .tool: .purple
        case .system: .secondary
        }
    }

    private var phaseText: String {
        switch screen.phase {
        case .idle: "Not started"
        case .preparing: "Reading the agent…"
        case .asking: "Waiting for you"
        case .connecting: "Connecting…"
        case .live: "Live"
        case .ending: "Ending…"
        case .ended: "Ended"
        }
    }
}

/// One MCP tool approval: which tool, on which server, at which host, with what — as data — and
/// the owner's two answers. Neither is the default button.
struct LiveApprovalCard: View {
    let approval: LiveAgentModel.Approval
    let now: Date
    let answer: (Bool) -> Void

    var body: some View {
        LiveCard("“\(approval.agentName)” wants to run “\(approval.toolName)”") {
            VStack(alignment: .leading, spacing: 8) {
                Text("On the MCP server \(approval.serverName)\(approval.serverHost.map { " at \($0)" } ?? ""). It acts there, outside this conversation.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let description = approval.toolDescription, !description.isEmpty {
                    Text("The server describes it as: \(description)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if approval.parameters != .null {
                    Text(approval.parameters.jsonString(pretty: true))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                }
                HStack(spacing: 10) {
                    Button("Decline") { answer(false) }
                    Button("Approve") { answer(true) }
                    Text("Declined on its own in \(LiveClock.text(max(0, approval.deadline.timeIntervalSince(now)))).")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .disabled(approval.state != .waiting)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.7), lineWidth: 1.5))
    }
}

import SiliconRuntime
import SwiftUI
import WebKit

/// The Chat tab when the DeepSeek Harness engine is selected: the harness's own web UI,
/// embedded, with the app supplying the model underneath it.
struct HarnessChatView: View {
    @Environment(AppModel.self) private var model
    @State private var isHoveringCollapse = false

    private var isExpanded: Bool { model.chatColumnVisibility == .detailOnly }

    var body: some View {
        Group {
            switch model.harnessState {
            case .ready(let endpoint):
                VStack(spacing: 0) {
                    if model.loadedModel == nil {
                        // Nothing local doesn't always mean nothing at all: the swarm may
                        // be serving a model, or have one a single Start away.
                        if let remote = model.runningPeerLLM {
                            banner(
                                "Nothing is loaded on this Mac — \(remote.model) is live on "
                                + "\(remote.peer.name). Pick it in the model picker, or load "
                                + "a local model.",
                                actionTitle: "Open Models"
                            ) { model.selectedTab = .models }
                        } else if let stopped = model.stoppedPeerLLM {
                            banner(
                                "No model is running anywhere — \(stopped.model) on "
                                + "\(stopped.peer.name) is stopped. Chat fails with a "
                                + "connection error until a model is up.",
                                actionTitle: model.peerLLMBusy.contains(stopped.peer.name)
                                    ? "Starting…" : "Start \(stopped.model)"
                            ) {
                                Task { await model.setPeerLLM(stopped.peer, running: true) }
                            }
                        } else {
                            banner(
                                "No model is loaded — the harness has nothing to answer "
                                + "with. Requests will fail until one is loaded.",
                                actionTitle: "Open Models", action: { model.selectedTab = .models },
                                secondaryActionTitle: model.lastLoaded.map {
                                    "Reload \($0.model.name)"
                                },
                                secondaryAction: model.lastLoaded != nil
                                    ? { model.reloadLastModel() } : nil
                            )
                        }
                        Divider()
                    } else if let warning = contextWarning {
                        banner(warning, actionTitle: nil, action: nil)
                        Divider()
                    }
                    EmbeddedChatWebView(url: endpoint, gatewayPort: model.gatewayPort())
                }
                .task {
                    // The banner's claims about peers must be as fresh as the page.
                    await model.refreshSwarm()
                }
                .overlay(alignment: .topTrailing) {
                    if isExpanded { collapseButton }
                }
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
        // Expanded means the whole window: the toolbar goes away and the content extends up
        // into the title bar area, leaving only the floating collapse button as the way back.
        .toolbar(isExpanded ? .hidden : .automatic, for: .windowToolbar)
        .ignoresSafeArea(edges: isExpanded ? .top : [])
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.chatColumnVisibility =
                        model.chatColumnVisibility == .detailOnly ? .all : .detailOnly
                } label: {
                    Label(
                        model.chatColumnVisibility == .detailOnly ? "Show Sidebar" : "Expand",
                        systemImage: model.chatColumnVisibility == .detailOnly
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                }
                .help(model.chatColumnVisibility == .detailOnly
                    ? "Bring the sidebar back"
                    : "Give the harness the whole window")
                if case .ready(let endpoint) = model.harnessState {
                    Button {
                        NSWorkspace.shared.open(endpoint)
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    .help("Open the harness in your default browser")
                }
                Button {
                    model.restartHarness()
                } label: {
                    Label("Restart Harness", systemImage: "arrow.clockwise")
                }
                .help("Restart the DeepSeek Harness process")
            }
        }
        .task { model.startHarnessIfNeeded() }
    }

    /// The way back from full-window mode: a translucent button floating over the page, kept
    /// faint until hovered so it does not sit visibly on top of the harness UI.
    private var collapseButton: some View {
        Button {
            model.chatColumnVisibility = .all
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(7)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(isHoveringCollapse ? 1.0 : 0.3)
        .animation(.easeOut(duration: 0.15), value: isHoveringCollapse)
        .onHover { isHoveringCollapse = $0 }
        .padding(10)
        .help("Exit full window")
    }

    /// A loaded model whose context cannot hold the harness's preamble fails on the very
    /// first message, with an error that surfaces inside the web UI where nothing explains
    /// it. Diagnose it here, where the fix can be named.
    private var contextWarning: String? {
        guard model.loadedModel != nil,
              let context = model.activeConfiguration?.contextLength,
              context < AppModel.harnessContextMinimum
        else { return nil }
        return "The loaded model has a \(context)-token context — the harness needs about "
            + "\(AppModel.harnessContextMinimum) before the conversation even starts. Reload "
            + "the model (the app raises the context automatically when memory allows), or "
            + "free memory by choosing a smaller quantization."
    }

    private func banner(
        _ warning: String, actionTitle: String?, action: (() -> Void)?,
        secondaryActionTitle: String? = nil, secondaryAction: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(warning)
                .font(.callout)
            Spacer(minLength: 0)
            // The reload offer first and prominent: it is one click back to exactly where
            // things were, where "Open Models" is a detour through picking everything again.
            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle, action: secondaryAction)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
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
            Text("The harness could not start")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 480)
            HStack(spacing: 10) {
                Button("Try Again") { model.startHarnessIfNeeded() }
                    .keyboardShortcut(.defaultAction)
                Button("Use Built-in Chat") {
                    model.settings.chatEngine = .legacy
                    model.settings.save()
                    model.chatEngineDidChange()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


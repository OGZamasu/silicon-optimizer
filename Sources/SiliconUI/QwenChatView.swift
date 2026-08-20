import AppKit
import SiliconRuntime
import SwiftUI

/// The Chat tab when the Qwen Code engine is selected: its Web Shell, embedded, with the
/// app's gateway supplying every model underneath it. Media the chat produces gets the
/// same injected players and Finder buttons the harness view has — it is the same
/// embedded web view.
struct QwenChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.qwenState {
            case .ready(let endpoint):
                EmbeddedChatWebView(url: endpoint, gatewayPort: model.gatewayPort())
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
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if case .ready(let endpoint) = model.qwenState {
                    Button {
                        NSWorkspace.shared.open(endpoint)
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    .help("Open the Web Shell in your default browser")
                }
                Button {
                    model.restartQwen()
                } label: {
                    Label("Restart Qwen Code", systemImage: "arrow.clockwise")
                }
                .help("Restart the Qwen Code process — also refreshes its model list")
            }
        }
        .task { model.startQwenIfNeeded() }
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
            Text("Qwen Code could not start")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 480)
            HStack(spacing: 10) {
                Button("Try Again") { model.startQwenIfNeeded() }
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

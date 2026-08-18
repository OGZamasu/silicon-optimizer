import SiliconRuntime
import SwiftUI
import WebKit

/// The Chat tab when the DeepSeek Harness engine is selected: the harness's own web UI,
/// embedded, with the app supplying the model underneath it.
struct HarnessChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.harnessState {
            case .ready(let endpoint):
                VStack(spacing: 0) {
                    if model.loadedModel == nil {
                        banner(
                            "No model is loaded — the harness has nothing to answer with. "
                            + "Requests will fail until one is loaded.",
                            actionTitle: "Open Models"
                        ) { model.selectedTab = .models }
                        Divider()
                    } else if let warning = contextWarning {
                        banner(warning, actionTitle: nil, action: nil)
                        Divider()
                    }
                    HarnessWebView(url: endpoint)
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
        _ warning: String, actionTitle: String?, action: (() -> Void)?
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(warning)
                .font(.callout)
            Spacer(minLength: 0)
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

/// A minimal WKWebView host. The page is served from localhost by a process this app manages,
/// so there is no navigation policy to speak of — external links open in the default browser.
private struct HarnessWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // Reload only when the harness moved to a different port; SwiftUI calls this on every
        // unrelated state change and reloading each time would wreck in-page state.
        if view.url?.host() != url.host() || view.url?.port != url.port {
            view.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            // Keep the embedded view on the harness itself; anything else (result links,
            // documentation) belongs in the real browser.
            if let target = navigationAction.request.url,
               navigationAction.navigationType == .linkActivated,
               target.host() != webView.url?.host() || target.port != webView.url?.port {
                NSWorkspace.shared.open(target)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

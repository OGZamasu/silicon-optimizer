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
                    HarnessWebView(url: endpoint, gatewayPort: model.gatewayPort())
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

/// A minimal WKWebView host. The page is served from localhost by a process this app manages,
/// so there is no navigation policy to speak of — external links open in the default browser.
///
/// One enrichment is injected: a script that watches the transcript for media file paths —
/// a clip the chat just rendered, an image it generated — and puts a real player under
/// them, with Reveal-in-Finder and copy buttons. The page cannot read local files or touch
/// Finder itself, so the media bytes and the reveal action go through the app's loopback
/// gateway. The harness version is pinned, which is what makes leaning on its DOM sane.
private struct HarnessWebView: NSViewRepresentable {
    let url: URL
    let gatewayPort: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let script = WKUserScript(
            source: Self.mediaScript(gatewayPort: gatewayPort),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(script)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    /// The injected media enricher. Plain JS, no dependencies; everything it loads or
    /// asks for goes to the gateway, which only serves the app's own output folders.
    static func mediaScript(gatewayPort: Int) -> String {
        """
        (function () {
          const GATEWAY = "http://127.0.0.1:\(gatewayPort)";
          // Segments may hold single spaces ("Silicon Optimizer" is the default output
          // folder); the lookbehind keeps URLs out.
          const PATTERN = /(?<![:\\/\\w])(\\/(?:[\\w.\\-]+(?: [\\w.\\-]+)*\\/)*[\\w.\\-]+(?: [\\w.\\-]+)*\\.(?:mp4|mov|webm|png|jpe?g|webp|gif|wav|mp3|m4a|aiff|flac|glb|obj))\\b/gi;
          const seen = new Set();

          const style = document.createElement("style");
          style.textContent = `
            .so-media { margin: 8px 0; padding: 10px; border-radius: 10px;
                        background: rgba(127,127,127,.12); max-width: 640px; }
            .so-media video, .so-media img { max-width: 100%; max-height: 360px;
                        border-radius: 6px; display: block; }
            .so-media audio { width: 100%; }
            .so-media .so-row { display: flex; gap: 8px; margin-top: 8px; flex-wrap: wrap; }
            .so-media button { font: inherit; font-size: 12px; padding: 4px 10px;
                        border-radius: 6px; border: 1px solid rgba(127,127,127,.4);
                        background: rgba(127,127,127,.15); color: inherit; cursor: pointer; }
            .so-media button:hover { background: rgba(127,127,127,.3); }
            .so-media .so-name { font-size: 11px; opacity: .7; margin-top: 6px;
                        word-break: break-all; }
          `;
          document.head.appendChild(style);

          function mediaURL(path) {
            return GATEWAY + "/ui/media?path=" + encodeURIComponent(path);
          }

          function button(label, action) {
            const control = document.createElement("button");
            control.textContent = label;
            control.addEventListener("click", (event) => {
              event.stopPropagation();
              action(control);
            });
            return control;
          }

          function flash(control, text) {
            const original = control.textContent;
            control.textContent = text;
            setTimeout(() => { control.textContent = original; }, 1200);
          }

          function card(path) {
            const kind = path.split(".").pop().toLowerCase();
            const box = document.createElement("div");
            box.className = "so-media";
            box.dataset.soPath = path;

            if (["mp4", "mov", "webm"].includes(kind)) {
              const video = document.createElement("video");
              video.controls = true; video.preload = "metadata";
              video.src = mediaURL(path);
              box.appendChild(video);
            } else if (["png", "jpg", "jpeg", "webp", "gif"].includes(kind)) {
              const img = document.createElement("img");
              img.src = mediaURL(path);
              box.appendChild(img);
            } else if (["wav", "mp3", "m4a", "aiff", "flac"].includes(kind)) {
              const audio = document.createElement("audio");
              audio.controls = true; audio.preload = "metadata";
              audio.src = mediaURL(path);
              box.appendChild(audio);
            }

            const row = document.createElement("div");
            row.className = "so-row";
            if (["glb", "obj"].includes(kind)) {
              row.appendChild(button("Open in 3D viewer", (control) => {
                fetch(GATEWAY + "/ui/open3d", { method: "POST", body: "{}" });
                flash(control, "Opening…");
              }));
            }
            row.appendChild(button("Show in Finder", (control) => {
              fetch(GATEWAY + "/ui/reveal", {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({ path }),
              }).then(r => flash(control, r.ok ? "Opened" : "Not allowed"));
            }));
            row.appendChild(button("Copy path", (control) => {
              navigator.clipboard.writeText(path).then(() => flash(control, "Copied"));
            }));
            if (["png", "jpg", "jpeg", "webp", "gif"].includes(kind)) {
              row.appendChild(button("Copy image", (control) => {
                fetch(mediaURL(path))
                  .then(r => r.blob())
                  .then(blob => {
                    // The clipboard API only takes PNG; transcode through a canvas.
                    const img = new Image();
                    img.onload = () => {
                      const canvas = document.createElement("canvas");
                      canvas.width = img.naturalWidth; canvas.height = img.naturalHeight;
                      canvas.getContext("2d").drawImage(img, 0, 0);
                      canvas.toBlob(png => {
                        navigator.clipboard
                          .write([new ClipboardItem({ "image/png": png })])
                          .then(() => flash(control, "Copied"), () => flash(control, "Failed"));
                      }, "image/png");
                    };
                    img.src = URL.createObjectURL(blob);
                  });
              }));
            }
            box.appendChild(row);

            const name = document.createElement("div");
            name.className = "so-name";
            name.textContent = path.split("/").pop();
            box.appendChild(name);
            return box;
          }

          function blockOf(node) {
            let element = node.nodeType === 1 ? node : node.parentElement;
            while (element && element !== document.body) {
              const display = getComputedStyle(element).display;
              if (display === "block" || display === "flex" || display === "grid") {
                return element;
              }
              element = element.parentElement;
            }
            return null;
          }

          function scan(root) {
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
            let node;
            while ((node = walker.nextNode())) {
              if (node.parentElement && node.parentElement.closest(".so-media")) continue;
              const text = node.textContent;
              if (!text || text.length < 8) continue;
              PATTERN.lastIndex = 0;
              let match;
              while ((match = PATTERN.exec(text))) {
                const path = match[1];
                const block = blockOf(node);
                if (!block) continue;
                // A React re-render can reconcile an inserted card away; a card whose
                // element is gone gets made again rather than remembered as done.
                const alive = document.querySelector(
                  '.so-media[data-so-path="' + CSS.escape(path) + '"]'
                );
                if (alive) continue;
                seen.add(path);
                block.insertAdjacentElement("afterend", card(path));
              }
            }
          }

          scan(document.body);
          const observer = new MutationObserver((mutations) => {
            for (const mutation of mutations) {
              for (const added of mutation.addedNodes) {
                if (added.nodeType === 1 && !added.closest?.(".so-media")) {
                  scan(added);
                } else if (added.nodeType === 3 && added.parentElement) {
                  scan(added.parentElement);
                }
              }
            }
          });
          observer.observe(document.body, { childList: true, subtree: true });
        })();
        """
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

import AppKit
import SwiftUI
import WebKit

/// A minimal WKWebView host. The page is served from localhost by a process this app manages,
/// so there is no navigation policy to speak of — external links open in the default browser.
///
/// One enrichment is injected: a script that watches the transcript for media file paths —
/// a clip the chat just rendered, an image it generated — and puts a real player under
/// them, with Reveal-in-Finder and copy buttons. The page cannot read local files or touch
/// Finder itself, so the media bytes and the reveal action go through the app's loopback
/// gateway. Both embedded engines are version-pinned, which is what makes leaning on its DOM sane.
struct EmbeddedChatWebView: NSViewRepresentable {
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

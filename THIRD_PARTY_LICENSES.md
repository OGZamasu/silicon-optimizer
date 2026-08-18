# Third-party software shipped inside Silicon Optimizer

The app bundle includes these runtimes so that a fresh install works without any separate
setup. Each remains the property of its authors under its own licence.

## llama.cpp (`Contents/Resources/bin/llama-server` and `lib*.dylib`)

- Upstream: https://github.com/ggml-org/llama.cpp — MIT licence.
- The bundled build includes the expert-streaming changes discussed in
  ggml-org/llama.cpp#23324, compiled for Apple Silicon. The app probes the binary's actual
  capabilities at runtime and never assumes them.

## Node.js (`Contents/Resources/bin/node`)

- Upstream: https://nodejs.org — the official `darwin-arm64` build, unmodified
  (checksum-verified against the release SHASUMS at bundle time).
- Node.js is available under the MIT licence with bundled components under their own
  licences; the full text ships alongside this file as `NODE_LICENSE`.
- Used to run the DeepSeek Harness (`@deepseek-ai/dsh`, MIT), which the app installs into
  its own application-support directory on first use of the Chat tab.

## Sparkle (`Contents/Frameworks/Sparkle.framework`)

- Upstream: https://sparkle-project.org — MIT licence. Handles signed automatic updates.

Models are not bundled. Every model the app downloads shows its own licence in the app and
links to its source.

# Third-party software shipped inside Silicon Optimizer

The app bundle includes these runtimes so that a fresh install works without any separate
setup. Each remains the property of its authors under its own licence.

Release inputs under `Vendor/` are ignored by Git because they are large platform binaries.
Every native file that may enter a public bundle must therefore be listed, by exact filename
and SHA-256 digest, in the tracked `Scripts/vendor-runtime-manifest.sha256`. The release
script rejects a missing, changed, symlinked, or undeclared runtime before code signing.

## llama.cpp (`Contents/Resources/bin/llama-server` and `lib*.dylib`)

- Upstream: https://github.com/ggml-org/llama.cpp — MIT licence.
- The bundled build includes the expert-streaming changes discussed in
  ggml-org/llama.cpp#23324, compiled for Apple Silicon. The app probes the binary's actual
  capabilities at runtime and never assumes them.

## Node.js (`Contents/Resources/bin/node`)

- Upstream: https://nodejs.org — an official `darwin-arm64` build, unmodified.
  Its reviewed release bytes must match the digest in the tracked runtime manifest.
- Node.js is available under the MIT licence with bundled components under their own
  licences; the full text ships alongside this file as `NODE_LICENSE`.
- Used to run the DeepSeek Harness (`@deepseek-ai/dsh`, MIT), which the app installs into
  its own application-support directory on first use of the Chat tab.

## Sparkle (`Contents/Frameworks/Sparkle.framework`)

- Upstream: https://sparkle-project.org — MIT licence. Handles signed automatic updates.

Models are not bundled. Every model the app downloads shows its own licence in the app and
links to its source.

## Deep-Live-Cam

The live face camera is [Deep-Live-Cam](https://github.com/hacksider/Deep-Live-Cam),
licensed **AGPL-3.0**. Silicon Optimizer does not bundle or modify it: the setup step
clones it into its own Python environment under `~/.silicon-facecam`, and the app runs
it there as a separate process through a small driver script (`Resources/facecam.py`).
Its own content check runs as shipped.

Its face model (`inswapper_128`) is downloaded by the project's own pre-check, from the
project's own release, and carries the InsightFace non-commercial research licence.

## laya-mlx and the Laya decision models

The local decision lane (**Settings → Decisions**) is optional and is downloaded on request,
into the model library you configure — nothing ships in this app's bundle but the small
driver script it runs.

- **laya-mlx** (`laya-mlx==0.1.0`), the MLX runtime — Apache-2.0.
  <https://github.com/mizorewww/laya-mlx>
- **Laya** decision model weights, © Convai Innovations — Apache-2.0.
  <https://github.com/NandhaKishorM/laya>
  Fetched as `aac6fef/laya-mlx`, `aac6fef/laya-multilingual-mlx` or
  `aac6fef/laya-typed-decisions-mlx`, each pinned to an exact commit.

The two halves share a licence and have different rightsholders. Each repository ships its
own `NOTICE`, which is fetched alongside its weights and kept beside them, as Apache-2.0
§4(d) requires; both attributions are shown on the lane's row in Settings.

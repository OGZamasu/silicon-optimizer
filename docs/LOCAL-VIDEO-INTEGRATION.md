# Local video integration and source parity

The local video node in `Resources/video-node` makes an installed Apple Silicon
renderer available through Silicon Optimizer's normal swarm job API. The app
owns model selection and delivery; the node owns its persistent queue and MP4
validation; Phosphene or LTX owns model loading and generation.

```text
Video tab / Control API / MCP / OpenMontage
  -> NodeVideoRuntime (selected model, duration, optional H3 window prompts)
  -> authenticated loopback video node (persistent queue)
  -> Phosphene H3 or LTX MLX
  -> validated MP4 + model sidecar
```

See the [node setup and update instructions](../Resources/video-node/README.md)
and [batch/gallery example](../Resources/video-node/examples/README.md).
App bundles include the installer, adapter, documentation, and example inputs;
renderer installations and model downloads remain separate dependencies.

## Coverage of the working installation

The September 8, 2026 audit compared the installed application, its original
build checkout, the deployed node, and the renderer checkouts. This is the
accounting for the changes that made the local batch work:

| Component | Source coverage |
| --- | --- |
| Model-specific video routing and durations | PR #19's original two commits. Their patch IDs match the two video commits in the installed application's build checkout. |
| Local Phosphene H3 / LTX adapter | `Resources/video-node/silicon_video_node.py`, with portable configuration and installation replacing the original machine-specific paths. |
| H3 per-window prompts | Adapter support plus the Control API, MCP, OpenMontage, and node-request fields in this change. A regular single-prompt request remains valid. |
| Batch submission, retry, validation, provenance, and gallery | `Resources/video-node/examples`; the twenty honey-badger prompts are an example dataset. |
| LaunchAgent and node pairing | Reproducible installer in `Resources/video-node/install.py`; it preserves existing configuration and offers a dry run. |
| Other installed application changes | Already proposed in [PR #18](https://github.com/OGZamasu/silicon-optimizer/pull/18). The installed app binary matched the build combining that PR with PR #19's original two commits. |
| Phosphene and its MiniMax MLX engine | Clean third-party checkouts; no extra source patches from this integration. |
| Legacy LTX package build workaround | Two local `readme` metadata edits worked around Hatchling 1.32's rejection of paths outside the package. The documented `hatchling<1.32` build constraint replaces those edits for the tested LTX 0.14.19 checkout. Current LTX versions may not need it. |
| Local `LSUIElement=false` override | A local application-launch preference, not needed for video. Main already promotes the app to Dock/Cmd+Tab while its main window is visible; [PR #7 was incorporated through #6](https://github.com/OGZamasu/silicon-optimizer/pull/7#issuecomment-5329358380). |
| Local `.swift-version` (`6.3.3`) | Records the compiler used for the installed build. It is not a product feature or a runtime requirement. |
| Weights, tokens, job history, generated videos | Runtime data. Retained outside the repository; the installer and example create or use them through documented paths. |

PR #19 can be reviewed on its own. Full parity with the installed application's
non-video behavior also depends on PR #18 being accepted. The PRs overlap in
some source files, so maintainers should preserve both changes when merging.

## Rendering evidence and its limits

The source adapter that preceded this portable version generated twenty unique
MiniMax H3 clips locally through Phosphene 4.11.1 (`94bd30d`) and its MiniMax MLX
engine (`21e8824`). The legacy LTX adapter used LTX MLX 0.14.19 (`1192051`).

All twenty H3 outputs passed full audio/video decoding and contained exactly
240 H.264 frames at 24 fps, 854 x 480, 10.000 seconds, with stereo AAC audio.
Each matched a distinct Phosphene job, engine `h3`, tier `draft_10s`, two window
prompts, and an applied Turbo adapter without fallback. Rendering took roughly
2.4–4.1 minutes per clip; no retries were required. These results describe the
tested Mac and settings, not a performance promise for other machines.

The portable implementation adds automated tests around the node contract,
installation, restart recovery, prompt validation, batch behavior, and timeout
handling. Its CI uses fake renderers and temporary data; it does not download
weights or claim to measure generation quality. Model capability checks still
come from the installed renderer at runtime. Higher resolutions and 15-second
clips require more time and memory than this batch's 10-second draft setting.

A separate live smoke test of the portable adapter also completed a two-window
10-second H3 render through the installed Phosphene engine. The adapter resumed
the same engine job after a restart, returned the same ID on an idempotent
submission, and served bytes matching its local artifact. The result was
854 x 480, 24 fps, 240 frames, H.264 with AAC, and passed full decoding; the
Phosphene sidecar recorded `draft_10s`, two windows, and 208 Turbo tensors
applied without fallback. Test data and generated media are not repository
fixtures.

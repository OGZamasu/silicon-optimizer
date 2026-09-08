# MiniMax H3 batch and review example

This optional Python controller exercises the local video node with a replayable 20-clip honey-badger example. It queues jobs, resumes interrupted monitoring, downloads each completed video, checks its MiniMax provenance and media, and writes a local HTML review gallery. The app's normal video-generation UI does not depend on the example or its prompts.

The source workflow completed all 20 example clips locally with **MiniMax Hailuo H3, 10 seconds, 480p draft, Turbo enabled, and two sequential five-second prompt windows**. The worker produced 854×480 H.264 video at 24 fps with 240 frames and AAC audio. Every clip passed a full audio/video decode and matching H3 provenance checks. Render timing and visual output depend on hardware, runtime versions, and model versions; fixed seeds do not promise identical files across installations.

## Prerequisites

- Install the [local video node](../README.md), including its bearer token and persistent service.
- Have Phosphene running with H3 model weights, the Turbo adapter, and support for H3 `chain` and `chain_prompts`. The node must advertise H3 availability. Configure its H3 quality as `draft`, Turbo enabled, and upscale `off`.
- Install Python 3.9 or newer, plus `ffmpeg` and `ffprobe` on `PATH` (Homebrew's standard locations are also detected).
- Run this controller on the same Mac as the video node. It reads the worker's local provenance sidecars; its HTTP client accepts only a loopback origin and does not follow redirects or use proxy settings.

The repository contains code, prompts, and tests only. Obtain model weights and any required access directly through the model provider and Phosphene setup.

## Run the included example

From the repository root, first prepare a gallery without calling the video API or starting a render:

```sh
python3 Resources/video-node/examples/minimax_h3_batch.py build-review
```

The default review folder is `~/Movies/Silicon Optimizer/MiniMax H3`. The controller reads the raw bearer token from `~/Library/Application Support/SiliconOptimizer/video-node/token` and uses the worker's `artifacts` directory next to that token. It supports the current `artifacts/<job-id>/` layout and the legacy flat layout. If the default token file is absent, it can use the credential for the exact loopback origin in Silicon Optimizer's `swarm.json`.

Render and review one clip before queuing the rest:

```sh
python3 Resources/video-node/examples/minimax_h3_batch.py submit HB001
python3 Resources/video-node/examples/minimax_h3_batch.py wait HB001
open "$HOME/Movies/Silicon Optimizer/MiniMax H3/index.html"
```

Then submit the complete set and materialize completed videos as they arrive:

```sh
python3 Resources/video-node/examples/minimax_h3_batch.py submit
python3 Resources/video-node/examples/minimax_h3_batch.py wait --interval 15
```

Repeated `submit` commands reuse existing matching jobs. The example's IDs are `MMH3_HB001` through `MMH3_HB020`, and the node serializes GPU jobs. Interrupting `wait` stops polling; the persistent video-node service continues its queue. Run `wait` again to resume, or `status` to refresh progress. Refresh the HTML gallery to see newly materialized clips.

```sh
python3 Resources/video-node/examples/minimax_h3_batch.py status
python3 Resources/video-node/examples/minimax_h3_batch.py materialize
python3 Resources/video-node/examples/minimax_h3_batch.py retry HB007
python3 Resources/video-node/examples/minimax_h3_batch.py wait HB007
```

`retry` only retries a failed/cancelled/error job without a verified final. It creates a new deterministic attempt ID such as `MMH3_HB007_R02`; it does not silently regenerate successful clips. A failed media or provenance check is reported in the manifest and gallery. Re-run `materialize` after resolving the cause. Command exit status is nonzero if validation or an explicitly selected retry fails, or if `wait` finishes with failed/unverified clips.

## Use your own prompts or directories

Global options go **before** the command and should remain identical for every invocation of a batch:

```sh
python3 Resources/video-node/examples/minimax_h3_batch.py \
  --prompts /path/to/clips.json \
  --chain-prompts /path/to/chains.json \
  --review-dir "$HOME/Movies/My H3 Batch" \
  --job-prefix MyBatch \
  --api http://127.0.0.1:8790 \
  --token-file "$HOME/Library/Application Support/SiliconOptimizer/video-node/token" \
  --worker-artifacts "$HOME/Library/Application Support/SiliconOptimizer/video-node/artifacts" \
  submit
```

`clips.json` can contain any nonempty number of clips:

```json
{
  "batch": "My H3 Batch",
  "model": "hailuo-h3",
  "seconds": 10,
  "resolution": "480p",
  "clips": [
    {
      "id": "Scene-1",
      "title": "Morning coffee",
      "slug": "morning_coffee",
      "seed": 42,
      "prompt": "A continuous ten-second shot of a honey badger making coffee."
    }
  ]
}
```

The matching `chains.json` contains exactly the same clip IDs and two nonempty strings per ID (maximum 4,000 characters each):

```json
{
  "Scene-1": [
    "Window 1: A honey badger reaches for a coffee cup at sunrise. Soft birdsong, steady close camera.",
    "Window 2: Seamless continuation with the same badger, cup, camera and light. It pours coffee and smiles. Birdsong continues."
  ]
}
```

Clip IDs must be 1–32 letters, digits or hyphens, start with a letter, and be unique ignoring case. Slugs must be 1–40 letters, digits, underscores or hyphens, starting with a letter or digit. Seeds are integers from 0 through 4,294,967,295. The job prefix must be 1–16 letters, digits, underscores or hyphens and start with a letter.

The full brief is preserved in job metadata; the two window prompts guide the sequential H3 generation. This controller intentionally validates the tested 10-second 480p workflow. The video node supports other H3 durations, but changing this example to 15 seconds also requires three prompts and corresponding media-validation changes.

Use a **new review directory and job prefix** for a new batch or changed prompts. Existing manifests and remote job identities are checked before reuse, so previously verified outputs cannot silently acquire new prompts or seeds. An existing legacy `MMH3` manifest can be resumed using explicit review/artifact paths and the same prompt specifications.

The equivalent environment variables are `SILICON_VIDEO_API`, `SILICON_VIDEO_TOKEN_FILE`, `SILICON_VIDEO_PROMPTS`, `SILICON_VIDEO_CHAIN_PROMPTS`, `SILICON_VIDEO_REVIEW_DIR`, `SILICON_VIDEO_WORKER_ARTIFACTS`, and `SILICON_VIDEO_JOB_PREFIX`. `SILICON_VIDEO_DATA_DIR` overrides the video-node data root and therefore the default token and artifact paths. Use `--swarm-config` or `SILICON_SWARM_CONFIG` to override the legacy credential fallback. Pass a token **file path**, not the bearer token itself.

## Outputs and checks

The review folder contains `index.html`, `manifest.json`, `final/*.mp4`, `final/*.json`, and `posters/*.jpg`. Each final sidecar preserves the worker's MiniMax model and Phosphene pipeline/job identity, seed, prompt windows, requested quality, duration, and Turbo setting, with additional probe/decode results and a SHA-256 of the downloaded file.

Materialization requires matching `MiniMaxAI/MiniMax-H3` provenance, the `Phosphene Hailuo H3` pipeline, two exact prompt windows, draft/10s/Turbo metadata with upscale off, and audio. It checks H.264, 854×480, 24 fps, 239–241 frames, AAC audio, duration from 9.25 to 11 seconds, and a complete audio/video decode. Downloaded bytes must match the local worker artifact's SHA-256. An existing final is reused only when its recorded provenance matches the current job and its recorded, actual, and worker hashes agree. Downloaded replacements must pass checks before replacing an existing video; their posters are regenerated. These checks establish the recorded generation route and playable media; visual review is still needed to judge prompt adherence.

Run the tests without a video server, model weights, network calls, or rendering:

```sh
python3 -m unittest discover -s Resources/video-node/examples -p 'test_*.py' -v
```

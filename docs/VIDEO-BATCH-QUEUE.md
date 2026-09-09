# Video batches and variations

In **Video**, choose **Batch & variations**. Paste one shot per paragraph, with
a blank line between shots. Select the model, duration and size, choose 1–20
variations per prompt, and click **Queue N clips**. Twenty prompts with three
variations produce sixty clips. Up to 200 unfinished clips may be queued.

Every variation gets a distinct saved 32-bit seed. An optional base seed makes
the sequence predictable: subsequent clips increment it, wrapping after
4,294,967,295. Settings are captured when added; changing the composer does not
change queued jobs. This batch composer is text-only; the single-clip API still
supports images and H3 per-window prompts.

## Leave it working

Keep Silicon Optimizer open, the Mac powered, and its lid open. The app prevents
**idle system sleep** while the queue is working, not manual sleep, lid closure,
shutdown or loss of power. One clip is submitted at a time: more variations
increase total time, not simultaneous GPU renders. Other apps can still compete
for the GPU and unified memory.

The queue is saved as `video-queue.json` beside the app's control handshake in
`~/Library/Application Support/SiliconOptimizer`. Pending clips acquire the
node's 12-hour queue/render deadline only when submitted, so a whole batch may
take longer than twelve hours.

- **Pause after this clip** stops future submissions, not the active GPU job.
  **Resume queue** continues remaining clips.
- Quitting saves the queue. The accepted node job can continue, but the app must
  reopen to download it and dispatch later clips. It reconnects to the original
  node/job ID instead of submitting another render.
- Confirmed renderer failures do not discard the rest of the batch. A retry
  makes a new attempt with the same seed and records the previous node ID.
- A lost connection or failed download pauses future dispatch. **Reconnect /
  download** follows the existing job without regenerating it.
- If the app closes before saving a submission receipt, the outcome is unknown.
  Check the node before explicitly choosing to render again; that action may
  make a duplicate. Such submissions are never retried automatically.
- Only unsubmitted items can be removed. **Clear finished history** keeps media
  and editing manifests on disk. Invalid queue files are preserved; failed
  persistence prevents further submissions.

## Review and edit

Every batch gets a unique folder under the configured video destination:

```text
~/Movies/Silicon Optimizer/Batches/<timestamp>-<batch-id>/
  scene-001_take-01_seed-1400_<item-id>-a1.mp4
  scene-001_take-02_seed-1401_<item-id>-a1.mp4
  manifest.json
```

Use **Play**, **Show clip** and **Batch folder** in the queue. The manifest records
prompts, scene/take order, seeds, settings, node job IDs, status and output paths,
never tokens. Import your chosen MP4s into an editor. This feature makes clips,
not an automatically assembled or character-consistent movie.

## Sampling, quality and resource use

H3 sampling choices with the updated node:

| Choice | What changes |
| --- | --- |
| Renderer default | Uses the node's configured Turbo setting; compatible with older nodes. |
| Turbo — faster | Requests Phosphene's Turbo adapter and shorter schedule. Availability and actual behavior depend on the installed adapter; renderer provenance records the result. |
| Full sampling — slower | Disables Turbo for this clip and uses the non-Turbo schedule at the same selected canvas. This is an A/B-test option, not a promise of better output. |

The node advertises `h3_turbo` support. The app refuses to send an explicit
sampling choice to older nodes that could silently ignore it. Follow the
[node update instructions](../Resources/video-node/README.md#updates-existing-deployments-and-troubleshooting)
to install the bundled adapter. Overrides are per job, not global service changes.
Renderer default is resolved when each clip reaches the node; choose an explicit
setting if a batch must not inherit service-default changes between clips.

For better selection **without increasing peak memory**, render more seeds
serially and choose the best take. Compare sampling with two one-prompt batches
using the same base seed, size and duration, changing only Turbo versus Full.
Fixed seeds do not guarantee identical output across model/runtime versions.
Full sampling often has similar peak memory at the same canvas, but keeps the
GPU busy longer and uses more total energy. CPU encoding/orchestration still
exists; no quality mode promises a CPU-load cap.

Higher H3 **Size** increases the generation canvas and/or export work and may
increase memory as well as time. A 1080p export is not native 1080p generation.
Start with 480p variations and test a selected shot before increasing size for
a whole batch. The standalone LTX adapter currently falls back to 720p delivery
for a 1080p request; use 480p or 720p pending [the separate resolution fix](https://github.com/OGZamasu/silicon-optimizer/issues/21). Do not
arbitrarily increase LTX's distilled step schedule and assume higher quality.

Renderer references: [Phosphene](https://github.com/mrbizarro/phosphene) and
[LTX MLX](https://github.com/dgrauet/ltx-2-mlx). Models and dependencies remain
separate installations; this feature neither downloads weights nor accepts terms.

## Agent and Control API use

The MCP tools **queue_videos** (add prompts and return immediately) and
**video_queue** (inspect/control) expose the same app queue. Example arguments:

```json
{
  "prompts": ["A honey badger sails a boat.", "A honey badger makes pancakes."],
  "title": "Honey badger movie",
  "variations": 3,
  "model_id": "hailuo-h3",
  "seconds": 10,
  "resolution": "480p",
  "seed": 1400,
  "h3_turbo": true
}
```

Authenticated Control API equivalents:

- `POST /video/queue`: use the same fields, but `modelID` instead of `model_id`.
- `GET /video/queue`: durable history and output paths.
- `POST /video/queue/control`: for example `{"action":"pause"}` or
  `{"action":"retry","id":"<queue-item-id>"}`. Actions are `pause`, `resume`,
  `retry`, `remove`, and `clear_finished`. Explicit new-render confirmation is
  `confirmNewRender: true`; the MCP spelling is `confirm_new_render`.

Adding a batch is not a long-running request. After a lost response, inspect
the queue before submitting the same batch again. The synchronous single-clip
`POST /video/generate` remains available. Restart/refresh the MCP client after
installing the updated app to discover its two new tools.

## Verification

Tests cover parsing, seed order/wraparound, whole-batch validation, private
persistence, restart/reconnect, uncertain submissions, retry identity, deadline
placement and manifest retention. Mock HTTP tests run the app queue through two
variations and verify separate output files, receipt-before-poll ordering,
completed jobs older than twelve hours and capability gating for older nodes.
Python HTTP tests verify that per-job Turbo reaches Phosphene, participates in
deduplication and is recorded in provenance.

A separate opt-in smoke test produced two real MiniMax H3 variations from one
prompt, seeds 83000/83001, with distinct Phosphene job IDs. Both passed full
decoding: 3.000 seconds, 854×480, H.264, 24 fps, 72 frames. This confirms the
generation path, not a quality or performance promise. No weights or generated
media are repository fixtures.

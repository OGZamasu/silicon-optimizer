# Video queue, batches and variations

Every generation now uses the same **Video queue**, including **Single clip**
and synchronous chat/API requests. In **Make a clip**, click **Add to queue**:
the clip is saved immediately, the queue opens on the right (below the composer
in a narrow window), and the composer clears for your next prompt. If the queue
is unpaused and a compatible node is ready, the first clip starts automatically.
Keep adding clips while it renders; their progress lives in the queue, not in
the composer. Active work and FIFO waiting clips appear above finished history.
Adding a clip never resumes a manually paused queue.

In **Video**, choose **Batch & variations**. Paste one shot per paragraph, with
a blank line between shots. Select the model, duration and size, choose 1–20
variations per prompt, and click **Queue N clips**. Twenty prompts with three
variations produce sixty clips. Up to 200 unfinished clips may be queued.

Every variation gets a distinct saved 32-bit seed. An optional base seed makes
the sequence predictable: subsequent clips increment it, wrapping after
4,294,967,295. Settings are captured when added; changing the composer does not
change queued jobs. This batch composer is text-only; single clips retain image
input, and the single-clip API retains H3 per-window prompts. A single prompt
stays one clip even if it contains blank lines. Reference images are copied into
the clip's private `inputs/` folder when queued (up to 20 MiB), so subsequent
source-file changes cannot alter a waiting render. Failed enqueue keeps the draft.

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
- **Stop following…** pauses future submissions and interrupts the app's active
  wait/download. It **does not stop the remote GPU render**. Its saved receipt
  remains available through **Reconnect / download**; if interrupted before a
  receipt arrived, check the node before explicitly rendering again. The former
  composer's Cancel button also only interrupted local polling. Use the node's
  own controls to stop GPU work. Safe, capability-gated cancel-by-job-ID is
  [tracked separately](https://github.com/OGZamasu/silicon-optimizer/issues/25);
  the adapter must not call Phosphene's global stop and risk stopping another job.
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
- Removing a never-submitted single clip also discards its unused, queue-owned
  reference-image copy and empty job folders after saving the removal. Original
  images, shared references, prior-attempt inputs and any media remain untouched;
  cleanup never follows symlinks or recursively deletes a folder.
  Failed enqueue also removes only its unused snapshot and empty owned folders,
  preserving unrelated files and the original image.

## Review and edit

Every batch or single clip gets a unique folder under the configured video destination:

```text
~/Movies/Silicon Optimizer/Batches/<timestamp>-<batch-id>/
  scene-001_take-01_seed-1400_<item-id>-a1.mp4
  scene-001_take-02_seed-1401_<item-id>-a1.mp4
  manifest.json
```

Use **Play**, **Show clip** and **Output folder** in the queue. The manifest records
prompts, scene/take order, seeds, settings, node job IDs, status and output paths,
never tokens. Import your chosen MP4s into an editor. This feature makes clips,
not an automatically assembled or character-consistent movie.
Recent clips discovers both flat output files and `Batches/<job>/` media even
after clearing finished history and relaunching. Discovery runs off the UI
thread, skips inputs, deeper folders and symlinks, and shows the newest 60 files.
To keep very large destinations responsive, scans examine at most 50,000 entries
and 2,000 job folders, preferring recently modified folders. Up to 2,000 queue
receipt paths can also supply files from a previous destination, consuming the
same 50,000-entry budget. An entry bound is not a timeout on an individual
filesystem operation on a slow or unavailable volume.

Active and waiting clips stay above a mixed completed/failed history ordered by
finish time. Older receipts without a finish timestamp fall back to creation
time and queue order. Presentation order is cached at queue changes; renderer
progress updates only the progress view, not the history sorting.

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

### Can I denoise more times?

For the current Phosphene H3 non-Turbo tiers, Auto uses **9 sigma points / 8
model forwards per window**. Recent Phosphene versions also expose `h3_steps`
in their own **Steps** controls: Auto or 4–30 sigma points. For example, 20
points means 19 forwards, roughly 2.4× the *denoising work* of 9 points at the
same canvas, not necessarily 2.4× total render time. Turbo pins its distilled
schedule and ignores a step override.

In Silicon Optimizer, choose **Full sampling — slower**, then **Denoising
steps**: Auto, 9, 12, 16, 20 or 30 points. This works for both single clips and
batches. Auto omits the override and uses the non-Turbo tier default. Choosing
Turbo or Renderer default resets the *composer* to Auto, not already queued
clips. Each queue card shows its explicit step count and passes per window.

The updated node advertises `h3_steps` only after checking the **running**
Phosphene `/version`: the supported contract starts at 4.12.2, within the 4.x
release line. Unknown/dev/new-major versions fail closed for explicit steps;
Auto continues to work as before. Phosphene 4.12.2 does not publish a steps
capability in `/status`, so the adapter uses the boot-version contract and
also verifies the completed job's actual `params.steps`, `params.h3_steps`
and Turbo state before publishing an overridden result. It rechecks support
immediately before dispatch in case the panel changed while the clip waited.
No Phosphene source patch, model download or global setting change is required.

The Control and MCP APIs accept optional `h3_steps` integers from **4 through
30**, with explicit `h3_turbo: false`. Omit steps (or use JSON null) for Auto;
0, fractions, strings, booleans, other models and Turbo/default combinations
are rejected. Saved queue requests and manifests use `h3Steps`, matching their
existing camel-case settings. Step counts survive restart, retries and receipt
reconnection, and participate in the node's deduplication identity. An older
node leaves an explicit-steps clip pending instead of dropping its override.
Legacy requests/queue documents without the field retain their old behavior
and node fingerprints.

Renderer sidecars distinguish `requested_h3_steps` from actual `h3_steps` and
`h3_forwards_per_window`. Unknown actual values on legacy jobs remain null,
not guessed from the request. The app's editing manifest records the request;
the node's sidecar is the actual-parameter evidence.

More steps are an experiment, not a guaranteed quality improvement. Compare
the same prompt, seed, duration and size before spending a whole queue's time.
They can keep peak memory similar, but additional schedule/modulation caches
may use more memory. They increase GPU busy time, heat and energy. 30 points
means 29 forwards, about 3.6× the default's denoising work, **not** a prediction
of whole-render duration. See the renderer's [H3 engine notes](https://github.com/mrbizarro/phosphene/blob/main/docs/H3_ENGINE.md)
and [step handling](https://github.com/mrbizarro/phosphene/blob/main/mlx_ltx_panel.py).

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
  "h3_turbo": false,
  "h3_steps": 20
}
```

Authenticated Control API equivalents:

- `POST /video/queue`: use the same fields, but `modelID` instead of `model_id`.
- `GET /video/queue`: durable history and output paths.
- `POST /video/queue/control`: for example `{"action":"pause"}` or
  `{"action":"retry","id":"<queue-item-id>"}`. Actions are `pause`, `resume`,
  `retry`, `remove`, `stop_following`, and `clear_finished`. `stop_following`
  requires the actively followed item ID and never cancels the remote GPU job.
  Explicit new-render confirmation is
  `confirmNewRender: true`; the MCP spelling is `confirm_new_render`.

Adding a batch is not a long-running request. After a lost response, inspect
the queue before submitting the same batch again. The synchronous single-clip
`POST /video/generate` remains available: it now adds one durable clip and waits
for its file, including behind already queued work. It rejects a paused queue
before adding anything; use `/video/queue` to intentionally save work for later.
Pausing during an accepted wait does not fail that caller, including when an
unrelated clip causes a safety pause. The waiter keeps its original deadline;
it does not resume dispatch automatically. A timeout or client disconnect
ends only the wait: the saved clip is **not cancelled**. Check `GET /video/queue`
before resubmitting. Clearing finished history preserves completed response
receipts in memory until their live callers finish, so it cannot turn a
successful render into a missing-history error. Long backlogs should use the
asynchronous queue API rather than holding a synchronous request open. Restart/refresh the MCP client after
installing the updated app to discover its tools.

At most **eight synchronous video requests** may wait at once. Overflow receives
HTTP **429 Too Many Requests** before adding a clip, leaving connection capacity
for health, status and queue controls. Use `POST /video/queue` and poll
`GET /video/queue` for larger submissions; the async queue's 200 unfinished-clip
limit is independent of this eight-waiter limit. Closing the synchronous
connection interrupts its waiter and releases its slot without dropping the
saved job. This single-request-per-connection endpoint does not support HTTP
pipelining or request-side half-close while waiting for the response.

## Verification

Tests cover parsing, seed order/wraparound, whole-batch validation, private
persistence, restart/reconnect, uncertain submissions, retry identity, deadline
placement and manifest retention. Mock HTTP tests run the app queue through two
variations and verify separate output files, receipt-before-poll ordering,
completed jobs older than twelve hours and capability gating for older nodes.
Python HTTP tests verify that per-job Turbo reaches Phosphene, participates in
deduplication and is recorded in provenance. H3 steps tests cover single/batch
wire types and bounds, composer snapshots, persistence and manifests, unsupported
nodes, boot-version gating, rechecking at dispatch, legacy fingerprints, form
forwarding and actual-parameter mismatch refusal. These do not render videos.
Loopback control-server tests hold eight video requests while rejecting 56
overflow requests, exercise authenticated status/queue controls, and verify slot
reuse after success, renderer errors, malformed input and two waves of client
disconnects. App tests cover waiters surviving pauses, result receipts outliving
cleared history, and Stop following/reconnect without a second render submission.
Ordering tests cover mixed finished statuses, retries and legacy receipts. Filesystem regressions
cover recents after clear/relaunch, bounded shallow discovery, and safe reference
cleanup including persistence failures, shared receipts, symlinks and sibling media.

A separate opt-in smoke test produced two real MiniMax H3 variations from one
prompt, seeds 83000/83001, with distinct Phosphene job IDs. Both passed full
decoding: 3.000 seconds, 854×480, H.264, 24 fps, 72 frames. This confirms the
generation path, not a quality or performance promise. No weights or generated
media are repository fixtures.

# Local Apple Silicon video node

This optional, standard-library Python service connects Silicon Optimizer's
Video screen to local MLX renderers. It provides an authenticated swarm peer,
a persistent single-render queue, downloadable MP4s and model/provenance JSON
sidecars. The same source is included in the app bundle under
`Contents/Resources/video-node`.

Supported engines:

| Silicon model ID | Runtime | Durations exposed by the app |
| --- | --- | --- |
| `hailuo-h3` | MiniMax Hailuo H3 through an existing local Phosphene panel | 3, 5, 10, 15 seconds |
| `ltx2-distilled` | Standalone LTX-2.3 distilled Q4 via `ltx-2-mlx` | 3, 5, 8, 10, 15 seconds |

H3 10/15-second generation chains two/three five-second windows. The node
checks the panel's live `h3.available`, `capable`, `chain`, `first_frame`, and
`chain_prompts` capabilities as needed before accepting and dispatching a job.
An unavailable engine is reported as unavailable; model selection is preserved.

## Install and use H3 from a clean checkout

1. Use an Apple Silicon Mac with an arm64 Python 3.9 or newer and `ffmpeg` /
   `ffprobe` on PATH. For example, a Homebrew installation can provide these
   with `brew install python@3.11 ffmpeg`. The rendering engine itself uses
   its separately installed Python environment.
2. Install [Phosphene](https://github.com/mrbizarro/phosphene#manual-install)
   using its supported installer or manual installation instructions. Install
   the MiniMax H3 pack, any required gated components and the optional Turbo
   adapter through Phosphene's supported model setup. Model access and terms
   are handled by the user through the model distributor's normal workflow.
   This installer does not download models, manage accounts, or accept terms.
3. Start the Phosphene panel using its launcher. Its default address is
   `http://127.0.0.1:8198`; its H3 status must report ready before rendering.
   The node installer validates the checkout, while live engine readiness is
   checked by the node. A stopped panel can therefore be paired before it is
   started. Phosphene remains independently installed and started.
4. From the Silicon Optimizer checkout, preview the install, then quit Silicon
   Optimizer and install/start the node:

   ```sh
   python3 Resources/video-node/install.py --phosphene-root "$HOME/phosphene" --dry-run
   python3 Resources/video-node/install.py --phosphene-root "$HOME/phosphene" --start
   ```

   Replace the Phosphene path with your actual checkout. `--dry-run` writes
   nothing and reports missing prerequisites and running app/service conflicts.
   `--help` lists all path and port overrides. Without `--start`, installation
   prints the command to start the service later.
5. Reopen Silicon Optimizer, open **Video**, select **MiniMax Hailuo H3**, choose
   a duration and generate. The normal app video destination receives the
   downloaded result. **Swarm** shows the paired `local-mlx-video` peer.

The installer uses the app's existing `swarm.json` schema (`peers`, `base_url`,
per-peer `token`, optional `swarm_token`). It merges one exact loopback endpoint,
preserves all other peers and unknown fields, reuses a matching credential, and
saves a private backup when changing an existing registry. The app must be
closed because its own pairing/token-management code also writes that file.
There is no supported local peer-write HTTP API to update it atomically while
the app runs. Conflicting names, duplicate endpoints, credential disagreements,
invalid JSON and symlinks are reported without overwriting those files.

Defaults:

| Item | Path/address |
| --- | --- |
| Node | `http://127.0.0.1:8790` |
| Data, script, token | `~/Library/Application Support/SiliconOptimizer/video-node/` |
| Queue | `<data-dir>/state/jobs.json` |
| MP4 and JSON sidecar | `<data-dir>/artifacts/<job-id>/<output-name>` |
| Service logs | `<data-dir>/logs/node.stdout.log`, `node.stderr.log` |
| Per-job logs | `<data-dir>/state/logs/<job-id>.log` |
| Peer registry | `~/Library/Application Support/SiliconOptimizer/swarm.json` |
| LaunchAgent | `~/Library/LaunchAgents/dev.siliconoptimizer.video-node.plist` |

The token is raw text in `<data-dir>/token`, mode `0600`. It is never printed or
embedded in the LaunchAgent. The node binds only to loopback and requires a
Bearer token for node/job/artifact endpoints. `/health` exposes readiness only.
The unauthenticated Phosphene API is also restricted to a loopback HTTP origin;
redirects/proxies are disabled and completed files must resolve under explicitly
trusted Phosphene output folders.

## Output quality, chain prompts and queue behavior

H3 delivery choices map to Phosphene as follows: 480p → Draft/no upscale;
720p → Standard/fit 720p; 1080p → High/fit 1080p. H3 Turbo is enabled by default;
set `PHOSPHENE_H3_TURBO=false` in the node's LaunchAgent environment to request
the non-Turbo path. Actual readiness, memory requirements, model access and
supported tiers are determined by the installed Phosphene/H3 version.

The node converts completed H3 output to a 24 fps H.264 MP4, with AAC when
audio is present, at the requested delivery resolution. It validates dimensions,
codec, frame count and duration before publishing the artifact. Sidecars record
MiniMax H3, Phosphene job ID, quality/length/upscale, Turbo, prompts, seed and
output properties. LTX uses a smaller internal canvas and scales for delivery:
720p is rendered at 768×448, and 480p at 672×384. Delivery resolution does not
promise native generation at that size.

The node API accepts an optional `h3_chain_prompts` JSON array for H3 10/15-second
requests: exactly two/three nonblank prompts, each at most 4,000 characters.
These prompts are persisted and forwarded as separate window conditions. The
regular Video screen uses its single prompt; the optional
[H3 batch example](examples/README.md) demonstrates two prompts per clip, media
verification and a review gallery.

Jobs are persisted before dispatch and retain their IDs across restarts. A
known Phosphene job is polled again; an interrupted submission whose remote ID
was not saved fails clearly so an unknown render is not duplicated. Corrupt
queue JSON is preserved for repair. Repeating an `entry_id` with identical
settings is idempotent, including a generated random seed; conflicting settings
are rejected. Different jobs can reuse a display filename without overwriting
each other's artifact.

Each accepted job has a 12-hour deadline including time in the node queue.
Expired queued jobs fail before dispatch, H3 polling stops at that deadline,
and the LTX child process has a deadline watchdog. ffmpeg and ffprobe calls are
bounded as well. The app's outer request budget includes additional time for
submission and downloading. A timed-out H3 job may still finish inside
Phosphene: the node does not globally stop a shared panel queue. Its remote ID
remains in the saved node state for inspection. Submit a new job only after
checking the panel when the previous submission outcome is uncertain.

## Optional standalone LTX setup

Use the upstream [LTX MLX installation instructions](https://github.com/dgrauet/ltx-2-mlx#installation)
to install the CLI into its own environment, and use the model distributor's
normal download/authentication workflow to obtain complete snapshots of
`dgrauet/ltx-2.3-mlx-q4` and a compatible Gemma 3 12B 4-bit text encoder. Point
the installer at those existing folders:

```sh
python3 Resources/video-node/install.py \
  --ltx-root "$HOME/ltx-2-mlx" \
  --model-dir "$HOME/Models/ltx-2.3-mlx-q4" \
  --gemma-dir "$HOME/Models/gemma-3-12b-it-4bit" \
  --start
```

This expects `<ltx-root>/.venv/bin/ltx-2-mlx`. For another executable path, set
`SILICON_VIDEO_LTX_BIN` in the LaunchAgent environment. Include
`--phosphene-root` too when installing both engines. LTX runs with
`HF_HUB_OFFLINE=1`, so required assets must already be present.

The verified standalone LTX environment used `ltx-pipelines-mlx==0.14.19`,
`mlx==0.31.1`, and `mlx-lm==0.31.1`. At that old LTX tag, packages reference
`readme = "../../README.md"`, which Hatchling 1.32 rejects during builds.
Use a **build-time** `hatchling<1.32` constraint, as documented in Phosphene's
`pip-build-constraints.txt`, when reproducing that tag; there is no need to edit
the dependency's source files. For a current installation, follow the engine's
current version pins and instructions rather than applying those old local
packaging edits. Phosphene manages its own LTX/H3 dependency versions separately
from this standalone LTX process.

## Updates, existing deployments and troubleshooting

Wait for active jobs to finish, quit Silicon Optimizer, then stop the installed
node before rerunning the installer from a newer checkout or app bundle:

```sh
launchctl bootout "gui/$(id -u)/dev.siliconoptimizer.video-node"
```

Reinstall with the same path/port flags and `--start`. It updates the installed
script while retaining the token, persisted jobs, models and existing outputs.
The app bundle can be moved because the installer copies the script into the
data directory. Models and the separately maintained Phosphene checkout are
not copied into the Silicon Optimizer repository or app bundle.

An older HoneyBadger deployment can be reused explicitly after stopping its
old `dev.honeybadger.silicon-video-node` LaunchAgent. Run the new installer with
`--data-dir "$HOME/Library/Application Support/HoneyBadgerVideo"`, the same
Phosphene root/port, and optionally `--review-dir "$HOME/Movies/HoneyBadger Clips"
--legacy-hb-layout`. Existing saved output paths and remote job IDs are retained.
The optional layout flag preserves old `HBnnn` review filenames for future jobs;
new installations use isolated per-job artifact folders. Do not run the two
services against the same queue. Keep the old LaunchAgent unloaded after this
explicit migration.

The standalone node also accepts environment variables
`SILICON_VIDEO_DATA_DIR`, `SILICON_VIDEO_TOKEN_FILE`, `SILICON_SWARM_CONFIG`,
`SILICON_VIDEO_LTX_ROOT`, `SILICON_VIDEO_LTX_BIN`, `SILICON_VIDEO_MODEL_DIR`,
`SILICON_VIDEO_GEMMA_DIR`, `SILICON_VIDEO_REVIEW_DIR`, `PHOSPHENE_PANEL_URL`,
`PHOSPHENE_OUTPUT_ROOTS` (colon-separated absolute folders), and
`PHOSPHENE_H3_TURBO`. These must be in the LaunchAgent's `EnvironmentVariables`
when launched by macOS; shell exports do not configure an existing agent.
For a legacy launch without a token file, the node reads only the registry entry
whose loopback origin and port match this service, using that peer's credential
or its shared swarm token fallback. It never selects an unrelated peer token.

If H3 is missing from Video, inspect `/health`, the node's logs and the panel's
H3 readiness; verify the exact peer endpoint and restart the app after registry
changes. If the installer reports an occupied port or live node, finish its work
and stop that service deliberately, or use another port/data directory. The
installer never terminates other processes automatically.

## Tests

```sh
python3 -m unittest discover -s Resources/video-node -v
```

Tests use temporary directories and mocked hardware/processes. The HTTP
integration test starts loopback-only node and fake Phosphene servers and checks
authenticated submit/status/download, chain prompts, idempotency and provenance;
its media bytes and ffmpeg/probe results are synthetic. No tests download weights,
contact an external service, use a GPU or change a real LaunchAgent/registry.

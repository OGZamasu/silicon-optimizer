# Silicon Node for Windows — build plan and handoff prompt

**Hand this whole document to Claude on the Windows machine.** It is written to be executed
there. Everything in §2 is a wire contract already implemented and shipped on the Mac side —
do not redesign it; build to it. Everything in §5 is direction, not yet contract: propose, then
align before freezing.

---

## 0. Mission

The Mac runs **Silicon Optimizer**: a native app that plans memory before running local AI
(LLMs via llama.cpp/MLX, images via MFLUX, 3D via TRELLIS.2/Hunyuan3D), exposes everything
over a local control API, and ships an MCP server (`silicon-mcp`) so Claude and ChatGPT can
drive it. Repo: `github.com/OGZamasu/silicon-optimizer`.

You are building its **Windows/CUDA counterpart** — working name **Silicon Node**. Three
jobs, in order:

1. **Serve LATO.2** (CUDA-only image→clean-low-poly-mesh) to the Mac app, which already
   ships a client for it.
2. **Generalize into a CUDA job service**: anything this machine can run that the Mac
   cannot, behind one capability-listing, job-queueing API.
3. **Join a swarm**: multiple Silicon nodes (this Windows box, the Mac, future machines)
   advertising resources and delegating work to whichever peer fits it best — and each node
   drivable as a subagent by Claude via MCP.

The user's setup today: one MacBook Pro (M3 Max, 36 GB) and one Windows desktop with an
NVIDIA GPU. Design for N heterogeneous nodes, not this pair.

## 1. Read these first (they exist on the Windows side or came from the Mac)

- **`LATO2-SETUP-PLAN.md`** — the earlier handoff for installing LATO.2 itself under WSL2
  (Route A: TRELLIS densify → LATO.2 retopology). Its §1 "verified findings" still stand:
  CUDA-only, WSL2 + conda, `ATTN_BACKEND=xformers` fallback, weights ~3.5 GB from HF
  `0x4c48/LATO.2`, smoke test via `scripts/e2e_inference.py`. If LATO.2 is not yet installed
  and smoke-tested, that document is Phase 0 — finish it before anything here.
- This document's §2, which supersedes LATO2-SETUP-PLAN §4's sketch: the API below is no
  longer a proposal, it is what the Mac client sends and parses **today**.

## 2. Phase 1 — the LATO.2 service (the Mac client already exists; build to this contract)

The Mac app's client (`Sources/SiliconRuntime/MeshBackends.swift`, `Lato2Runtime`) behaves
exactly as follows. Where the client is liberal, you may choose any shape it accepts; where
it is strict, you must match.

### 2.1 Endpoints

| Endpoint | Contract |
|---|---|
| `GET /health` | Any 2xx = reachable. Used as a 4-second-timeout probe. |
| `POST /v1/image-to-mesh` | `multipart/form-data` with fields: `image` (file, arbitrary filename, octet-stream), `vert_num` (string int, 200–5000), `seed` (string int, optional). Reply 2xx + JSON containing `job_id` (string) — the key `id` is also accepted. Non-2xx bodies are shown to the user (first 300 bytes), so make errors human. |
| `GET /v1/jobs/{job_id}` | JSON. `status`: the client treats `done / completed / complete / succeeded / finished` as success, `failed / error` as failure (message read from `error`), anything else as still running. `progress`: optional number 0–1. **Result files: the client recursively collects every string anywhere in the JSON that parses as a URL ending `.glb` or `.obj`** (relative URLs are resolved against the service base). Recommended shape: `{"status":"done","progress":1.0,"result_urls":["/v1/files/abc.glb","/v1/files/abc.obj"]}`. |
| `GET /v1/files/{name}` | The bytes. The client downloads and renames locally, so server-side names only need to be stable and unguessable-ish. |

Client cadence: poll every 3 s, give up after 30 min, download `.glb`/`.obj` only. Return
**both** the dense TRELLIS mesh and the LATO.2 retopologized mesh when you have both — the
client keeps whatever arrives; the OBJ slot is the low-poly product.

### 2.2 Operational requirements

- **Serialize GPU work** — one job at a time behind a queue (the Mac's TRELLIS MCP service
  uses a `threading.Semaphore(1)`; same idea). Queued jobs report `status: "running"` with
  no progress rather than erroring.
- **Survive the request** — jobs run in a worker, never in the HTTP handler. A render can
  take minutes; the 300-second HTTP timeout death of the first TRELLIS attempts is the
  lesson here.
- **Auth**: the current Mac client sends no auth header. Bind to the LAN and treat the URL
  as the secret for the first milestone, but *also* accept an optional
  `Authorization: Bearer <token>` (ignore when unset) so both ends can turn auth on
  together later without a breaking change. Never expose this through a public tunnel
  without the token enabled.
- The user pastes the base URL (e.g. `http://192.168.x.x:8790`) into the Mac app under
  **Settings → 3D toolkit → LATO.2 service URL**. Suggested port: 8790.

### 2.3 Acceptance (Phase 1 done when)

1. `curl <base>/health` from the Mac returns 2xx.
2. On the Mac app, model **LATO.2 (remote)** in the 3D tab goes from "Set the service URL"
   to ready, and a generation round-trips: image up, clean OBJ + dense GLB back, visible in
   the app's 3D viewer.
3. From Claude on the Mac: `generate_3d` with `model_id: "lato-2"` succeeds end-to-end.
4. Two overlapping submissions queue; neither OOMs the GPU.

## 3. Phase 2 — from one model to a CUDA job service

Same jobs pattern, more capabilities. Add:

- `GET /v1/capabilities` → array of
  `{"id", "name", "kind": "mesh|image|video|llm|retopo", "peak_vram_gb", "typical_seconds",
  "ready": bool, "detail"}`. This is the vocabulary the swarm (§5) will route on, so keep
  ids stable.
- One generic submit: `POST /v1/jobs {"capability": id, params…}` alongside the Phase-1
  endpoint (which stays, as sugar, forever — the Mac client depends on it).
- Candidate capabilities for this box, in value order: `image-to-mesh` (Phase 1),
  `retopologize` (LATO.2 without the TRELLIS stage — mesh in, clean mesh out),
  big-VRAM image generation (SDXL/FLUX at full precision), and anything else CUDA-locked
  that the user asks for. Measure peak VRAM per capability before advertising it; the whole
  Silicon philosophy is *measured numbers, stated before the run*.

## 4. Phase 3 — the node becomes a subagent

- **Implement an MCP server** exposing the node's capabilities as tools, mirroring the
  Mac's tool style (`list_3d_models`, `plan_3d`, `generate_3d`, `get_status`…). The Mac's
  `silicon-mcp` speaks stdio to a local control HTTP API; the same split is right here —
  MCP shim in front, service behind. This makes the Windows node directly drivable from
  Claude Code / Claude Desktop / ChatGPT on *any* machine that can reach it.
- Keep the MCP layer a thin adapter over the HTTP API from §2–3. One implementation of the
  actual work, two doors into it.

## 5. Phase 4 — the swarm (design direction; align before freezing)

The goal: N Silicon nodes that see each other's resources and hand work to whoever fits it.
The Mac app already has the vocabulary the swarm needs — its control API serves `profile`
(chip, memory, bandwidth), `metrics` (live memory/GPU), `status` (loaded model), and
planners that return verdicts before work runs. The swarm generalizes this from
localhost-only to peer-visible:

- **Peer registry**: static first — each node has a config listing peer base URLs + shared
  bearer token. mDNS/Bonjour discovery later; never instead.
- **Advertisement**: `GET /v1/node` → `{name, platform, profile, capabilities, metrics}` —
  the union of what both apps already know about themselves.
- **Delegation**: when a node's own planner says a job doesn't fit (the Mac's verdicts:
  `willSwap`/`impossible`), it lists peers, filters by capability + advertised headroom,
  and submits over the same jobs API a human would use. No new protocol — the swarm *is*
  the jobs API plus the registry.
- **Both directions matter**: Windows borrows the Mac for MLX-native work (Hunyuan3D shape,
  MLX image gen) and small-LLM prompts; the Mac borrows Windows for CUDA-only and
  big-VRAM work. The Mac side will need its control server to optionally bind beyond
  localhost with the shared token — that change lands in the Mac repo, not yours; flag it
  when you get here.
- **Trust model**: one shared secret per swarm, TLS or WireGuard/Tailscale between homes if
  the swarm ever leaves the LAN. Jobs execute code paths, so an unauthenticated node is an
  unauthenticated remote-execution service — do not ship Phase 4 without the token made
  mandatory for non-localhost binds.
- **Other configurations**: nothing above assumes two nodes or these two platforms. A
  second Mac, a Linux CUDA box, or a rented GPU node joins by implementing `/v1/node`,
  `/v1/capabilities`, and the jobs API.

## 6. Practical notes for the Windows build

- WSL2 Ubuntu 22.04 for the CUDA/Python side (LATO.2 setup plan explains why); the service
  itself can live in WSL and bind to `0.0.0.0` so the LAN sees it — mind Windows firewall
  and WSL port forwarding (`netsh interface portproxy` or WSL2 mirrored networking).
- Keep the models resident between jobs (LATO.2 + DINOv2 reload is the expensive part);
  restart the worker on CUDA OOM rather than trying to recover in-process.
- Log every job: request params, timings per stage, peak VRAM (`torch.cuda.max_memory_allocated`),
  and the exact artifact paths. The Mac side's culture is receipts; match it.
- Report progress honestly: LATO.2's own stages (TRELLIS sample → mesh preprocess →
  retopology → export) map cleanly onto `progress` fractions.
- Version the API from day one (`/v1/`), and return a `server` field from `/health`
  (name + version) so the Mac can display what it is talking to.

## 7. What to send back to the Mac side when done

1. The service base URL (goes into Settings → 3D toolkit).
2. The capability list with measured VRAM/timing numbers.
3. Anything in §2 the implementation had to deviate from, so the Mac client and this
   contract get updated together rather than drifting.

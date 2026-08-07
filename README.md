# Silicon Optimizer

[optimize.zamasu.dev](https://optimize.zamasu.dev)

A native macOS menu bar app that makes running local LLMs on Apple Silicon effortless — and
exposes the whole thing to Claude and ChatGPT over MCP.

No Terminal. No flags. No guessing whether a model will fit.

```
Apple M3 Max · 38.7 GB unified memory · 300 GB/s
→ Qwen3-Coder 30B A3B, Q4_K_M, 16K context
  20.3 GB of a 27.2 GB budget · ≈89 tok/s
```

---

## What it does

**Reads your actual hardware.** Chip generation and variant, performance/efficiency core split,
GPU core count, Neural Engine, memory bandwidth, disk headroom — all probed from `sysctl` and the
IORegistry, no elevated privileges.

**Predicts memory before you download anything.** Weights, expert pool, KV cache and compute
buffers are each estimated from the model's real architecture, not a rule of thumb. If it will not
fit, you get a ranked list of things to change with the exact saving of each.

**Picks the model for you.** One button. The highest-quality model your machine can actually run
at a context length that is useful, with an estimated tokens/sec you can trust.

**Measures itself.** A one-click benchmark reports generation speed, prompt throughput,
first-token latency and long-context falloff as a scorecard, then feeds the result back as a
correction for that model, so later estimates are grounded in measurement rather than in a
published bandwidth figure. Corrections are per model — architectures differ enough that a single
global factor makes other predictions worse.

**Streams MoE experts from disk.** Full support for llama.cpp's on-demand expert paging, including
the slot-pool sizing and the micro-batch constraint it imposes. This is what lets a 117B model run
on a 36 GB Mac.

**Talks to Claude and ChatGPT.** A bundled MCP server exposes the hardware profile, the planner,
the catalog and the loaded model as tools. See [MCP setup](#use-from-claude-or-chatgpt).

---

## Install

Requires macOS 14 or later on Apple Silicon.

```bash
git clone https://github.com/OGZamasu/silicon-optimizer
cd silicon-optimizer
Scripts/build-app.sh --release
cp -R "build/Silicon Optimizer.app" /Applications/
```

You also need a runtime. Either is fine; llama.cpp is recommended because it is the only one that
can page experts from disk:

```bash
brew install llama.cpp        # llama.cpp
pip install mlx-lm            # MLX
```

The app finds them automatically. Settings shows what it found and whether the build supports
expert streaming.

---

## Use from Claude or ChatGPT

The app publishes a loopback control API when it launches. `silicon-mcp` bridges that to MCP, so
an assistant drives **the model you already have loaded** instead of starting a second copy and
doubling the memory bill.

Build and install the bridge:

```bash
Scripts/install-mcp.sh
```

That prints the exact config block for your client. Or wire it up manually:

**Claude Desktop** — `~/Library/Application Support/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "silicon-optimizer": {
      "command": "/usr/local/bin/silicon-mcp"
    }
  }
}
```

**Claude Code**

```bash
claude mcp add silicon-optimizer /usr/local/bin/silicon-mcp
```

**ChatGPT** — Settings → Connectors → Advanced → Developer mode, then add a local MCP server
pointing at `/usr/local/bin/silicon-mcp`.

### Tools it exposes

| Tool | What it answers |
|---|---|
| `get_hardware_profile` | What is this Mac, and what can it hold? |
| `get_system_metrics` | Memory, swap, GPU and CPU right now |
| `recommend_model` | What should I run? |
| `list_models` | What is available, and what fits? |
| `plan_memory` | Will X fit at Y context? What would I change? |
| `install_model` | Download it |
| `load_model` / `unload_model` | Load it into memory, or free it |
| `chat` | Ask the local model — text or images, nothing leaves the machine |
| `run_benchmark` | Measure this model here, and recalibrate its estimates |
| `get_status` | What is loaded, at what settings, how fast |

Once connected you can ask things like:

> *What's the best coding model my Mac can run, and how fast will it be?*
>
> *Would gpt-oss-120b fit if I stream experts from disk?*
>
> *Load Qwen3-Coder and ask it to review this function — keep it local.*
>
> *Show the local vision model this screenshot and tell me what it reads.*

The `chat` tool is the interesting one: it lets a cloud assistant hand private work to a model
running entirely on your machine, then reason about the answer.

---

## How the memory planner works

Most tools guess model memory as `file size + a bit`. That is wrong in ways that matter, so this
computes each component from the architecture.

**Weights** — parameter count times the *effective* bit rate. Using the nominal width (4 bits for
Q4_K_M) underestimates real files by about 20%, because k-quants carry per-block scales.

**KV cache** — `2 × layers × kv_heads × head_dim × context × bytes_per_element`. Note `head_dim`
is read from the model rather than derived: Qwen3 keeps a 128-wide head on a 2048-wide residual
stream, and gpt-oss uses 64 on 2880. Deriving it as `d_model / n_heads` puts those families off by
a factor of two.

**Compute buffers** — scales with micro-batch and hidden size. Without Flash Attention the
attention score matrix (`ubatch × context × heads`, fp32) is materialised, which on a 32K context
is over 2 GB on its own. That is why the planner treats Flash Attention as close to mandatory.

**Expert pool** — see below.

The budget is a fraction of unified memory that scales with machine size (55% on 8 GB, 85% on
128 GB+), reduced only by other processes' **wired** memory. Ordinary app memory is compressible
and evictable — macOS pages it out to make room for the model — so charging the planner for it
would make any machine with a browser open look unable to run anything.

### Measured accuracy

Checked against llama.cpp b10280 on an M3 Max, against its own buffer accounting and against
`footprint(1)`.

**Qwen3-1.7B Q4_K_M, 32K context** — dense:

| Component | Predicted | Actual | Error |
|---|---|---|---|
| KV cache | 3.76 GB | 3584 MiB | **0.05%** |
| Weights | 1.04 GB | 1.107 GB | −5.8% |
| Compute buffers | 201 MB | 118 MiB | +62% (over-reserves) |
| **Total** | **5.0 GB** | **4.99 GB** | **0.3%** |

**Qwen3-Coder 30B-A3B Q4_K_M, 16K context** — mixture-of-experts, the case the expert model
exists for:

| Component | Predicted | Actual | Error |
|---|---|---|---|
| Non-expert weights | 924 MB | — | |
| Routed experts | 17.6 GB | — | |
| Weights total | 18.50 GB | 18.56 GB (file) | −0.3% |
| KV + compute | 1.81 GB | 1.68 GB | +7.7% |
| **Total resident** | **20.30 GB** | **20.24 GB** | **0.31%** |

**Throughput**, measured on the same M3 Max:

| Model | Predicted | Measured |
|---|---|---|
| Qwen3-Coder 30B-A3B — generation | 89 tok/s | **89 tok/s** |
| Qwen3-Coder 30B-A3B — prompt | 896 tok/s | 895 tok/s |
| Qwen3-1.7B — prompt | 2344 tok/s | 2374 tok/s |
| Qwen2.5-VL 7B — generation | 39 tok/s | 57 tok/s |

Prompt throughput uses separate efficiency constants for dense and mixture-of-experts models,
because MoE routing turns one large GEMM per layer into a gather plus many smaller per-expert
matmuls that never reach the same utilization. Generation is within 10% for the models above
except the dense 7B, which the benchmark's per-model calibration corrects.

KV figures are exact because they are pure arithmetic. Compute buffers are deliberately
over-reserved — predicting *more* memory than is used is the safe direction.

---

## MoE expert streaming

Based on [ggml-org/llama.cpp#23324](https://github.com/ggml-org/llama.cpp/discussions/23324).
Instead of keeping all experts resident, a fixed pool of slots lives in Metal shared memory, a CPU
sidecar resolves the router's choices to slots with an LRU policy, and misses are `pread` from the
GGUF. **Inference stays numerically exact** — only residency changes.

One slot holds one expert across every MoE layer, so its cost is:

```
3 × d_model × d_expert_ffn × n_moe_layers × bits_per_weight / 8
```

For Qwen3-30B-A3B at Q6_K that is `3 × 2048 × 768 × 48 × 6.56/8` = **0.173 GiB per slot**, which
reproduces the RFC's measured table to three significant figures:

| Slots | Measured wired | Planner predicts |
|---|---|---|
| 32 | 10.6 GiB | 10.6 GiB |
| 64 | 16.1 GiB | 16.1 GiB |
| 80 | 18.9 GiB | 18.9 GiB |

The catch the app makes sure you see: the pool must hold every expert the in-flight batch could
select, so `ubatch × n_expert_used ≤ n_slots`. A 32-slot pool on an 8-expert model forces a
micro-batch of 4, and prompt processing slows sharply. Generation is barely affected. The UI states
this before you turn it on.

Expert streaming needs a llama.cpp build carrying the patch. The app detects this by probing
`--help` for `--moe-n-slots` and disables the option if it is absent, rather than letting the
runtime fail at launch.

---

## Architecture

```
SiliconCore       Value types: Bytes, Quantization, ModelShape
SiliconHardware   sysctl/IOKit probes, live metrics, SSD benchmark
SiliconCatalog    Curated models, GGUF header parser, HF client, downloader
SiliconPlanner    Memory planner, speed estimator, auto-configurator
SiliconRuntime    Runtime abstraction, llama.cpp + MLX process supervision
SiliconControl    Loopback control API (server + client)
SiliconUI         SwiftUI app
SiliconMCP        MCP bridge binary
```

Runtimes are driven as child processes over their OpenAI-compatible HTTP API rather than linked as
libraries. That keeps the app pure Swift, isolates a crash during a 30 GB load from the UI, and
lets you point at your own llama.cpp build — including a patched one — without recompiling
anything.

Adding a runtime means writing one type conforming to `InferenceRuntime`. Nothing in the UI
changes.

---

## Beyond the catalog

The bundled list is 17 models chosen for Apple Silicon. Searching also queries Hugging Face for
anything else with GGUF weights, and picking a result does not mean losing the memory plan: the
GGUF header is fetched with a range request — a few hundred kilobytes, no download — so an
unknown repository gets the same weights/KV/compute breakdown, the same verdict, and its real
architecture read from the file rather than guessed from its name.

Reading a 30B model's full architecture this way takes under two seconds.

## Advanced mode

Every setting the planner derives can be overridden by hand, from the installed model's menu.
Context length, KV cache precision, batch and micro-batch, GPU layers, threads, expert slot
count, and a free-text field for any llama.cpp flag this app does not model yet.

The point is that nothing becomes guesswork when you take over: the same memory plan updates
live as you change things, the launch command is shown verbatim, and constraints the runtime
enforces — the `ubatch x n_expert_used <= n_slots` rule, a micro-batch larger than the batch,
a flag the app already sets — are reported before the load rather than after it fails.

## Development

```bash
swift build           # build everything
swift test            # run the suite
Scripts/build-app.sh  # assemble Silicon Optimizer.app
```

The test suite validates the planner against the RFC's published benchmark numbers, so a
regression in the memory model fails the build rather than silently shipping bad advice.

---

## Security

The control API binds to `127.0.0.1` only and requires a bearer token, regenerated each launch and
published to `~/Library/Application Support/SiliconOptimizer/control.json` with `0600`
permissions. Any local process could otherwise drive your model silently.

The app is not sandboxed: it launches runtime binaries the user may keep anywhere and reads model
files from arbitrary paths. Neither is possible under App Sandbox.

---

## Licence

MIT.

Models carry their own licences — the app shows each one and links to its source. Gemma is under
the Gemma Terms of Use, Llama under the Llama Community Licence; the rest of the shipped catalog
is Apache-2.0 or MIT.

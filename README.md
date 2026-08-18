# Silicon Optimizer

[optimize.zamasu.dev](https://optimize.zamasu.dev)

A free Mac app that runs AI on your own computer. Chat models, coding models, image
generators — all running directly on your Mac, with nothing sent to the cloud. No
subscription, no API key, and your conversations never leave your machine.

The hard part of local AI was never pressing "run". It's knowing what your Mac can actually
handle. Models come in hundreds of sizes, and picking wrong means either a 20 GB download
that chokes your machine, or playing it so safe you run something far weaker than your Mac
could manage. This app does that math for you, before you download anything:

```
Apple M3 Max · 38.7 GB unified memory · 300 GB/s
→ Qwen3-Coder 30B A3B, Q4_K_M, 16K context
  20.3 GB of a 27.2 GB budget · ≈89 tok/s
```

That's the app reading one Mac's hardware, picking the strongest coding model it can hold,
and predicting the speed. The predictions are measured, not vibes — usually within a few
percent of what you actually get (the receipts are [further down](#the-math-for-the-curious)).

---

## What it does

### Tells you what fits — before you download

The app reads your Mac's real specs (chip, memory, GPU cores, disk speed) and calculates
exactly how much memory a model needs. If something won't fit, it lists what to change and
how much each change saves, instead of letting you find out the hard way.

### Picks a model for you

One button. It ranks everything it knows against your machine and picks the best model you
can actually run at a useful speed. You can always override it and choose your own.

### Chats like a real assistant, not just a text box

The Chat tab runs [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness), an
open-source agent framework, on top of your local model. A harness is the wrapper that turns
a bare model into something useful: your chats can fetch web pages, search, read and edit
files in a project folder, and run commands (it asks first). It needs Node.js
(`brew install node`) — the app handles the rest and starts it on demand. Web search needs a
free API key from a search provider, added inside the chat's own settings; fetching pages
works with no key at all. If you just want plain chat, Settings → Chat switches to the
built-in one.

### Runs models that look too big for your Mac

Some large models ("mixture of experts") only use a small slice of themselves for each word
they generate. The app supports llama.cpp's trick of keeping just that slice in memory and
loading the rest from disk as needed — which is how a 117 GB-class model runs on a 36 GB Mac.
The answers stay exactly the same; only where the weights live changes.

### Makes images

FLUX and friends run locally through MFLUX. Image models eat memory in phases (load, encode,
denoise, decode), so the app shows a bar per phase and tells you which one decides whether
your render fits. Usually it's the last one — which is why a render can die at 95% after
minutes of work. The app warns you before you spend those minutes.

### Measures itself and gets smarter

A one-click benchmark measures your real speed — generation, prompt reading, time to first
word — and feeds the result back in, so the next prediction for that model is based on your
machine, not a spec sheet.

### Lets Claude and ChatGPT use your local model

The app ships a small [MCP](https://modelcontextprotocol.io) server. Connect it and a cloud
assistant can check your hardware, pick and download a model, load it, and hand private work
to the model running on your desk. [Setup below](#use-from-claude-or-chatgpt).

---

## Get started

You need a Mac with Apple Silicon (M1 or newer) and macOS 14+.

```bash
brew tap OGZamasu/tap
brew install --cask silicon-optimizer
```

Or build it yourself:

```bash
git clone https://github.com/OGZamasu/silicon-optimizer
cd silicon-optimizer
Scripts/build-app.sh --release
cp -R "build/Silicon Optimizer.app" /Applications/
```

After that the app keeps itself updated. Updates are signed and checked, so a tampered one
gets refused.

You also need an engine — the thing that actually runs the model's math. The app is the
planner and dashboard; either of these does the heavy lifting:

```bash
brew install llama.cpp        # recommended — it's the one that can stream experts from disk
pip install mlx-lm            # Apple's MLX, a fine alternative
```

The app finds them on its own. Settings shows what it found.

---

## Use from Claude or ChatGPT

The bundled `silicon-mcp` bridge lets a cloud assistant drive the model you already have
loaded, instead of starting a second copy and doubling the memory cost.

```bash
Scripts/install-mcp.sh
```

That prints the exact config for your client. Or set it up by hand:

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

### What the assistant can do with it

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
| `list_image_models` | Which image models exist here, and what each would peak at |
| `plan_image` | Phase-by-phase memory for a given size, steps and precision |
| `generate_image` | Draw it locally, with a warning first if it looks too big |
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

The `chat` tool is the fun one: a cloud assistant can hand private work to a model running
entirely on your machine, then reason about the answer.

---

## The math, for the curious

Everything below is how the predictions work under the hood. You don't need any of it to use
the app — it's here so you can check the work.

Most tools guess a model's memory as "file size plus a bit". That's wrong in ways that
matter, so this app computes each piece from the model's actual architecture:

**Weights** — the parameter count times the *effective* bits per parameter. Compressed
("quantized") models carry bookkeeping data alongside the weights; ignoring it
underestimates real files by about 20%.

**KV cache** — the model's working memory of your conversation. It grows with context
length: `2 × layers × kv_heads × head_dim × context × bytes_per_element`. One subtlety: the
head width is read from the model file rather than derived, because some model families
(Qwen3, gpt-oss) break the usual rule of thumb and would come out wrong by 2×.

**Compute buffers** — scratch space for the math itself. Without Flash Attention this blows
up quadratically (over 2 GB at a 32K context), which is why the planner treats Flash
Attention as basically mandatory.

**The budget** — a slice of your unified memory that scales with machine size (55% on 8 GB
up to 85% on 128 GB+), reduced only by other apps' *wired* memory — the kind macOS can't
page out. Ordinary app memory gets evicted to make room for the model, so counting it would
make any Mac with a browser open look unable to run anything.

### Receipts

Checked against llama.cpp's own accounting on an M3 Max.

**Qwen3-1.7B Q4_K_M, 32K context** — a dense model:

| Component | Predicted | Actual | Error |
|---|---|---|---|
| KV cache | 3.76 GB | 3584 MiB | **0.05%** |
| Weights | 1.04 GB | 1.107 GB | −5.8% |
| Compute buffers | 201 MB | 118 MiB | +62% (over-reserves) |
| **Total** | **5.0 GB** | **4.99 GB** | **0.3%** |

**Qwen3-Coder 30B-A3B Q4_K_M, 16K context** — mixture-of-experts, the case the expert
model exists for:

| Component | Predicted | Actual | Error |
|---|---|---|---|
| Weights total | 18.50 GB | 18.56 GB (file) | −0.3% |
| KV + compute | 1.81 GB | 1.68 GB | +7.7% |
| **Total resident** | **20.30 GB** | **20.24 GB** | **0.31%** |

**Speed**, same machine:

| Model | Predicted | Measured |
|---|---|---|
| Qwen3-Coder 30B-A3B — generation | 89 tok/s | **89 tok/s** |
| Qwen3-Coder 30B-A3B — prompt | 896 tok/s | 895 tok/s |
| Qwen3-1.7B — prompt | 2344 tok/s | 2374 tok/s |
| Qwen2.5-VL 7B — generation | 39 tok/s | 57 tok/s |

The dense 7B misses by a lot, which is exactly what the benchmark's per-model calibration
exists to fix — one run and its future estimates are corrected.

**Image models**, two models on two different machines, mflux 0.18.1 at 4-bit:

| Model | Resolution | Predicted | Measured | Error |
|---|---|---|---|---|
| klein-4B | 512×512 | 11.1 GB | 10.52 GB | +6.0% |
| klein-4B | 768×768 | 14.4 GB | 13.53 GB | +6.1% |
| klein-4B | 1024×1024 | 18.9 GB | 17.94 GB | +5.1% |
| klein-9B | 512×512 | 21.4 GB | 20.93 GB | +2.3% |
| klein-9B | 768×768 | 24.6 GB | 23.94 GB | +2.8% |

The error is kept deliberately on the high side, capped at 10%: warning slightly early is a
much better failure than promising a fit and running your machine out of memory.

Two of the image-model numbers are measured rather than derived, because measurement
disagreed with theory. The final decode step costs about 9.8 GB per megapixel — twenty times
what counting feature maps suggests — and it, not the model size, is what usually decides
whether a render fits. And a running transformer parameter costs two bytes regardless of the
precision you asked for; both test models agree on that within 3%. Why is not established.
The number is.

An earlier version of the planner was checked at only one resolution — and was quietly wrong
at every other one, with two errors cancelling exactly there. [A contributor with different
hardware](https://github.com/OGZamasu/silicon-optimizer/issues/3) caught it. Fits are now
checked across the whole table above.

### Expert streaming, in short

Based on [ggml-org/llama.cpp#23324](https://github.com/ggml-org/llama.cpp/discussions/23324).
Mixture-of-experts models route each token through a few "experts" out of many. Instead of
keeping all of them in memory, a fixed pool of slots lives in GPU-shared memory and experts
are read from disk when the router asks for one that isn't resident. The output is
numerically identical — only residency changes.

One slot costs `3 × d_model × d_expert_ffn × n_moe_layers × bits_per_weight / 8`. For
Qwen3-30B-A3B at Q6_K that's 0.173 GiB per slot, which reproduces the llama.cpp discussion's
measured numbers to three significant figures:

| Slots | Measured wired | Planner predicts |
|---|---|---|
| 32 | 10.6 GiB | 10.6 GiB |
| 64 | 16.1 GiB | 16.1 GiB |
| 80 | 18.9 GiB | 18.9 GiB |

The catch — which the app tells you about before you enable it — is that a small pool forces
prompt processing to slow down sharply on some models. Generation speed is barely affected.

The app checks whether your llama.cpp build actually supports this (by probing for the
flag) and hides the option if it doesn't, instead of letting the load fail.

---

## Beyond the built-in catalog

The bundled list is 17 models curated for Apple Silicon. Search also covers all of Hugging
Face: for any model with GGUF weights, the app fetches just the file's header (a few hundred
kilobytes, not the download) and gives an unknown model the same memory breakdown and
verdict as a curated one — its real architecture read from the file, not guessed from its
name.

## Advanced mode

Everything the planner decides, you can override: context length, cache precision, batch
sizes, GPU layers, threads, expert slots, plus a free-text field for any llama.cpp flag the
app doesn't model yet. The memory plan updates live as you change things, the exact launch
command is shown, and impossible combinations are flagged before the load instead of after
it fails.

## Development

```bash
swift build           # build everything
swift test            # run the suite
Scripts/build-app.sh  # assemble Silicon Optimizer.app
```

The tests pin the planner to published benchmark numbers, so a regression in the memory
model fails the build rather than silently shipping bad advice.

## Security

The app's local control API binds to `127.0.0.1` only and requires a token that's
regenerated on every launch — otherwise any process on your machine could quietly drive your
model. The app is not sandboxed, because it launches engine binaries you may keep anywhere
and reads model files from arbitrary paths; neither works under App Sandbox.

## Licence

MIT.

Models carry their own licences — the app shows each one and links to its source. Gemma is
under the Gemma Terms of Use, Llama under the Llama Community Licence; the rest of the
shipped catalog is Apache-2.0 or MIT.

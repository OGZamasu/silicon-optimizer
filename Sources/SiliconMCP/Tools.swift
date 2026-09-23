import Foundation
import Darwin
import ImageIO
import SiliconControl

/// The tools exposed to Claude and ChatGPT.
///
/// Descriptions are written for a model to read, not a developer: they say when to reach for the
/// tool and what the numbers mean, because that is what determines whether a model uses them
/// correctly.
enum Tools {

    struct Tool: Sendable {
        var name: String
        var description: String
        var properties: [String: JSONValue]
        var required: [String]

        var descriptor: JSONValue {
            .object([
                "name": .string(name),
                "description": .string(description),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object(properties),
                    "required": .array(required.map(JSONValue.string)),
                ]),
            ])
        }
    }

    static func property(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    static let h3StepsProperty: JSONValue = .object([
        "type": .string("integer"), "minimum": .number(4), "maximum": .number(30),
        "description": .string("H3 only, requires advertised h3_steps support and h3_turbo=false. Sigma points per window: 20 means 19 denoising passes. Omit for Auto. More steps take longer at the same canvas; quality improvement and identical memory use are not guaranteed."),
    ])

    static func videoSamplingArguments(_ arguments: [String: JSONValue]) throws -> (turbo: Bool?, steps: Int?) {
        if arguments["h3_turbo"] != nil && arguments["h3_turbo"]?.boolValue == nil {
            throw ToolError.invalid("h3_turbo must be a boolean.")
        }
        let turbo = arguments["h3_turbo"]?.boolValue
        guard let value = arguments["h3_steps"], value != .null else { return (turbo, nil) }
        guard case .number(let raw) = value, raw.isFinite, raw.rounded() == raw,
              raw >= 4, raw <= 30 else {
            throw ToolError.invalid("h3_steps must be an integer from 4 through 30. Omit it for Auto.")
        }
        guard turbo == false else { throw ToolError.invalid("h3_steps requires h3_turbo=false.") }
        return (turbo, Int(raw))
    }

    static func videoSeedArgument(_ arguments: [String: JSONValue]) throws -> UInt32? {
        guard let value = arguments["seed"] else { return nil }
        guard case .number(let raw) = value, raw.isFinite, raw.rounded() == raw,
              raw >= 0, raw <= Double(UInt32.max) else {
            throw ToolError.invalid("seed must be an integer from 0 through 4294967295.")
        }
        return UInt32(raw)
    }

    static func describeQueue(_ queue: ControlAPI.VideoQueueView) -> String {
        let pending = queue.items.filter { ["pending", "submitting", "rendering"].contains($0.status) }.count
        let failed = queue.items.filter { $0.status == "failed" }.count
        let cancelled = queue.items.filter { $0.status == "cancelled" }.count
        var lines = ["Video queue: \(queue.paused ? "paused" : "running"), \(pending) queued/running, \(failed) failed, "
            + (cancelled > 0 ? "\(cancelled) cancelled, " : "") + "\(queue.items.count) total."]
        if let message = queue.message { lines.append(message) }
        let visible = queue.items.filter { $0.status != "completed" } + queue.items.filter { $0.status == "completed" }.reversed()
        for item in visible.prefix(100) {
            lines.append("\(item.id): \(item.title), scene \(item.scene), variation \(item.variation), seed \(item.seed ?? 0) — \(item.status)")
            lines.append("  folder: \(item.outputDirectory)")
            if let steps = item.h3Steps { lines.append("  sampling: Full, \(steps) points / \(steps - 1) passes per window") }
            if let file = item.file { lines.append("  file: \(file)") }
            if let job = item.nodeJobID { lines.append("  node job: \(job)") }
            if item.canCancel == true { lines.append("  can cancel: the node offers to stop this render") }
            if let state = item.cancelState {
                lines.append("  cancel: \(state)" + (item.cancelDetail.map { " — \($0)" } ?? ""))
            }
            if let error = item.error { lines.append("  \(error)") }
        }
        if visible.count > 100 { lines.append("Showing 100 items. Full history is in the app and GET /video/queue.") }
        lines.append("Leave the app open to dispatch the remaining clips; the Mac must remain powered and awake.")
        return lines.joined(separator: "\n")
    }

    static let all: [Tool] = [
        Tool(
            name: "get_hardware_profile",
            description: """
                Describe this Mac's AI-relevant hardware: chip, unified memory, CPU/GPU core \
                counts, memory bandwidth, and the memory budget available to a model. Call this \
                first when reasoning about what will run here — memory bandwidth is what \
                determines generation speed, and total memory is what determines what fits.
                """,
            properties: [:], required: []
        ),
        Tool(
            name: "get_system_metrics",
            description: """
                Current memory, swap, GPU and CPU load. Use to check whether the machine has \
                room right now, or to explain why generation has become slow.
                """,
            properties: [:], required: []
        ),
        Tool(
            name: "recommend_model",
            description: """
                The single best model this Mac can run, with the quantization, context length \
                and settings to use, plus estimated tokens/sec and a full memory breakdown. \
                This is the right tool for "what should I run?" — it accounts for the machine's \
                actual memory, bandwidth and current load. Describe the work in `task` and it \
                judges what that job needs — vision, tool calling, long context, speed — and \
                returns the best three for it with a reason each, instead of the strongest \
                model in general.
                """,
            properties: [
                "category": property(
                    "string",
                    "Optional filter: General, Coding, Reasoning, Vision, Small & Fast, Embeddings."
                ),
                "task": property(
                    "string",
                    """
                    Optional. What the model will actually be used for, in the user's own \
                    words — "reviewing Rust pull requests", "reading scanned invoices", \
                    "a Japanese support bot". A sentence or two beats a keyword; anything \
                    past about 4 KB is trimmed before it is judged. Asking Jev costs the \
                    owner money per distinct description, so send a task when the job is \
                    known and leave it out otherwise. Needs the model recommendation \
                    feature enabled in Settings → TypeSafe (Jev); without it the answer is \
                    the ordinary hardware-fit pick.
                    """
                ),
            ],
            required: []
        ),
        Tool(
            name: "list_models",
            description: """
                The catalog of available models, each annotated with whether this Mac can run it \
                and at what settings. Set only_runnable to false to include models that are too \
                large, which is useful for explaining what a memory upgrade would unlock.
                """,
            properties: [
                "category": property("string", "Optional category filter."),
                "only_runnable": property(
                    "boolean", "Only models this Mac can actually run. Defaults to true."
                ),
            ],
            required: []
        ),
        Tool(
            name: "list_installed_models",
            description: "Models already downloaded on this Mac, and which one is loaded.",
            properties: [:], required: []
        ),
        Tool(
            name: "plan_memory",
            description: """
                Predict exactly what a model will cost in memory at a given quantization and \
                context length: weights, expert pool, KV cache and compute buffers, plus a \
                verdict and ranked suggestions if it will not fit. Use this to answer "will X \
                fit?" or "what context length can I afford?" before downloading anything.
                """,
            properties: [
                "model_id": property("string", "Catalog id, e.g. qwen3-coder-30b-a3b."),
                "quantization": property("string", "e.g. Q4_K_M, Q6_K, Q8_0, MXFP4."),
                "context_length": property("number", "Context window in tokens, e.g. 32768."),
                "kv_cache_precision": property("string", "f16, q8_0, q5_1 or q4_0."),
                "expert_slots": property(
                    "number",
                    """
                    Mixture-of-experts models only: how many experts stay resident in memory. \
                    The rest are paged from disk on demand, which cuts memory sharply at the \
                    cost of prompt-processing speed. Omit for full residency.
                    """
                ),
            ],
            required: ["model_id"]
        ),
        Tool(
            name: "install_model",
            description: """
                Download a model into the local library. Returns immediately; the app shows \
                progress. Downloads are large (often 10–60 GB), so confirm with the user first.
                """,
            properties: [
                "model_id": property("string", "Catalog id."),
                "directory": property("string", "Optional absolute folder to download into — "
                    + "an external volume, say — instead of the app's library on the startup "
                    + "volume."),
                "quantization": property(
                    "string", "Optional. Defaults to the recommendation for this Mac."
                ),
            ],
            required: ["model_id"]
        ),
        Tool(
            name: "load_model",
            description: """
                Load an installed model into memory so it can answer prompts. Settings default \
                to whatever is optimal for this Mac. Loading takes seconds to minutes depending \
                on model size.
                """,
            properties: [
                "model_id": property("string", "Installed model id, or a catalog id."),
                "quantization": property("string", "Required if model_id is a catalog id."),
                "context_length": property("number", "Optional context window override."),
                "expert_slots": property(
                    "number", "Optional: enable expert streaming with this many resident experts."
                ),
            ],
            required: ["model_id"]
        ),
        Tool(
            name: "unload_model",
            description: "Unload the current model and release its memory.",
            properties: [:], required: []
        ),
        Tool(
            name: "chat",
            description: """
                Send a prompt to the model currently loaded on this Mac and get its reply. This \
                runs entirely locally — nothing leaves the machine. Use it to consult the local \
                model, to compare its answer with your own, or to run work the user wants kept \
                private. Load a model first if none is loaded.
                """,
            properties: [
                "prompt": property("string", "The user message to send."),
                "system": property("string", "Optional system prompt."),
                "image_paths": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "Absolute paths to image files to attach. Vision models only — check "
                        + "supportsVision on the loaded model first. The images are read from "
                        + "disk and inlined; nothing is uploaded anywhere."
                    ),
                ]),
                "temperature": property("number", "0–2. Defaults to the app's setting."),
                "max_tokens": property("number", "Optional cap on reply length."),
            ],
            required: ["prompt"]
        ),
        Tool(
            name: "decide",
            description: """
                Typed, probabilistic decisions — a System One call in the TypeSafe/Jev shape. \
                Give a state (text or JSON) and named questions; get back, per question, a typed \
                answer with probabilities and a confidence, never free text. Three question \
                kinds: {"type":"noul","instructions":"…"} answers a yes/no as a 0–1 probability; \
                {"type":"choice","instructions":"…","criteria":{"label":"when it applies",…}} \
                picks a label; {"type":"score","instructions":"…","criteria":["level 0","level \
                1",…]} rates on an ordered rubric and returns the expected level. Ask several \
                questions in one call. Every question needs instructions saying what is being \
                judged. By default ("auto") the best free local lane answers first — Laya on \
                this Mac if it is installed, then a swarm node, then the model loaded here, \
                one forward pass per question, nothing leaves the machine for that half, \
                uncalibrated probabilities — and then only the answers it was unsure of are \
                put to Jev, which returns `provider: "local+typesafe"` and a `sources` map \
                saying which lane answered each question. Where "unsure" sits is set by \
                calibrate_decisions; with nothing free installed, or Decision calibration \
                off, "auto" is a single lane as before. provider "local" never pays and never \
                escalates, choosing from that same free order; "laya" or "node" names one of \
                those lanes outright, skipping the order; "typesafe" asks Jev alone \
                (calibrated, ~$0.0003 per call). The Jev lane is \
                governed by Settings → TypeSafe (Jev) on the Mac: the master switch, the \
                decide-tool switch, the pinned model version, the state size limit and the \
                monthly budget all apply, and every call is recorded \
                in that ledger. If it refuses, call jev_status to see which of those said no. \
                Use it for routing, gating, scoring and classification inside a loop, not for \
                anything that needs generated text.
                """,
            properties: [
                "state": .object([
                    "description": .string(
                        "What to decide about: a string, or a JSON object/array. Send only "
                        + "the fields the questions need."
                    ),
                ]),
                "questions": .object([
                    "type": .string("object"),
                    "description": .string(
                        "Named questions. Each value is {type: noul|choice|score, "
                        + "instructions?, criteria?} as described above."
                    ),
                ]),
                "provider": property(
                    "string", "auto (default), local, laya, node, or typesafe."
                ),
            ],
            required: ["state", "questions"]
        ),
        Tool(
            name: "jev_status",
            description: """
                How the TypeSafe (Jev) integration on this Mac is set up and what it has cost \
                this month: the master switch, the pinned model version, whether a key is \
                stored, the per-feature switches with what each one would do, the monthly \
                budget and the running spend. Read-only, costs nothing, and never returns the \
                API key — it stays in this Mac's Keychain. Call it when decide with provider \
                "typesafe" refuses, to see which switch said no.
                """,
            properties: [:], required: []
        ),
        Tool(
            name: "calibrate_decisions",
            description: """
                Measure how often a local decision lane decides the way Jev does, and retune \
                when `decide` with provider "auto" escalates to Jev. Runs a fixed set of about \
                \(ControlAPI.JevCalibration.builtInCaseCount) short cases — routing, support \
                triage, safety, sentiment — through both lanes, then reports agreement per \
                question kind, a reliability table of local confidence against agreement, and \
                the two floors "auto" will use from now on: the confidence below which a \
                choice or score is sent to Jev, and the middle band in which a noul is. Takes \
                an optional lane: "local" (the model loaded here, one token deep — the \
                default), "laya" (Laya on this Mac), or "node" (Laya on a swarm node); never \
                "typesafe", which is the reference a calibration measures against, not a lane \
                it can measure. \
                COSTS MONEY: about \(ControlAPI.JevCalibration.estimatedCents()) cent(s) of \
                Jev tokens, plus a minute or two of whichever lane is being measured, so ask \
                the user before running it. Needs that lane ready — a model loaded for \
                "local", Laya installed for "laya", a reachable node for "node" — and \
                Decision calibration switched on in Settings → TypeSafe (Jev). The result is \
                kept and reused only while that same lane is the one running — a threshold \
                found on one says nothing about another. \
                Jev is the reference here, not ground truth: agreement means the two lanes \
                landed in the same place, which they can do while both being wrong.
                """,
            properties: [
                "lane": property(
                    "string",
                    "Which lane to calibrate: \"local\" (default), \"laya\", or \"node\". "
                    + "Never \"typesafe\"."
                ),
            ],
            required: []
        ),
        Tool(
            name: "run_benchmark",
            description: """
                Measure what the loaded model actually does on this Mac: generation speed, prompt \
                throughput, first-token latency and how much it slows down at long context. \
                Returns a scorecard plus specific advice, and recalibrates every future speed \
                estimate against the result. Takes about a minute of sustained generation, so \
                confirm with the user before running it.
                """,
            properties: [:], required: []
        ),
        Tool(
            name: "list_image_models",
            description: """
                Image generation models this Mac can run, each with a memory plan. Diffusion \
                memory is phased — encode, denoise, decode — and the phases release each \
                other's memory, so what matters is the tallest one rather than the total.
                """,
            properties: [:], required: []
        ),
        Tool(
            name: "plan_image",
            description: """
                Predict what generating an image will cost before running it: the three phases, \
                which one peaks, and whether it fits. Cost scales with image *area*, so \
                doubling the width roughly quadruples the memory. Use this to answer "can I \
                render 2048x2048?" without waiting for a failure.
                """,
            properties: [
                "prompt": property("string", "Not used for planning, but accepted so the same "
                    + "arguments work for generate_image."),
                "model_id": property("string", "e.g. flux1-schnell, flux2-klein-4b. "
                    + "\"auto\" plans the model the router would pick for this prompt."),
                "width": property("number", "Image width in pixels."),
                "height": property("number", "Image height in pixels."),
                "steps": property("number", "Denoising steps."),
                "quantization": property("string", "MLX-4bit, MLX-6bit or MLX-8bit."),
            ],
            required: []
        ),
        Tool(
            name: "generate_image",
            description: """
                Generate an image on this Mac and return the path to it. Runs entirely locally. \
                Attempts the run even when the memory plan says it will not comfortably fit — \
                the estimate is pessimistic on some models — and reports a warning in the \
                response instead of refusing beforehand. Use plan_image first if you want to \
                know the risk before spending the time. The first use of a model downloads its \
                weights, which can take several minutes. Pass model_id "auto" (or omit it) to \
                let the app pick: with TypeSafe's media routing turned on it reads the prompt \
                and chooses the model and the denoising steps, and otherwise it falls back to \
                the best model this Mac can comfortably run.
                """,
            properties: [
                "prompt": property("string", "What to draw."),
                "model_id": property("string", "Optional. \"auto\" asks the app to choose from "
                    + "the prompt; omitted or unset defaults to the best model that fits."),
                "width": property("number", "Image width in pixels."),
                "height": property("number", "Image height in pixels."),
                "steps": property("number", "Denoising steps. Distilled models need very few."),
                "quantization": property("string", "MLX-4bit, MLX-6bit or MLX-8bit."),
                "seed": property("number", "Optional seed for a reproducible image."),
                "init_image_path": property("string", "Optional revision: absolute path to "
                    + "an existing image to start from instead of noise (img2img)."),
                "init_image_influence": property("number", "0-1, how strongly the init "
                    + "image steers the result — 0 ignores it, 1 clings to it. Default 0.5."),
            ],
            required: ["prompt"]
        ),
        Tool(
            name: "list_3d_models",
            description: """
                Image-to-3D backends on this Mac: TRELLIS.2 (textured, minutes), Hunyuan3D \
                (fast geometry, seconds) and the remote LATO.2 retopology service, with \
                whether each is ready to run and what it peaks at in memory.
                """,
            properties: [:], required: []
        ),
        Tool(
            name: "plan_3d",
            description: """
                Predict what generating a 3D model will cost in memory before running it. \
                3D figures are measured rather than derived — the planner interpolates \
                benchmark tables instead of formulas.
                """,
            properties: [
                "model_id": property("string", "trellis2-4b, hunyuan3d-2-mini, "
                    + "hunyuan3d-2-turbo or lato-2."),
                "quantize": property("number", "Hunyuan weight quantization: 4 or 8. "
                    + "Omit for fp16."),
                "pipeline_type": property("string", "TRELLIS pipeline: 512, 1024 or "
                    + "1024_cascade."),
            ],
            required: []
        ),
        Tool(
            name: "generate_3d",
            description: """
                Turn an image into a 3D mesh on this Mac and return the file paths. Give it \
                the absolute path of an image file — a photo, or something made with \
                generate_image. TRELLIS.2 produces a textured GLB in minutes; Hunyuan3D \
                produces clean geometry in well under a minute; lato-2 sends the job to the \
                remote LATO.2 service and returns a clean low-poly mesh. Long-running: \
                expect minutes, not seconds.
                """,
            properties: [
                "image_path": property("string", "Absolute path to the input image."),
                "model_id": property("string", "Optional. Defaults to the best installed "
                    + "backend."),
                "steps": property("number", "Hunyuan denoising steps."),
                "quantize": property("number", "Hunyuan quantization: 4 or 8."),
                "pipeline_type": property("string", "TRELLIS pipeline: 512, 1024, "
                    + "1024_cascade."),
                "texture_size": property("number", "TRELLIS texture side: 512, 1024, 2048."),
                "vertex_budget": property("number", "LATO.2 output vertex count, 200–5000."),
                "seed": property("number", "Optional seed."),
            ],
            required: ["image_path"]
        ),
        Tool(
            name: "list_video_models",
            description: """
                Video generation models, their supported clip lengths, and whether an exact \
                model capability is ready right now. The renderer may be a paired GPU machine \
                or a loopback Apple Silicon adapter such as Phosphene.
                """,
            properties: [:], required: []
        ),
        Tool(
            name: "generate_video",
            description: """
                Render a short video clip from a prompt on a swarm node that can run that \
                model and return the file path. Long-running: ltx2-distilled generally takes \
                one to three minutes, wan22-ti2v-5b around ten, the uncensored LTX-2.3 merge \
                (ltx23-uncensored: adult content allowed, clips carry audio) a few minutes, \
                and hailuo-h3 through Phosphene may take several minutes or longer for a \
                chained clip. Call list_video_models first for availability and supported \
                lengths. The finished clip also appears in the app's Video tab under Recent \
                clips. Pass model_id "auto" (or omit it) to let the app pick: with TypeSafe's \
                media routing turned on it reads the prompt once and chooses the model, the \
                clip length and the sampling, returns what it chose and why in `detail`, and \
                refuses rather than sending a prompt to a lane that would reject it.
                """,
            properties: [
                "prompt": property("string", "What happens in the clip."),
                "model_id": property("string", "Optional: wan22-ti2v-5b (cinematic, ~10 min), "
                    + "ltx2-distilled (fast, 1-3 min), ltx23-uncensored (LTX-2.3 merge, "
                    + "adult content allowed, audio, 2-5 min) or hailuo-h3 (local Phosphene, "
                    + "chained 10/15 s clips). \"auto\" reads the prompt and picks one, along "
                    + "with the clip length. Defaults to the app's selection."),
                "seconds": .object([
                    "type": .string("number"),
                    "description": .string(
                        "Clip length in seconds, "
                            + "\(ControlAPI.VideoGenerateRequest.minimumSeconds)-"
                            + "\(ControlAPI.VideoGenerateRequest.maximumSeconds). It must be "
                            + "one of the selected model's supported lengths; default 5."
                    ),
                    "minimum": .number(Double(ControlAPI.VideoGenerateRequest.minimumSeconds)),
                    "maximum": .number(Double(ControlAPI.VideoGenerateRequest.maximumSeconds)),
                ]),
                "resolution": property("string", "e.g. 720p. Defaults to the app's setting."),
                "image_path": property("string", "Optional still to animate (image-to-video): "
                    + "absolute path, e.g. something from generate_image."),
                "seed": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(4294967295), "description": .string("Optional fixed seed for sampling comparisons.")]),
                "h3_turbo": property("boolean", "H3 only: false = Full sampling, true = Turbo, omit = renderer default. Requires node support."),
                "h3_steps": h3StepsProperty,
                "h3_chain_prompts": .object([
                    "type": .string("array"),
                    "description": .string("Optional per-window prompts for hailuo-h3 only: "
                        + "exactly 2 for 10 seconds or 3 for 15 seconds, in temporal order. "
                        + "Omit to use the main prompt throughout."),
                    "minItems": .number(2), "maxItems": .number(3),
                    "items": .object([
                        "type": .string("string"), "minLength": .number(1),
                        "maxLength": .number(4000),
                    ]),
                ]),
            ],
            required: ["prompt"]
        ),
        Tool(
            name: "queue_videos",
            description: "Persist video prompts and return immediately. Generate 1–20 variations per prompt with distinct saved seeds, up to 200 unfinished clips, one render at a time. Clips and manifests go in batch folders. Leave the app open and the Mac powered with its lid open. A relaunch reconnects to saved jobs. Inspect video_queue before resubmitting after an uncertain response. Call list_video_models for supported controls. Pass model_id \"auto\" (or omit it) to let the app read the prompts and choose the model, the clip length and the sampling for the whole batch; each queued clip records what it decided.",
            properties: [
                "prompts": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(200), "items": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(12000)]), "description": .string("One prompt per shot, in scene order.")]),
                "title": property("string", "Optional batch name."),
                "variations": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(20), "description": .string("Generations per prompt; default 1.")]),
                "model_id": property("string", "Optional model ID. \"auto\" reads the prompts "
                    + "and picks one, along with the clip length; omitted defaults to the app selection."),
                "seconds": property("integer", "Supported clip length for the model, up to 15 seconds."),
                "resolution": property("string", "480p, 720p or 1080p. Higher sizes may need more memory."),
                "seed": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(4294967295), "description": .string("Optional base seed, incremented per clip. Omit for random.")]),
                "h3_turbo": property("boolean", "H3 only, when the node advertises this control: true = Turbo, false = slower full sampling at the same canvas, omit = renderer default. Slower is not guaranteed to look better."),
                "h3_steps": h3StepsProperty,
            ], required: ["prompts"]
        ),
        Tool(
            name: "video_queue",
            description: "Inspect or control the persistent queue. Pause stops future dispatch, not the active render. stop_following also stops the app waiting for the active clip, but does NOT cancel the remote GPU job; its receipt is preserved. cancel asks the clip's node to stop that one render, and only applies to items listed as \"can cancel\" (their node advertises job cancellation); it reports whether the node confirmed, is stopping, had already finished, or could not stop it, and never resubmits. Everywhere else stop_following is the only option. Retry reconnects to a saved non-terminal job. Check the node and obtain user approval before confirm_new_render=true for an uncertain submission. Remove only affects unsubmitted entries; clear_finished keeps media and manifests.",
            properties: [
                "action": .object(["type": .string("string"), "enum": .array(["status", "pause", "resume", "retry", "remove", "stop_following", "cancel", "clear_finished"].map(JSONValue.string)), "description": .string("Default status.")]),
                "id": property("string", "Queue item ID for retry, remove, stop_following or cancel."),
                "confirm_new_render": property("boolean", "Explicit user confirmation to create a new render after checking the original job."),
            ], required: []
        ),
        Tool(
            name: "get_status",
            description: "What is loaded right now, at what settings, and its last measured speed.",
            properties: [:], required: []
        ),
    ]

    // MARK: - Dispatch

    static func invoke(
        _ name: String, arguments: [String: JSONValue], client: ControlClient
    ) async throws -> String {
        switch name {
        case "get_hardware_profile":
            return try await describe(await client.get("/profile") as ControlAPI.Profile)

        case "get_system_metrics":
            return try await describe(await client.get("/metrics") as ControlAPI.Metrics)

        case "get_status":
            var status = try await describe(await client.get("/status") as ControlAPI.Status)
            // Appended rather than folded into `ControlAPI.Status`, which the phone apps are
            // generated from and which has nothing to do with Jev — and read through a short
            // cache, so a tool an agent calls in a loop does not pay a second round trip
            // every time. A Mac that has never calibrated answers 404, which is remembered
            // too rather than re-asked.
            if let calibration = await CalibrationCache.shared.current(from: client) {
                status += "\n" + cascadeLine(calibration)
            }
            return status

        case "recommend_model":
            let category = arguments["category"]?.stringValue
            // A task is the paid, full-control half of this route and goes in a body: a job
            // description is the user's prose about their own work, and a URL is the part
            // of a request that survives in histories and logs.
            if let task = arguments["task"]?.stringValue,
               !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let ranked: ControlAPI.CatalogModel = try await client.post(
                    "/recommend", ControlAPI.RecommendRequest(category: category, task: task)
                )
                return describeRecommendation(ranked)
            }
            var path = "/recommend"
            if let category, let escaped = category.addingPercentEncoding(
                withAllowedCharacters: Tools.queryValueCharacters
            ) {
                path += "?category=\(escaped)"
            }
            return describeRecommendation(try await client.get(path) as ControlAPI.CatalogModel)

        case "list_models":
            var path = "/catalog?onlyRunnable="
                + String(arguments["only_runnable"]?.boolValue ?? true)
            if let category = arguments["category"]?.stringValue,
               let escaped = category.addingPercentEncoding(
                   withAllowedCharacters: .urlQueryAllowed
               ) {
                path += "&category=\(escaped)"
            }
            let models: [ControlAPI.CatalogModel] = try await client.get(path)
            return describeCatalog(models)

        case "list_installed_models":
            let installed: [ControlAPI.InstalledModel] = try await client.get("/installed")
            guard !installed.isEmpty else {
                return "No models installed yet. Use recommend_model, then install_model."
            }
            return installed.map { model in
                "- \(model.name) (\(model.quantization), \(bytes(model.sizeOnDiskBytes)))"
                    + (model.isLoaded ? " — LOADED" : "")
                    + "\n  id: \(model.id)"
            }.joined(separator: "\n")

        case "plan_memory":
            guard let modelID = arguments["model_id"]?.stringValue else {
                throw ToolError.missing("model_id")
            }
            let request = ControlAPI.PlanRequest(
                modelID: modelID,
                quantization: arguments["quantization"]?.stringValue,
                contextLength: arguments["context_length"]?.intValue,
                kvCachePrecision: arguments["kv_cache_precision"]?.stringValue,
                flashAttention: arguments["flash_attention"]?.boolValue,
                expertSlots: arguments["expert_slots"]?.intValue
            )
            return describe(try await client.post("/plan", request) as ControlAPI.Plan)

        case "install_model":
            guard let modelID = arguments["model_id"]?.stringValue else {
                throw ToolError.missing("model_id")
            }
            let response: [String: String] = try await client.post("/install", ControlAPI.LoadRequest(
                modelID: modelID, quantization: arguments["quantization"]?.stringValue,
                directory: arguments["directory"]?.stringValue
            ))
            return response["status"] ?? "Download started."

        case "load_model":
            guard let modelID = arguments["model_id"]?.stringValue else {
                throw ToolError.missing("model_id")
            }
            let request = ControlAPI.LoadRequest(
                modelID: modelID,
                quantization: arguments["quantization"]?.stringValue,
                contextLength: arguments["context_length"]?.intValue,
                expertSlots: arguments["expert_slots"]?.intValue
            )
            return describe(try await client.post("/load", request) as ControlAPI.Status)

        case "list_image_models":
            let models: [ControlAPI.ImageModel] = try await client.get("/image/models")
            return models.map { model in
                var line = "- \(model.name) [\(model.id)] — \(model.parameters), "
                    + "\(model.blocks) blocks, \(model.defaultSteps) steps"
                if model.isGated { line += " (gated)" }
                if let plan = model.recommendation {
                    line += "\n  \(plan.width)x\(plan.height) peaks at "
                        + "\(bytes(plan.peakBytes)) during \(plan.peakPhase.lowercased()) "
                        + "— \(plan.verdict)"
                } else {
                    line += "\n  too large for this Mac"
                }
                return line
            }.joined(separator: "\n")

        case "plan_image":
            let plan: ControlAPI.ImagePlan = try await client.post("/image/plan", imageRequest(arguments))
            return describe(plan)

        case "generate_image":
            guard arguments["prompt"]?.stringValue != nil else {
                throw ToolError.missing("prompt")
            }
            let response: ControlAPI.ImageResponse = try await client.post(
                "/image/generate", imageRequest(arguments)
            )
            var lines = [
                "Generated with \(response.model).",
                "  path    : \(response.path)",
                String(format: "  time    : %.1fs", response.elapsedSeconds),
                "  predicted peak: \(bytes(response.predictedPeakBytes))",
            ]
            if let measured = response.peakMemoryBytes {
                let error = abs(Double(measured - response.predictedPeakBytes))
                    / Double(max(1, response.predictedPeakBytes)) * 100
                lines.append("  measured peak : \(bytes(measured)) "
                    + String(format: "(%.0f%% from prediction)", error))
            }
            if let warning = response.warning {
                lines.append("\nWarning: \(warning)")
            }
            return lines.joined(separator: "\n")

        case "list_3d_models":
            let models: [ControlAPI.MeshModel] = try await client.get("/mesh/models")
            return models.map { model in
                var line = "- \(model.name) [\(model.id)] — \(model.outputs), "
                    + "\(model.typicalDuration)"
                if model.peakBytes > 0 {
                    line += ", peaks ~\(bytes(model.peakBytes))"
                }
                line += "\n  " + (model.isInstalled ? "READY" : "NOT READY") + ": "
                    + model.installDetail
                return line
            }.joined(separator: "\n")

        case "plan_3d":
            let plan: ControlAPI.MeshPlan = try await client.post("/mesh/plan", meshRequest(arguments))
            var lines = ["\(plan.model): \(plan.verdict)"]
            if plan.isRemote {
                lines.append("  Runs remotely — this Mac's memory is untouched.")
            } else {
                lines.append("  peak \(bytes(plan.peakBytes)) during "
                    + "\(plan.peakPhase.lowercased()), budget \(bytes(plan.budgetBytes))")
                for phase in plan.phases {
                    lines.append("  \(phase.name): \(bytes(phase.residentBytes)) — \(phase.detail)")
                }
            }
            for suggestion in plan.suggestions {
                lines.append("  Try: \(suggestion.title) — \(suggestion.detail)")
            }
            for note in plan.notes {
                lines.append("  Note: \(note)")
            }
            return lines.joined(separator: "\n")

        case "generate_3d":
            guard arguments["image_path"]?.stringValue != nil else {
                throw ToolError.missing("image_path")
            }
            let response: ControlAPI.MeshResponse = try await client.post(
                "/mesh/generate", meshRequest(arguments)
            )
            var lines = ["Generated with \(response.model)."]
            if let glb = response.glbPath { lines.append("  glb : \(glb)") }
            if let obj = response.objPath { lines.append("  obj : \(obj)") }
            lines.append(String(format: "  time: %.0fs", response.elapsedSeconds))
            if let warning = response.warning {
                lines.append("\nWarning: \(warning)")
            }
            return lines.joined(separator: "\n")

        case "list_video_models":
            let models: [ControlAPI.VideoModel] = try await client.get("/video/models")
            return models.map { model in
                var line = "- \(model.name) [\(model.id)] — \(model.typicalDuration)"
                line += ", \(model.supportedSeconds.map(String.init).joined(separator: "/")) s"
                if model.supportsImageInput { line += ", can animate a still image" }
                line += model.available
                    ? "\n  available now on \(model.node ?? "a node")"
                    : "\n  NOT available — no reachable node offers this model right now"
                if let parameters = model.supportedParameters, !parameters.isEmpty {
                    line += "\n  supported controls: \(parameters.joined(separator: ", "))"
                }
                line += "\n  \(model.summary)"
                return line
            }.joined(separator: "\n")

        case "generate_video":
            guard let prompt = arguments["prompt"]?.stringValue else {
                throw ToolError.missing("prompt")
            }
            let chainPrompts: [String]?
            if let value = arguments["h3_chain_prompts"] {
                guard let values = value.arrayValue,
                      values.allSatisfy({ $0.stringValue != nil }) else {
                    throw ToolError.invalid("h3_chain_prompts must be an array of strings.")
                }
                chainPrompts = values.compactMap(\.stringValue)
            } else {
                chainPrompts = nil
            }
            let sampling = try videoSamplingArguments(arguments)
            let request = ControlAPI.VideoGenerateRequest(
                prompt: prompt,
                modelID: arguments["model_id"]?.stringValue,
                seconds: arguments["seconds"]?.intValue,
                resolution: arguments["resolution"]?.stringValue,
                imagePath: arguments["image_path"]?.stringValue,
                h3ChainPrompts: chainPrompts, seed: try videoSeedArgument(arguments),
                h3Turbo: sampling.turbo, h3Steps: sampling.steps
            )
            let clip: ControlAPI.VideoResponse = try await client.post(
                "/video/generate", request
            )
            return "Rendered on \(clip.node) with \(clip.model) in "
                + String(format: "%.0fs", clip.elapsedSeconds)
                + ".\n  file: \(clip.file)"
                + "\nThe clip is also in the app's Video tab under Recent clips."

        case "queue_videos":
            guard let values = arguments["prompts"]?.arrayValue,
                  values.allSatisfy({ $0.stringValue != nil }) else {
                throw ToolError.invalid("prompts must be an array of strings.")
            }
            let seed = try videoSeedArgument(arguments)
            for key in ["variations", "seconds"] where arguments[key] != nil {
                guard let value = arguments[key]?.doubleValue, value.isFinite,
                      value.rounded() == value, value >= 1, value <= 200 else {
                    throw ToolError.invalid("\(key) must be a positive integer in range.")
                }
            }
            let sampling = try videoSamplingArguments(arguments)
            let queue: ControlAPI.VideoQueueView = try await client.post("/video/queue", ControlAPI.VideoQueueRequest(
                prompts: values.compactMap(\.stringValue), title: arguments["title"]?.stringValue,
                variations: arguments["variations"]?.intValue, modelID: arguments["model_id"]?.stringValue,
                seconds: arguments["seconds"]?.intValue, resolution: arguments["resolution"]?.stringValue,
                seed: seed, h3Turbo: sampling.turbo, h3Steps: sampling.steps
            ))
            return describeQueue(queue)

        case "video_queue":
            let action = arguments["action"]?.stringValue ?? "status"
            let queue: ControlAPI.VideoQueueView
            if action == "status" { queue = try await client.get("/video/queue") }
            else {
                queue = try await client.post("/video/queue/control", ControlAPI.VideoQueueControl(
                    action: action, id: arguments["id"]?.stringValue,
                    confirmNewRender: arguments["confirm_new_render"]?.boolValue
                ))
            }
            return describeQueue(queue)

        case "run_benchmark":
            let result: ControlAPI.BenchmarkResult = try await client.postEmpty("/benchmark")
            return describe(result)

        case "unload_model":
            let response: [String: String] = try await client.postEmpty("/unload")
            return response["status"] ?? "Unloaded."

        case "chat":
            guard let prompt = arguments["prompt"]?.stringValue else {
                throw ToolError.missing("prompt")
            }
            var messages: [ControlAPI.ChatRequest.Message] = []
            if let system = arguments["system"]?.stringValue {
                messages.append(.init(role: "system", content: system))
            }
            var images: [String] = []
            let imageValues = arguments["image_paths"]?.arrayValue ?? []
            guard imageValues.count <= Self.maximumImageCount else {
                throw ToolError.tooManyImages(Self.maximumImageCount)
            }
            var aggregateImageBytes = 0
            for value in imageValues {
                guard let path = value.stringValue else { continue }
                guard let attachment = Self.dataURL(forImageAt: path) else {
                    throw ToolError.unreadableImage(path)
                }
                aggregateImageBytes += attachment.bytes
                guard aggregateImageBytes <= Self.maximumAggregateImageBytes else {
                    throw ToolError.imagesTooLarge(Self.maximumAggregateImageBytes)
                }
                images.append(attachment.url)
            }
            messages.append(.init(role: "user", content: prompt, images: images))

            let response: ControlAPI.ChatResponse = try await client.post("/chat", ControlAPI.ChatRequest(
                messages: messages,
                temperature: arguments["temperature"]?.doubleValue,
                maxTokens: arguments["max_tokens"]?.intValue
            ))
            let reasoning = response.reasoning ?? ""
            // Jev's verdict, when answer verification is on, under the rule rather than in
            // the reply: it is a note *about* the answer, not part of it.
            //
            // The first line has to be right about who wrote the text above it. Normally
            // that is the model on this Mac and the line is its token count. When an
            // escalation replaced the answer, saying "(local)" would be false and the local
            // run's throughput would describe text that is no longer here — so both are
            // dropped and the line names the model that did answer.
            var footer: String
            if let escalated = response.verification?.escalatedTo {
                footer = "\n\n---\nAnswered by \(escalated). Jev flagged the local model's "
                    + "reply and it was re-run there."
            } else {
                footer = String(
                    format: "\n\n---\n%d tokens at %.1f tok/s (local)",
                    response.generatedTokens, response.tokensPerSecond
                )
            }
            if let verification = response.verification {
                let reasons = verification.reasons.joined(separator: " ")
                switch verification.verdict {
                case "escalate" where verification.escalatedTo != nil:
                    if !reasons.isEmpty { footer += "\n" + reasons }
                case "escalate", "annotate":
                    footer += "\nJev flagged this answer: " + reasons
                default:
                    break
                }
                if let suggestion = verification.suggestion { footer += "\n" + suggestion }
            }

            // A reasoning model can spend its entire token budget thinking and never reach an
            // answer. Returning an empty string looks like a broken tool, so say what happened
            // and let the caller raise the limit rather than guess.
            if response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !reasoning.isEmpty {
                let limit = arguments["max_tokens"]?.intValue
                return """
                    The model spent its whole token budget reasoning and did not reach an answer.\
                    \(limit.map { " The limit was \($0) tokens." } ?? "") Retry with a larger \
                    max_tokens, or use a model that reasons less verbosely.

                    Tail of its reasoning:
                    \(reasoning.suffix(400))
                    """ + footer
            }

            var output = response.content
            if !reasoning.isEmpty {
                output = "<reasoning>\n" + reasoning + "\n</reasoning>\n\n" + output
            }
            return output + footer

        case "decide":
            guard let state = arguments["state"] else { throw ToolError.missing("state") }
            guard let questions = arguments["questions"]?.objectValue, !questions.isEmpty else {
                throw ToolError.missing("questions")
            }
            // Both sides are Codable JSON, so the MCP value becomes the wire request by
            // going through bytes once; a malformed question fails right here, by name.
            var envelope: [String: JSONValue] = ["state": state, "questions": .object(questions)]
            if let provider = arguments["provider"]?.stringValue { envelope["provider"] = .string(provider) }
            // No `model`: the local lane uses what is loaded and the Jev lane uses the
            // version pinned in Settings, so accepting one here would be a promise this
            // tool cannot keep.
            let request: ControlAPI.DecideRequest
            do {
                request = try JSONDecoder().decode(
                    ControlAPI.DecideRequest.self, from: JSONEncoder().encode(JSONValue.object(envelope))
                )
                try request.validate()
            } catch {
                throw ToolError.invalid("Bad decide request: \(error.localizedDescription)")
            }
            let response: ControlAPI.DecideResponse = try await client.post("/decide", request)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let answers = String(decoding: try encoder.encode(response.answers), as: UTF8.self)
            let latency = response.latencyMS.map { String(format: "%.0f ms", $0) } ?? "-"
            var footer = String(
                format: "\n\n---\n%@ · %@ · %d input tokens · %@",
                response.provider ?? "unknown lane", response.model, response.usage.inputTokens, latency
            )
            // Only the cascade sets this, and when it does, "which lane answered" is no
            // longer one fact about the response — so it is spelled out per question.
            if let sources = response.sources, !sources.isEmpty {
                footer += "\n" + sources.sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }.joined(separator: " · ")
            }
            return answers + footer

        case "jev_status":
            return describe(try await client.get("/jev") as ControlAPI.JevStatus)

        case "calibrate_decisions":
            // No `lane` is still the old route, unchanged: `POST /decisions/calibrate` with
            // an absent lane is `POST /jev/calibrate` in every respect but the path.
            let lane = arguments["lane"]?.stringValue
            let result: ControlAPI.JevCalibration = try await client.post(
                "/decisions/calibrate", ControlAPI.DecisionCalibrateRequest(lane: lane)
            )
            // What get_status is holding is now last week's answer.
            await CalibrationCache.shared.forget()
            return describe(result)

        default:
            throw ToolError.unknown(name)
        }
    }

    enum ToolError: Error, LocalizedError {
        case invalid(String)
        case missing(String)
        case unknown(String)
        case unreadableImage(String)
        case tooManyImages(Int)
        case imagesTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .invalid(let message): message
            case .missing(let field): "Required argument '\(field)' was not provided."
            case .unknown(let name): "Unknown tool '\(name)'."
            case .unreadableImage(let path):
                "Could not safely read an image at '\(path)'. Use an owner-readable regular "
                    + "PNG, JPEG, GIF, or WebP under \(Tools.maximumImageBytes / 1_048_576) "
                    + "MB and 40 megapixels."
            case .tooManyImages(let limit):
                "At most \(limit) images may be attached to one request."
            case .imagesTooLarge(let limit):
                "The attached images exceed the \(limit / 1_048_576) MB aggregate limit."
            }
        }
    }

    static let maximumImageCount = 4
    // Data-URL encoding expands bytes by roughly one third. The aggregate therefore stays
    // below the control listener's 16 MiB authenticated JSON body ceiling with room for text.
    static let maximumImageBytes = 10 * 1_048_576
    static let maximumAggregateImageBytes = 10 * 1_048_576
    static let maximumImagePixels = 40_000_000

    /// Opens without following a final symlink, verifies owner/type/size and image metadata,
    /// then reads through the admitted descriptor under a hard byte budget. This keeps devices,
    /// FIFOs, symlink swaps, decompression bombs, and base64 duplication out of the MCP process.
    static func dataURL(forImageAt path: String) -> (url: String, bytes: Int)? {
        guard (path as NSString).isAbsolutePath else { return nil }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        // O_NONBLOCK matters before fstat: opening an attacker-selected FIFO for reading can
        // otherwise wait forever for a writer even though the later regular-file check rejects it.
        let descriptor = open(normalized, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_size >= 0,
              metadata.st_size <= off_t(maximumImageBytes)
        else { return nil }

        var data = Data()
        do {
            while data.count <= maximumImageBytes {
                let remaining = maximumImageBytes + 1 - data.count
                guard remaining > 0,
                      let chunk = try handle.read(upToCount: min(1_048_576, remaining)),
                      !chunk.isEmpty
                else { break }
                data.append(chunk)
            }
        } catch {
            return nil
        }
        guard !data.isEmpty, data.count <= maximumImageBytes,
              let mime = admittedImageMIME(data: data, extension: URL(
                fileURLWithPath: normalized
              ).pathExtension.lowercased()),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= maximumImagePixels / height
        else { return nil }
        return ("data:\(mime);base64,\(data.base64EncodedString())", data.count)
    }

    static func admittedImageMIME(data: Data, extension fileExtension: String) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if fileExtension == "png",
           bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if ["jpg", "jpeg"].contains(fileExtension),
           bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if fileExtension == "gif",
           data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) {
            return "image/gif"
        }
        if fileExtension == "webp", bytes.count >= 12,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return "image/webp"
        }
        return nil
    }

    // MARK: - Rendering
    //
    // Tool results are rendered as prose rather than raw JSON. A model reads "20.3 GB of a
    // 27.1 GB budget" far more reliably than it reads two Int64 fields, and it keeps the
    // token cost of a tool call low.

    static func bytes(_ value: Int64) -> String {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6)]
        for (suffix, scale) in units where abs(Double(value)) >= scale {
            return String(format: "%.1f %@", Double(value) / scale, suffix)
        }
        return "\(value) B"
    }

    /// The one line `get_status` appends: what `decide` with provider "auto" will send to
    /// Jev, and what measured it.
    ///
    /// Written for an agent deciding whether a local answer is worth trusting, so it leads
    /// with the floors *in effect*. A calibration measured against a model that is no longer
    /// loaded is not a description of what will happen now, and saying its numbers plainly
    /// would be a quiet lie — so that case says so first and gives the defaults that are
    /// actually running.
    static func cascadeLine(_ calibration: ControlAPI.JevCalibration) -> String {
        let applies = calibration.appliesToLoadedModel ?? true
        let floors = calibration.floorsInEffect ?? calibration.floors
        let head = String(
            format: "Decision cascade: choices under %.2f confidence, scores under %.2f, "
            + "and nouls between %.2f and %.2f are escalated to Jev.",
            floors.choiceConfidence, floors.scoreConfidence, floors.noulLow, floors.noulHigh
        )
        guard applies else {
            return head + String(
                format: " The %@ calibration of %@ is NOT in effect — it was measured on %@, "
                + "and %@ is loaded — so those are the defaults. Run calibrate_decisions "
                + "against the loaded model to replace them.",
                calibration.date.prefix(10).description, calibration.modelName,
                calibration.modelName, calibration.loadedModelName ?? "another model"
            )
        }
        return head + String(
            format: " Calibrated %@ against %@: %d cases, %d%% agreement, %d%% of answers "
            + "escalated.%@",
            calibration.date.prefix(10).description, calibration.modelName,
            calibration.cases,
            Int((calibration.overallAgreementRate * 100).rounded()),
            Int((calibration.escalationRate * 100).rounded()),
            calibration.choiceFloorMeasured && calibration.scoreFloorMeasured
                && calibration.noulBandMeasured
                ? "" : " Some floors fell back to the defaults."
        )
    }

    /// A calibration run as a page an agent can read: what it measured, what it changed, and
    /// the caveat that goes with it.
    static func describe(_ calibration: ControlAPI.JevCalibration) -> String {
        var lines = [
            "Calibrated \(calibration.modelName) against \(calibration.jevModel) "
            + "on \(calibration.date).",
            "\(calibration.cases) cases (\(calibration.builtInCases) built in, "
            + "\(calibration.userCases) yours) · \(calibration.comparisons) answers compared "
            + String(format: "· %d%% agreement overall", Int((calibration.overallAgreementRate * 100).rounded())),
            String(
                format: "Cost: %d input tokens, about $%.4f.",
                calibration.inputTokens, calibration.estimatedUSD
            ),
            "",
            "Agreement by question kind:",
        ]
        for row in calibration.agreement where row.compared > 0 {
            lines.append(String(
                format: "- %@: %d of %d (%d%%)", row.kind, row.agreed, row.compared,
                Int((row.rate * 100).rounded())
            ))
        }
        lines.append("")
        lines.append(cascadeLine(calibration))
        lines.append(String(
            format: "Under these floors, %d%% of this set would have gone to Jev.",
            Int((calibration.escalationRate * 100).rounded())
        ))
        if !calibration.choiceFloorMeasured {
            lines.append("  The choice floor is the default; the search found none better.")
        }
        if !calibration.scoreFloorMeasured {
            lines.append("  The score floor is the default; the search found none better.")
        }
        if !calibration.noulBandMeasured {
            lines.append("  The noul band is the default; there were too few disagreements to place one.")
        }
        if !calibration.bins.isEmpty {
            lines.append("")
            lines.append("Local confidence against agreement:")
            for bin in calibration.bins {
                lines.append(String(
                    format: "- %.1f–%.1f: %d answers, %d%% agreed (mean confidence %.2f)",
                    bin.lower, bin.upper, bin.count,
                    Int((bin.agreementRate * 100).rounded()), bin.meanConfidence
                ))
            }
        }
        if !calibration.notes.isEmpty {
            lines.append("")
            lines.append("Notes:")
            lines.append(contentsOf: calibration.notes.map { "- \($0)" })
        }
        lines.append("")
        lines.append(
            "Jev is the reference, not ground truth: an agreement rate says the two lanes "
            + "landed in the same place, not that either was right. These floors apply only "
            + "while \(calibration.modelName) is the loaded model."
        )
        return lines.joined(separator: "\n")
    }

    /// The same facts as `GET /jev`, as a page an agent can read. Deliberately not the raw
    /// JSON: the useful answer to "why did decide refuse?" is one of these lines.
    static func describe(_ status: ControlAPI.JevStatus) -> String {
        var lines = [
            "TypeSafe (Jev): \(status.enabled ? "on" : "off") · model \(status.model) · "
            + "API key \(status.keySet ? "stored on this Mac" : "not set")",
        ]
        let spend = String(format: "$%.4f", status.estimatedUSD)
        var spendLine = "\(status.month): \(status.calls) calls · "
            + "\(status.inputTokens) input tokens · about \(spend)"
        if let budget = status.monthlyBudgetUSD {
            spendLine += String(
                format: " of a $%.2f cap (%@ left)", budget,
                String(format: "$%.4f", max(0, status.budgetRemainingUSD ?? 0))
            )
        } else {
            spendLine += " (no budget cap set)"
        }
        lines.append(spendLine)
        if !status.models.isEmpty {
            lines.append("Answered by: " + status.models.sorted { $0.key < $1.key }
                .map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
        }
        lines.append("")
        lines.append("Features:")
        for feature in status.features {
            let state = feature.available
                ? "available"
                : (feature.enabled ? "on, but not available" : "off")
            lines.append(
                "- \(feature.displayName) (\(feature.id)): \(state)"
                + (feature.built ? "" : " — not built yet")
            )
            lines.append("  \(feature.summary)")
            if feature.calls > 0 {
                lines.append(String(
                    format: "  %d calls · %d input tokens · about $%.4f this month",
                    feature.calls, feature.inputTokens, feature.estimatedUSD
                ))
            }
        }
        lines.append("")
        lines.append(
            "Only the state a feature needs is sent. The key stays in this Mac's Keychain and "
            + "is never returned by this API. Change any of this in Settings → TypeSafe (Jev)."
        )
        return lines.joined(separator: "\n")
    }

    static func describe(_ profile: ControlAPI.Profile) -> String {
        """
        \(profile.chip)
        - Unified memory: \(bytes(profile.totalMemoryBytes)) \
        (\(bytes(profile.modelBudgetBytes)) usable by a model)
        - Memory bandwidth: \(Int(profile.memoryBandwidthGBps)) GB/s — this is what caps \
        generation speed
        - CPU: \(profile.performanceCores) performance + \(profile.efficiencyCores) efficiency cores
        - GPU: \(profile.gpuCores) cores · Neural Engine: \(profile.neuralEngineCores) cores
        - Free disk: \(bytes(profile.diskFreeBytes))
        """
    }

    static func describe(_ metrics: ControlAPI.Metrics) -> String {
        """
        Memory: \(bytes(metrics.memoryUsedBytes)) used of \(bytes(metrics.memoryTotalBytes)) \
        (\(bytes(metrics.memoryWiredBytes)) wired, cannot be reclaimed)
        Swap: \(bytes(metrics.swapUsedBytes)) · Pressure: \(metrics.memoryPressure)
        GPU: \(Int(metrics.gpuUtilization * 100))% · CPU: \(Int(metrics.cpuUtilization * 100))%
        """
    }

    static func describe(_ status: ControlAPI.Status) -> String {
        guard let name = status.loadedModelName else {
            var line = "No language model loaded. State: \(status.state)"
            if let activity = status.activity {
                line += "\nWorking: \(activity)"
            }
            return line
        }
        var lines = ["Loaded: \(name)"]
        if let activity = status.activity {
            lines.append("Also working: \(activity)")
        }
        if let context = status.contextLength {
            lines.append("Context: \(context) tokens")
        }
        if status.expertStreaming {
            lines.append("Expert streaming: on (experts paged from disk)")
        }
        if let speed = status.lastGenerationTokensPerSecond, speed > 0 {
            lines.append(String(format: "Last measured: %.1f tok/s", speed))
        }
        lines.append("State: \(status.state)")
        return lines.joined(separator: "\n")
    }

    static func describe(_ plan: ControlAPI.Plan) -> String {
        var lines = [
            "Verdict: \(plan.verdict)",
            "Resident: \(bytes(plan.residentBytes)) of a \(bytes(plan.budgetBytes)) budget",
            "  Weights:         \(bytes(plan.weightsBytes))",
        ]
        if plan.expertsBytes > 0 {
            lines.append("  Experts:         \(bytes(plan.expertsBytes))")
        }
        lines.append("  KV cache:        \(bytes(plan.kvCacheBytes))")
        lines.append("  Compute buffers: \(bytes(plan.computeBytes))")
        if plan.streamedFromDiskBytes > 0 {
            lines.append("  Streamed from disk: \(bytes(plan.streamedFromDiskBytes))")
        }
        for note in plan.notes { lines.append("\nNote: \(note)") }
        if !plan.suggestions.isEmpty {
            lines.append("\nSuggestions:")
            for suggestion in plan.suggestions {
                lines.append(
                    "- \(suggestion.title) (saves \(bytes(suggestion.savingBytes)))"
                    + "\n  \(suggestion.detail)\n  Cost: \(suggestion.cost)"
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    static func imageRequest(_ arguments: [String: JSONValue]) -> ControlAPI.ImageRequest {
        ControlAPI.ImageRequest(
            prompt: arguments["prompt"]?.stringValue ?? "",
            modelID: arguments["model_id"]?.stringValue,
            width: arguments["width"]?.intValue,
            height: arguments["height"]?.intValue,
            steps: arguments["steps"]?.intValue,
            quantization: arguments["quantization"]?.stringValue,
            seed: arguments["seed"]?.intValue,
            initImagePath: arguments["init_image_path"]?.stringValue,
            initImageInfluence: arguments["init_image_influence"]?.doubleValue
        )
    }

    static func meshRequest(_ arguments: [String: JSONValue]) -> ControlAPI.MeshRequest {
        ControlAPI.MeshRequest(
            imagePath: arguments["image_path"]?.stringValue ?? "",
            modelID: arguments["model_id"]?.stringValue,
            pipelineType: arguments["pipeline_type"]?.stringValue,
            textureSize: arguments["texture_size"]?.intValue,
            steps: arguments["steps"]?.intValue,
            quantize: arguments["quantize"]?.intValue,
            octree: arguments["octree"]?.intValue,
            vertexBudget: arguments["vertex_budget"]?.intValue,
            seed: arguments["seed"]?.intValue
        )
    }

    static func describe(_ plan: ControlAPI.ImagePlan) -> String {
        var lines = [
            "\(plan.width)x\(plan.height) · \(plan.steps) steps · \(plan.quantization)",
            "Verdict: \(plan.verdict)",
            "Peak: \(bytes(plan.peakBytes)) during \(plan.peakPhase.lowercased()), "
                + "against a \(bytes(plan.budgetBytes)) budget",
            "",
            "Phases (they do not overlap — only the tallest matters):",
        ]
        for phase in plan.phases {
            let marker = phase.name == plan.peakPhase ? " <- peak" : ""
            lines.append("  \(phase.name.padding(toLength: 8, withPad: " ", startingAt: 0)) "
                + "\(bytes(phase.residentBytes))\(marker)")
            lines.append("           \(phase.detail)")
        }
        for note in plan.notes { lines.append("\nNote: \(note)") }
        if !plan.suggestions.isEmpty {
            lines.append("\nSuggestions:")
            for suggestion in plan.suggestions {
                lines.append("- \(suggestion.title) (saves \(bytes(suggestion.savingBytes)))"
                    + "\n  \(suggestion.detail)\n  Cost: \(suggestion.cost)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ result: ControlAPI.BenchmarkResult) -> String {
        var lines = [
            "\(result.modelName) — \(result.score)/100 (\(result.grade))",
            "",
            String(format: "Generation      %.1f tok/s", result.generationTokensPerSecond),
            String(format: "Prompt          %.0f tok/s", result.promptTokensPerSecond),
            String(format: "First token     %.2fs", result.timeToFirstToken),
            String(format: "Long-context    %.0f%% slower with a full cache",
                   result.longContextFalloff * 100),
            "",
            String(format: "Predicted %.0f tok/s, measured %.0f — estimates recalibrated by x%.2f",
                   result.predictedGenerationTokensPerSecond,
                   result.generationTokensPerSecond, result.calibration),
        ]
        if !result.findings.isEmpty {
            lines.append("")
            for finding in result.findings {
                let mark = finding.severity == "warning" ? "!"
                    : (finding.severity == "advice" ? "*" : "+")
                lines.append("\(mark) \(finding.title): \(finding.detail)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Everything a query-string value may carry unescaped.
    ///
    /// `.urlQueryAllowed` is the set legal in a whole query *string*, which includes `&`,
    /// `+` and `=` — so a task description containing one would arrive at the Mac as two
    /// parameters, or with its pluses read as spaces. Subtracted here rather than hoped
    /// about, because the value being escaped is a sentence a person typed.
    static let queryValueCharacters: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return allowed
    }()

    /// The answer to `recommend_model`. With a task, the top three and why each one is
    /// there, then the winner in full; without one, exactly what it printed before.
    static func describeRecommendation(_ model: ControlAPI.CatalogModel) -> String {
        guard let reason = model.reason else { return describe(model) }
        var lines = ["Best for this job:", "1. \(model.name) [\(model.id)] — \(reason)"]
        for (offset, alternative) in (model.alternatives ?? []).enumerated() {
            lines.append(
                "\(offset + 2). \(alternative.name) [\(alternative.id)]"
                + (alternative.reason.map { " — \($0)" } ?? "")
            )
        }
        // Why this list is this list, when that is not simply "Jev said so". An agent that
        // reads "ranked by how well they run here" knows not to quote the order as a
        // judgment about the models.
        if let note = model.note { lines.append("Note: \(note)") }
        lines.append("")
        lines.append(describe(model))
        return lines.joined(separator: "\n")
    }

    static func describe(_ model: ControlAPI.CatalogModel) -> String {
        var lines = [
            "\(model.name) — \(model.author), \(model.license)",
            model.summary,
            "\(model.parameters) parameters"
                + (model.activeParameters.map { " (\($0))" } ?? "")
                + (model.isMoE ? ", mixture-of-experts" : ", dense"),
            "Capabilities: \(model.capabilities.joined(separator: ", "))",
            "Catalog id: \(model.id)",
        ]
        if model.featured == true { lines.append("Featured pick.") }
        if let note = model.runtimeNote { lines.append("Runtime: \(note)") }
        if let recommendation = model.recommendation {
            lines.append("")
            lines.append("Recommended for this Mac:")
            lines.append("- \(recommendation.quantization) at \(recommendation.contextLength) context")
            if let slots = recommendation.expertSlots {
                lines.append("- Expert streaming with \(slots) resident experts")
            }
            lines.append(String(
                format: "- ~%.0f tok/s generation, ~%.0f tok/s prompt",
                recommendation.estimatedGenerationTokensPerSecond,
                recommendation.estimatedPromptTokensPerSecond
            ))
            lines.append("- Download: \(bytes(recommendation.downloadBytes))")
            lines.append("")
            lines.append(describe(recommendation.plan))
        } else {
            lines.append("\nThis model is too large to run on this Mac.")
        }
        return lines.joined(separator: "\n")
    }

    static func describeCatalog(_ models: [ControlAPI.CatalogModel]) -> String {
        guard !models.isEmpty else { return "No models matched." }
        return models.map { model in
            let fit = model.recommendation.map { recommendation in
                String(
                    format: "%@ · %@ context · ~%.0f tok/s · %@",
                    recommendation.quantization,
                    "\(recommendation.contextLength)",
                    recommendation.estimatedGenerationTokensPerSecond,
                    recommendation.plan.verdict
                )
            } ?? "too large for this Mac"
            return "- \(model.name) [\(model.id)]"
                + (model.featured == true ? " ★ featured" : "")
                + " — \(model.parameters)"
                + (model.isMoE ? " MoE" : "")
                + ", \(model.category)\n  \(fit)"
                + (model.runtimeNote.map { "\n  \($0)" } ?? "")
        }.joined(separator: "\n")
    }
}

/// `GET /jev/calibration`, remembered for a minute.
///
/// `get_status` is one of the cheapest tools here and agents call it in loops; adding an
/// unconditional second HTTP request to it would make "what is loaded?" twice as expensive
/// for a line most callers never read. A minute is long enough to cover a burst and short
/// enough that a calibration run started elsewhere shows up on its own. A 404 — the Mac has
/// never calibrated — is cached just as firmly, because that is the common case and the one
/// that would otherwise re-ask forever.
actor CalibrationCache {
    static let shared = CalibrationCache()

    static let lifetime: TimeInterval = 60

    private var value: ControlAPI.JevCalibration?
    private var readAt: Date?

    func current(from client: ControlClient) async -> ControlAPI.JevCalibration? {
        if let readAt, Date().timeIntervalSince(readAt) < Self.lifetime { return value }
        value = try? await client.get("/jev/calibration") as ControlAPI.JevCalibration
        readAt = Date()
        return value
    }

    func forget() {
        value = nil
        readAt = nil
    }
}

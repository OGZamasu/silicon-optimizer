import Foundation
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
                actual memory, bandwidth and current load.
                """,
            properties: [
                "category": property(
                    "string",
                    "Optional filter: General, Coding, Reasoning, Vision, Small & Fast, Embeddings."
                )
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
                "model_id": property("string", "e.g. flux1-schnell, flux2-klein-4b."),
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
                weights, which can take several minutes.
                """,
            properties: [
                "prompt": property("string", "What to draw."),
                "model_id": property("string", "Optional. Defaults to the best model that fits."),
                "width": property("number", "Image width in pixels."),
                "height": property("number", "Image height in pixels."),
                "steps": property("number", "Denoising steps. Distilled models need very few."),
                "quantization": property("string", "MLX-4bit, MLX-6bit or MLX-8bit."),
                "seed": property("number", "Optional seed for a reproducible image."),
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
            return try await describe(await client.get("/status") as ControlAPI.Status)

        case "recommend_model":
            var path = "/recommend"
            if let category = arguments["category"]?.stringValue,
               let escaped = category.addingPercentEncoding(
                   withAllowedCharacters: .urlQueryAllowed
               ) {
                path += "?category=\(escaped)"
            }
            return try await describe(await client.get(path) as ControlAPI.CatalogModel)

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
                modelID: modelID, quantization: arguments["quantization"]?.stringValue
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
            for value in arguments["image_paths"]?.arrayValue ?? [] {
                guard let path = value.stringValue else { continue }
                guard let dataURL = Self.dataURL(forImageAt: path) else {
                    throw ToolError.unreadableImage(path)
                }
                images.append(dataURL)
            }
            messages.append(.init(role: "user", content: prompt, images: images))

            let response: ControlAPI.ChatResponse = try await client.post("/chat", ControlAPI.ChatRequest(
                messages: messages,
                temperature: arguments["temperature"]?.doubleValue,
                maxTokens: arguments["max_tokens"]?.intValue
            ))
            let reasoning = response.reasoning ?? ""
            let footer = String(
                format: "\n\n---\n%d tokens at %.1f tok/s (local)",
                response.generatedTokens, response.tokensPerSecond
            )

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

        default:
            throw ToolError.unknown(name)
        }
    }

    enum ToolError: Error, LocalizedError {
        case missing(String)
        case unknown(String)
        case unreadableImage(String)

        var errorDescription: String? {
            switch self {
            case .missing(let field): "Required argument '\(field)' was not provided."
            case .unknown(let name): "Unknown tool '\(name)'."
            case .unreadableImage(let path):
                "Could not read an image at '\(path)'. Give an absolute path to a PNG or JPEG."
            }
        }
    }

    /// Inlines an image as a data URL, which is what the OpenAI vision schema expects.
    static func dataURL(forImageAt path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime: String
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        default: mime = "image/png"
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
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
            return "No model loaded. State: \(status.state)"
        }
        var lines = ["Loaded: \(name)"]
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
            seed: arguments["seed"]?.intValue
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
            return "- \(model.name) [\(model.id)] — \(model.parameters)"
                + (model.isMoE ? " MoE" : "")
                + ", \(model.category)\n  \(fit)"
        }.joined(separator: "\n")
    }
}

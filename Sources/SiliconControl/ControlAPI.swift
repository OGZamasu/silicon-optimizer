import Foundation

/// Wire types shared by the app's control server and its clients (the MCP bridge, scripts, or
/// anything else that wants to drive a loaded model).
///
/// These are deliberately separate from the domain types. The domain model is free to change
/// shape; this contract is what external tools depend on.
public enum ControlAPI {

    /// Where the running app publishes its endpoint and token, so a client can find it without
    /// configuration. Written on launch, removed on quit.
    public static var handshakeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SiliconOptimizer/control.json")
    }

    public struct Handshake: Codable, Sendable {
        public var port: Int
        /// Process id of the app that wrote this file. A crash or a SIGTERM leaves the file
        /// behind, and the port can eventually be recycled by something else — checking the
        /// pid turns a confusing failure into an accurate "the app is not running".
        public var pid: Int32?
        /// Bearer token. The listener is bound to 127.0.0.1, but any local process could still
        /// reach it, and driving someone's model is not something a random process should be
        /// able to do silently.
        public var token: String
        public var version: String

        public init(port: Int, pid: Int32? = nil, token: String, version: String) {
            self.port = port
            self.pid = pid
            self.token = token
            self.version = version
        }
    }

    // MARK: - Responses

    public struct Profile: Codable, Sendable {
        public var chip: String
        public var generation: String
        public var totalMemoryBytes: Int64
        public var modelBudgetBytes: Int64
        public var performanceCores: Int
        public var efficiencyCores: Int
        public var gpuCores: Int
        public var neuralEngineCores: Int
        public var memoryBandwidthGBps: Double
        public var diskFreeBytes: Int64

        public init(
            chip: String, generation: String, totalMemoryBytes: Int64, modelBudgetBytes: Int64,
            performanceCores: Int, efficiencyCores: Int, gpuCores: Int, neuralEngineCores: Int,
            memoryBandwidthGBps: Double, diskFreeBytes: Int64
        ) {
            self.chip = chip
            self.generation = generation
            self.totalMemoryBytes = totalMemoryBytes
            self.modelBudgetBytes = modelBudgetBytes
            self.performanceCores = performanceCores
            self.efficiencyCores = efficiencyCores
            self.gpuCores = gpuCores
            self.neuralEngineCores = neuralEngineCores
            self.memoryBandwidthGBps = memoryBandwidthGBps
            self.diskFreeBytes = diskFreeBytes
        }
    }

    public struct Metrics: Codable, Sendable {
        public var memoryUsedBytes: Int64
        public var memoryWiredBytes: Int64
        public var memoryTotalBytes: Int64
        public var swapUsedBytes: Int64
        public var gpuUtilization: Double
        public var cpuUtilization: Double
        public var memoryPressure: String

        public init(
            memoryUsedBytes: Int64, memoryWiredBytes: Int64, memoryTotalBytes: Int64,
            swapUsedBytes: Int64, gpuUtilization: Double, cpuUtilization: Double,
            memoryPressure: String
        ) {
            self.memoryUsedBytes = memoryUsedBytes
            self.memoryWiredBytes = memoryWiredBytes
            self.memoryTotalBytes = memoryTotalBytes
            self.swapUsedBytes = swapUsedBytes
            self.gpuUtilization = gpuUtilization
            self.cpuUtilization = cpuUtilization
            self.memoryPressure = memoryPressure
        }
    }

    public struct CatalogModel: Codable, Sendable {
        public var id: String
        public var name: String
        public var author: String
        public var license: String
        public var summary: String
        public var category: String
        public var parameters: String
        public var activeParameters: String?
        public var isMoE: Bool
        public var capabilities: [String]
        public var rating: Int
        public var maxContext: Int
        public var quantizations: [String]
        /// Whether this Mac can run it, and how.
        public var recommendation: Recommendation?
        /// Editorial spotlight. Optional on the wire so an older app still decodes.
        public var featured: Bool?
        /// Set when the entry needs a runtime the app has to check for (a fork, say) —
        /// whether it is present, and what to do if not.
        public var runtimeNote: String?
        /// Why this model was picked for the job the caller described — "needs vision and
        /// tool calling; fits at Q4_K_M at ~28 tok/s". Only `POST /recommend` fills it in,
        /// and only when Jev's model recommendation is enabled; `/catalog` and a plain
        /// `GET /recommend` never do. Optional on the wire, so an older client decodes a
        /// newer app's answer.
        public var reason: String?
        /// What the caller should know about the ranking itself rather than about this
        /// model: that the order is hardware fit because Jev could not separate the
        /// shortlist, that Jev preferred something the weights demoted, that nothing on
        /// the list met a requirement, that the description was trimmed before it was sent.
        ///
        /// Kept apart from `reason` so a client can show one without the other: `reason` is
        /// a caption under a model's name, `note` is a line about the whole answer.
        public var note: String?
        /// Whether the order is the one Jev's judgment produced. False when hardware fit
        /// did the ordering instead; absent when nothing was asked.
        public var followedJev: Bool?
        /// The rest of the top three for that job, best first, each with its own `reason`
        /// and no `alternatives` of its own. Absent rather than empty when there was no
        /// task to rank against.
        public var alternatives: [CatalogModel]?

        public init(
            id: String, name: String, author: String, license: String, summary: String,
            category: String, parameters: String, activeParameters: String?, isMoE: Bool,
            capabilities: [String], rating: Int, maxContext: Int, quantizations: [String],
            recommendation: Recommendation?, featured: Bool? = nil, runtimeNote: String? = nil,
            reason: String? = nil, note: String? = nil, followedJev: Bool? = nil,
            alternatives: [CatalogModel]? = nil
        ) {
            self.id = id
            self.name = name
            self.author = author
            self.license = license
            self.summary = summary
            self.category = category
            self.parameters = parameters
            self.activeParameters = activeParameters
            self.isMoE = isMoE
            self.capabilities = capabilities
            self.rating = rating
            self.maxContext = maxContext
            self.quantizations = quantizations
            self.recommendation = recommendation
            self.featured = featured
            self.runtimeNote = runtimeNote
            self.reason = reason
            self.note = note
            self.followedJev = followedJev
            self.alternatives = alternatives
        }
    }

    /// `POST /recommend`: which model should do *this* job.
    ///
    /// A POST rather than a query parameter, and this is not style. The description is
    /// somebody's prose about their own work; a URL is the one part of a request that ends
    /// up in a shell history, a proxy log and an `/events` line, and it is also the part a
    /// caller is most likely to paste somewhere. A body is read once and kept nowhere. It
    /// is also the honest shape for what this route now is: `GET /recommend` reads and
    /// advises and spends nothing, while ranking against a task spends the owner's money,
    /// so the two want different verbs and different scopes.
    public struct RecommendRequest: Codable, Sendable {
        /// The same filter `GET /recommend` takes: General, Coding, Reasoning, Vision,
        /// Small & Fast, Embeddings. Absent means everything but embeddings.
        public var category: String?
        /// What the model is actually for, in the owner's own words.
        public var task: String

        public init(category: String? = nil, task: String) {
            self.category = category
            self.task = task
        }
    }

    public struct Recommendation: Codable, Sendable {
        public var quantization: String
        public var contextLength: Int
        public var expertSlots: Int?
        public var estimatedGenerationTokensPerSecond: Double
        public var estimatedPromptTokensPerSecond: Double
        public var downloadBytes: Int64
        public var plan: Plan
        public var rationale: String

        public init(
            quantization: String, contextLength: Int, expertSlots: Int?,
            estimatedGenerationTokensPerSecond: Double, estimatedPromptTokensPerSecond: Double,
            downloadBytes: Int64, plan: Plan, rationale: String
        ) {
            self.quantization = quantization
            self.contextLength = contextLength
            self.expertSlots = expertSlots
            self.estimatedGenerationTokensPerSecond = estimatedGenerationTokensPerSecond
            self.estimatedPromptTokensPerSecond = estimatedPromptTokensPerSecond
            self.downloadBytes = downloadBytes
            self.plan = plan
            self.rationale = rationale
        }
    }

    public struct Plan: Codable, Sendable {
        public var verdict: String
        public var residentBytes: Int64
        public var budgetBytes: Int64
        public var weightsBytes: Int64
        public var expertsBytes: Int64
        public var kvCacheBytes: Int64
        public var computeBytes: Int64
        public var streamedFromDiskBytes: Int64
        public var suggestions: [Suggestion]
        public var notes: [String]

        public init(
            verdict: String, residentBytes: Int64, budgetBytes: Int64, weightsBytes: Int64,
            expertsBytes: Int64, kvCacheBytes: Int64, computeBytes: Int64,
            streamedFromDiskBytes: Int64, suggestions: [Suggestion], notes: [String]
        ) {
            self.verdict = verdict
            self.residentBytes = residentBytes
            self.budgetBytes = budgetBytes
            self.weightsBytes = weightsBytes
            self.expertsBytes = expertsBytes
            self.kvCacheBytes = kvCacheBytes
            self.computeBytes = computeBytes
            self.streamedFromDiskBytes = streamedFromDiskBytes
            self.suggestions = suggestions
            self.notes = notes
        }
    }

    public struct Suggestion: Codable, Sendable {
        public var title: String
        public var detail: String
        public var savingBytes: Int64
        public var cost: String

        public init(title: String, detail: String, savingBytes: Int64, cost: String) {
            self.title = title
            self.detail = detail
            self.savingBytes = savingBytes
            self.cost = cost
        }
    }

    public struct InstalledModel: Codable, Sendable {
        public var id: String
        public var name: String
        public var quantization: String
        public var sizeOnDiskBytes: Int64
        public var isLoaded: Bool
        public var supportsVision: Bool

        public init(
            id: String, name: String, quantization: String, sizeOnDiskBytes: Int64,
            isLoaded: Bool, supportsVision: Bool
        ) {
            self.id = id
            self.name = name
            self.quantization = quantization
            self.sizeOnDiskBytes = sizeOnDiskBytes
            self.isLoaded = isLoaded
            self.supportsVision = supportsVision
        }
    }

    public struct Status: Codable, Sendable {
        public var state: String
        public var loadedModelID: String?
        public var loadedModelName: String?
        public var contextLength: Int?
        public var expertStreaming: Bool
        public var lastGenerationTokensPerSecond: Double?
        /// A non-language model at work right now — an image render or a 3D generation.
        /// Those are models too, and "nothing loaded" while one is running would be false.
        public var activity: String?

        public init(
            state: String, loadedModelID: String?, loadedModelName: String?,
            contextLength: Int?, expertStreaming: Bool,
            lastGenerationTokensPerSecond: Double?,
            activity: String? = nil
        ) {
            self.state = state
            self.loadedModelID = loadedModelID
            self.loadedModelName = loadedModelName
            self.contextLength = contextLength
            self.expertStreaming = expertStreaming
            self.lastGenerationTokensPerSecond = lastGenerationTokensPerSecond
            self.activity = activity
        }
    }

    // MARK: - Requests

    public struct PlanRequest: Codable, Sendable {
        public var modelID: String
        public var quantization: String?
        public var contextLength: Int?
        public var kvCachePrecision: String?
        public var flashAttention: Bool?
        public var expertSlots: Int?

        public init(
            modelID: String, quantization: String? = nil, contextLength: Int? = nil,
            kvCachePrecision: String? = nil, flashAttention: Bool? = nil,
            expertSlots: Int? = nil
        ) {
            self.modelID = modelID
            self.quantization = quantization
            self.contextLength = contextLength
            self.kvCachePrecision = kvCachePrecision
            self.flashAttention = flashAttention
            self.expertSlots = expertSlots
        }
    }

    public struct LoadRequest: Codable, Sendable {
        /// Either an installed model id, or a catalog id plus quantization.
        public var modelID: String
        public var quantization: String?
        public var contextLength: Int?
        public var expertSlots: Int?
        /// Installs only: an absolute folder to download into — an external volume, say —
        /// instead of the library on the startup volume. Optional on the wire, so an older
        /// MCP binary in the bundle still talks to a newer app.
        public var directory: String?

        public init(
            modelID: String, quantization: String? = nil,
            contextLength: Int? = nil, expertSlots: Int? = nil, directory: String? = nil
        ) {
            self.modelID = modelID
            self.quantization = quantization
            self.contextLength = contextLength
            self.expertSlots = expertSlots
            self.directory = directory
        }
    }

    public struct ChatRequest: Codable, Sendable {
        public struct Message: Codable, Sendable {
            public var role: String
            public var content: String
            /// Base64 `data:` URLs. Only meaningful for vision models.
            public var images: [String]

            public init(role: String, content: String, images: [String] = []) {
                self.role = role
                self.content = content
                self.images = images
            }
        }
        public var messages: [Message]
        public var temperature: Double?
        public var maxTokens: Int?

        public init(messages: [Message], temperature: Double? = nil, maxTokens: Int? = nil) {
            self.messages = messages
            self.temperature = temperature
            self.maxTokens = maxTokens
        }
    }

    public struct ChatResponse: Codable, Sendable {
        public var content: String
        public var reasoning: String?
        public var promptTokens: Int
        public var generatedTokens: Int
        public var tokensPerSecond: Double

        public init(
            content: String, reasoning: String?, promptTokens: Int,
            generatedTokens: Int, tokensPerSecond: Double
        ) {
            self.content = content
            self.reasoning = reasoning
            self.promptTokens = promptTokens
            self.generatedTokens = generatedTokens
            self.tokensPerSecond = tokensPerSecond
        }
    }

    public struct BenchmarkResult: Codable, Sendable {
        public var modelName: String
        public var score: Int
        public var grade: String
        public var generationTokensPerSecond: Double
        public var promptTokensPerSecond: Double
        public var timeToFirstToken: Double
        public var longContextFalloff: Double
        public var predictedGenerationTokensPerSecond: Double
        public var calibration: Double
        public var findings: [Finding]

        public struct Finding: Codable, Sendable {
            public var title: String
            public var detail: String
            public var severity: String
            public init(title: String, detail: String, severity: String) {
                self.title = title
                self.detail = detail
                self.severity = severity
            }
        }

        public init(
            modelName: String, score: Int, grade: String,
            generationTokensPerSecond: Double, promptTokensPerSecond: Double,
            timeToFirstToken: Double, longContextFalloff: Double,
            predictedGenerationTokensPerSecond: Double, calibration: Double,
            findings: [Finding]
        ) {
            self.modelName = modelName
            self.score = score
            self.grade = grade
            self.generationTokensPerSecond = generationTokensPerSecond
            self.promptTokensPerSecond = promptTokensPerSecond
            self.timeToFirstToken = timeToFirstToken
            self.longContextFalloff = longContextFalloff
            self.predictedGenerationTokensPerSecond = predictedGenerationTokensPerSecond
            self.calibration = calibration
            self.findings = findings
        }
    }

    public struct ImageModel: Codable, Sendable {
        public var id: String
        public var name: String
        public var author: String
        public var license: String
        public var summary: String
        public var parameters: String
        public var blocks: Int
        public var defaultSteps: Int
        public var isGated: Bool
        public var recommendation: ImagePlan?

        public init(
            id: String, name: String, author: String, license: String, summary: String,
            parameters: String, blocks: Int, defaultSteps: Int, isGated: Bool,
            recommendation: ImagePlan?
        ) {
            self.id = id
            self.name = name
            self.author = author
            self.license = license
            self.summary = summary
            self.parameters = parameters
            self.blocks = blocks
            self.defaultSteps = defaultSteps
            self.isGated = isGated
            self.recommendation = recommendation
        }
    }

    /// A diffusion memory plan. Phased rather than a single total, because the stages release
    /// each other's memory and only the tallest one decides whether generation succeeds.
    public struct ImagePlan: Codable, Sendable {
        public var width: Int
        public var height: Int
        public var steps: Int
        public var quantization: String
        public var peakBytes: Int64
        public var peakPhase: String
        public var budgetBytes: Int64
        public var verdict: String
        public var phases: [Phase]
        public var suggestions: [Suggestion]
        public var notes: [String]

        public struct Phase: Codable, Sendable {
            public var name: String
            public var detail: String
            public var residentBytes: Int64
            public init(name: String, detail: String, residentBytes: Int64) {
                self.name = name
                self.detail = detail
                self.residentBytes = residentBytes
            }
        }

        public init(
            width: Int, height: Int, steps: Int, quantization: String,
            peakBytes: Int64, peakPhase: String, budgetBytes: Int64, verdict: String,
            phases: [Phase], suggestions: [Suggestion], notes: [String]
        ) {
            self.width = width
            self.height = height
            self.steps = steps
            self.quantization = quantization
            self.peakBytes = peakBytes
            self.peakPhase = peakPhase
            self.budgetBytes = budgetBytes
            self.verdict = verdict
            self.phases = phases
            self.suggestions = suggestions
            self.notes = notes
        }
    }

    public struct ImageRequest: Codable, Sendable {
        public var prompt: String
        public var modelID: String?
        public var width: Int?
        public var height: Int?
        public var steps: Int?
        public var quantization: String?
        public var seed: Int?
        /// Enforced routing capability: true forbids handing the prompt or source image to
        /// a paired node even when remote rendering is otherwise configured.
        public var localOnly: Bool?
        /// Revision: path to an existing image to start from instead of noise.
        public var initImagePath: String?
        /// How strongly that image steers the result, 0–1 (mflux influence semantics).
        public var initImageInfluence: Double?

        public init(
            prompt: String, modelID: String? = nil, width: Int? = nil, height: Int? = nil,
            steps: Int? = nil, quantization: String? = nil, seed: Int? = nil,
            initImagePath: String? = nil, initImageInfluence: Double? = nil,
            localOnly: Bool? = nil
        ) {
            self.prompt = prompt
            self.modelID = modelID
            self.width = width
            self.height = height
            self.steps = steps
            self.quantization = quantization
            self.seed = seed
            self.localOnly = localOnly
            self.initImagePath = initImagePath
            self.initImageInfluence = initImageInfluence
        }
    }

    public struct ImageResponse: Codable, Sendable {
        public var path: String
        public var elapsedSeconds: Double
        public var peakMemoryBytes: Int64?
        public var predictedPeakBytes: Int64
        public var model: String
        /// Set when the plan predicted this configuration would not comfortably fit. The run was
        /// attempted anyway; this explains what to expect (swapping, slowdown, or possible
        /// failure) rather than having refused before trying.
        public var warning: String?

        public init(
            path: String, elapsedSeconds: Double, peakMemoryBytes: Int64?,
            predictedPeakBytes: Int64, model: String, warning: String? = nil
        ) {
            self.path = path
            self.elapsedSeconds = elapsedSeconds
            self.peakMemoryBytes = peakMemoryBytes
            self.predictedPeakBytes = predictedPeakBytes
            self.model = model
            self.warning = warning
        }
    }

    public struct MeshModel: Codable, Sendable {
        public var id: String
        public var name: String
        public var author: String
        public var summary: String
        public var outputs: String
        public var typicalDuration: String
        public var peakBytes: Int64
        public var weightsBytes: Int64
        public var isInstalled: Bool
        public var installDetail: String

        public init(
            id: String, name: String, author: String, summary: String, outputs: String,
            typicalDuration: String, peakBytes: Int64, weightsBytes: Int64,
            isInstalled: Bool, installDetail: String
        ) {
            self.id = id
            self.name = name
            self.author = author
            self.summary = summary
            self.outputs = outputs
            self.typicalDuration = typicalDuration
            self.peakBytes = peakBytes
            self.weightsBytes = weightsBytes
            self.isInstalled = isInstalled
            self.installDetail = installDetail
        }
    }

    public struct MeshPlan: Codable, Sendable {
        public var model: String
        public var peakBytes: Int64
        public var peakPhase: String
        public var budgetBytes: Int64
        public var verdict: String
        public var isRemote: Bool
        public var phases: [ImagePlan.Phase]
        public var suggestions: [Suggestion]
        public var notes: [String]

        public init(
            model: String, peakBytes: Int64, peakPhase: String, budgetBytes: Int64,
            verdict: String, isRemote: Bool, phases: [ImagePlan.Phase],
            suggestions: [Suggestion], notes: [String]
        ) {
            self.model = model
            self.peakBytes = peakBytes
            self.peakPhase = peakPhase
            self.budgetBytes = budgetBytes
            self.verdict = verdict
            self.isRemote = isRemote
            self.phases = phases
            self.suggestions = suggestions
            self.notes = notes
        }
    }

    public struct MeshRequest: Codable, Sendable {
        /// Path to the conditioning image on this machine.
        public var imagePath: String
        public var modelID: String?
        public var pipelineType: String?
        public var textureSize: Int?
        public var steps: Int?
        public var quantize: Int?
        public var octree: Int?
        public var vertexBudget: Int?
        public var seed: Int?

        public init(
            imagePath: String, modelID: String? = nil, pipelineType: String? = nil,
            textureSize: Int? = nil, steps: Int? = nil, quantize: Int? = nil,
            octree: Int? = nil, vertexBudget: Int? = nil, seed: Int? = nil
        ) {
            self.imagePath = imagePath
            self.modelID = modelID
            self.pipelineType = pipelineType
            self.textureSize = textureSize
            self.steps = steps
            self.quantize = quantize
            self.octree = octree
            self.vertexBudget = vertexBudget
            self.seed = seed
        }
    }

    public struct MeshResponse: Codable, Sendable {
        public var glbPath: String?
        public var objPath: String?
        public var elapsedSeconds: Double
        public var model: String
        public var warning: String?

        public init(
            glbPath: String?, objPath: String?, elapsedSeconds: Double, model: String,
            warning: String? = nil
        ) {
            self.glbPath = glbPath
            self.objPath = objPath
            self.elapsedSeconds = elapsedSeconds
            self.model = model
            self.warning = warning
        }
    }

    /// One video model, with whether any model-aware node can serve it right now. That
    /// node may be remote or a loopback adapter, but it must advertise this exact model.
    public struct VideoModel: Codable, Sendable {
        public var id: String
        public var name: String
        public var summary: String
        public var typicalDuration: String
        public var supportsImageInput: Bool
        public var supportedSeconds: [Int]
        public var available: Bool
        /// The node that would run it, when one is ready.
        public var node: String?

        /// Optional renderer controls; absent on older nodes.
        public var supportedParameters: [String]?

        public init(
            id: String, name: String, summary: String, typicalDuration: String,
            supportsImageInput: Bool, supportedSeconds: [Int], available: Bool,
            node: String?, supportedParameters: [String]? = nil
        ) {
            self.id = id
            self.name = name
            self.summary = summary
            self.typicalDuration = typicalDuration
            self.supportsImageInput = supportsImageInput
            self.supportedSeconds = supportedSeconds
            self.available = available
            self.node = node
            self.supportedParameters = supportedParameters
        }
    }

    public struct VideoGenerateRequest: Codable, Sendable {
        /// The wire-level duration contract shared by the app UI and MCP bridge. Nodes may
        /// offer fewer choices, but callers never send a value outside this range.
        public static let minimumSeconds = 1
        public static let maximumSeconds = 15
        public static let pickerSeconds = [3, 5, 8, 10, 15]

        public static func clampedSeconds(_ seconds: Int) -> Int {
            max(minimumSeconds, min(maximumSeconds, seconds))
        }

        public var prompt: String
        public var modelID: String?
        public var seconds: Int?
        public var resolution: String?
        /// Optional still to animate (image-to-video), as an absolute path.
        public var imagePath: String?
        /// Optional prompt for each five-second H3 window, in temporal order.
        public var h3ChainPrompts: [String]?
        public var seed: UInt32?
        public var h3Turbo: Bool?
        /// Optional H3 sigma-point count (4–30); requires explicit Full sampling.
        public var h3Steps: Int?

        enum CodingKeys: String, CodingKey {
            case prompt, modelID, seconds, resolution, imagePath, seed
            case h3ChainPrompts = "h3_chain_prompts"
            case h3Turbo = "h3_turbo"
            case h3Steps = "h3_steps"
        }

        public enum ValidationError: LocalizedError {
            case invalidChainPrompts(String)
            public var errorDescription: String? {
                switch self { case .invalidChainPrompts(let message): message }
            }
        }

        public static func validateSampling(h3Turbo: Bool?, h3Steps: Int? = nil, modelID: String) throws {
            if h3Turbo != nil, modelID != "hailuo-h3" {
                throw ValidationError.invalidChainPrompts("h3_turbo is only supported for hailuo-h3.")
            }
            if let h3Steps {
                guard modelID == "hailuo-h3", (4...30).contains(h3Steps) else {
                    throw ValidationError.invalidChainPrompts("h3_steps must be an integer from 4 through 30, only for hailuo-h3. Omit it for Auto.")
                }
                guard h3Turbo == false else {
                    throw ValidationError.invalidChainPrompts("h3_steps requires h3_turbo: false (Full sampling). Turbo pins its own schedule.")
                }
            }
        }

        /// Validate after resolving the app's current model and duration defaults.
        /// The runtime uses the same check for callers that do not use the control API.
        public static func validatedH3ChainPrompts(
            _ prompts: [String]?, modelID: String, seconds: Int
        ) throws -> [String]? {
            guard let prompts else { return nil }
            guard modelID == "hailuo-h3", seconds == 10 || seconds == 15 else {
                throw ValidationError.invalidChainPrompts(
                    "h3_chain_prompts is only supported for hailuo-h3 at 10 or 15 seconds."
                )
            }
            let trimmed = prompts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard trimmed.count == seconds / 5,
                  trimmed.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.count <= 4000 }) else {
                throw ValidationError.invalidChainPrompts(
                    "h3_chain_prompts requires exactly \(seconds / 5) nonempty prompts, "
                    + "each at most 4000 characters."
                )
            }
            return trimmed
        }

        public init(
            prompt: String, modelID: String? = nil, seconds: Int? = nil,
            resolution: String? = nil, imagePath: String? = nil,
            h3ChainPrompts: [String]? = nil, seed: UInt32? = nil, h3Turbo: Bool? = nil,
            h3Steps: Int? = nil
        ) {
            self.prompt = prompt
            self.modelID = modelID
            self.seconds = seconds
            self.resolution = resolution
            self.imagePath = imagePath
            self.h3ChainPrompts = h3ChainPrompts
            self.seed = seed
            self.h3Turbo = h3Turbo
            self.h3Steps = h3Steps
        }
    }

    public struct VideoResponse: Codable, Sendable {
        public var file: String
        public var node: String
        public var model: String
        public var elapsedSeconds: Double
        /// How the model and the settings were arrived at, when nobody typed them: the
        /// media router's one line. Absent when the caller named what it wanted — and the
        /// reason a caller that passed `model_id: "auto"` can find out what it got.
        public var detail: String?

        public init(
            file: String, node: String, model: String, elapsedSeconds: Double,
            detail: String? = nil
        ) {
            self.file = file
            self.node = node
            self.model = model
            self.elapsedSeconds = elapsedSeconds
            self.detail = detail
        }
    }

    public struct ErrorResponse: Codable, Sendable {
        public var error: String
        public init(error: String) { self.error = error }
    }
}

/// What the app must provide for the control server to answer requests.
extension ControlAPI {
    /// One peer as this app currently sees it — what the swarm card shows, in a form
    /// a script or an MCP client can read. Exists because "the node advertises it"
    /// and "this app sees it" are different claims, and only the second one decides
    /// whether a button is enabled.
    public struct SwarmView: Codable, Sendable {
        public struct Peer: Codable, Sendable {
            public var name: String
            public var baseURL: String
            public var reachable: Bool
            public var error: String?
            public var capabilities: [Capability]

            public init(
                name: String, baseURL: String, reachable: Bool,
                error: String?, capabilities: [Capability]
            ) {
                self.name = name
                self.baseURL = baseURL
                self.reachable = reachable
                self.error = error
                self.capabilities = capabilities
            }
        }

        public struct Capability: Codable, Sendable {
            public var id: String
            public var kind: String
            public var ready: Bool

            public init(id: String, kind: String, ready: Bool) {
                self.id = id
                self.kind = kind
                self.ready = ready
            }
        }

        /// Whether this Mac's peers can reach *it*, which is the other half of the
        /// swarm and used to be invisible from here: a node that cannot call back
        /// looks like a node that is down, and the reason is usually tailscale.
        public struct Exposure: Codable, Sendable, Equatable {
            /// The owner asked for the swarm to reach this Mac, and there is a swarm
            /// token for it to authenticate with.
            public var requested: Bool
            /// The tailnet listener is actually up.
            public var listening: Bool
            /// This Mac's tailscale address and the port peers dial there.
            public var address: String?
            public var port: Int?
            /// Why it is not up, when it was asked for and could not be — almost always
            /// "join the tailnet first".
            public var problem: String?

            public init(
                requested: Bool, listening: Bool, address: String? = nil,
                port: Int? = nil, problem: String? = nil
            ) {
                self.requested = requested
                self.listening = listening
                self.address = address
                self.port = port
                self.problem = problem
            }
        }

        public var peers: [Peer]
        /// When the app last polled, in seconds ago — a stale view is the failure
        /// this endpoint exists to expose.
        public var polledSecondsAgo: Double?
        /// How this Mac is reachable by its peers. Nil only from a host that has no
        /// control server to ask.
        public var exposure: Exposure?

        public init(peers: [Peer], polledSecondsAgo: Double?, exposure: Exposure? = nil) {
            self.peers = peers
            self.polledSecondsAgo = polledSecondsAgo
            self.exposure = exposure
        }
    }
}

public protocol ControlHost: AnyObject, Sendable {
    func swarm() async -> ControlAPI.SwarmView
    func profile() async -> ControlAPI.Profile
    func metrics() async -> ControlAPI.Metrics
    func status() async -> ControlAPI.Status
    func catalog(category: String?, onlyRunnable: Bool) async -> [ControlAPI.CatalogModel]
    func installed() async -> [ControlAPI.InstalledModel]
    /// `GET /recommend`. With `task`, the strongest model for that job — Jev judges what
    /// the job needs and code combines it with hardware fit. Without one, the strongest
    /// model this machine can run, which is what this route has always answered.
    func recommend(category: String?, task: String?) async -> ControlAPI.CatalogModel?
    func plan(_ request: ControlAPI.PlanRequest) async throws -> ControlAPI.Plan
    func install(_ request: ControlAPI.LoadRequest) async throws -> String
    func load(_ request: ControlAPI.LoadRequest) async throws -> ControlAPI.Status
    func unload() async
    func chat(_ request: ControlAPI.ChatRequest) async throws -> ControlAPI.ChatResponse
    /// Typed probabilistic decisions: `POST /decide`, also at `/v1/systemone`.
    func decide(_ request: ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse
    /// How the Jev integration is set up, what it would answer, and what it has cost:
    /// `GET /jev`. Never carries the API key.
    func jevStatus() async -> ControlAPI.JevStatus
    /// `POST /jev`. The server lets only the control token reach this — changing what the
    /// Mac spends is the owner's own business, not a paired phone's.
    func updateJev(_ update: ControlAPI.JevUpdate) async throws -> ControlAPI.JevStatus
    /// The last screenings the tool-call guardrail made: `GET /jev/guardrails/recent`.
    /// Question ids, bands and verdicts — never what was screened.
    func recentGuardrailScreenings() async -> ControlAPI.GuardrailScreenings
    func benchmark() async throws -> ControlAPI.BenchmarkResult
    func imageModels() async -> [ControlAPI.ImageModel]
    func planImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImagePlan
    func generateImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImageResponse
    func meshModels() async -> [ControlAPI.MeshModel]
    func planMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshPlan
    func generateMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshResponse
    func videoModels() async -> [ControlAPI.VideoModel]
    func videoQueue() async -> ControlAPI.VideoQueueView
    func enqueueVideos(_ request: ControlAPI.VideoQueueRequest) async throws -> ControlAPI.VideoQueueView
    func controlVideoQueue(_ request: ControlAPI.VideoQueueControl) async throws -> ControlAPI.VideoQueueView
    func generateVideo(
        _ request: ControlAPI.VideoGenerateRequest
    ) async throws -> ControlAPI.VideoResponse
    func nodeAdvertisement() async -> ControlAPI.NodeAdvertisement

    // MARK: Silicon Buddy

    /// The same request as `chat`, delivered token by token. Cancelling the consumer must
    /// stop the generation: a phone that walks out of range should not leave a model
    /// talking to itself for another two minutes.
    func chatStream(
        _ request: ControlAPI.ChatRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error>
    /// Named `conversationList` rather than `conversations` because the Mac's host already
    /// has a stored property by that name.
    func conversationList() async -> [ControlAPI.ConversationSummary]
    func createConversation(title: String?) async -> ControlAPI.ConversationSummary
    func conversation(id: String) async throws -> ControlAPI.ConversationDetail
    /// Appends the user's message, then streams the answer — persisting both, so the
    /// exchange appears in the Mac's own chat window as it happens.
    func replyInConversation(
        id: String, to message: ControlAPI.NewMessageRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error>
    /// Called when an `/events` stream opens, so a host only pays for watching its own
    /// state while somebody is reading it. The hub is the server's own, which is what lets
    /// a test drive a real state change onto a real socket.
    func beginEventUpdates(postingTo hub: BuddyEventHub) async
}

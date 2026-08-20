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

        public init(
            id: String, name: String, author: String, license: String, summary: String,
            category: String, parameters: String, activeParameters: String?, isMoE: Bool,
            capabilities: [String], rating: Int, maxContext: Int, quantizations: [String],
            recommendation: Recommendation?
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

        public init(
            modelID: String, quantization: String? = nil,
            contextLength: Int? = nil, expertSlots: Int? = nil
        ) {
            self.modelID = modelID
            self.quantization = quantization
            self.contextLength = contextLength
            self.expertSlots = expertSlots
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
        /// Revision: path to an existing image to start from instead of noise.
        public var initImagePath: String?
        /// How strongly that image steers the result, 0–1 (mflux influence semantics).
        public var initImageInfluence: Double?

        public init(
            prompt: String, modelID: String? = nil, width: Int? = nil, height: Int? = nil,
            steps: Int? = nil, quantization: String? = nil, seed: Int? = nil,
            initImagePath: String? = nil, initImageInfluence: Double? = nil
        ) {
            self.prompt = prompt
            self.modelID = modelID
            self.width = width
            self.height = height
            self.steps = steps
            self.quantization = quantization
            self.seed = seed
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

    /// One video model, with whether any swarm node can serve it right now. Video is the
    /// one capability with no local backend, so availability is a claim about the swarm.
    public struct VideoModel: Codable, Sendable {
        public var id: String
        public var name: String
        public var summary: String
        public var typicalDuration: String
        public var supportsImageInput: Bool
        public var available: Bool
        /// The node that would run it, when one is ready.
        public var node: String?

        public init(
            id: String, name: String, summary: String, typicalDuration: String,
            supportsImageInput: Bool, available: Bool, node: String?
        ) {
            self.id = id
            self.name = name
            self.summary = summary
            self.typicalDuration = typicalDuration
            self.supportsImageInput = supportsImageInput
            self.available = available
            self.node = node
        }
    }

    public struct VideoGenerateRequest: Codable, Sendable {
        public var prompt: String
        public var modelID: String?
        public var seconds: Int?
        public var resolution: String?
        /// Optional still to animate (image-to-video), as an absolute path.
        public var imagePath: String?

        public init(
            prompt: String, modelID: String? = nil, seconds: Int? = nil,
            resolution: String? = nil, imagePath: String? = nil
        ) {
            self.prompt = prompt
            self.modelID = modelID
            self.seconds = seconds
            self.resolution = resolution
            self.imagePath = imagePath
        }
    }

    public struct VideoResponse: Codable, Sendable {
        public var file: String
        public var node: String
        public var model: String
        public var elapsedSeconds: Double

        public init(file: String, node: String, model: String, elapsedSeconds: Double) {
            self.file = file
            self.node = node
            self.model = model
            self.elapsedSeconds = elapsedSeconds
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

        public var peers: [Peer]
        /// When the app last polled, in seconds ago — a stale view is the failure
        /// this endpoint exists to expose.
        public var polledSecondsAgo: Double?

        public init(peers: [Peer], polledSecondsAgo: Double?) {
            self.peers = peers
            self.polledSecondsAgo = polledSecondsAgo
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
    func recommend(category: String?) async -> ControlAPI.CatalogModel?
    func plan(_ request: ControlAPI.PlanRequest) async throws -> ControlAPI.Plan
    func install(_ request: ControlAPI.LoadRequest) async throws -> String
    func load(_ request: ControlAPI.LoadRequest) async throws -> ControlAPI.Status
    func unload() async
    func chat(_ request: ControlAPI.ChatRequest) async throws -> ControlAPI.ChatResponse
    func benchmark() async throws -> ControlAPI.BenchmarkResult
    func imageModels() async -> [ControlAPI.ImageModel]
    func planImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImagePlan
    func generateImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImageResponse
    func meshModels() async -> [ControlAPI.MeshModel]
    func planMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshPlan
    func generateMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshResponse
    func videoModels() async -> [ControlAPI.VideoModel]
    func generateVideo(
        _ request: ControlAPI.VideoGenerateRequest
    ) async throws -> ControlAPI.VideoResponse
    func nodeAdvertisement() async -> ControlAPI.NodeAdvertisement
}

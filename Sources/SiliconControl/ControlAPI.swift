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

        public init(
            state: String, loadedModelID: String?, loadedModelName: String?,
            contextLength: Int?, expertStreaming: Bool,
            lastGenerationTokensPerSecond: Double?
        ) {
            self.state = state
            self.loadedModelID = loadedModelID
            self.loadedModelName = loadedModelName
            self.contextLength = contextLength
            self.expertStreaming = expertStreaming
            self.lastGenerationTokensPerSecond = lastGenerationTokensPerSecond
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

    public struct ErrorResponse: Codable, Sendable {
        public var error: String
        public init(error: String) { self.error = error }
    }
}

/// What the app must provide for the control server to answer requests.
public protocol ControlHost: AnyObject, Sendable {
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
}

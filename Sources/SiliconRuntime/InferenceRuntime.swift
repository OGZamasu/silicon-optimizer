import Foundation
import SiliconCatalog
import SiliconCore
import SiliconPlanner

public enum RuntimeKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case llamaCpp = "llama.cpp"
    case mlx = "MLX"

    public var id: String { rawValue }

    public var supportsExpertStreaming: Bool { self == .llamaCpp }
    public var supportsVision: Bool { true }

    public var summary: String {
        switch self {
        case .llamaCpp:
            "Broadest model support, every GGUF quantization, and on-demand MoE expert paging."
        case .mlx:
            "Apple's own array framework. Often faster on dense models, and lower first-token latency."
        }
    }
}

/// State of a runtime process, observable by the UI.
public enum RuntimeState: Sendable, Equatable {
    case idle
    case starting(stage: String)
    case ready(endpoint: URL)
    case failed(message: String)
    case stopping

    public var isRunning: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .starting, .stopping: true
        default: false
        }
    }

    public var label: String {
        switch self {
        case .idle: "Not loaded"
        case .starting(let stage): stage
        case .ready: "Ready"
        case .failed(let message): message
        case .stopping: "Unloading…"
        }
    }
}

/// A concrete request to load a model.
public struct LoadRequest: Sendable {
    public var model: InstalledModel
    public var configuration: LoadConfiguration
    public var port: Int
    /// Flags from Advanced mode, appended after everything the app generates.
    public var extraArguments: [String]
    /// A chat template to render with instead of the model's own.
    public var chatTemplateFile: URL?

    public init(
        model: InstalledModel, configuration: LoadConfiguration,
        port: Int = 0, extraArguments: [String] = [], chatTemplateFile: URL? = nil
    ) {
        self.model = model
        self.configuration = configuration
        self.port = port
        self.extraArguments = extraArguments
        self.chatTemplateFile = chatTemplateFile
    }
}

/// The abstraction every backend implements. Keeping this narrow is what makes adding Ollama or
/// vLLM-MLX later a matter of writing one type rather than touching the UI.
public protocol InferenceRuntime: Actor {
    nonisolated var kind: RuntimeKind { get }

    /// Whether this runtime is installed and usable on this machine.
    nonisolated static func locate() -> RuntimeInstallation?

    var state: RuntimeState { get }

    func start(_ request: LoadRequest) async throws
    func stop() async

    /// Streams a chat completion. Every runtime here speaks the OpenAI wire format, so the chat
    /// layer above does not need to know which one is loaded.
    func chat(_ request: ChatRequest) async throws -> AsyncThrowingStream<ChatEvent, any Error>

    /// Most recently observed throughput, for the dashboard.
    var lastMetrics: GenerationMetrics? { get }
}

/// Where a runtime binary lives and what it can do.
public struct RuntimeInstallation: Sendable, Equatable {
    public var kind: RuntimeKind
    public var executable: URL
    public var version: String?
    /// True when the build exposes the MoE expert-paging flags from llama.cpp#23324.
    public var hasExpertStreaming: Bool
    public var source: Source

    public enum Source: String, Sendable, Equatable {
        case bundled = "Bundled with the app"
        case homebrew = "Homebrew"
        case userPath = "Custom path"
        case systemPath = "Found on PATH"
    }

    public init(
        kind: RuntimeKind, executable: URL, version: String?,
        hasExpertStreaming: Bool, source: Source
    ) {
        self.kind = kind
        self.executable = executable
        self.version = version
        self.hasExpertStreaming = hasExpertStreaming
        self.source = source
    }
}

public struct GenerationMetrics: Sendable, Equatable {
    public var promptTokens: Int
    public var generatedTokens: Int
    public var prefillTokensPerSecond: Double
    public var generationTokensPerSecond: Double
    public var timeToFirstToken: TimeInterval

    public init(
        promptTokens: Int = 0, generatedTokens: Int = 0,
        prefillTokensPerSecond: Double = 0, generationTokensPerSecond: Double = 0,
        timeToFirstToken: TimeInterval = 0
    ) {
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.generationTokensPerSecond = generationTokensPerSecond
        self.timeToFirstToken = timeToFirstToken
    }
}

public enum RuntimeError: Error, LocalizedError {
    case notInstalled(RuntimeKind)
    case launchFailed(String)
    case didNotBecomeReady(log: String)
    case notRunning
    case expertStreamingUnsupported

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let kind):
            "\(kind.rawValue) is not installed. Install it from Settings."
        case .launchFailed(let message):
            "Could not start the runtime: \(message)"
        case .didNotBecomeReady(let log):
            "The model did not finish loading.\n\n\(log)"
        case .notRunning:
            "No model is loaded."
        case .expertStreamingUnsupported:
            "This llama.cpp build does not support expert streaming. Update it in Settings."
        }
    }
}

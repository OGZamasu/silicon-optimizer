import Foundation
import SiliconCatalog
import SiliconCore
import SiliconPlanner

public enum RuntimeKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case llamaCpp = "llama.cpp"
    case mlx = "MLX"
    /// PrismML's fork of llama.cpp, used only for the ternary GGUFs stock builds refuse.
    case llamaCppPrism = "llama.cpp (PrismML)"

    public var id: String { rawValue }

    public var supportsExpertStreaming: Bool { self == .llamaCpp }
    public var supportsVision: Bool { true }

    public var summary: String {
        switch self {
        case .llamaCpp:
            "Broadest model support, every GGUF quantization, and on-demand MoE expert paging."
        case .mlx:
            "Apple's own array framework. Often faster on dense models, and lower first-token latency."
        case .llamaCppPrism:
            "PrismML's llama.cpp fork: the ternary kernels Bonsai's 1.7-bit weights need. Fetched "
                + "on demand — a 12 MB download — and used only for those models."
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
    /// True when the build carries PrismML's ternary tensor types (PTQ1_0/PQ2_0) — their
    /// llama.cpp fork, which Bonsai 2's GGUF needs. Stock builds refuse the file.
    public var hasPrismTernary: Bool
    public var source: Source

    public enum Source: String, Sendable, Equatable {
        case bundled = "Bundled with the app"
        case homebrew = "Homebrew"
        case userPath = "Custom path"
        case systemPath = "Found on PATH"
        case managed = "Installed by the app"
    }

    public init(
        kind: RuntimeKind, executable: URL, version: String?,
        hasExpertStreaming: Bool, hasPrismTernary: Bool = false, source: Source
    ) {
        self.kind = kind
        self.executable = executable
        self.version = version
        self.hasExpertStreaming = hasExpertStreaming
        self.hasPrismTernary = hasPrismTernary
        self.source = source
    }
}

public struct GenerationMetrics: Sendable, Equatable {
    public var promptTokens: Int
    public var generatedTokens: Int
    public var prefillTokensPerSecond: Double
    public var generationTokensPerSecond: Double
    public var timeToFirstToken: TimeInterval
    /// The OpenAI `finish_reason` the runtime reported on the last chunk: `stop` when the
    /// model chose to end, `length` when the token budget ran out, nil when the runtime
    /// said nothing. Carried rather than dropped because "did this answer get cut off?" is
    /// a fact the server already knows, and asking a model to guess at it instead would be
    /// inventing an answer to a question code can read.
    public var finishReason: String?

    public init(
        promptTokens: Int = 0, generatedTokens: Int = 0,
        prefillTokensPerSecond: Double = 0, generationTokensPerSecond: Double = 0,
        timeToFirstToken: TimeInterval = 0, finishReason: String? = nil
    ) {
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.generationTokensPerSecond = generationTokensPerSecond
        self.timeToFirstToken = timeToFirstToken
        self.finishReason = finishReason
    }

    /// Whether the token budget, not the model, ended the answer.
    ///
    /// Either signal is enough, and that is deliberate. `llama-server` says `length` and
    /// means it; some `mlx_lm.server` builds stop exactly at `max_tokens` and still report
    /// `stop`, so believing the finish reason alone would read a truncated answer as a
    /// finished one. An answer that used every token it was given is truncated whatever the
    /// server called it — the cost of being wrong here is one unnecessary escalation, and
    /// the cost of the other error is shipping half a sentence as if it were the answer.
    public func wasTruncated(budget: Int?) -> Bool {
        if finishReason == "length" { return true }
        guard let budget, budget > 0 else { return false }
        return generatedTokens >= budget
    }
}

public enum RuntimeError: Error, LocalizedError {
    case notInstalled(RuntimeKind)
    case launchFailed(String)
    case didNotBecomeReady(log: String)
    case notRunning
    case expertStreamingUnsupported
    case prismTernaryUnsupported

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
        case .prismTernaryUnsupported:
            "This model's ternary format needs PrismML's llama.cpp fork, and no build with its "
                + "kernels is installed. Install it from the model's page or Settings › Runtimes "
                + "(a 12 MB download), or point Settings › Advanced at a fork build."
        }
    }
}

import Foundation
import SiliconCore

public enum ModelFormat: String, Sendable, Codable, CaseIterable {
    case gguf = "GGUF"
    case mlx = "MLX"
}

public struct ModelCapabilities: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let vision = ModelCapabilities(rawValue: 1 << 0)
    public static let coding = ModelCapabilities(rawValue: 1 << 1)
    public static let reasoning = ModelCapabilities(rawValue: 1 << 2)
    public static let toolCalling = ModelCapabilities(rawValue: 1 << 3)
    public static let multilingual = ModelCapabilities(rawValue: 1 << 4)
    public static let embedding = ModelCapabilities(rawValue: 1 << 5)

    public var labels: [(String, String)] {
        var result: [(String, String)] = []
        if contains(.vision) { result.append(("Vision", "eye")) }
        if contains(.coding) { result.append(("Coding", "chevron.left.forwardslash.chevron.right")) }
        if contains(.reasoning) { result.append(("Reasoning", "brain")) }
        if contains(.toolCalling) { result.append(("Tools", "wrench.and.screwdriver")) }
        if contains(.multilingual) { result.append(("Multilingual", "globe")) }
        if contains(.embedding) { result.append(("Embeddings", "point.3.connected.trianglepath.dotted")) }
        return result
    }
}

public enum ModelCategory: String, Sendable, Codable, CaseIterable, Identifiable {
    case general = "General"
    case coding = "Coding"
    case reasoning = "Reasoning"
    case vision = "Vision"
    case small = "Small & Fast"
    case embedding = "Embeddings"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .general: "bubble.left.and.bubble.right"
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .reasoning: "brain"
        case .vision: "eye"
        case .small: "bolt"
        case .embedding: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// One downloadable artifact — a specific quantization of a specific model.
public struct ModelVariant: Sendable, Codable, Hashable, Identifiable {
    public var quantization: Quantization
    /// Hugging Face repository, e.g. `unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF`.
    public var repository: String
    /// File within the repo. GGUF models sharded across parts list the first shard here.
    public var filename: String
    /// Additional shards, in order, for models split across several files.
    public var additionalShards: [String]
    /// Size on disk. Verified against the Hugging Face API before download begins.
    public var downloadSize: Bytes
    /// Optional companion projector file for vision models.
    public var visionProjector: String?

    public var id: String { "\(repository)/\(filename)" }

    public var allFiles: [String] { [filename] + additionalShards }

    public init(
        quantization: Quantization,
        repository: String,
        filename: String,
        downloadSize: Bytes,
        additionalShards: [String] = [],
        visionProjector: String? = nil
    ) {
        self.quantization = quantization
        self.repository = repository
        self.filename = filename
        self.downloadSize = downloadSize
        self.additionalShards = additionalShards
        self.visionProjector = visionProjector
    }
}

/// A model in the curated catalog, independent of which quantization the user picks.
public struct ModelEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var author: String
    public var license: String
    public var summary: String
    public var category: ModelCategory
    public var capabilities: ModelCapabilities
    public var format: ModelFormat
    public var shape: ModelShape
    public var variants: [ModelVariant]

    /// Editorial rating, 1–5. Reflects how well the model performs *for its size class on
    /// Apple Silicon*, not raw benchmark position.
    public var rating: Int
    /// Maximum usable context, which may exceed the trained length via RoPE scaling.
    public var maxContext: Int
    /// Set when a model needs a llama.cpp or MLX build newer than the last stable release.
    public var requiresRecentRuntime: Bool

    public init(
        id: String, name: String, author: String, license: String, summary: String,
        category: ModelCategory, capabilities: ModelCapabilities, format: ModelFormat,
        shape: ModelShape, variants: [ModelVariant], rating: Int, maxContext: Int,
        requiresRecentRuntime: Bool = false
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.license = license
        self.summary = summary
        self.category = category
        self.capabilities = capabilities
        self.format = format
        self.shape = shape
        self.variants = variants
        self.rating = rating
        self.maxContext = maxContext
        self.requiresRecentRuntime = requiresRecentRuntime
    }

    public var isMoE: Bool { shape.isMoE }

    /// Parameter count formatted the way model names express it ("30B", "3.8B").
    public var parameterLabel: String {
        let billions = Double(shape.totalParameters) / 1e9
        if billions >= 100 { return String(format: "%.0fB", billions) }
        if billions >= 10 { return String(format: "%.0fB", billions) }
        return String(format: "%.1fB", billions)
    }

    /// For MoE models the active-parameter count is what determines speed, and it is the
    /// number users are most often surprised by.
    public var activeParameterLabel: String? {
        guard let moe = shape.moe else { return nil }
        let billions = Double(moe.activeParameters) / 1e9
        return billions >= 10 ? String(format: "%.0fB active", billions)
                              : String(format: "%.1fB active", billions)
    }

    public func variant(for quantization: Quantization) -> ModelVariant? {
        variants.first { $0.quantization == quantization }
    }
}

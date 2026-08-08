import Foundation
import SiliconCatalog
import SiliconCore
import SiliconPlanner

/// A request to generate an image.
public struct ImageRequest: Sendable {
    public var prompt: String
    public var negativePrompt: String?
    public var configuration: ImageConfiguration
    public var seed: Int?
    /// Guidance strength. Ignored by distilled models such as FLUX schnell.
    public var guidance: Double?
    /// Where to write the result.
    public var output: URL

    public init(
        prompt: String,
        negativePrompt: String? = nil,
        configuration: ImageConfiguration = ImageConfiguration(),
        seed: Int? = nil,
        guidance: Double? = nil,
        output: URL
    ) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.configuration = configuration
        self.seed = seed
        self.guidance = guidance
        self.output = output
    }
}

/// Progress through a generation.
public enum ImageEvent: Sendable {
    case stage(String)
    /// Denoising step `index` of `total`.
    case step(index: Int, total: Int)
    case finished(ImageResult)
}

public struct ImageResult: Sendable, Equatable {
    public var image: URL
    public var elapsed: TimeInterval
    /// Peak memory the runtime reported, when it reports one. This is what the planner's
    /// prediction is checked against.
    public var peakMemory: Bytes?
    public var stepsPerSecond: Double

    public init(image: URL, elapsed: TimeInterval, peakMemory: Bytes?, stepsPerSecond: Double) {
        self.image = image
        self.elapsed = elapsed
        self.peakMemory = peakMemory
        self.stepsPerSecond = stepsPerSecond
    }
}

/// A backend that turns prompts into images.
///
/// Deliberately not folded into `InferenceRuntime`. That protocol is built around a long-lived
/// server holding a model in memory and streaming tokens over HTTP; image runtimes on Apple
/// Silicon are one-shot processes that load, render, write a file and exit. Forcing both through
/// one interface would mean a `chat` method that throws for half its implementations and a
/// `load` that does nothing for the other half.
public protocol ImageRuntime: Actor {
    nonisolated var kind: ImageRuntimeKind { get }
    nonisolated static func locate() -> RuntimeInstallation?

    var state: RuntimeState { get }

    /// Renders an image, reporting progress as it goes.
    func generate(
        _ request: ImageRequest, model: InstalledModel
    ) async throws -> AsyncThrowingStream<ImageEvent, any Error>

    func cancel() async
}

public enum ImageRuntimeKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case mflux = "MFLUX"

    public var id: String { rawValue }

    public var summary: String {
        switch self {
        case .mflux:
            "MLX-native image generation, written for Apple Silicon's unified memory."
        }
    }
}

public enum ImageRuntimeError: Error, LocalizedError {
    case notInstalled
    case generationFailed(String)
    case noImageProduced
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "MFLUX is not installed. Run `pip install mflux` in a Python environment."
        case .generationFailed(let message):
            message
        case .noImageProduced:
            "The runtime finished without writing an image."
        case .cancelled:
            "Generation cancelled."
        }
    }
}

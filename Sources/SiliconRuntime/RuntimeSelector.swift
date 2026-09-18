import Foundation
import SiliconCatalog
import SiliconCore
import SiliconPlanner

/// Chooses the runtime for a given model and configuration.
///
/// The user should never have to know that a GGUF goes to llama.cpp and an MLX checkpoint goes
/// to MLX, or that only one of them can page experts off disk. This makes that call and explains
/// it in a sentence.
public struct RuntimeSelector: Sendable {

    public struct Selection: Sendable {
        public var kind: RuntimeKind
        public var installation: RuntimeInstallation
        public var reason: String
        /// Set when the ideal runtime is unavailable and we fell back.
        public var warning: String?
    }

    public var available: [RuntimeKind: RuntimeInstallation]

    public init(available: [RuntimeKind: RuntimeInstallation]) {
        self.available = available
    }

    /// Probes the machine for every supported runtime.
    public static func discover() -> RuntimeSelector {
        var found: [RuntimeKind: RuntimeInstallation] = [:]
        if let llama = LlamaCppRuntime.locate() { found[.llamaCpp] = llama }
        if let mlx = MLXRuntime.locate() { found[.mlx] = mlx }
        if let prism = RuntimeLocator.locatePrismServer() { found[.llamaCppPrism] = prism }
        return RuntimeSelector(available: found)
    }

    public func select(
        model: InstalledModel, configuration: LoadConfiguration
    ) throws -> Selection {
        // The model's own format decides this first — a GGUF cannot be loaded by MLX and an MLX
        // checkpoint cannot be loaded by llama.cpp.
        switch model.format {
        case .mlx:
            guard let installation = available[.mlx] else {
                throw RuntimeError.notInstalled(.mlx)
            }
            return Selection(
                kind: .mlx, installation: installation,
                reason: "This is an MLX checkpoint, so it runs on Apple's MLX runtime."
            )

        case .gguf:
            // PrismML's ternary packings only load on their fork: the copy the app fetched,
            // or a main build that happens to carry the types (a custom path at the fork).
            // A stock build refuses the file, so say so here — with the fix — rather than
            // after the launch fails.
            if model.quantization.needsPrismRuntime {
                let capable = available[.llamaCppPrism]
                    ?? available[.llamaCpp].flatMap { $0.hasPrismTernary ? $0 : nil }
                guard let capable else { throw RuntimeError.prismTernaryUnsupported }
                return Selection(
                    kind: capable.kind, installation: capable,
                    reason: "PrismML ternary GGUF — this llama.cpp build carries the fork's "
                        + "ternary kernels."
                )
            }

            guard let installation = available[.llamaCpp] else {
                throw RuntimeError.notInstalled(.llamaCpp)
            }

            if configuration.expertStreaming != nil {
                guard installation.hasExpertStreaming else {
                    throw RuntimeError.expertStreamingUnsupported
                }
                return Selection(
                    kind: .llamaCpp, installation: installation,
                    reason: "Expert streaming needs llama.cpp's on-demand expert paging, "
                        + "which only this runtime provides."
                )
            }

            if model.shape?.isMoE == true {
                return Selection(
                    kind: .llamaCpp, installation: installation,
                    reason: "Mixture-of-experts GGUF — llama.cpp handles expert routing and can "
                        + "page experts from disk if memory gets tight later."
                )
            }

            return Selection(
                kind: .llamaCpp, installation: installation,
                reason: "Dense GGUF — llama.cpp is the right fit."
            )
        }
    }

    /// Instantiates the runtime chosen by `select`.
    public func makeRuntime(for selection: Selection) -> any InferenceRuntime {
        switch selection.kind {
        case .llamaCpp, .llamaCppPrism: LlamaCppRuntime(installation: selection.installation)
        case .mlx: MLXRuntime(installation: selection.installation)
        }
    }

    public var isAnythingInstalled: Bool { !available.isEmpty }

    public var expertStreamingAvailable: Bool {
        available[.llamaCpp]?.hasExpertStreaming ?? false
    }
}

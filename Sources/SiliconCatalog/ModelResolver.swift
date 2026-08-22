import Foundation
import SiliconCore

/// Turns a catalog entry plus a chosen quantization into the concrete list of files to fetch.
///
/// The bundled catalog cannot stay perfectly in sync with community repositories, so nothing
/// downloads on the strength of a hardcoded filename. We list the repository, prefer the exact
/// hint when it is still there, and otherwise fall back to matching on the quantization suffix.
public struct ModelResolver: Sendable {

    public struct Resolution: Sendable {
        public var repository: String
        public var files: [HuggingFaceClient.RepoFile]
        public var projector: HuggingFaceClient.RepoFile?

        public var totalSize: Bytes {
            files.reduce(Bytes.zero) { $0 + $1.size } + (projector?.size ?? .zero)
        }
        public var isSharded: Bool { files.count > 1 }
    }

    private let client: HuggingFaceClient

    public init(client: HuggingFaceClient) {
        self.client = client
    }

    public func resolve(entry: ModelEntry, quantization: Quantization) async throws -> Resolution {
        guard let variant = entry.variant(for: quantization) else {
            throw HuggingFaceClient.ClientError.fileNotFound(
                repository: entry.id, quantization: quantization.rawValue
            )
        }

        let available = try await client.files(in: variant.repository)

        // MLX models are directories, not files: the runtime wants the whole repo —
        // weights shards, config, tokenizer — laid out together. Everything that isn't
        // documentation comes along, weights first so the primary file registered from
        // `files.first` sits inside the model's directory.
        if entry.format == .mlx {
            let wanted = Self.mlxModelFiles(in: available)
            guard wanted.contains(where: { $0.path.lowercased().hasSuffix(".safetensors") })
            else {
                throw HuggingFaceClient.ClientError.fileNotFound(
                    repository: variant.repository, quantization: quantization.rawValue
                )
            }
            return Resolution(repository: variant.repository, files: wanted, projector: nil)
        }

        let ggufFiles = available.filter { $0.path.lowercased().hasSuffix(".gguf") }

        let matched = try match(
            variant: variant, quantization: quantization,
            in: ggufFiles.filter { !Self.isCompanionFile($0.path) }
        )

        // Vision models need the multimodal projector alongside the weights.
        let projector = entry.capabilities.contains(.vision)
            ? selectProjector(from: ggufFiles, hint: variant.visionProjector)
            : nil

        return Resolution(repository: variant.repository, files: matched, projector: projector)
    }

    /// Everything an MLX model directory needs, weights first — so the first file
    /// registered as primary sits inside the model's directory, which is all the MLX
    /// server actually reads from it.
    static func mlxModelFiles(
        in available: [HuggingFaceClient.RepoFile]
    ) -> [HuggingFaceClient.RepoFile] {
        available
            .filter { isMLXModelFile($0.path) }
            .sorted { lhs, rhs in
                let lhsWeights = lhs.path.lowercased().hasSuffix(".safetensors")
                let rhsWeights = rhs.path.lowercased().hasSuffix(".safetensors")
                if lhsWeights != rhsWeights { return lhsWeights }
                return lhs.path < rhs.path
            }
    }

    /// What an MLX model directory needs from its repo: the weights, every JSON
    /// (config, index, tokenizer, generation defaults), and the classic tokenizer
    /// sidecars. Documentation and repo housekeeping stay behind.
    public static func isMLXModelFile(_ path: String) -> Bool {
        guard !path.contains("/") else { return false }   // mlx-community repos are flat
        let name = path.lowercased()
        if name.hasSuffix(".safetensors") || name.hasSuffix(".json") { return true }
        if name.hasSuffix(".jinja") || name.hasSuffix(".tiktoken") { return true }
        return ["tokenizer.model", "merges.txt", "vocab.txt"].contains(name)
    }

    /// Files that live beside the weights but are not the model.
    ///
    /// `ggml-org/gpt-oss-20b-GGUF` ships `eagle3-gpt-oss-20b-Q8_0.gguf`, a speculative-decoding
    /// draft model. Asking for Q8_0 there would otherwise match it, and since the fallback takes
    /// the largest match, a repository whose draft happened to be bigger than the main file
    /// would hand the user the wrong model entirely. Projectors are excluded for the same
    /// reason: `mmproj-F16.gguf` matches a search for the F16 quantization.
    public static func isCompanionFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name.contains("mmproj")
            || name.hasPrefix("eagle")
            || name.contains("-eagle")
            || name.contains("draft")
    }

    /// Chooses the multimodal projector for a vision model.
    ///
    /// Publishers routinely ship several — Qwen2.5-VL offers `mmproj-F16` (1.35 GB),
    /// `mmproj-BF16` (1.35 GB) and `mmproj-F32` (2.70 GB). Taking whichever the API happens to
    /// list first is a coin flip that can silently double the download, so the catalog's hint
    /// wins and the fallback order is deliberate: F16 is the format every Metal build handles,
    /// BF16 is newer and less universally supported, and F32 is twice the size for no benefit
    /// on Apple Silicon.
    func selectProjector(
        from files: [HuggingFaceClient.RepoFile], hint: String?
    ) -> HuggingFaceClient.RepoFile? {
        let candidates = files.filter { $0.path.lowercased().contains("mmproj") }
        guard !candidates.isEmpty else { return nil }

        if let hint, let exact = candidates.first(where: {
            ($0.path as NSString).lastPathComponent == hint
        }) { return exact }

        // Compared as whole tokens, not substrings: "mmproj-bf16" *contains* "f16", so a
        // substring test silently picks BF16 when F16 was asked for.
        func tokens(_ file: HuggingFaceClient.RepoFile) -> Set<String> {
            let name = (file.path as NSString).lastPathComponent.lowercased()
            return Set(
                name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            )
        }
        for preferred in ["f16", "bf16", "f32"] {
            if let match = candidates.first(where: { tokens($0).contains(preferred) }) {
                return match
            }
        }
        // Unknown naming: take the smallest, which is the cheapest thing to be wrong about.
        return candidates.min { $0.size < $1.size }
    }

    private func match(
        variant: ModelVariant,
        quantization: Quantization,
        in files: [HuggingFaceClient.RepoFile]
    ) throws -> [HuggingFaceClient.RepoFile] {
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })

        // 1. The catalog hint is still valid — take it and any shards it declares.
        if let head = byPath[variant.filename] {
            let shards = variant.additionalShards.compactMap { byPath[$0] }
            if shards.count == variant.additionalShards.count { return [head] + shards }
        }

        // 2. Fall back to any file carrying this quantization in its name. Directory-nested
        //    layouts (`Q4_K_M/model-00001-of-00002.gguf`) are common for large models, so match
        //    against the whole path rather than just the basename.
        let needle = quantization.rawValue.lowercased()
        let candidates = files.filter { $0.path.lowercased().contains(needle) }
        guard !candidates.isEmpty else {
            throw HuggingFaceClient.ClientError.fileNotFound(
                repository: variant.repository, quantization: quantization.rawValue
            )
        }

        // Shards must be fetched in order; `-00001-of-00003` sorts correctly as a string.
        let shards = candidates.filter { Self.shardPattern.firstMatch(in: $0.path) != nil }
        if !shards.isEmpty {
            return shards.sorted { $0.path < $1.path }
        }
        // Otherwise pick the single largest match, which avoids accidentally selecting a
        // small companion file that happens to share the suffix.
        return [candidates.max(by: { $0.size < $1.size })!]
    }

    private static let shardPattern = Regex.shard
}

private enum Regex {
    /// Matches the `-00001-of-00005` shard suffix llama.cpp writes when splitting a GGUF.
    static let shard = NSRegularExpression.shardSuffix
}

private extension NSRegularExpression {
    static let shardSuffix: NSRegularExpression = {
        // Force-try is safe here: the pattern is a compile-time constant.
        try! NSRegularExpression(pattern: #"-\d{5}-of-\d{5}\.gguf$"#, options: [.caseInsensitive])
    }()

    func firstMatch(in string: String) -> NSTextCheckingResult? {
        firstMatch(in: string, options: [], range: NSRange(string.startIndex..., in: string))
    }
}

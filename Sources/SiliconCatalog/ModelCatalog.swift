import Foundation
import SiliconCore

/// The curated model list that ships with the app.
///
/// Filenames here are *hints*. Community GGUF repositories rename and re-quantize files
/// regularly, so `ModelResolver` confirms the real filename against the Hugging Face API before
/// any download starts and falls back to matching on quantization suffix. That keeps a stale
/// bundled catalog from turning into a 404 for the user.
public enum ModelCatalog {

    public static let all: [ModelEntry] = [
        qwen3Coder30B, qwen3_8_27B, qwen3_8_27B_mlx, qwen3_30B_A3B, qwen3_32B, qwen3_14B,
        qwen3_8B, qwen3_4B, qwen3_4B_mlx, qwen3_1_7B, gptOSS20B, gptOSS120B, gemma3_27B,
        gemma3_12B, mistralSmall24B, llama3_3_70B, phi4_14B, glm4_5Air, qwen2_5VL_7B,
        nomicEmbed,
    ]

    public static func entry(id: String) -> ModelEntry? {
        all.first { $0.id == id }
    }

    // MARK: - Size helper

    /// GGUF file size from parameter count and effective bit rate. Real files land within a few
    /// percent of this because token embeddings are usually stored at a different rate than the
    /// body; close enough to plan a download against, and the exact size is fetched from the
    /// Hugging Face API before the transfer begins.
    static func size(_ parameters: Int64, _ quantization: Quantization) -> Bytes {
        Bytes(Int64(Double(parameters) * quantization.bitsPerWeight / 8.0))
    }

    static func ggufVariants(
        repository: String,
        stem: String,
        parameters: Int64,
        quantizations: [Quantization] = [.q4_K_M, .q5_K_M, .q6_K, .q8_0],
        visionProjector: String? = nil
    ) -> [ModelVariant] {
        quantizations.map { quantization in
            ModelVariant(
                quantization: quantization,
                repository: repository,
                filename: "\(stem)-\(quantization.rawValue).gguf",
                downloadSize: size(parameters, quantization),
                visionProjector: visionProjector
            )
        }
    }

    // MARK: - Qwen 3 family

    public static let qwen3Coder30B = ModelEntry(
        id: "qwen3-coder-30b-a3b",
        name: "Qwen3-Coder 30B A3B",
        author: "Qwen",
        license: "Apache-2.0",
        summary: """
            The best coding model that fits on a mainstream Mac. Only 3.3B of its 30B parameters \
            are active per token, so it generates at the speed of a small model while reasoning \
            like a large one.
            """,
        category: .coding,
        capabilities: [.coding, .toolCalling, .multilingual],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 30_500_000_000, blockCount: 48, embeddingLength: 2048,
            feedForwardLength: 5472, headCount: 32, headCountKV: 4,
            trainingContextLength: 262_144, vocabSize: 151_936, headDimension: 128,
            moe: MoEShape(
                expertCount: 128, expertsUsedPerToken: 8, expertFeedForwardLength: 768,
                moeLayerCount: 48, activeParameters: 3_300_000_000
            )
        ),
        variants: ggufVariants(
            repository: "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF",
            stem: "Qwen3-Coder-30B-A3B-Instruct",
            parameters: 30_500_000_000
        ),
        rating: 5, maxContext: 262_144
    )

    /// Shape figures read from the GGUF header of a real install, not a spec sheet — the
    /// qwen35 architecture's 256-wide heads (24 Q over 4 KV) are exactly the kind of
    /// rule-of-thumb break the planner exists to catch.
    public static let qwen3_8_27B = ModelEntry(
        id: "qwen3.8-27b",
        name: "Qwen3.8 27B",
        author: "Qwen",
        license: "Apache-2.0",
        summary: """
            The dense flagship of the Qwen3.8 generation — the strongest general model a \
            36 GB Mac holds at Q6, trained to a 256K context. Check the memory plan before \
            going long: a dense 27B with a huge context is exactly where guessing hurts.
            """,
        category: .general,
        capabilities: [.reasoning, .toolCalling, .multilingual, .coding],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 27_400_000_000, blockCount: 65, embeddingLength: 5120,
            feedForwardLength: 17_408, headCount: 24, headCountKV: 4,
            trainingContextLength: 262_144, vocabSize: 248_320, headDimension: 256
        ),
        variants: ggufVariants(
            repository: "unsloth/Qwen3.8-27B-GGUF", stem: "Qwen3.8-27B",
            parameters: 27_400_000_000
        ),
        rating: 5, maxContext: 262_144
    )

    /// The flagship again, in Apple's own runtime. MLX reaches first token faster than
    /// llama.cpp on dense models; the trade is a single 4-bit variant instead of the
    /// GGUF quantization ladder. Sizes are the repo's real totals, and the weights ship
    /// in three shards — the multi-file download path in production.
    public static let qwen3_8_27B_mlx = ModelEntry(
        id: "qwen3.8-27b-mlx",
        name: "Qwen3.8 27B (MLX)",
        author: "Qwen · mlx-community",
        license: "Apache-2.0",
        summary: """
            The same flagship, running on Apple's MLX engine — noticeably quicker to the \
            first word on dense models. Needs `mlx_lm.server`, which Settings can point \
            at; the app tells you if it's missing before anything downloads.
            """,
        category: .general,
        capabilities: [.reasoning, .toolCalling, .multilingual, .coding],
        format: .mlx,
        shape: ModelShape(
            totalParameters: 27_400_000_000, blockCount: 65, embeddingLength: 5120,
            feedForwardLength: 17_408, headCount: 24, headCountKV: 4,
            trainingContextLength: 262_144, vocabSize: 248_320, headDimension: 256
        ),
        variants: [
            ModelVariant(
                quantization: .mlx4,
                repository: "mlx-community/Qwen3.8-27B-4bit",
                filename: "model-00001-of-00003.safetensors",
                downloadSize: Bytes(16_080_000_000)
            )
        ],
        rating: 5, maxContext: 262_144
    )

    public static let qwen3_30B_A3B = ModelEntry(
        id: "qwen3-30b-a3b-instruct",
        name: "Qwen3 30B A3B Instruct",
        author: "Qwen",
        license: "Apache-2.0",
        summary: """
            A general-purpose mixture-of-experts model with the same economics as Qwen3-Coder: \
            large-model quality at small-model speed. The best default for 24 GB and up.
            """,
        category: .general,
        capabilities: [.reasoning, .toolCalling, .multilingual, .coding],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 30_500_000_000, blockCount: 48, embeddingLength: 2048,
            feedForwardLength: 5472, headCount: 32, headCountKV: 4,
            trainingContextLength: 262_144, vocabSize: 151_936, headDimension: 128,
            moe: MoEShape(
                expertCount: 128, expertsUsedPerToken: 8, expertFeedForwardLength: 768,
                moeLayerCount: 48, activeParameters: 3_300_000_000
            )
        ),
        variants: ggufVariants(
            repository: "unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF",
            stem: "Qwen3-30B-A3B-Instruct-2507",
            parameters: 30_500_000_000
        ),
        rating: 5, maxContext: 262_144
    )

    public static let qwen3_32B = ModelEntry(
        id: "qwen3-32b",
        name: "Qwen3 32B",
        author: "Qwen",
        license: "Apache-2.0",
        summary: """
            A dense 32B model. Slower per token than the 30B-A3B mixture-of-experts, but stronger \
            on hard single-shot reasoning. Wants 32 GB or more.
            """,
        category: .reasoning,
        capabilities: [.reasoning, .toolCalling, .multilingual, .coding],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 32_800_000_000, blockCount: 64, embeddingLength: 5120,
            feedForwardLength: 25_600, headCount: 64, headCountKV: 8,
            trainingContextLength: 32_768, vocabSize: 151_936, headDimension: 128
        ),
        variants: ggufVariants(
            repository: "unsloth/Qwen3-32B-GGUF", stem: "Qwen3-32B",
            parameters: 32_800_000_000
        ),
        rating: 4, maxContext: 131_072
    )

    public static let qwen3_14B = ModelEntry(
        id: "qwen3-14b",
        name: "Qwen3 14B",
        author: "Qwen",
        license: "Apache-2.0",
        summary: "Strong all-rounder that fits comfortably in 16 GB at Q4. A safe default.",
        category: .general,
        capabilities: [.reasoning, .toolCalling, .multilingual, .coding],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 14_800_000_000, blockCount: 40, embeddingLength: 5120,
            feedForwardLength: 17_408, headCount: 40, headCountKV: 8,
            trainingContextLength: 32_768, vocabSize: 151_936, headDimension: 128
        ),
        variants: ggufVariants(
            repository: "unsloth/Qwen3-14B-GGUF", stem: "Qwen3-14B",
            parameters: 14_800_000_000
        ),
        rating: 4, maxContext: 131_072
    )

    public static let qwen3_8B = ModelEntry(
        id: "qwen3-8b",
        name: "Qwen3 8B",
        author: "Qwen",
        license: "Apache-2.0",
        summary: "Fast, capable, and comfortable on 16 GB alongside your other apps.",
        category: .general,
        capabilities: [.reasoning, .toolCalling, .multilingual, .coding],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 8_190_000_000, blockCount: 36, embeddingLength: 4096,
            feedForwardLength: 12_288, headCount: 32, headCountKV: 8,
            trainingContextLength: 32_768, vocabSize: 151_936, headDimension: 128
        ),
        variants: ggufVariants(
            repository: "unsloth/Qwen3-8B-GGUF", stem: "Qwen3-8B",
            parameters: 8_190_000_000
        ),
        rating: 4, maxContext: 131_072
    )

    public static let qwen3_4B = ModelEntry(
        id: "qwen3-4b",
        name: "Qwen3 4B",
        author: "Qwen",
        license: "Apache-2.0",
        summary: "Punches far above its weight. The right starting point on 8 GB machines.",
        category: .small,
        capabilities: [.reasoning, .toolCalling, .multilingual],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 4_020_000_000, blockCount: 36, embeddingLength: 2560,
            feedForwardLength: 9728, headCount: 32, headCountKV: 8,
            trainingContextLength: 32_768, vocabSize: 151_936, headDimension: 128
        ),
        variants: ggufVariants(
            repository: "unsloth/Qwen3-4B-Instruct-2507-GGUF", stem: "Qwen3-4B-Instruct-2507",
            parameters: 4_020_000_000
        ),
        rating: 4, maxContext: 262_144
    )

    /// The small MLX pick — 2.3 GB, quick everywhere, and the gentlest way to find out
    /// what the MLX engine feels like before committing to the 16 GB flagship.
    public static let qwen3_4B_mlx = ModelEntry(
        id: "qwen3-4b-mlx",
        name: "Qwen3 4B (MLX)",
        author: "Qwen · mlx-community",
        license: "Apache-2.0",
        summary: "Qwen3 4B on Apple's MLX engine: small, quick to first token, 2.3 GB.",
        category: .small,
        capabilities: [.reasoning, .toolCalling, .multilingual],
        format: .mlx,
        shape: ModelShape(
            totalParameters: 4_020_000_000, blockCount: 36, embeddingLength: 2560,
            feedForwardLength: 9728, headCount: 32, headCountKV: 8,
            trainingContextLength: 32_768, vocabSize: 151_936, headDimension: 128
        ),
        variants: [
            ModelVariant(
                quantization: .mlx4,
                repository: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
                filename: "model.safetensors",
                downloadSize: Bytes(2_280_000_000)
            )
        ],
        rating: 4, maxContext: 262_144
    )

    public static let qwen3_1_7B = ModelEntry(
        id: "qwen3-1.7b",
        name: "Qwen3 1.7B",
        author: "Qwen",
        license: "Apache-2.0",
        summary: "Tiny and instant. Good for autocomplete, classification and quick edits.",
        category: .small,
        capabilities: [.toolCalling, .multilingual],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 1_720_000_000, blockCount: 28, embeddingLength: 2048,
            feedForwardLength: 6144, headCount: 16, headCountKV: 8,
            trainingContextLength: 32_768, vocabSize: 151_936, headDimension: 128
        ),
        variants: ggufVariants(
            repository: "unsloth/Qwen3-1.7B-GGUF", stem: "Qwen3-1.7B",
            parameters: 1_720_000_000
        ),
        rating: 3, maxContext: 32_768
    )

    // MARK: - gpt-oss

    public static let gptOSS20B = ModelEntry(
        id: "gpt-oss-20b",
        name: "gpt-oss 20B",
        author: "OpenAI",
        license: "Apache-2.0",
        summary: """
            Released natively in 4-bit, so there is no quantization tax to pay. Only 3.6B \
            parameters are active per token and it has adjustable reasoning effort.
            """,
        category: .reasoning,
        capabilities: [.reasoning, .toolCalling, .coding],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 20_900_000_000, blockCount: 24, embeddingLength: 2880,
            feedForwardLength: 2880, headCount: 64, headCountKV: 8,
            trainingContextLength: 131_072, vocabSize: 201_088, headDimension: 64,
            moe: MoEShape(
                expertCount: 32, expertsUsedPerToken: 4, expertFeedForwardLength: 2880,
                moeLayerCount: 24, activeParameters: 3_600_000_000
            )
        ),
        variants: [
            ModelVariant(
                quantization: .mxfp4, repository: "ggml-org/gpt-oss-20b-GGUF",
                filename: "gpt-oss-20b-MXFP4.gguf", downloadSize: Bytes(12_110_000_000)
            )
        ],
        rating: 5, maxContext: 131_072
    )

    public static let gptOSS120B = ModelEntry(
        id: "gpt-oss-120b",
        name: "gpt-oss 120B",
        author: "OpenAI",
        license: "Apache-2.0",
        summary: """
            Frontier-class reasoning with only 5.1B active parameters. Needs 64 GB to sit in \
            memory, or expert streaming on a fast SSD below that.
            """,
        category: .reasoning,
        capabilities: [.reasoning, .toolCalling, .coding],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 116_800_000_000, blockCount: 36, embeddingLength: 2880,
            feedForwardLength: 2880, headCount: 64, headCountKV: 8,
            trainingContextLength: 131_072, vocabSize: 201_088, headDimension: 64,
            moe: MoEShape(
                expertCount: 128, expertsUsedPerToken: 4, expertFeedForwardLength: 2880,
                moeLayerCount: 36, activeParameters: 5_100_000_000
            )
        ),
        variants: [
            ModelVariant(
                quantization: .mxfp4, repository: "ggml-org/gpt-oss-120b-GGUF",
                filename: "gpt-oss-120b-MXFP4.gguf",
                downloadSize: Bytes(63_390_000_000)
            )
        ],
        rating: 5, maxContext: 131_072
    )

    // MARK: - Gemma

    public static let gemma3_27B = ModelEntry(
        id: "gemma-3-27b-it",
        name: "Gemma 3 27B",
        author: "Google",
        license: "Gemma Terms of Use",
        summary: "Google's strongest open model with native image understanding and 128K context.",
        category: .vision,
        capabilities: [.vision, .reasoning, .multilingual],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 27_400_000_000, blockCount: 62, embeddingLength: 5376,
            feedForwardLength: 21_504, headCount: 32, headCountKV: 16,
            trainingContextLength: 131_072, vocabSize: 262_144, headDimension: 128
        ),
        variants: ggufVariants(
            repository: "unsloth/gemma-3-27b-it-GGUF", stem: "gemma-3-27b-it",
            parameters: 27_400_000_000, visionProjector: "mmproj-F16.gguf"
        ),
        rating: 4, maxContext: 131_072
    )

    public static let gemma3_12B = ModelEntry(
        id: "gemma-3-12b-it",
        name: "Gemma 3 12B",
        author: "Google",
        license: "Gemma Terms of Use",
        summary: "Vision plus long context in a size that fits 16 GB machines.",
        category: .vision,
        capabilities: [.vision, .reasoning, .multilingual],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 12_200_000_000, blockCount: 48, embeddingLength: 3840,
            feedForwardLength: 15_360, headCount: 16, headCountKV: 8,
            trainingContextLength: 131_072, vocabSize: 262_144, headDimension: 256
        ),
        variants: ggufVariants(
            repository: "unsloth/gemma-3-12b-it-GGUF", stem: "gemma-3-12b-it",
            parameters: 12_200_000_000, visionProjector: "mmproj-F16.gguf"
        ),
        rating: 4, maxContext: 131_072
    )

    // MARK: - Others

    public static let mistralSmall24B = ModelEntry(
        id: "mistral-small-3.2-24b",
        name: "Mistral Small 3.2 24B",
        author: "Mistral AI",
        license: "Apache-2.0",
        summary: "Excellent instruction following and function calling, with vision support.",
        category: .general,
        capabilities: [.vision, .toolCalling, .coding, .multilingual],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 23_600_000_000, blockCount: 40, embeddingLength: 5120,
            feedForwardLength: 32_768, headCount: 32, headCountKV: 8,
            trainingContextLength: 131_072, vocabSize: 131_072, headDimension: 128
        ),
        variants: ggufVariants(
            repository: "unsloth/Mistral-Small-3.2-24B-Instruct-2506-GGUF",
            stem: "Mistral-Small-3.2-24B-Instruct-2506",
            parameters: 23_600_000_000, visionProjector: "mmproj-F16.gguf"
        ),
        rating: 4, maxContext: 131_072
    )

    public static let llama3_3_70B = ModelEntry(
        id: "llama-3.3-70b",
        name: "Llama 3.3 70B",
        author: "Meta",
        license: "Llama 3.3 Community License",
        summary: "A dense 70B. Needs 48 GB+ and generates slowly, but remains a strong generalist.",
        category: .general,
        capabilities: [.toolCalling, .multilingual, .coding],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 70_600_000_000, blockCount: 80, embeddingLength: 8192,
            feedForwardLength: 28_672, headCount: 64, headCountKV: 8,
            trainingContextLength: 131_072, vocabSize: 128_256, headDimension: 128
        ),
        variants: ggufVariants(
            repository: "unsloth/Llama-3.3-70B-Instruct-GGUF", stem: "Llama-3.3-70B-Instruct",
            parameters: 70_600_000_000, quantizations: [.q3_K_M, .q4_K_M, .q5_K_M]
        ),
        rating: 3, maxContext: 131_072
    )

    public static let phi4_14B = ModelEntry(
        id: "phi-4",
        name: "Phi-4 14B",
        author: "Microsoft",
        license: "MIT",
        summary: "Unusually strong at maths and reasoning for its size. Short context.",
        category: .reasoning,
        capabilities: [.reasoning, .coding],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 14_700_000_000, blockCount: 40, embeddingLength: 5120,
            feedForwardLength: 17_920, headCount: 40, headCountKV: 10,
            trainingContextLength: 16_384, vocabSize: 100_352, headDimension: 128
        ),
        variants: ggufVariants(
            repository: "unsloth/phi-4-GGUF", stem: "phi-4",
            parameters: 14_700_000_000
        ),
        rating: 4, maxContext: 16_384
    )

    public static let glm4_5Air = ModelEntry(
        id: "glm-4.5-air",
        name: "GLM 4.5 Air",
        author: "Zhipu AI",
        license: "MIT",
        summary: """
            A 106B mixture-of-experts with 12B active. Very strong at agentic and tool-use work \
            when you have the memory for it.
            """,
        category: .reasoning,
        capabilities: [.reasoning, .toolCalling, .coding],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 106_000_000_000, blockCount: 46, embeddingLength: 4096,
            feedForwardLength: 10_944, headCount: 96, headCountKV: 8,
            trainingContextLength: 131_072, vocabSize: 151_552, headDimension: 128,
            moe: MoEShape(
                expertCount: 128, expertsUsedPerToken: 8, expertFeedForwardLength: 1408,
                moeLayerCount: 45, activeParameters: 12_000_000_000, hasSharedExpert: true
            )
        ),
        variants: ggufVariants(
            repository: "unsloth/GLM-4.5-Air-GGUF", stem: "GLM-4.5-Air",
            parameters: 106_000_000_000, quantizations: [.q3_K_M, .q4_K_M, .q5_K_M]
        ),
        rating: 5, maxContext: 131_072
    )

    public static let qwen2_5VL_7B = ModelEntry(
        id: "qwen2.5-vl-7b",
        name: "Qwen2.5-VL 7B",
        author: "Qwen",
        license: "Apache-2.0",
        summary: "Compact vision-language model. Reads screenshots, documents and charts well.",
        category: .vision,
        capabilities: [.vision, .multilingual],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 8_290_000_000, blockCount: 28, embeddingLength: 3584,
            feedForwardLength: 18_944, headCount: 28, headCountKV: 4,
            trainingContextLength: 128_000, vocabSize: 152_064, headDimension: 128
        ),
        variants: ggufVariants(
            repository: "unsloth/Qwen2.5-VL-7B-Instruct-GGUF", stem: "Qwen2.5-VL-7B-Instruct",
            parameters: 8_290_000_000, visionProjector: "mmproj-F16.gguf"
        ),
        rating: 4, maxContext: 128_000
    )

    public static let nomicEmbed = ModelEntry(
        id: "nomic-embed-text-v1.5",
        name: "Nomic Embed Text v1.5",
        author: "Nomic AI",
        license: "Apache-2.0",
        summary: "Fast local embeddings for retrieval. Tiny and always worth keeping installed.",
        category: .embedding,
        capabilities: [.embedding],
        format: .gguf,
        shape: ModelShape(
            totalParameters: 137_000_000, blockCount: 12, embeddingLength: 768,
            feedForwardLength: 3072, headCount: 12, headCountKV: 12,
            trainingContextLength: 8192, vocabSize: 30_522, headDimension: 64
        ),
        variants: [
            ModelVariant(
                quantization: .f16, repository: "nomic-ai/nomic-embed-text-v1.5-GGUF",
                filename: "nomic-embed-text-v1.5.f16.gguf", downloadSize: .mib(274)
            )
        ],
        rating: 4, maxContext: 8192
    )
}

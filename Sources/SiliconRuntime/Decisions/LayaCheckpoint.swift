import Foundation
import SiliconControl

/// The Laya checkpoints this app will fetch, pinned to a commit each.
///
/// Every number here was read off the Hugging Face API rather than a README, and the
/// revisions are full commit shas rather than `main`: a branch moves, and a lane whose
/// thresholds were calibrated against one revision is not a promise about the next one.
///
/// The weights are Convai Innovations' Laya models; the MLX conversion is a third party's.
/// Both halves are Apache-2.0 but they have **different rightsholders**, which is why
/// `licence` and `weightsAttribution` are two properties and why the Decisions panel shows
/// both — Apache-2.0 §4(d) requires the NOTICE that ships in each repository to travel with
/// it, and a single "Apache-2.0" label would hide whose notice it is.
public enum LayaCheckpoint: String, Codable, Sendable, CaseIterable, Hashable {
    /// The default: English, ModernBERT-large, 421M parameters.
    case english
    /// 100+ languages, mmBERT-base, 322M — the smallest and the fastest of the three.
    case multilingual
    /// ModernBERT-large again, tuned for typed decisions specifically.
    case typedDecisions

    public static let `default` = LayaCheckpoint.english

    /// The Hugging Face repository the MLX weights come from.
    ///
    /// Always passed explicitly to `laya_mlx.load`, never defaulted: the library's own
    /// default is `convaiinnovations/laya`, the upstream **PyTorch** checkpoint, so a
    /// missing argument silently fetches weights this runtime cannot use.
    public var repository: String {
        switch self {
        case .english: "aac6fef/laya-mlx"
        case .multilingual: "aac6fef/laya-multilingual-mlx"
        case .typedDecisions: "aac6fef/laya-typed-decisions-mlx"
        }
    }

    /// The exact commit fetched. Read from `GET /api/models/<repo>` on 2026-09-20.
    public var revision: String {
        switch self {
        case .english: "20aed815fc6acde75733882e7ec0e3f28aeb9717"
        case .multilingual: "f2b4faf51023039425946074e2cf1361d2db11d5"
        case .typedDecisions: "f9e501c2080cc57c13d6887820329758f5351125"
        }
    }

    /// Bytes the repository occupies once fetched — every file, not just the weights.
    public var downloadBytes: Int64 {
        switch self {
        case .english: 842_646_217
        case .multilingual: 643_872_398
        case .typedDecisions: 842_646_500
        }
    }

    public var displayName: String {
        switch self {
        case .english: "Laya 421M (English)"
        case .multilingual: "Laya 322M (multilingual)"
        case .typedDecisions: "Laya 421M (typed decisions)"
        }
    }

    public var baseModel: String {
        switch self {
        case .english, .typedDecisions: "ModernBERT-large"
        case .multilingual: "mmBERT-base"
        }
    }

    public var parameterMillions: Int {
        switch self {
        case .english, .typedDecisions: 421
        case .multilingual: 322
        }
    }

    /// Tokens of state plus questions the encoder can see. Past it laya-mlx truncates the
    /// state, which is a wrong answer rather than an error — so the sidecar checks it up
    /// front and refuses (`DecisionLaneError.stateTooLong`).
    public var contextTokens: Int {
        switch self {
        case .english: 512
        case .multilingual, .typedDecisions: 1024
        }
    }

    /// The published P50 for one short question on an M3 Max, in milliseconds.
    ///
    /// A headline, and labelled as one wherever it is shown. The same benchmark file
    /// measures ten full-context questions at about a second, so this number describes the
    /// cheap end of the range rather than the lane. What the panel shows once the lane has
    /// actually answered something is this Mac's own measurement — which on the machine
    /// this was built on was about 23 ms for a single short question and 21 ms per question
    /// with three in one request, against the 13.4 ms published here.
    public var publishedShortQuestionMS: Double {
        switch self {
        case .english, .typedDecisions: 13.4
        case .multilingual: 7.4
        }
    }

    /// Peak resident memory for the short-question case, in bytes. Full-context ten-question
    /// runs peak near 1.8 GB, which is what the idle unload is for.
    public var publishedPeakMemoryBytes: Int64 {
        switch self {
        case .english, .typedDecisions: 989_398_630
        case .multilingual: 721_047_552
        }
    }

    public var summary: String {
        switch self {
        case .english:
            "The default. Trained in English, the most accurate of the three on English "
            + "questions, and the one the built-in thresholds were written against."
        case .multilingual:
            "100+ languages, and the fastest and smallest — about half the memory. Choose "
            + "this if your prompts are not all in English."
        case .typedDecisions:
            "The same size as the default, tuned specifically for typed decisions rather "
            + "than general classification."
        }
    }

    // MARK: Licensing

    /// One licence for both halves, as it happens — but two rightsholders.
    public static let licence = "Apache-2.0"
    /// Who owns the weights.
    public static let weightsAttribution = "Laya, © Convai Innovations, Apache-2.0"
    /// Who owns the MLX conversion and the Python package.
    public static let portAttribution = "laya-mlx (MLX port), Apache-2.0"
}

/// The Python side of the lane, pinned.
///
/// Written down in one place because three different things need to agree about it: the
/// installer that creates the environment, the check that decides whether an existing
/// environment is the right one, and the sentence the Decisions panel shows the owner.
public enum LayaPackage {
    /// The only release that exists. There are no git tags upstream, so the wheel's digest
    /// below is the only thing a reproducible install can be pinned to.
    public static let version = "0.1.0"
    public static let requirement = "laya-mlx==\(version)"
    /// sha256 of `laya_mlx-0.1.0-py3-none-any.whl` on PyPI.
    public static let wheelSHA256 =
        "50f29ddcd6c9e71fd18a4c284695f18c2e560c803a099c5f6870c2dc5c037189"
    /// What the package itself requires. MLX is capped below 0.33 rather than open-ended.
    public static let mlxRequirement = "mlx>=0.32.2,<0.33"
    public static let minimumPython = (major: 3, minor: 11)
    /// The Pythons its dependencies are hash-locked for (`Resources/pinned-installs/laya`).
    public static let lockedPythons = PinnedInstall.layaPythons
    public static let repository = "https://github.com/mizorewww/laya-mlx"
    public static let upstreamRepository = "https://github.com/NandhaKishorM/laya"

    /// How many questions the Agent batches in one forward pass. laya-mlx's own default,
    /// left alone: the published throughput figures are measured at it.
    public static let batchSize = 16
}

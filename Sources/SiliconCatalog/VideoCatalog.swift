import Foundation
import SiliconCore

/// How a video model runs. Video engines live behind the swarm job contract so the app
/// can use a paired CUDA node or a loopback Apple Silicon adapter without knowing which
/// runtime actually renders the clip.
public enum VideoBackend: String, Sendable, Codable {
    /// A swarm node advertising a video capability runs the job; this Mac sends the
    /// prompt and receives the clip.
    case nodeRemote
    /// Catalogued for the roadmap; no runner wired yet.
    case unsupported
}

/// One text/image-to-video model. Weight sizes describe the node's disk, not this Mac's;
/// durations are published figures for a 24 GB CUDA card.
public struct VideoEntry: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var author: String
    public var license: String
    public var summary: String
    public var backend: VideoBackend
    /// The capability id a node advertises when it can run this model.
    public var capabilityID: String
    public var weightsSize: Bytes
    public var typicalDuration: String
    public var outputs: String
    public var rating: Int
    /// Whether a still image can seed the clip (image-to-video).
    public var supportsImageInput: Bool
    /// Clip lengths this model/runtime contract can actually serve.
    public var supportedSeconds: [Int]
    public var setupHint: String?

    public init(
        id: String, name: String, author: String, license: String, summary: String,
        backend: VideoBackend, capabilityID: String, weightsSize: Bytes,
        typicalDuration: String, outputs: String, rating: Int,
        supportsImageInput: Bool = false, supportedSeconds: [Int],
        setupHint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.license = license
        self.summary = summary
        self.backend = backend
        self.capabilityID = capabilityID
        self.weightsSize = weightsSize
        self.typicalDuration = typicalDuration
        self.outputs = outputs
        self.rating = rating
        self.supportsImageInput = supportsImageInput
        self.supportedSeconds = supportedSeconds
        self.setupHint = setupHint
    }

    /// The closest duration this model supports. Picker values are already valid, but
    /// this also makes a persisted selection safe when the user switches models.
    public func normalizedSeconds(_ seconds: Int) -> Int {
        supportedSeconds.min {
            abs($0 - seconds) < abs($1 - seconds)
        } ?? seconds
    }
}

public enum VideoCatalog {

    public static let all: [VideoEntry] = [wan22, ltx2, ltx23Uncensored, hailuoH3]

    public static func entry(id: String) -> VideoEntry? {
        all.first { $0.id == id }
    }

    /// Wan 2.2 TI2V-5B — the cinematic pick: 720p at 24 fps in about ten minutes on a
    /// 24 GB card, with the motion quality the Wan family is known for.
    public static let wan22 = VideoEntry(
        id: "wan22-ti2v-5b",
        name: "Wan 2.2 5B",
        author: "Alibaba",
        license: "Apache 2.0",
        summary: "The cinematic pick: real 720p motion from a prompt or a still image. "
            + "Worth the ~10 minute wait when the clip matters.",
        backend: .nodeRemote,
        capabilityID: "wan22-ti2v-5b",
        weightsSize: .gib(10),
        typicalDuration: "~10 min per 5 s clip (remote)",
        outputs: "MP4, 720p 24 fps",
        rating: 5,
        supportsImageInput: true,
        supportedSeconds: [3, 5, 8],
        setupHint: "Runs on a swarm node with an NVIDIA card. Your silicon-node machine "
            + "qualifies — it just hasn't set video up yet."
    )

    /// LTX-2 distilled — the iteration pick: several times faster than Wan at the same
    /// resolution, ideal for trying prompts before committing to a long render.
    public static let ltx2 = VideoEntry(
        id: "ltx2-distilled",
        name: "LTX-2 distilled",
        author: "Lightricks",
        license: "LTX Open Weights",
        summary: "The iteration pick: clips in a fraction of Wan's time, so you can try "
            + "five ideas and then render the winner properly.",
        backend: .nodeRemote,
        capabilityID: "ltx2-distilled",
        weightsSize: .gib(13),
        typicalDuration: "1–3 min per clip (remote)",
        outputs: "MP4, up to 1080p",
        rating: 4,
        supportsImageInput: true,
        supportedSeconds: [3, 5, 8, 10, 15],
        setupHint: "Runs on a swarm node with an NVIDIA card. Your silicon-node machine "
            + "qualifies — it just hasn't set video up yet."
    )

    /// LTX-2.3 Uncensored v1.4 — a community merge of LTX-2.3 with the Eros10, DMD-distilled
    /// and in-context detailer LoRAs baked into the weights. The node runs it as a GGUF
    /// transformer dropped into the same diffusers pipeline as the distilled model, so it
    /// rides on that install and costs one extra file of disk, not a second 95 GB tree.
    public static let ltx23Uncensored = VideoEntry(
        id: "ltx23-uncensored",
        name: "LTX-2.3 Uncensored v1.4",
        author: "ChrisColeTech (Lightricks base)",
        license: "Unknown (LTX-2.3 merge)",
        summary: "The unfiltered pick: LTX-2.3 with the Eros10 and DMD-distilled LoRAs baked "
            + "in — eight steps, sound with the picture, adult content allowed. Holds a face "
            + "through image-to-video better than stock.",
        backend: .nodeRemote,
        capabilityID: "ltx23-uncensored",
        weightsSize: .gib(16.5),
        typicalDuration: "2–5 min per 5 s clip (remote)",
        outputs: "MP4 with audio, up to 720p 24 fps",
        rating: 4,
        supportsImageInput: true,
        supportedSeconds: [3, 5, 8, 10, 15],
        setupHint: "Runs on a swarm node with an NVIDIA card, on top of the LTX-2 distilled "
            + "install it borrows the text encoder and decoders from. Install it from the "
            + "node's Store page; it is not in the recommended set."
    )

    /// Hailuo H3 through Phosphene — a large local Apple Silicon pipeline whose longer
    /// clips are composed from chained five-second windows to keep memory bounded.
    public static let hailuoH3 = VideoEntry(
        id: "hailuo-h3",
        name: "MiniMax Hailuo H3",
        author: "MiniMax",
        license: "MiniMax-H3 Model License (authorization required in excluded territories)",
        summary: "The high-motion Apple Silicon option through Phosphene. It can render "
            + "three- or five-second shots and chain them into coherent 10- or 15-second clips.",
        backend: .nodeRemote,
        capabilityID: "hailuo-h3",
        weightsSize: .gib(98),
        typicalDuration: "several minutes per clip (Phosphene Q8)",
        outputs: "MP4, 480p–1080p",
        rating: 5,
        supportsImageInput: true,
        supportedSeconds: [3, 5, 10, 15],
        setupHint: "Install MiniMax-H3 in Phosphene after accepting its license and obtaining "
            + "any authorization it requires, then enable the model-aware video adapter so it "
            + "advertises the hailuo-h3 capability."
    )
}

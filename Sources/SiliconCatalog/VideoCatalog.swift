import Foundation
import SiliconCore

/// How a video model runs. Local video generation on Apple Silicon is still a research
/// exercise — minutes per second of footage through unported pipelines — so the first
/// backends are the swarm's CUDA nodes, the way LATO.2 already works for 3D.
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
    public var setupHint: String?

    public init(
        id: String, name: String, author: String, license: String, summary: String,
        backend: VideoBackend, capabilityID: String, weightsSize: Bytes,
        typicalDuration: String, outputs: String, rating: Int,
        supportsImageInput: Bool = false, setupHint: String? = nil
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
        self.setupHint = setupHint
    }
}

public enum VideoCatalog {

    public static let all: [VideoEntry] = [wan22, ltx2]

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
        capabilityID: "text-to-video",
        weightsSize: .gib(10),
        typicalDuration: "~10 min per 5 s clip (remote)",
        outputs: "MP4, 720p 24 fps",
        rating: 5,
        supportsImageInput: true,
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
        capabilityID: "text-to-video",
        weightsSize: .gib(13),
        typicalDuration: "1–3 min per clip (remote)",
        outputs: "MP4, up to 1080p",
        rating: 4,
        supportsImageInput: true,
        setupHint: "Runs on a swarm node with an NVIDIA card. Your silicon-node machine "
            + "qualifies — it just hasn't set video up yet."
    )
}

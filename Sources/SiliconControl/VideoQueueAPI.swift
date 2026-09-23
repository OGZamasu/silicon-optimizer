import Foundation

extension ControlAPI {
    /// Returns immediately after persisting; generation continues in the app.
    public struct VideoQueueRequest: Codable, Sendable {
        public var prompts: [String]
        public var title: String?
        public var variations: Int?
        public var modelID: String?
        public var seconds: Int?
        public var resolution: String?
        public var seed: UInt32?
        public var h3Turbo: Bool?
        public var h3Steps: Int?
        /// One negative prompt for the whole batch — the same model and the same settings
        /// are chosen for all of it, and what to keep out of the shot belongs with those.
        public var negativePrompt: String?

        enum CodingKeys: String, CodingKey {
            case prompts, title, variations, modelID, seconds, resolution, seed
            case negativePrompt
            case h3Turbo = "h3_turbo"
            case h3Steps = "h3_steps"
        }
        public init(
            prompts: [String], title: String? = nil, variations: Int? = nil,
            modelID: String? = nil, seconds: Int? = nil, resolution: String? = nil,
            seed: UInt32? = nil, h3Turbo: Bool? = nil, h3Steps: Int? = nil,
            negativePrompt: String? = nil
        ) {
            self.prompts = prompts; self.title = title; self.variations = variations
            self.modelID = modelID; self.seconds = seconds; self.resolution = resolution
            self.seed = seed; self.h3Turbo = h3Turbo
            self.h3Steps = h3Steps
            self.negativePrompt = negativePrompt
        }
    }

    public struct VideoQueueControl: Codable, Sendable {
        public var action: String
        public var id: String?
        public var confirmNewRender: Bool?
        public init(action: String, id: String? = nil, confirmNewRender: Bool? = nil) {
            self.action = action; self.id = id; self.confirmNewRender = confirmNewRender
        }
    }

    public struct VideoQueueView: Codable, Sendable {
        public struct Item: Codable, Sendable {
            public var id: String
            public var batchID: String
            public var title: String
            public var prompt: String
            public var scene: Int
            public var variation: Int
            public var seed: UInt32?
            public var modelID: String
            public var seconds: Int
            public var resolution: String
            public var h3Turbo: Bool?
            public var h3Steps: Int?
            public var status: String
            public var nodeJobID: String?
            public var file: String?
            public var outputDirectory: String
            public var error: String?
            public var uncertainSubmission: Bool
            /// How these settings were arrived at, when they were not typed: the media
            /// router's one line. Absent on everything queued by hand.
            public var detail: String?
            /// What was asked to be kept out of the shot, when anything was.
            public var negativePrompt: String?
            /// The finished clip, fetchable at `GET /media/{mediaID}`. Set only once the
            /// render has landed somewhere this Mac serves from — which is why it is the
            /// honest test for "can this phone play it?", and `file` is not.
            public var mediaID: String?
            /// `/media/<id>`, relative to whatever address the client dialled.
            public var mediaURL: String?
            /// A JPEG poster frame, when one could be made from the clip.
            public var thumbnailMediaID: String?
            /// Set once someone asked the node to cancel this clip's render: `sending`,
            /// `requested`, `confirmed`, `completed` (it finished first), `failed`,
            /// `unsupported` or `unknown`. A `cancelled` status means `confirmed`.
            public var cancelState: String?
            /// The node's own words about that cancel, when it gave any.
            public var cancelDetail: String?
            /// Whether the `cancel` verb applies to this clip now: its node advertises
            /// job cancellation for the lane and the render may still be running. When it
            /// is false, `stop_following` is the only way to stop waiting.
            public var canCancel: Bool?

            public init(id: String, batchID: String, title: String, prompt: String,
                        scene: Int, variation: Int, seed: UInt32?, modelID: String,
                        seconds: Int, resolution: String, h3Turbo: Bool?, status: String,
                        nodeJobID: String?, file: String?, outputDirectory: String,
                        error: String?, uncertainSubmission: Bool, h3Steps: Int? = nil,
                        detail: String? = nil, negativePrompt: String? = nil,
                        mediaID: String? = nil, mediaURL: String? = nil,
                        thumbnailMediaID: String? = nil, cancelState: String? = nil,
                        cancelDetail: String? = nil, canCancel: Bool? = nil) {
                self.id = id; self.batchID = batchID; self.title = title; self.prompt = prompt
                self.scene = scene; self.variation = variation; self.seed = seed
                self.modelID = modelID; self.seconds = seconds; self.resolution = resolution
                self.h3Turbo = h3Turbo; self.status = status; self.nodeJobID = nodeJobID
                self.file = file; self.outputDirectory = outputDirectory; self.error = error
                self.uncertainSubmission = uncertainSubmission
                self.h3Steps = h3Steps
                self.detail = detail
                self.negativePrompt = negativePrompt
                self.mediaID = mediaID
                self.mediaURL = mediaURL
                self.thumbnailMediaID = thumbnailMediaID
                self.cancelState = cancelState
                self.cancelDetail = cancelDetail
                self.canCancel = canCancel
            }
        }
        public var paused: Bool
        public var activeID: String?
        public var message: String?
        public var items: [Item]
        public init(paused: Bool, activeID: String?, message: String?, items: [Item]) {
            self.paused = paused; self.activeID = activeID; self.message = message; self.items = items
        }
    }
}

extension ControlHost {
    // Keep external hosts source compatible; the desktop app supplies the queue.
    public func videoQueue() async -> ControlAPI.VideoQueueView {
        .init(paused: true, activeID: nil, message: "This host does not support the video queue.", items: [])
    }
    public func enqueueVideos(_ request: ControlAPI.VideoQueueRequest) async throws -> ControlAPI.VideoQueueView {
        throw VideoQueueUnavailable()
    }
    public func controlVideoQueue(_ request: ControlAPI.VideoQueueControl) async throws -> ControlAPI.VideoQueueView {
        throw VideoQueueUnavailable()
    }
}

private struct VideoQueueUnavailable: LocalizedError {
    var errorDescription: String? { "This host does not support the video queue." }
}

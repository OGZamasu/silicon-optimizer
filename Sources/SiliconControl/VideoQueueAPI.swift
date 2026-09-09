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

        enum CodingKeys: String, CodingKey {
            case prompts, title, variations, modelID, seconds, resolution, seed
            case h3Turbo = "h3_turbo"
        }
        public init(
            prompts: [String], title: String? = nil, variations: Int? = nil,
            modelID: String? = nil, seconds: Int? = nil, resolution: String? = nil,
            seed: UInt32? = nil, h3Turbo: Bool? = nil
        ) {
            self.prompts = prompts; self.title = title; self.variations = variations
            self.modelID = modelID; self.seconds = seconds; self.resolution = resolution
            self.seed = seed; self.h3Turbo = h3Turbo
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
            public var status: String
            public var nodeJobID: String?
            public var file: String?
            public var outputDirectory: String
            public var error: String?
            public var uncertainSubmission: Bool

            public init(id: String, batchID: String, title: String, prompt: String,
                        scene: Int, variation: Int, seed: UInt32?, modelID: String,
                        seconds: Int, resolution: String, h3Turbo: Bool?, status: String,
                        nodeJobID: String?, file: String?, outputDirectory: String,
                        error: String?, uncertainSubmission: Bool) {
                self.id = id; self.batchID = batchID; self.title = title; self.prompt = prompt
                self.scene = scene; self.variation = variation; self.seed = seed
                self.modelID = modelID; self.seconds = seconds; self.resolution = resolution
                self.h3Turbo = h3Turbo; self.status = status; self.nodeJobID = nodeJobID
                self.file = file; self.outputDirectory = outputDirectory; self.error = error
                self.uncertainSubmission = uncertainSubmission
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

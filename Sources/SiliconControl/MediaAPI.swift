import Foundation

extension ControlAPI {

    /// What `POST /uploads` answers.
    ///
    /// Two ids, because they are two different permissions. `uploadID` names a file this
    /// device sent and may use as the subject of a render; `mediaID` is the same file in the
    /// serving table, so the phone can show back the photograph it just sent without keeping
    /// a second copy. Neither is a path, and neither can be turned into one by a client.
    public struct UploadResponse: Codable, Sendable, Equatable {
        public var uploadID: String
        public var mediaID: String
        public var bytes: Int
        /// The type the Mac *read off the bytes*, which is not necessarily the one the
        /// request claimed. A client that sent a PNG called `.jpg` is told it sent a PNG.
        public var contentType: String
        /// Relative, like every media link this server hands out: `/media/<id>`.
        public var mediaURL: String
        /// When this file will be swept, so an app can say "available until …" rather than
        /// discovering the 404 a week later.
        public var expiresAt: String

        public init(
            uploadID: String, mediaID: String, bytes: Int, contentType: String,
            mediaURL: String, expiresAt: String
        ) {
            self.uploadID = uploadID
            self.mediaID = mediaID
            self.bytes = bytes
            self.contentType = contentType
            self.mediaURL = mediaURL
            self.expiresAt = expiresAt
        }
    }

    /// One peer, asked directly rather than remembered: what `GET /swarm/peers/{name}/status`
    /// forwards from the node's own `/v1/node` and `/v1/gguf`.
    ///
    /// `GET /swarm` is what this Mac *last saw*, which is the honest thing for a list. This
    /// is what the node says now, and it carries the two things a poll cannot: the adapter
    /// riding on the loaded GGUF, and the models the node has on disk but is not serving.
    /// The credential that fetched it never appears in it.
    public struct PeerNodeStatus: Codable, Sendable {
        public var name: String
        public var baseURL: String
        public var reachable: Bool
        public var error: String?
        public var platform: String?
        /// "NVIDIA GeForce RTX 3090 Ti" on a CUDA node, the chip on a Mac.
        public var hardware: String?
        public var totalMemoryGB: Double?
        public var usedMemoryGB: Double?
        public var headroomGB: Double?
        public var gpuUtilization: Double?
        public var queueDepth: Int?
        public var capabilities: [SwarmView.Capability]
        public var gguf: GGUF?

        /// The node's llama.cpp lane, as `/v1/gguf` reports it.
        public struct GGUF: Codable, Sendable, Equatable {
            public var running: Bool
            /// The GGUF file being served, when one is.
            public var model: String?
            /// The LoRA riding on it. The one field `GET /swarm` cannot carry, because this
            /// Mac never asks the question its poll would need.
            public var adapter: String?
            /// Which build is serving it — "stock" or "prism".
            public var engine: String?
            public var contextLength: Int?
            public var uptimeSeconds: Double?
            /// On the node's disk, serving or not.
            public var installedModels: [String]
            public var adapters: [String]

            public init(
                running: Bool, model: String? = nil, adapter: String? = nil,
                engine: String? = nil, contextLength: Int? = nil,
                uptimeSeconds: Double? = nil, installedModels: [String] = [],
                adapters: [String] = []
            ) {
                self.running = running
                self.model = model
                self.adapter = adapter
                self.engine = engine
                self.contextLength = contextLength
                self.uptimeSeconds = uptimeSeconds
                self.installedModels = installedModels
                self.adapters = adapters
            }
        }

        public init(
            name: String, baseURL: String, reachable: Bool, error: String? = nil,
            platform: String? = nil, hardware: String? = nil, totalMemoryGB: Double? = nil,
            usedMemoryGB: Double? = nil, headroomGB: Double? = nil,
            gpuUtilization: Double? = nil, queueDepth: Int? = nil,
            capabilities: [SwarmView.Capability] = [], gguf: GGUF? = nil
        ) {
            self.name = name
            self.baseURL = baseURL
            self.reachable = reachable
            self.error = error
            self.platform = platform
            self.hardware = hardware
            self.totalMemoryGB = totalMemoryGB
            self.usedMemoryGB = usedMemoryGB
            self.headroomGB = headroomGB
            self.gpuUtilization = gpuUtilization
            self.queueDepth = queueDepth
            self.capabilities = capabilities
            self.gguf = gguf
        }
    }
}

// MARK: - Reading what a device sent

/// The two body shapes `POST /uploads` takes.
///
/// A phone's HTTP stack usually posts a file as `multipart/form-data`, and a script posts
/// the bytes with a `Content-Type` and be done with it. Both are read here rather than in
/// the route, so the route has one thing to do: decide whether what came out is something
/// this Mac will keep.
enum UploadBody {

    /// The bytes of the first file part of a multipart body, or the whole body when it is
    /// not multipart. Nil when a multipart body has no part in it to read.
    static func payload(of body: Data, contentType: String?) -> Data? {
        guard let contentType,
              contentType.lowercased().contains("multipart/"),
              let boundary = boundary(in: contentType)
        else { return body }
        return firstPart(of: body, boundary: boundary)
    }

    static func boundary(in contentType: String) -> String? {
        // `boundary=----abc` or `boundary="----abc"`, possibly with other parameters
        // around it.
        for parameter in contentType.split(separator: ";") {
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
            var value = String(trimmed.dropFirst("boundary=".count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// One part's body: everything between this part's blank line and the next boundary.
    /// Only the first part is read — this route takes one file, and a client that sends
    /// two has sent one more than it was asked for.
    static func firstPart(of body: Data, boundary: String) -> Data? {
        let marker = Data("--\(boundary)".utf8)
        guard let start = body.range(of: marker) else { return nil }
        let afterMarker = body[start.upperBound...]
        guard let headerEnd = afterMarker.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let content = body[headerEnd.upperBound...]
        guard let next = content.range(of: marker) else { return Data(content) }
        var end = next.lowerBound
        // The CRLF before the closing boundary belongs to the framing, not to the file.
        if end >= content.startIndex + 2 { end -= 2 }
        guard end >= content.startIndex else { return Data() }
        return Data(content[content.startIndex..<end])
    }
}

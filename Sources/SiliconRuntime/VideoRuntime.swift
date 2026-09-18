import Foundation
import OSLog
import SiliconCatalog
import SiliconCore
import SiliconControl

public struct VideoRequest: Sendable, Codable {
    public var entryID: String
    public var prompt: String
    /// A still image to animate, for models that take one.
    public var image: URL?
    public var seconds: Int
    public var resolution: String
    public var h3ChainPrompts: [String]?
    public var seed: UInt32?
    public var h3Turbo: Bool?
    public var h3Steps: Int?
    /// Stable client identity for node-side deduplication; not the model ID.
    public var clientID: String?
    public var outputDirectory: URL

    public init(
        entryID: String, prompt: String, image: URL? = nil,
        seconds: Int = 5, resolution: String = "720p", h3ChainPrompts: [String]? = nil,
        outputDirectory: URL, seed: UInt32? = nil, h3Turbo: Bool? = nil,
        clientID: String? = nil, h3Steps: Int? = nil
    ) {
        self.entryID = entryID
        self.prompt = prompt
        self.image = image
        self.seconds = seconds
        self.resolution = resolution
        self.h3ChainPrompts = h3ChainPrompts
        self.outputDirectory = outputDirectory
        self.seed = seed
        self.h3Turbo = h3Turbo
        self.h3Steps = h3Steps
        self.clientID = clientID
    }

    /// Shared by UI and control requests; validate before submitting any node job.
    func nodeBody() throws -> Data {
        let chainPrompts = try ControlAPI.VideoGenerateRequest.validatedH3ChainPrompts(
            h3ChainPrompts, modelID: entryID, seconds: seconds
        )
        try ControlAPI.VideoGenerateRequest.validateSampling(h3Turbo: h3Turbo, h3Steps: h3Steps, modelID: entryID)
        var body: [String: Any] = [
            "model": entryID, "prompt": prompt, "seconds": seconds, "resolution": resolution,
        ]
        if let chainPrompts { body["h3_chain_prompts"] = chainPrompts }
        if let seed { body["seed"] = seed }
        if let h3Turbo { body["h3_turbo"] = h3Turbo }
        if let h3Steps { body["h3_steps"] = h3Steps }
        if let clientID { body["entry_id"] = clientID }
        if let image {
            let data = try Data(contentsOf: image)
            body["image_b64"] = data.base64EncodedString()
            body["image_name"] = image.lastPathComponent
        }
        return try JSONSerialization.data(withJSONObject: body)
    }
}

public struct VideoNodeJob: Sendable, Codable, Equatable {
    public var id: String
    public var submittedAt: Date

    public init(id: String, submittedAt: Date = Date()) {
        self.id = id
        self.submittedAt = submittedAt
    }
}

public struct VideoResult: Sendable, Identifiable {
    public var id: String { file.path }
    public var file: URL
    public var modelName: String
    public var prompt: String
    public var elapsed: TimeInterval
    /// Which machine produced it. Nil means this Mac; a name means the work was delegated,
    /// and a clip that took eleven minutes deserves to say where those minutes went.
    public var node: String?

    public init(
        file: URL, modelName: String, prompt: String, elapsed: TimeInterval,
        node: String? = nil
    ) {
        self.file = file
        self.modelName = modelName
        self.prompt = prompt
        self.elapsed = elapsed
        self.node = node
    }
}

public enum VideoRuntimeError: LocalizedError {
    case noNode(String)
    case failed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noNode(let detail): detail
        case .failed(let message): message
        case .cancelled: "Cancelled."
        }
    }
}

/// Runs video generation on a swarm node — the same shape as the LATO.2 client: submit
/// the job, poll its status, download what it produced. A node can be a paired GPU
/// machine or the local Apple Silicon adapter; both advertise exact model capabilities.
public actor NodeVideoRuntime {

    /// Delegated jobs run on another machine and fail in ways nothing local can see.
    /// This logs the whole conversation — submit, each status, the artifact, the
    /// download — so a job that vanishes can be traced with `log show` instead of
    /// guessed at. Read it with:
    ///   log show --last 30m --predicate 'subsystem == "dev.siliconoptimizer"'
    public static let log = Logger(subsystem: "dev.siliconoptimizer", category: "delegated-jobs")

    /// The capability kind a node advertises when it can make video.
    public static let capabilityKind = "video"
    private static let maximumArtifactBytes: Int64 = 1_024 * 1_024 * 1_024
    private static let maximumJobBytes: Int64 = 1_024 * 1_024 * 1_024
    private static let maximumArtifactURLs = 8

    private var session: URLSession
    private var cancelled = false

    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: Self.sessionConfiguration())
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // Per-request idle limits below are shorter for submit/status operations.
        // A finite resource limit also bounds a server that keeps trickling bytes.
        configuration.timeoutIntervalForRequest = TimeInterval(VideoGenerationBudget.networkResourceSeconds)
        configuration.timeoutIntervalForResource = TimeInterval(VideoGenerationBudget.networkResourceSeconds)
        return configuration
    }

    public func cancel() { cancelled = true }

    /// Generates a clip on the node at `baseURL`, reporting progress through `onProgress`.
    public func generate(
        _ request: VideoRequest,
        node baseURL: URL,
        token: String?,
        resuming job: VideoNodeJob? = nil,
        onSubmitted: @escaping @Sendable (VideoNodeJob) async throws -> Void = { _ in },
        onProgress: @escaping @Sendable (NodeJobProgress) -> Void
    ) async throws -> VideoResult {
        guard let entry = VideoCatalog.entry(id: request.entryID) else {
            throw VideoRuntimeError.failed("Unknown video model \(request.entryID).")
        }
        cancelled = false
        let started = Date()

        let acceptedJob: VideoNodeJob
        if let job {
            acceptedJob = job
            onProgress(.stage("Reconnecting to the saved job"))
        } else {
            onProgress(.stage("Sending the job"))
            var submit = URLRequest(url: baseURL.appendingPathComponent("v1/text-to-video"))
            submit.httpMethod = "POST"
            submit.timeoutInterval = 120
            submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { submit.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            submit.httpBody = try request.nodeBody()

            let jobID = try await submitJob(
                submit, nodeName: baseURL.host ?? "the node", baseURL: baseURL
            )
            acceptedJob = VideoNodeJob(id: jobID)
            // Persist the receipt before any polling. A relaunch must never submit
            // another render merely because the previous download was interrupted.
            try await onSubmitted(acceptedJob)
        }
        let jobID = acceptedJob.id
        guard let statusURL = RemotePathIdentifier.appending(
            jobID, to: baseURL.appendingPathComponent("v1/jobs")
        ) else {
            throw VideoRuntimeError.failed("The node returned an invalid job id.")
        }
        Self.log.notice("video job \(jobID, privacy: .public) submitted to \(baseURL.absoluteString, privacy: .public)")

        // Includes time waiting behind other renders. Keep outer control/MCP timeouts
        // longer than this budget plus submission and the final artifact transfer.
        let deadline = acceptedJob.submittedAt.addingTimeInterval(TimeInterval(VideoGenerationBudget.nodeJobSeconds))
        // Check even an old receipt once: the node may have finished while the app
        // was closed, and the original deadline must not prevent downloading it.
        var firstPoll = true
        while firstPoll || Date() < deadline {
            if cancelled || Task.isCancelled { throw VideoRuntimeError.cancelled }
            if !firstPoll { try? await Task.sleep(for: .seconds(5)) }
            firstPoll = false
            if cancelled || Task.isCancelled { throw VideoRuntimeError.cancelled }

            var poll = URLRequest(url: statusURL)
            poll.timeoutInterval = 30
            if let token { poll.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            guard let (data, _) = try? await RemoteHTTP.data(
                for: poll, session: session, policy: .peerHost(baseURL),
                credentialOrigin: baseURL
            ) else {
                Self.log.notice("video job \(jobID, privacy: .public): poll failed, retrying")
                continue
            }
            guard let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                Self.log.notice("video job \(jobID, privacy: .public): unreadable status body")
                continue
            }

            onProgress(NodeJobProgress(from: status))

            guard let rawState = status["status"] as? String, !rawState.isEmpty else {
                throw VideoRuntimeError.failed(Self.reason(in: data)
                    ?? "The node returned no status for saved video job \(jobID). Check the peer and job before rendering again.")
            }
            let state = rawState.lowercased()
            Self.log.notice("video job \(jobID, privacy: .public): status=\(state, privacy: .public)")
            if ["failed", "error", "cancelled"].contains(state) {
                let detail = (status["error"] as? String ?? status["detail"] as? String)
                    .map { String($0.prefix(512)) }
                throw VideoNodeFailed(detail ?? "The node reported the job failed.")
            }
            if ["done", "completed", "succeeded", "finished"].contains(state) {
                onProgress(.stage("Downloading the clip"))
                let found = Self.videoURLs(in: status, base: baseURL)
                Self.log.notice("video job \(jobID, privacy: .public): artifacts=\(found.map(\.absoluteString).joined(separator: ", "), privacy: .public)")
                guard let remote = found.first else {
                    throw VideoRuntimeError.failed(
                        "The job finished but the node listed no video file."
                    )
                }
                let file = try await download(
                    remote, baseURL: baseURL, token: token, into: request.outputDirectory
                )
                Self.log.notice("video job \(jobID, privacy: .public): wrote \(file.path, privacy: .public)")
                return VideoResult(
                    file: file, modelName: entry.name, prompt: request.prompt,
                    elapsed: Date().timeIntervalSince(started),
                    node: baseURL.host
                )
            }
        }
        Self.log.error("video job \(jobID, privacy: .public): gave up waiting")
        throw VideoRuntimeError.failed(
            "Video job \(jobID) did not finish within the 12-hour queue/render limit. "
            + "Check the node's job status before submitting again; an older node may still be rendering."
        )
    }

    /// Sends a portrait and a performance to a node that can animate one with the
    /// other, and brings back the clip. Same submit-poll-download shape as video
    /// generation, because it is the same jobs API on the other end.
    public func animatePortrait(
        portrait: URL,
        driving: URL,
        node baseURL: URL,
        token: String?,
        outputDirectory: URL,
        onProgress: @escaping @Sendable (NodeJobProgress) -> Void
    ) async throws -> URL {
        cancelled = false
        onProgress(.stage("Sending the job"))
        guard let portraitData = try? Data(contentsOf: portrait),
              let drivingData = try? Data(contentsOf: driving)
        else { throw VideoRuntimeError.failed("The portrait or the take could not be read.") }

        let body: [String: Any] = [
            "image_b64": portraitData.base64EncodedString(),
            "image_name": portrait.lastPathComponent,
            "driving_b64": drivingData.base64EncodedString(),
            "driving_name": driving.lastPathComponent,
        ]
        var submit = URLRequest(url: baseURL.appendingPathComponent("v1/portrait-animate"))
        submit.httpMethod = "POST"
        submit.timeoutInterval = 300
        submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { submit.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        submit.httpBody = try JSONSerialization.data(withJSONObject: body)

        let jobID = try await submitJob(
            submit, nodeName: baseURL.host ?? "the node", baseURL: baseURL
        )
        guard let statusURL = RemotePathIdentifier.appending(
            jobID, to: baseURL.appendingPathComponent("v1/jobs")
        ) else {
            throw VideoRuntimeError.failed("The node returned an invalid job id.")
        }
        let deadline = Date().addingTimeInterval(1800)
        while Date() < deadline {
            if cancelled || Task.isCancelled { throw VideoRuntimeError.cancelled }
            try? await Task.sleep(for: .seconds(3))

            var poll = URLRequest(url: statusURL)
            poll.timeoutInterval = 30
            if let token { poll.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            guard let (data, _) = try? await RemoteHTTP.data(
                    for: poll, session: session, policy: .peerHost(baseURL),
                    credentialOrigin: baseURL
                  ),
                  let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            onProgress(NodeJobProgress(from: status))
            let state = (status["status"] as? String ?? "").lowercased()
            if ["failed", "error", "cancelled"].contains(state) {
                let detail = (status["error"] as? String ?? status["detail"] as? String)
                    .map { String($0.prefix(512)) }
                throw VideoRuntimeError.failed(detail ?? "The node reported the job failed.")
            }
            if ["done", "completed", "succeeded", "finished"].contains(state) {
                onProgress(.stage("Downloading the clip"))
                guard let remote = Self.videoURLs(in: status, base: baseURL).first else {
                    throw VideoRuntimeError.failed(
                        "The job finished but the node listed no video file."
                    )
                }
                return try await download(
                    remote, baseURL: baseURL, token: token, into: outputDirectory
                )
            }
        }
        throw VideoRuntimeError.failed("The job didn't finish in time.")
    }

    private func submitJob(
        _ request: URLRequest, nodeName: String, baseURL: URL
    ) async throws -> String {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await RemoteHTTP.data(
                for: request, session: session, policy: .peerHost(baseURL),
                credentialOrigin: baseURL
            )
        } catch {
            throw VideoRuntimeError.noNode("Could not reach \(nodeName).")
        }
        guard let http = response as? HTTPURLResponse else {
            throw VideoRuntimeError.noNode("Could not reach \(nodeName).")
        }
        guard (200..<300).contains(http.statusCode) else {
            // The node explains itself in the body — which model it actually has, what
            // it could not read. Reporting only the status code threw that away and
            // left a dead end where there was a fix-it instruction.
            if let reason = Self.reason(in: data) {
                throw VideoRuntimeError.failed(reason)
            }
            if http.statusCode == 404 {
                throw VideoRuntimeError.noNode(
                    "\(nodeName) doesn't offer this yet."
                )
            }
            throw VideoRuntimeError.failed(
                "\(nodeName) refused the job (\(http.statusCode)) without saying why."
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobID = (json["job_id"] as? String) ?? (json["id"] as? String)
        else {
            throw VideoRuntimeError.failed("\(nodeName) accepted the job but sent no job id.")
        }
        return jobID
    }

    /// Whatever the other end wrote to explain itself. Different services name the
    /// field differently, and a plain string body is worth reading too.
    static func reason(in data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error", "detail", "message", "reason"] {
                if let text = json[key] as? String, !text.isEmpty {
                    return String(text.prefix(512))
                }
                // FastAPI nests validation errors under `detail` as a list.
                if let items = json[key] as? [[String: Any]] {
                    let joined = items.compactMap { $0["msg"] as? String }.joined(separator: "; ")
                    if !joined.isEmpty { return String(joined.prefix(512)) }
                }
            }
        }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 400, !text.hasPrefix("<") else { return nil }
        return text
    }

    private func download(
        _ remote: URL, baseURL: URL, token: String?, into directory: URL
    ) async throws -> URL {
        let name = Self.outputName(extension: remote.pathExtension.isEmpty
            ? "mp4" : remote.pathExtension)
        let destination = directory.appendingPathComponent(name)
        do {
            return try await RemoteArtifactTransfer.download(
                from: remote,
                policy: .peerHost(baseURL),
                credentialOrigin: baseURL,
                bearerToken: token,
                to: destination,
                maximumBytes: Self.maximumArtifactBytes,
                budget: RemoteByteBudget(limit: Self.maximumJobBytes),
                timeout: 600,
                allowedContentTypes: ["video/*", "application/octet-stream"],
                sessionConfiguration: session.configuration
            )
        } catch {
            throw VideoRuntimeError.failed(
                "Downloading the finished clip failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Liberal status parsing

    /// Any string anywhere in the status payload that ends in a video extension is an
    /// artifact — the same forgiving read the LATO.2 client uses, because pinning a
    /// nested schema across two codebases is how integrations rot.
    static func videoURLs(in json: Any, base: URL) -> [URL] {
        var found: [URL] = []
        collectVideoStrings(json, into: &found, base: base, depth: 0)
        return found
    }

    private static func collectVideoStrings(
        _ value: Any, into found: inout [URL], base: URL, depth: Int
    ) {
        guard depth <= 32, found.count < maximumArtifactURLs else { return }
        if let text = value as? String {
            let policy = RemoteURLPolicy.peerHost(base)
            if let url = policy.resolve(text, relativeTo: base),
               ["mp4", "webm", "mov"].contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        } else if let dictionary = value as? [String: Any] {
            for entry in dictionary.values {
                collectVideoStrings(entry, into: &found, base: base, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            for entry in array {
                collectVideoStrings(entry, into: &found, base: base, depth: depth + 1)
            }
        }
    }

    public static func outputName(extension fileExtension: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let suffix = String(UUID().uuidString.prefix(8))
        return "silicon-video-\(formatter.string(from: date))-\(suffix).\(fileExtension)"
    }
}

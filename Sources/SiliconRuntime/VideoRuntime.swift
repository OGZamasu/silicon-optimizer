import Foundation
import OSLog
import SiliconCatalog
import SiliconCore

public struct VideoRequest: Sendable {
    public var entryID: String
    public var prompt: String
    /// A still image to animate, for models that take one.
    public var image: URL?
    public var seconds: Int
    public var resolution: String
    public var outputDirectory: URL

    public init(
        entryID: String, prompt: String, image: URL? = nil,
        seconds: Int = 5, resolution: String = "720p", outputDirectory: URL
    ) {
        self.entryID = entryID
        self.prompt = prompt
        self.image = image
        self.seconds = seconds
        self.resolution = resolution
        self.outputDirectory = outputDirectory
    }
}

public struct VideoResult: Sendable, Identifiable {
    public var id: String { file.path }
    public var file: URL
    public var modelName: String
    public var prompt: String
    public var elapsed: TimeInterval

    public init(file: URL, modelName: String, prompt: String, elapsed: TimeInterval) {
        self.file = file
        self.modelName = modelName
        self.prompt = prompt
        self.elapsed = elapsed
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
/// the job, poll its status, download what it produced. Local video generation on Apple
/// Silicon is not worth pretending about yet, so there is no local branch to fall back
/// to; the honest answer without a capable node is "not yet", said in the UI.
public actor NodeVideoRuntime {

    /// Delegated jobs run on another machine and fail in ways nothing local can see.
    /// This logs the whole conversation — submit, each status, the artifact, the
    /// download — so a job that vanishes can be traced with `log show` instead of
    /// guessed at. Read it with:
    ///   log show --last 30m --predicate 'subsystem == "dev.siliconoptimizer"'
    public static let log = Logger(subsystem: "dev.siliconoptimizer", category: "delegated-jobs")

    /// The capability kind a node advertises when it can make video.
    public static let capabilityKind = "video"

    private var session: URLSession
    private var cancelled = false

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func cancel() { cancelled = true }

    /// Generates a clip on the node at `baseURL`, reporting progress through `onStage`.
    public func generate(
        _ request: VideoRequest,
        node baseURL: URL,
        token: String?,
        onStage: @escaping @Sendable (String) -> Void
    ) async throws -> VideoResult {
        guard let entry = VideoCatalog.entry(id: request.entryID) else {
            throw VideoRuntimeError.failed("Unknown video model \(request.entryID).")
        }
        cancelled = false
        let started = Date()

        onStage("Sending the job")
        var body: [String: Any] = [
            "model": entry.id,
            "prompt": request.prompt,
            "seconds": request.seconds,
            "resolution": request.resolution,
        ]
        if let image = request.image, let data = try? Data(contentsOf: image) {
            body["image_b64"] = data.base64EncodedString()
            body["image_name"] = image.lastPathComponent
        }

        var submit = URLRequest(url: baseURL.appendingPathComponent("v1/text-to-video"))
        submit.httpMethod = "POST"
        submit.timeoutInterval = 120
        submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { submit.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        submit.httpBody = try JSONSerialization.data(withJSONObject: body)

        let jobID = try await submitJob(submit, nodeName: baseURL.host ?? "the node")
        Self.log.notice("video job \(jobID, privacy: .public) submitted to \(baseURL.absoluteString, privacy: .public)")

        // Poll until the node says it is done. Video is minutes, not seconds, so the
        // interval is generous and the cap is a full hour.
        let deadline = Date().addingTimeInterval(3600)
        while Date() < deadline {
            if cancelled || Task.isCancelled { throw VideoRuntimeError.cancelled }
            try? await Task.sleep(for: .seconds(5))

            var poll = URLRequest(url: baseURL.appendingPathComponent("v1/jobs/\(jobID)"))
            poll.timeoutInterval = 30
            if let token { poll.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            guard let (data, _) = try? await session.data(for: poll) else {
                Self.log.notice("video job \(jobID, privacy: .public): poll failed, retrying")
                continue
            }
            guard let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                Self.log.notice("video job \(jobID, privacy: .public): unreadable status body")
                continue
            }

            if let stage = Self.stageDescription(from: status) { onStage(stage) }

            let state = (status["status"] as? String ?? "").lowercased()
            Self.log.notice("video job \(jobID, privacy: .public): status=\(state, privacy: .public)")
            if ["failed", "error", "cancelled"].contains(state) {
                let detail = status["error"] as? String ?? status["detail"] as? String
                throw VideoRuntimeError.failed(detail ?? "The node reported the job failed.")
            }
            if ["done", "completed", "succeeded", "finished"].contains(state) {
                onStage("Downloading the clip")
                let found = Self.videoURLs(in: status, base: baseURL)
                Self.log.notice("video job \(jobID, privacy: .public): artifacts=\(found.map(\.absoluteString).joined(separator: ", "), privacy: .public)")
                guard let remote = found.first else {
                    throw VideoRuntimeError.failed(
                        "The job finished but the node listed no video file."
                    )
                }
                let file = try await download(
                    remote, token: token, into: request.outputDirectory
                )
                Self.log.notice("video job \(jobID, privacy: .public): wrote \(file.path, privacy: .public)")
                return VideoResult(
                    file: file, modelName: entry.name, prompt: request.prompt,
                    elapsed: Date().timeIntervalSince(started)
                )
            }
        }
        Self.log.error("video job \(jobID, privacy: .public): gave up waiting")
        throw VideoRuntimeError.failed("The job didn't finish within an hour.")
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
        onStage: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        cancelled = false
        onStage("Sending the job")
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

        let jobID = try await submitJob(submit, nodeName: baseURL.host ?? "the node")
        let deadline = Date().addingTimeInterval(1800)
        while Date() < deadline {
            if cancelled || Task.isCancelled { throw VideoRuntimeError.cancelled }
            try? await Task.sleep(for: .seconds(3))

            var poll = URLRequest(url: baseURL.appendingPathComponent("v1/jobs/\(jobID)"))
            poll.timeoutInterval = 30
            if let token { poll.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            guard let (data, _) = try? await session.data(for: poll),
                  let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let stage = Self.stageDescription(from: status) { onStage(stage) }
            let state = (status["status"] as? String ?? "").lowercased()
            if ["failed", "error", "cancelled"].contains(state) {
                let detail = status["error"] as? String ?? status["detail"] as? String
                throw VideoRuntimeError.failed(detail ?? "The node reported the job failed.")
            }
            if ["done", "completed", "succeeded", "finished"].contains(state) {
                onStage("Downloading the clip")
                guard let remote = Self.videoURLs(in: status, base: baseURL).first else {
                    throw VideoRuntimeError.failed(
                        "The job finished but the node listed no video file."
                    )
                }
                return try await download(remote, token: token, into: outputDirectory)
            }
        }
        throw VideoRuntimeError.failed("The job didn't finish in time.")
    }

    private func submitJob(_ request: URLRequest, nodeName: String) async throws -> String {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
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
                if let text = json[key] as? String, !text.isEmpty { return text }
                // FastAPI nests validation errors under `detail` as a list.
                if let items = json[key] as? [[String: Any]] {
                    let joined = items.compactMap { $0["msg"] as? String }.joined(separator: "; ")
                    if !joined.isEmpty { return joined }
                }
            }
        }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 400, !text.hasPrefix("<") else { return nil }
        return text
    }

    private func download(_ remote: URL, token: String?, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var request = URLRequest(url: remote)
        request.timeoutInterval = 600
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty
        else {
            throw VideoRuntimeError.failed("Downloading the finished clip failed.")
        }
        let name = Self.outputName(extension: remote.pathExtension.isEmpty
            ? "mp4" : remote.pathExtension)
        let destination = directory.appendingPathComponent(name)
        try data.write(to: destination)
        return destination
    }

    // MARK: - Liberal status parsing

    /// Any string anywhere in the status payload that ends in a video extension is an
    /// artifact — the same forgiving read the LATO.2 client uses, because pinning a
    /// nested schema across two codebases is how integrations rot.
    static func videoURLs(in json: Any, base: URL) -> [URL] {
        var found: [URL] = []
        collectVideoStrings(json, into: &found, base: base)
        return found
    }

    private static func collectVideoStrings(_ value: Any, into found: inout [URL], base: URL) {
        if let text = value as? String {
            let lowered = text.lowercased()
            if ["mp4", "webm", "mov"].contains(where: { lowered.hasSuffix(".\($0)") }) {
                if text.hasPrefix("http") {
                    URL(string: text).map { found.append($0) }
                } else {
                    found.append(base.appendingPathComponent(
                        text.hasPrefix("/") ? String(text.dropFirst()) : text
                    ))
                }
            }
        } else if let dictionary = value as? [String: Any] {
            for entry in dictionary.values { collectVideoStrings(entry, into: &found, base: base) }
        } else if let array = value as? [Any] {
            for entry in array { collectVideoStrings(entry, into: &found, base: base) }
        }
    }

    static func stageDescription(from status: [String: Any]) -> String? {
        if let stage = status["stage"] as? String, !stage.isEmpty { return stage }
        if let progress = status["progress"] as? Double {
            return "Rendering — \(Int(progress * 100))%"
        }
        if let state = status["status"] as? String, !state.isEmpty {
            return state.capitalized
        }
        return nil
    }

    public static func outputName(extension fileExtension: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let suffix = String(UUID().uuidString.prefix(8))
        return "silicon-video-\(formatter.string(from: date))-\(suffix).\(fileExtension)"
    }
}

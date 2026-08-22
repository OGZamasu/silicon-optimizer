import Foundation
import os

/// Image generation on a swarm node — the #136 contract, built before the node ships
/// it so the capability lights up the moment a node advertises "text-to-image".
///
/// Mirrors `NodeVideoRuntime`: submit, poll the shared jobs queue, download. Images
/// finish in seconds-to-a-minute rather than minutes, so the poll is tighter and the
/// deadline shorter than video's.
public struct NodeImageRequest: Sendable {
    public var prompt: String
    public var negativePrompt: String?
    public var width: Int
    public var height: Int
    public var steps: Int?
    public var seed: Int?
    /// A model id the node's store knows, or nil for the node's configured default.
    public var model: String?
    public var outputDirectory: URL

    public init(
        prompt: String, negativePrompt: String? = nil, width: Int, height: Int,
        steps: Int? = nil, seed: Int? = nil, model: String? = nil, outputDirectory: URL
    ) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.steps = steps
        self.seed = seed
        self.model = model
        self.outputDirectory = outputDirectory
    }
}

public struct NodeImageResult: Sendable {
    public var images: [URL]
    public var elapsed: TimeInterval
}

public actor NodeImageRuntime {

    private static let log = Logger(subsystem: "dev.siliconoptimizer", category: "node-image")
    private let session = URLSession(configuration: .default)
    private var cancelled = false

    public init() {}

    public func cancel() { cancelled = true }

    /// The submission body, exactly as #136 specifies. Separated so tests can pin the
    /// contract without a server.
    static func submissionBody(for request: NodeImageRequest) -> [String: Any] {
        var body: [String: Any] = [
            "prompt": request.prompt,
            "width": request.width,
            "height": request.height,
        ]
        if let steps = request.steps { body["steps"] = steps }
        if let seed = request.seed { body["seed"] = seed }
        if let negative = request.negativePrompt, !negative.isEmpty {
            body["negative_prompt"] = negative
        }
        if let model = request.model { body["model"] = model }
        return body
    }

    public func generate(
        _ request: NodeImageRequest,
        node baseURL: URL,
        token: String?,
        onProgress: @escaping @Sendable (NodeJobProgress) -> Void
    ) async throws -> NodeImageResult {
        cancelled = false
        let started = Date()
        onProgress(.stage("Sending the job"))

        var submit = URLRequest(url: baseURL.appendingPathComponent("v1/text-to-image"))
        submit.httpMethod = "POST"
        submit.timeoutInterval = 60
        submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { submit.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        submit.httpBody = try JSONSerialization.data(
            withJSONObject: Self.submissionBody(for: request)
        )

        let nodeName = baseURL.host ?? "the node"
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: submit)
        } catch {
            throw VideoRuntimeError.noNode("Could not reach \(nodeName).")
        }
        guard let http = response as? HTTPURLResponse else {
            throw VideoRuntimeError.noNode("Could not reach \(nodeName).")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let reason = NodeVideoRuntime.reason(in: data) {
                throw VideoRuntimeError.failed(reason)
            }
            if http.statusCode == 404 {
                // The one refusal the contract predicts before the node ships #136.
                throw VideoRuntimeError.noNode(
                    "\(nodeName) doesn't generate images yet (node update #136)."
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
        Self.log.notice("image job \(jobID, privacy: .public) submitted to \(baseURL.absoluteString, privacy: .public)")

        // Images are seconds-to-a-minute; poll briskly, give up after fifteen minutes.
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            if cancelled || Task.isCancelled { throw VideoRuntimeError.cancelled }
            try? await Task.sleep(for: .seconds(2))

            var poll = URLRequest(url: baseURL.appendingPathComponent("v1/jobs/\(jobID)"))
            poll.timeoutInterval = 30
            if let token { poll.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            guard let (statusData, _) = try? await session.data(for: poll),
                  let status = try? JSONSerialization.jsonObject(with: statusData)
                    as? [String: Any]
            else { continue }

            onProgress(NodeJobProgress(from: status))

            let state = (status["status"] as? String ?? "").lowercased()
            if ["failed", "error", "cancelled"].contains(state) {
                let detail = status["error"] as? String ?? status["detail"] as? String
                throw VideoRuntimeError.failed(detail ?? "The node reported the job failed.")
            }
            if ["done", "completed", "succeeded", "finished"].contains(state) {
                onProgress(.stage("Downloading the image"))
                let remotes = Self.imageURLs(in: status, base: baseURL)
                guard !remotes.isEmpty else {
                    throw VideoRuntimeError.failed(
                        "The node finished the job but published no image."
                    )
                }
                var saved: [URL] = []
                for remote in remotes {
                    var fetch = URLRequest(url: remote)
                    fetch.timeoutInterval = 120
                    if let token {
                        fetch.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    let (bytes, _) = try await session.data(for: fetch)
                    let destination = request.outputDirectory.appendingPathComponent(
                        "silicon-image-\(UUID().uuidString.prefix(8)).png"
                    )
                    try FileManager.default.createDirectory(
                        at: request.outputDirectory, withIntermediateDirectories: true
                    )
                    try bytes.write(to: destination)
                    saved.append(destination)
                }
                return NodeImageResult(images: saved, elapsed: Date().timeIntervalSince(started))
            }
        }
        throw VideoRuntimeError.failed("The node did not finish the image within 15 minutes.")
    }

    /// Result URLs out of whatever field name the node uses, made absolute.
    static func imageURLs(in status: [String: Any], base: URL) -> [URL] {
        let raw = (status["result_urls"] as? [String])
            ?? (status["results"] as? [String])
            ?? (status["images"] as? [String])
            ?? []
        return raw.compactMap { path in
            if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
            return URL(string: path, relativeTo: base)?.absoluteURL
        }
    }
}

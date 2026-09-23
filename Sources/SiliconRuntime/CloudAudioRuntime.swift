import Foundation
import SiliconCatalog
import SiliconCore
import os

/// Speech and music on a remote provider, for people who have opted in with a key.
///
/// This is not the OpenAI-compatible path the chat models use. GMI Cloud's audio models live
/// behind a request queue on a different host entirely — submit, get an id, poll, download —
/// which is the same shape as a swarm node's job API, so this reuses `NodeJobProgress` and
/// reads the same way in the UI as a render happening on your own PC.
///
/// The model list it works from lives in `SiliconCatalog` beside every other catalogue.
public struct CloudAudioRequest: Sendable {
    /// The provider's model id, verbatim. Not an enum: GMI was serving models its own
    /// catalogue had not documented yet, so anything that only accepts ids known at compile
    /// time is wrong the week it ships.
    public var model: String
    public var kind: CloudAudioKind
    /// Speech: the text to read. Music: the lyrics, `\n` between lines, `[Verse]`-style
    /// structure tags honoured.
    public var text: String
    /// Music only: genre, mood, scenario.
    public var stylePrompt: String?
    /// Speech only. Nil takes the model's default voice.
    public var voiceID: String?
    public var speed: Double?
    public var format: String
    public var sampleRate: Int?
    public var outputDirectory: URL

    public init(
        model: String, kind: CloudAudioKind, text: String, stylePrompt: String? = nil,
        voiceID: String? = nil, speed: Double? = nil, format: String = "mp3",
        sampleRate: Int? = nil, outputDirectory: URL
    ) {
        self.model = model
        self.kind = kind
        self.text = text
        self.stylePrompt = stylePrompt
        self.voiceID = voiceID
        self.speed = speed
        self.format = format
        self.sampleRate = sampleRate
        self.outputDirectory = outputDirectory
    }
}

public struct CloudAudioResult: Sendable {
    public var audio: URL
    public var modelName: String
    public var elapsed: TimeInterval

    public init(audio: URL, modelName: String, elapsed: TimeInterval) {
        self.audio = audio
        self.modelName = modelName
        self.elapsed = elapsed
    }
}

public enum CloudAudioError: LocalizedError {
    case submitFailed(Int, String)
    case jobFailed(String)
    case noAudioReturned
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .submitFailed(let status, let message):
            "The provider answered \(status): \(message)"
        case .jobFailed(let message):
            message
        case .noAudioReturned:
            "The provider reported success but returned no audio."
        case .cancelled:
            "Cancelled."
        }
    }
}

public actor CloudAudioRuntime {

    private static let log = Logger(subsystem: "dev.siliconoptimizer", category: "cloud-audio")
    private static let maximumArtifactURLs = 8
    private static let maximumArtifactBytes: Int64 = 256 * 1_024 * 1_024
    private let session: URLSession
    private let artifactDownload: ArtifactDownload
    private var activeJobIDs = Set<UUID>()
    private var cancelledJobIDs = Set<UUID>()
    /// Each job's work, so cancelling a job stops the submission, poll or download that is in
    /// flight instead of waiting for it to come back to a checkpoint.
    private var work: [UUID: Task<CloudAudioResult, Error>] = [:]

    /// Source URL, destination, byte limit, budget and timeout in; the published file out.
    /// The app always uses the resolved-address transport, which is not URLSession, so a
    /// test's URLProtocol stub cannot answer it and the tests hand in a local TLS fixture.
    typealias ArtifactDownload = @Sendable (
        URL, URL, Int64, RemoteByteBudget, TimeInterval
    ) async throws -> URL

    public init() {
        session = URLSession(configuration: .default)
        artifactDownload = { url, destination, maximumBytes, budget, timeout in
            try await PublicHTTPSArtifactTransfer.download(
                from: url, to: destination, maximumBytes: maximumBytes, budget: budget,
                timeout: timeout
            )
        }
    }

    init(session: URLSession, artifactDownload: @escaping ArtifactDownload) {
        self.session = session
        self.artifactDownload = artifactDownload
    }

    public func cancel() {
        for jobID in activeJobIDs { cancel(jobID: jobID) }
    }

    /// A delayed cancellation must not stop the next job after the old one has finished.
    public func cancel(jobID: UUID) {
        guard activeJobIDs.contains(jobID) else { return }
        cancelledJobIDs.insert(jobID)
        work[jobID]?.cancel()
    }

    private func checkCancellation(jobID: UUID) throws {
        if cancelledJobIDs.contains(jobID) || Task.isCancelled {
            throw CloudAudioError.cancelled
        }
    }

    // MARK: - The wire, kept testable

    /// The queue path both submission and polling hang off.
    static let requestsPath = "api/v1/ie/requestqueue/apikey/requests"

    /// `{"model": …, "payload": {…}}` — the provider's envelope, with a payload whose keys
    /// differ entirely between the two kinds. Static so a test can pin the contract without
    /// a network or a key.
    static func submissionBody(for request: CloudAudioRequest) -> [String: Any] {
        var payload: [String: Any] = ["format": request.format]

        switch request.kind {
        case .speech:
            payload["text"] = request.text
            if let voice = request.voiceID, !voice.isEmpty { payload["voice_id"] = voice }
            // Sent as strings: the documented examples quote every numeric field on this
            // endpoint, and a server that parses "1" is not guaranteed to parse 1.
            if let speed = request.speed { payload["speed"] = String(format: "%g", speed) }
            if let rate = request.sampleRate { payload["audio_sample_rate"] = String(rate) }
        case .music:
            payload["lyrics"] = request.text
            if let prompt = request.stylePrompt, !prompt.isEmpty { payload["prompt"] = prompt }
            // Music quotes nothing — same provider, different convention per model family.
            if let rate = request.sampleRate { payload["sample_rate"] = rate }
        }

        return ["model": request.model, "payload": payload]
    }

    /// Every audio URL an outcome carries, in preference order.
    ///
    /// Three spellings for the same thing across two model families: music answers with a
    /// flat `audio_url` *and* a `medias` array *and* `media_urls`; speech answers with
    /// `media_urls` alone. Reading all three costs nothing and means one renamed key upstream
    /// does not become a failed render here.
    static func audioURLs(inOutcome outcome: [String: Any], base: URL) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        let policy = RemoteURLPolicy.publicHTTPS
        func add(_ raw: String) {
            guard found.count < maximumArtifactURLs, seen.insert(raw).inserted,
                  let url = policy.resolve(raw, relativeTo: base)
            else { return }
            found.append(url)
        }
        if let direct = outcome["audio_url"] as? String { add(direct) }
        for key in ["media_urls", "medias"] {
            for entry in (outcome[key] as? [[String: Any]]) ?? [] {
                if let url = entry["url"] as? String { add(url) }
                if found.count == maximumArtifactURLs { break }
            }
        }
        return found
    }

    /// Terminal states, so a failure ends the poll instead of running out the deadline.
    /// `cancelled` counts: a job someone stopped in the provider's console is finished, and
    /// waiting thirty more minutes for it helps no one.
    static func terminalStatus(_ status: String) -> Bool {
        ["success", "succeeded", "failed", "error", "cancelled", "canceled"]
            .contains(status.lowercased())
    }

    static func succeeded(_ status: String) -> Bool {
        ["success", "succeeded"].contains(status.lowercased())
    }

    // MARK: - Generation

    public func generate(
        _ request: CloudAudioRequest,
        base: URL,
        apiKey: String,
        jobID: UUID = UUID(),
        onProgress: @escaping @Sendable (NodeJobProgress) -> Void
    ) async throws -> CloudAudioResult {
        guard activeJobIDs.insert(jobID).inserted else {
            throw CloudAudioError.jobFailed("A cloud audio job already uses this identifier.")
        }
        defer {
            activeJobIDs.remove(jobID)
            cancelledJobIDs.remove(jobID)
            work[jobID] = nil
        }
        let job = Task {
            try await run(request, base: base, apiKey: apiKey, jobID: jobID, onProgress: onProgress)
        }
        work[jobID] = job
        let result: CloudAudioResult
        do {
            result = try await withTaskCancellationHandler {
                try await job.value
            } onCancel: {
                job.cancel()
            }
        } catch where cancelledJobIDs.contains(jobID) || job.isCancelled {
            // URLSession, the transport or a checkpoint: whichever noticed first, a stopped
            // job reports one thing.
            throw CloudAudioError.cancelled
        }
        // A cancellation that arrived as the work finished still wins over its audio.
        guard !cancelledJobIDs.contains(jobID), !Task.isCancelled else {
            try? FileManager.default.removeItem(at: result.audio)
            throw CloudAudioError.cancelled
        }
        return result
    }

    private func run(
        _ request: CloudAudioRequest, base: URL, apiKey: String, jobID: UUID,
        onProgress: @escaping @Sendable (NodeJobProgress) -> Void
    ) async throws -> CloudAudioResult {
        try checkCancellation(jobID: jobID)
        let started = Date()
        onProgress(.stage(request.kind == .music ? "Sending the lyrics" : "Sending the text"))

        var submit = URLRequest(url: base.appendingPathComponent(Self.requestsPath))
        submit.httpMethod = "POST"
        submit.timeoutInterval = 60
        submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submit.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        submit.httpBody = try JSONSerialization.data(
            withJSONObject: Self.submissionBody(for: request)
        )

        let (submitData, submitResponse) = try await RemoteHTTP.data(
            for: submit, session: session, policy: .sameOrigin(base),
            credentialOrigin: base
        )
        try checkCancellation(jobID: jobID)
        let submitStatus = (submitResponse as? HTTPURLResponse)?.statusCode ?? 502
        guard (200..<300).contains(submitStatus) else {
            throw CloudAudioError.submitFailed(
                submitStatus, Self.message(inBody: submitData) ?? "no detail"
            )
        }
        guard let submitted = (try? JSONSerialization.jsonObject(with: submitData))
                as? [String: Any],
              let requestID = submitted["request_id"] as? String,
              RemotePathIdentifier.appending(
                requestID, to: base.appendingPathComponent(Self.requestsPath)
              ) != nil
        else {
            throw CloudAudioError.submitFailed(submitStatus, "no valid request id in the answer")
        }

        Self.log.info("cloud audio \(request.model, privacy: .public) → \(requestID, privacy: .public)")

        // Music is documented at 30–60 seconds and speech is quicker, but a queue is a queue;
        // the deadline is generous and the poll is loose enough not to hammer a paid API.
        let outcome = try await poll(
            requestID: requestID, base: base, apiKey: apiKey, jobID: jobID,
            onProgress: onProgress
        )
        try checkCancellation(jobID: jobID)

        let urls = Self.audioURLs(inOutcome: outcome, base: base)
        guard let first = urls.first else { throw CloudAudioError.noAudioReturned }

        onProgress(.stage("Downloading"))
        let audio = try await download(
            first, into: request.outputDirectory, model: request.model,
            format: request.format, jobID: jobID
        )
        do {
            try checkCancellation(jobID: jobID)
        } catch {
            try? FileManager.default.removeItem(at: audio)
            throw error
        }
        return CloudAudioResult(
            audio: audio, modelName: request.model, elapsed: Date().timeIntervalSince(started)
        )
    }

    private func poll(
        requestID: String, base: URL, apiKey: String, jobID: UUID,
        onProgress: @escaping @Sendable (NodeJobProgress) -> Void
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(900)
        guard let statusURL = RemotePathIdentifier.appending(
            requestID, to: base.appendingPathComponent(Self.requestsPath)
        ) else {
            throw CloudAudioError.submitFailed(502, "invalid request id in the answer")
        }

        while Date() < deadline {
            try checkCancellation(jobID: jobID)

            var poll = URLRequest(url: statusURL)
            poll.timeoutInterval = 30
            poll.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            // A single failed poll is a blip, not a failure: keep waiting rather than
            // throwing away a render that is probably still running.
            let answer = try? await RemoteHTTP.data(
                    for: poll, session: session, policy: .sameOrigin(base),
                    credentialOrigin: base
               )
            try checkCancellation(jobID: jobID)
            if let (data, response) = answer,
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                onProgress(NodeJobProgress(from: status))
                let state = (status["status"] as? String) ?? ""
                if Self.terminalStatus(state) {
                    guard Self.succeeded(state) else {
                        throw CloudAudioError.jobFailed(
                            Self.message(inBody: data) ?? "The provider reported: \(state)."
                        )
                    }
                    return (status["outcome"] as? [String: Any]) ?? [:]
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        try checkCancellation(jobID: jobID)
        throw CloudAudioError.jobFailed("The provider did not finish within 15 minutes.")
    }

    private func download(
        _ url: URL, into directory: URL, model: String, format: String, jobID: UUID
    ) async throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let safeModel = String(model.map {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-"
        }.prefix(80))
        let safeFormat = String(format.filter(\.isLetter).prefix(8)).lowercased()
        let destination = directory.appendingPathComponent(
            "\(safeModel)-\(stamp)-\(UUID().uuidString).\(safeFormat.isEmpty ? "mp3" : safeFormat)"
        )
        do {
            try checkCancellation(jobID: jobID)
            return try await artifactDownload(
                url, destination, Self.maximumArtifactBytes,
                RemoteByteBudget(limit: Self.maximumArtifactBytes), 600
            )
        } catch let error as RemoteTransferError {
            throw CloudAudioError.submitFailed(502, error.localizedDescription)
        }
    }

    static func message(inBody body: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else { return nil }
        if let outcome = root["outcome"] as? [String: Any],
           let message = (outcome["message"] ?? outcome["error"]) as? String {
            return String(message.prefix(512))
        }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            return String(message.prefix(512))
        }
        for key in ["message", "error", "detail"] {
            if let message = root[key] as? String, !message.isEmpty {
                return String(message.prefix(512))
            }
        }
        return nil
    }
}

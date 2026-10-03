import Foundation

/// FreeVideo is a ComfyUI custom node on a separately installed CUDA machine. Its
/// native protocol is deliberately independent of the swarm video job contract.
public struct FreeVideoRequest: Sendable {
    public var prompt: String
    public var width: Int
    public var height: Int
    public var seconds: Double
    public var seed: UInt32
    public var twoPass: Bool
    public var firstFrame: URL?
    public var lastFrame: URL?

    public init(prompt: String, width: Int = 768, height: Int = 448, seconds: Double = 5,
                seed: UInt32, twoPass: Bool = true, firstFrame: URL? = nil, lastFrame: URL? = nil) {
        self.prompt = prompt
        self.width = width
        self.height = height
        self.seconds = seconds
        self.seed = seed
        self.twoPass = twoPass
        self.firstFrame = firstFrame
        self.lastFrame = lastFrame
    }

    public func validate() throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 64 * 1_024 else {
            throw FreeVideoError.invalidRequest("Enter a prompt of at most 64 KiB describing the video and its audio.")
        }
        guard [width, height].allSatisfy({ (256...4096).contains($0) && $0 % 32 == 0 }) else {
            throw FreeVideoError.invalidRequest("Canvas sides must be multiples of 32, from 256 to 4096 pixels.")
        }
        guard seconds.isFinite, (1.625...15).contains(seconds) else {
            throw FreeVideoError.invalidRequest("Choose a duration from 1.625 to 15 seconds. Longer FreeVideo clips are experimental and remain available in its workspace.")
        }
    }
}

public struct FreeVideoEngineStatus: Sendable, Equatable {
    public var ready: Bool
    public var detail: String
    public init(ready: Bool, detail: String) { self.ready = ready; self.detail = detail }
}

/// Save the receipt before following a job. Reopening the app follows this same
/// request, never submits the prompt again, and pins the original server address.
public struct FreeVideoJob: Codable, Sendable, Equatable {
    public var id: String
    public var nodeID: String
    public var submittedAt: Date
    public init(id: String, nodeID: String, submittedAt: Date = Date()) {
        self.id = id; self.nodeID = nodeID; self.submittedAt = submittedAt
    }
}

public struct FreeVideoResult: Sendable {
    public var file: URL
    public var jobID: String
    public init(file: URL, jobID: String) { self.file = file; self.jobID = jobID }
}

public enum FreeVideoCancelOutcome: String, Sendable {
    case cancelled, cancelling, finished
    public var message: String {
        switch self {
        case .cancelled: "The queued FreeVideo job was cancelled."
        case .cancelling: "FreeVideo is stopping this render. Waiting for confirmation…"
        case .finished: "This job has left the render queue. Checking its saved result…"
        }
    }
}

public enum FreeVideoError: LocalizedError, Sendable {
    case invalidRequest(String), notReady(String), server(String), invalidOutput(String)
    case submissionUnknown, cancelled, missingJob, expired
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .notReady(let message), .server(let message),
             .invalidOutput(let message): message
        case .submissionUnknown:
            "ComfyUI may have accepted the render, but the app did not receive a valid receipt. Open its workspace and check the queue/history before submitting again."
        case .cancelled: "The FreeVideo job was cancelled."
        case .missingJob:
            "This ComfyUI server no longer recognizes the saved job. Check its workspace and history before forgetting the receipt or submitting again."
        case .expired:
            "The app followed this job for 12 hours. It may still be rendering in ComfyUI; inspect the workspace before submitting again."
        }
    }
}

public actor FreeVideoRuntime {
    private let session: URLSession
    private let pollInterval: Duration
    private static let maximumVideoBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    private static let maximumFrameBytes = 32 * 1_024 * 1_024

    public init(session: URLSession? = nil, pollInterval: Duration = .seconds(2)) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        self.session = session ?? URLSession(configuration: configuration)
        self.pollInterval = pollInterval
    }

    public nonisolated static func validatedBaseURL(_ text: String) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true,
              !url.path.contains("\\"), !url.path.contains("%"),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              text.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw FreeVideoError.invalidRequest("Enter an http:// or https:// ComfyUI address without a password, query, or fragment.")
        }
        return url
    }

    /// Neither this probe nor submit calls the installation or model download routes.
    public func check(node base: URL) async throws -> FreeVideoEngineStatus {
        _ = try Self.validatedBaseURL(base.absoluteString)
        let launcher = try await json(at: base.appendingPathComponent("freevideo/launcher"), base: base)
        guard (launcher["protocol"] as? Int) == 1 else {
            throw FreeVideoError.notReady("This server does not expose the supported FreeVideo plugin protocol. Install or update FreeVideo in ComfyUI and restart it.")
        }
        let schema = try await json(at: base.appendingPathComponent("object_info/FreeVideoGenerate"), base: base)
        guard let generator = schema["FreeVideoGenerate"] as? [String: Any],
              let input = generator["input"] as? [String: Any],
              let required = input["required"] as? [String: Any],
              ["text", "width", "height", "seconds", "seed"].allSatisfy({ required[$0] != nil }) else {
            throw FreeVideoError.notReady("FreeVideoGenerate is missing or incompatible. Install the FreeVideo custom node and restart ComfyUI.")
        }
        let setup = try await json(at: base.appendingPathComponent("freevideo/setup"), base: base)
        guard let discovery = setup["discovery"] as? [String: Any],
              let ready = discovery["ready"] as? Bool else {
            throw FreeVideoError.notReady("FreeVideo did not report engine readiness. Open its workspace to complete setup.")
        }
        return FreeVideoEngineStatus(ready: ready,
            detail: (discovery["detail"] as? String).map { String($0.prefix(1_024)) }
                ?? (ready ? "FreeVideo is ready on this ComfyUI server." : "Complete FreeVideo setup in the ComfyUI workspace."))
    }

    public func submit(_ request: FreeVideoRequest, node base: URL) async throws -> FreeVideoJob {
        try request.validate()
        let readiness = try await check(node: base)
        guard readiness.ready else { throw FreeVideoError.notReady(readiness.detail) }
        let nodeID = "silicon_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var media: [[String: String]] = []
        for (role, file) in [("first", request.firstFrame), ("last", request.lastFrame)] {
            if let file { media.append(["role": role, "file": try await uploadFrame(file, base: base)]) }
        }
        try Task.checkCancellation()
        var submit = URLRequest(url: base.appendingPathComponent("prompt"))
        submit.httpMethod = "POST"
        submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submit.timeoutInterval = 120
        submit.httpBody = try Self.workflowBody(request, nodeID: nodeID, media: media)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await RemoteHTTP.data(for: submit, session: session, policy: .sameOrigin(base))
        } catch {
            // Cancellation/timeout after sending a POST also leaves the remote outcome unknown.
            throw FreeVideoError.submissionUnknown
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 502
        guard (200..<300).contains(status) else {
            if status >= 500 { throw FreeVideoError.submissionUnknown }
            throw FreeVideoError.server(Self.message(in: data)
                ?? "ComfyUI rejected the workflow (HTTP \(status)). Open the workspace for details.")
        }
        guard let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = answer["prompt_id"] as? String,
              RemotePathIdentifier.appending(id, to: base.appendingPathComponent("history")) != nil else {
            throw FreeVideoError.submissionUnknown
        }
        return FreeVideoJob(id: id, nodeID: nodeID)
    }

    static func workflowBody(_ request: FreeVideoRequest, nodeID: String, media: [[String: String]] = []) throws -> Data {
        try request.validate()
        var inputs: [String: Any] = ["text": request.prompt, "width": request.width,
            "height": request.height, "seconds": request.seconds, "seed": request.seed, "two_pass": request.twoPass]
        var graph: [String: Any] = [:]
        if !media.isEmpty {
            let mediaID = nodeID + "_media"
            let serialized = try JSONSerialization.data(withJSONObject: media)
            graph[mediaID] = ["class_type": "FreeVideoMedia", "inputs": ["assets": String(decoding: serialized, as: UTF8.self)]]
            inputs["media"] = [mediaID, 0] as [Any]
        }
        graph[nodeID] = ["class_type": "FreeVideoGenerate", "inputs": inputs]
        return try JSONSerialization.data(withJSONObject: ["client_id": UUID().uuidString, "prompt": graph])
    }

    public func follow(_ job: FreeVideoJob, node base: URL, outputDirectory: URL,
                       onProgress: @escaping @Sendable (String) -> Void) async throws -> FreeVideoResult {
        _ = try Self.validatedBaseURL(base.absoluteString)
        let historyURL = try Self.historyURL(job, base: base)
        let deadline = job.submittedAt.addingTimeInterval(12 * 60 * 60)
        var missingPolls = 0
        var first = true
        while first || Date() < deadline {
            if !first { try await Task.sleep(for: pollInterval) }
            first = false
            try Task.checkCancellation()
            let history = try await json(at: historyURL, base: base, limit: 4 * 1_024 * 1_024)
            if let record = history[job.id] as? [String: Any] {
                missingPolls = 0
                if let status = record["status"] as? [String: Any] {
                    let messages = status["messages"] as? [[Any]] ?? []
                    if messages.contains(where: { $0.first as? String == "execution_interrupted" }) {
                        throw FreeVideoError.cancelled
                    }
                    if status["status_str"] as? String == "error" {
                        let error = messages.first { $0.first as? String == "execution_error" }
                        let details = error?.dropFirst().first as? [String: Any]
                        throw FreeVideoError.server(String((details?["exception_message"] as? String
                            ?? "FreeVideo stopped with an error. Open the workspace for its diagnostics.").prefix(1_024)))
                    }
                    if status["completed"] as? Bool == true {
                        let remote = try Self.outputURL(record, nodeID: job.nodeID, base: base)
                        onProgress("Downloading the completed video…")
                        let target = outputDirectory.appendingPathComponent("FreeVideo-\(job.nodeID).mp4")
                        let file = try await RemoteArtifactTransfer.download(from: remote, policy: .sameOrigin(base),
                            to: target, maximumBytes: Self.maximumVideoBytes,
                            budget: RemoteByteBudget(limit: Self.maximumVideoBytes), timeout: 600,
                            allowedContentTypes: ["video/mp4", "application/octet-stream"],
                            sessionConfiguration: session.configuration)
                        do { try Self.validateMP4(file) } catch {
                            try? FileManager.default.removeItem(at: file)
                            throw error
                        }
                        return FreeVideoResult(file: file, jobID: job.id)
                    }
                }
            } else {
                let queue = try await json(at: base.appendingPathComponent("queue"), base: base, limit: 4 * 1_024 * 1_024)
                if Self.queueContains(job, queue: queue) {
                    missingPolls = 0
                } else {
                    missingPolls += 1
                    // History and queue are separate snapshots: completion can occur between
                    // them. Recheck rather than calling a just-completed job lost.
                    if missingPolls >= 3 { throw FreeVideoError.missingJob }
                }
            }
            if let progress = try? await json(at: base.appendingPathComponent("freevideo/progress"), base: base),
               let rows = progress["progress"] as? [[String: Any]],
               let row = rows.first(where: { $0["node"] as? String == job.nodeID }),
               let label = row["label"] as? String {
                onProgress(String(label.prefix(512)))
            } else {
                onProgress("Waiting for this FreeVideo job…")
            }
        }
        throw FreeVideoError.expired
    }

    public func cancel(_ job: FreeVideoJob, node base: URL) async throws -> FreeVideoCancelOutcome {
        _ = try Self.validatedBaseURL(base.absoluteString)
        _ = try Self.historyURL(job, base: base)
        let answer = try await json(at: base.appendingPathComponent("freevideo/cancel"), base: base,
            body: JSONSerialization.data(withJSONObject: ["prompt_id": job.id, "node_id": job.nodeID]))
        guard let state = answer["status"] as? String, let outcome = FreeVideoCancelOutcome(rawValue: state) else {
            throw FreeVideoError.server("FreeVideo did not confirm this job's cancellation. The saved receipt has been kept.")
        }
        return outcome
    }

    private func json(at url: URL, base: URL, body: Data? = nil,
                      limit: Int = RemoteHTTP.controlResponseLimit) async throws -> [String: Any] {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await RemoteHTTP.data(for: request, session: session, policy: .sameOrigin(base), successLimit: limit)
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 502
        guard (200..<300).contains(status) else {
            throw FreeVideoError.server(Self.message(in: data)
                ?? "ComfyUI answered HTTP \(status). Check its address and FreeVideo installation.")
        }
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FreeVideoError.server("ComfyUI returned an unreadable response. Check the configured address.")
        }
        return result
    }

    private func uploadFrame(_ file: URL, base: URL) async throws -> String {
        let ext = file.pathExtension.lowercased()
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp",
                     "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff"]
        guard file.isFileURL, let type = types[ext],
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= Self.maximumFrameBytes else {
            throw FreeVideoError.invalidRequest("First and last frames must be PNG, JPEG, WebP, BMP, or TIFF images, at most 32 MiB each.")
        }
        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        guard bytes.count <= Self.maximumFrameBytes else { throw FreeVideoError.invalidRequest("The frame is larger than 32 MiB.") }
        let boundary = "SiliconFreeVideo" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"frame.\(ext)\"\r\nContent-Type: \(type)\r\n\r\n".utf8)
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: base.appendingPathComponent("freevideo/media/upload"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await RemoteHTTP.data(for: request, session: session, policy: .sameOrigin(base))
        guard let status = response as? HTTPURLResponse, (200..<300).contains(status.statusCode),
              let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = answer["file"] as? String, Self.safeRelativePath(path),
              types[URL(fileURLWithPath: path).pathExtension.lowercased()] != nil else {
            throw FreeVideoError.server(Self.message(in: data) ?? "FreeVideo refused the frame upload or returned an invalid media path.")
        }
        return path
    }

    private static func historyURL(_ job: FreeVideoJob, base: URL) throws -> URL {
        guard job.nodeID.utf8.count <= 100, !job.nodeID.isEmpty,
              job.nodeID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              let url = RemotePathIdentifier.appending(job.id, to: base.appendingPathComponent("history")) else {
            throw FreeVideoError.invalidRequest("The saved FreeVideo job receipt is invalid.")
        }
        return url
    }

    private static func queueContains(_ job: FreeVideoJob, queue: [String: Any]) -> Bool {
        for name in ["queue_running", "queue_pending"] {
            for row in queue[name] as? [[Any]] ?? [] where row.count >= 3 {
                if row[1] as? String == job.id,
                   let graph = row[2] as? [String: Any],
                   let node = graph[job.nodeID] as? [String: Any],
                   node["class_type"] as? String == "FreeVideoGenerate" { return true }
            }
        }
        return false
    }

    static func outputURL(_ record: [String: Any], nodeID: String, base: URL) throws -> URL {
        guard let outputs = record["outputs"] as? [String: Any],
              let output = outputs[nodeID] as? [String: Any] else {
            throw FreeVideoError.invalidOutput("FreeVideo finished without this job's video output.")
        }
        // ComfyUI PreviewVideo uses `images`, including for native VIDEO outputs.
        let entries = output["images"] as? [[String: Any]] ?? []
        for entry in entries where entry["type"] as? String == "output" {
            guard let name = entry["filename"] as? String, safeRelativePath(name),
                  !name.contains("/"), name.lowercased().hasSuffix(".mp4"),
                  let folder = entry["subfolder"] as? String,
                  folder.isEmpty || folder == "." || safeRelativePath(folder) else { continue }
            var components = URLComponents(url: base.appendingPathComponent("view"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "filename", value: name),
                URLQueryItem(name: "subfolder", value: folder == "." ? "" : folder), URLQueryItem(name: "type", value: "output")]
            if let url = components.url, RemoteURLPolicy.sameOrigin(base).permits(url) { return url }
        }
        throw FreeVideoError.invalidOutput("FreeVideo did not return a valid MP4 in its ComfyUI output folder.")
    }

    static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 1_024 && !path.hasPrefix("/")
            && !path.contains("\\") && !path.contains(":") && !path.contains("%")
            && path.rangeOfCharacter(from: .controlCharacters) == nil
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// ComfyUI's workflow validation errors are nested, unlike the swarm API's.
    static func message(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return NodeVideoRuntime.reason(in: data)
        }
        if let nodes = root["node_errors"] as? [String: Any] {
            for key in nodes.keys.sorted() {
                if let node = nodes[key] as? [String: Any], let errors = node["errors"] as? [[String: Any]] {
                    for error in errors {
                        let parts = [error["message"] as? String, error["details"] as? String]
                            .compactMap { $0 }.filter { !$0.isEmpty }
                        if !parts.isEmpty { return String(parts.joined(separator: ": ").prefix(1_024)) }
                    }
                }
            }
        }
        if let error = root["error"] as? [String: Any] {
            let parts = [error["message"] as? String, error["details"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty { return String(parts.joined(separator: ": ").prefix(1_024)) }
        }
        return NodeVideoRuntime.reason(in: data)
    }

    private static func validateMP4(_ file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        guard header.count == 12, String(data: header[4..<8], encoding: .ascii) == "ftyp" else {
            throw FreeVideoError.invalidOutput("The downloaded file is not an MP4 video. Check the result in FreeVideo's workspace.")
        }
    }
}

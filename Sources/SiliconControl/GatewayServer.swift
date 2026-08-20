import Foundation
import Network

/// What the gateway needs a model routed to: the OpenAI-compatible server that now hosts it,
/// and the model name that server actually answers to (engines 404 unknown spellings).
public struct GatewayReadyBackend: Sendable {
    public var baseURL: URL
    public var backendModel: String

    public init(baseURL: URL, backendModel: String) {
        self.baseURL = baseURL
        self.backendModel = backendModel
    }
}

/// The app-side half of the gateway: knows every model, and can make any one of them
/// answer — loading it locally or starting it on the peer that owns it.
public protocol GatewayHost: AnyObject, Sendable {
    func gatewayModels() async -> [GatewayAPI.Model]
    /// Returns once the model behind `modelID` is serving. Progress lines feed the SSE
    /// keep-alive comments a waiting harness sees. Throws with a human-readable message
    /// when the model cannot come up.
    func gatewayEnsureReady(
        modelID: String, onStage: @escaping @Sendable (String) -> Void
    ) async throws -> GatewayReadyBackend
    /// Folders whose media the chat surfaces may play and reveal — the app's own
    /// output directories, nothing wider.
    func gatewayMediaRoots() async -> [String]
    /// Shows the file in Finder.
    func gatewayReveal(path: String) async
    /// Jumps the app to the 3D tab, where the newest mesh is already showing.
    func gatewayOpenMeshViewer() async
}

/// The model gateway: one loopback OpenAI-compatible server over every model this app and
/// its swarm can serve. `GET /v1/models` lists them all; `POST /v1/chat/completions` (what
/// DeepSeek Harness speaks) and `POST /v1/responses` (what Codex speaks) route to whichever
/// machine owns the named model, loading or starting it on demand.
///
/// Loopback only, no exceptions: this endpoint can trigger model loads and reach swarm
/// peers, so it follows the control server's hard rule and never binds beyond 127.0.0.1.
public actor GatewayServer {

    private let host: any GatewayHost
    private var listener: NWListener?
    public private(set) var port: Int = 0

    public init(host: any GatewayHost) {
        self.host = host
    }

    public func start(preferredPort: Int = 0) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(
            using: parameters,
            on: preferredPort > 0 ? NWEndpoint.Port(rawValue: UInt16(preferredPort))! : .any
        )
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            Task { await self?.noteReady() }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func noteReady() {
        if let resolved = listener?.port?.rawValue { port = Int(resolved) }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        Task { await serve(connection) }
    }

    private func serve(_ connection: NWConnection) async {
        defer { connection.cancel() }
        guard let request = try? await HTTPRequest.read(from: connection) else { return }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            try? await HTTPResponse.json(["status": "ok"]).write(to: connection)
        case ("GET", "/v1/models"), ("GET", "/models"):
            let models = await host.gatewayModels()
            let body = GatewayAPI.modelsJSON(models)
            try? await HTTPResponse(status: 200, body: body).write(to: connection)
        case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
            await serveChat(request, on: connection)
        case ("POST", "/v1/responses"), ("POST", "/responses"):
            await serveResponses(request, on: connection)
        case ("GET", "/ui/media"):
            await serveMedia(request, on: connection)
        case ("POST", "/ui/reveal"):
            await serveReveal(request, on: connection)
        case ("POST", "/ui/open3d"):
            await host.gatewayOpenMeshViewer()
            try? await HTTPResponse.json(["status": "ok"]).write(to: connection)
        default:
            try? await HTTPResponse.error(
                404, "Unknown endpoint \(request.method) \(request.path)"
            ).write(to: connection)
        }
    }

    // MARK: - Chat completions (DeepSeek Harness dialect)

    private func serveChat(_ request: HTTPRequest, on connection: NWConnection) async {
        guard let modelID = GatewayAPI.requestedModel(inBody: request.body) else {
            try? await HTTPResponse.error(400, "The request names no model.").write(to: connection)
            return
        }
        let wantsStream = GatewayAPI.wantsStream(body: request.body)

        if wantsStream {
            let stream = SSEConnection(connection: connection)
            guard await stream.sendHead() else { return }
            let backend: GatewayReadyBackend
            do {
                backend = try await ensureWithHeartbeat(modelID: modelID, stream: stream)
            } catch {
                await stream.send(GatewayAPI.sseErrorPayload(error.localizedDescription))
                await stream.send(GatewayAPI.sseDone)
                return
            }
            let body = GatewayAPI.rewritingModel(inBody: request.body, to: backend.backendModel)
            await pipeChatStream(body: body, backend: backend, to: stream)
        } else {
            do {
                let backend = try await host.gatewayEnsureReady(modelID: modelID) { _ in }
                let body = GatewayAPI.rewritingModel(
                    inBody: request.body, to: backend.backendModel
                )
                let (status, data) = try await BackendClient.send(
                    path: "chat/completions", body: body, to: backend.baseURL
                )
                try? await HTTPResponse(status: status, body: data).write(to: connection)
            } catch {
                try? await HTTPResponse.error(502, error.localizedDescription)
                    .write(to: connection)
            }
        }
    }

    /// Streams the backend's SSE bytes through untouched, frame by frame. The harness's
    /// adapter parses them exactly as it would parse llama-server directly.
    private func pipeChatStream(
        body: Data, backend: GatewayReadyBackend, to stream: SSEConnection
    ) async {
        do {
            let frames = try await BackendClient.streamFrames(
                path: "chat/completions", body: body, to: backend.baseURL
            )
            for try await frame in frames {
                await stream.send(frame + Data("\n\n".utf8))
            }
        } catch {
            await stream.send(GatewayAPI.sseErrorPayload(error.localizedDescription))
            await stream.send(GatewayAPI.sseDone)
        }
    }

    // MARK: - Responses (Codex dialect)

    private func serveResponses(_ request: HTTPRequest, on connection: NWConnection) async {
        guard let modelID = GatewayAPI.requestedModel(inBody: request.body) else {
            try? await HTTPResponse.error(400, "The request names no model.").write(to: connection)
            return
        }
        let translator = GatewayResponsesTranslator(model: modelID, includeReasoning: true)
        let wantsStream = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            .flatMap { $0?["stream"] as? Bool } ?? false

        let stream = SSEConnection(connection: connection)
        if wantsStream {
            guard await stream.sendHead() else { return }
            await stream.send(translator.opening())
        }

        let backend: GatewayReadyBackend
        do {
            if wantsStream {
                backend = try await ensureWithHeartbeat(modelID: modelID, stream: stream)
            } else {
                backend = try await host.gatewayEnsureReady(modelID: modelID) { _ in }
            }
        } catch {
            if wantsStream {
                for frame in translator.failure(message: error.localizedDescription) {
                    await stream.send(frame)
                }
            } else {
                try? await HTTPResponse.error(502, error.localizedDescription)
                    .write(to: connection)
            }
            return
        }

        do {
            // The backend is always asked to stream: the translator consumes deltas, and a
            // non-streaming caller just gets the assembled response at the end.
            var (chatBody, _) = try GatewayAPI.chatRequestBody(
                fromResponsesRequest: request.body, backendModel: backend.backendModel
            )
            if var json = (try? JSONSerialization.jsonObject(with: chatBody)) as? [String: Any] {
                json["stream"] = true
                json["stream_options"] = ["include_usage": true]
                chatBody = (try? JSONSerialization.data(withJSONObject: json)) ?? chatBody
            }

            let frames = try await BackendClient.streamFrames(
                path: "chat/completions", body: chatBody, to: backend.baseURL
            )
            var sawPayload = false
            for try await frame in frames {
                for payload in Self.dataPayloads(inFrame: frame) {
                    sawPayload = true
                    for out in translator.translate(payload: payload) {
                        if wantsStream { await stream.send(out) }
                    }
                }
            }
            // A stream that carried nothing at all is a dead connection wearing a 200,
            // not an empty answer — Codex must see a failure it can show and retry.
            guard sawPayload else {
                let message = "The model's server closed the stream without sending anything."
                if wantsStream {
                    for out in translator.failure(message: message) { await stream.send(out) }
                } else {
                    try? await HTTPResponse.error(502, message).write(to: connection)
                }
                return
            }
            if wantsStream {
                // A backend that hung up without [DONE] still owes Codex a terminal event.
                for out in translator.translate(payload: "[DONE]") {
                    await stream.send(out)
                }
            } else {
                _ = translator.translate(payload: "[DONE]")
                try? await HTTPResponse(status: 200, body: translator.completedResponseBody())
                    .write(to: connection)
            }
        } catch {
            if wantsStream {
                for frame in translator.failure(message: error.localizedDescription) {
                    await stream.send(frame)
                }
            } else {
                try? await HTTPResponse.error(502, error.localizedDescription)
                    .write(to: connection)
            }
        }
    }

    // MARK: - Media for the chat surfaces

    /// Serves a media file to the embedded chat pages, with the single-range support
    /// WebKit's players insist on. Only known media types inside the app's own output
    /// folders are served; everything else is a 403, loopback or not.
    private func serveMedia(_ request: HTTPRequest, on connection: NWConnection) async {
        guard let path = request.query["path"]?.removingPercentEncoding else {
            try? await HTTPResponse.error(400, "No path given.").write(to: connection)
            return
        }
        let roots = await host.gatewayMediaRoots()
        guard GatewayAPI.isAllowedMediaPath(path, roots: roots) else {
            try? await HTTPResponse.error(
                403, "Only media inside the app's output folders is served."
            ).write(to: connection)
            return
        }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: url) else {
            try? await HTTPResponse.error(404, "The file is gone.").write(to: connection)
            return
        }
        let type = GatewayAPI.mediaContentTypes[url.pathExtension.lowercased()]
            ?? "application/octet-stream"

        if let range = GatewayAPI.byteRange(
            header: request.headers["range"], fileSize: data.count
        ) {
            var response = HTTPResponse(
                status: 206, body: data.subdata(in: range), contentType: type
            )
            response.extraHeaders = [
                "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)",
                "Accept-Ranges": "bytes",
            ]
            try? await response.write(to: connection)
        } else {
            var response = HTTPResponse(status: 200, body: data, contentType: type)
            response.extraHeaders = ["Accept-Ranges": "bytes"]
            try? await response.write(to: connection)
        }
    }

    private func serveReveal(_ request: HTTPRequest, on connection: NWConnection) async {
        guard let json = try? JSONSerialization.jsonObject(with: request.body)
                as? [String: Any],
              let path = json["path"] as? String
        else {
            try? await HTTPResponse.error(400, "No path given.").write(to: connection)
            return
        }
        let roots = await host.gatewayMediaRoots()
        guard GatewayAPI.isAllowedMediaPath(path, roots: roots) else {
            try? await HTTPResponse.error(
                403, "Only media inside the app's output folders can be revealed."
            ).write(to: connection)
            return
        }
        await host.gatewayReveal(path: path)
        try? await HTTPResponse.json(["status": "ok"]).write(to: connection)
    }

    /// The `data:` payloads inside one SSE frame. Comments and other fields are dropped.
    static func dataPayloads(inFrame frame: Data) -> [String] {
        String(decoding: frame, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard line.hasPrefix("data:") else { return nil }
                var payload = line.dropFirst("data:".count)
                if payload.hasPrefix(" ") { payload = payload.dropFirst() }
                return String(payload)
            }
    }

    // MARK: - Load heartbeat

    /// Runs the host's ensure step while keeping the client's SSE connection visibly alive:
    /// a comment every few seconds carrying the latest stage line. Both harnesses' parsers
    /// ignore comments but count them as transport activity, which is exactly what a
    /// minute-long model load needs.
    private func ensureWithHeartbeat(
        modelID: String, stream: SSEConnection
    ) async throws -> GatewayReadyBackend {
        let stage = StageBox()
        let heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                let line = await stage.current
                await stream.send(GatewayAPI.sseComment(line))
            }
        }
        defer { heartbeat.cancel() }
        return try await host.gatewayEnsureReady(modelID: modelID) { line in
            Task { await stage.set(line) }
        }
    }
}

/// The latest human-readable stage of a load, shared between the ensure call and the
/// heartbeat loop.
private actor StageBox {
    var current = "getting the model ready"
    func set(_ line: String) { current = line }
}

// MARK: - SSE connection

/// A response that streams: head first (close-delimited, so no Content-Length), then frames
/// as they exist. Send failures latch — once the client is gone, everything else is dropped
/// without tearing down the caller.
private actor SSEConnection {
    private let connection: NWConnection
    private var broken = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func sendHead() async -> Bool {
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        return await sendRaw(Data(head.utf8))
    }

    @discardableResult
    func send(_ data: Data) async -> Bool {
        await sendRaw(data)
    }

    private func sendRaw(_ data: Data) async -> Bool {
        guard !broken else { return false }
        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
        if !ok { broken = true }
        return ok
    }
}

// MARK: - Backend client

/// Requests against the OpenAI-compatible server that actually hosts a model.
enum BackendClient {

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // First token can be minutes away on a long prompt; the whole answer longer still.
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration)
    }

    static func request(path: String, body: Data, base: URL) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Uncompressed, explicitly. URLSession's default advertises gzip, and the tailnet
        // proxy in front of a node kills a compressed SSE stream about five seconds into
        // the first quiet prefill — observed as headers, one chunk, then EOF. curl with
        // the same header dies identically, so this is the wire's rule, not a hunch.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = body
        return request
    }

    /// One buffered request, for non-streaming callers.
    static func send(path: String, body: Data, to base: URL) async throws -> (Int, Data) {
        let (data, response) = try await session().data(
            for: request(path: path, body: body, base: base)
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 502
        return (status, data)
    }

    enum BackendError: Error, LocalizedError {
        case status(Int, String)

        var errorDescription: String? {
            switch self {
            case .status(let code, let message):
                return "The model's server answered \(code): \(message)"
            }
        }
    }

    /// Streams a backend SSE response as whole frames (without their trailing blank line).
    /// A non-200 answer is read in full and thrown as an error with the server's own words.
    static func streamFrames(
        path: String, body: Data, to base: URL
    ) async throws -> AsyncThrowingStream<Data, any Error> {
        let session = session()
        let (bytes, response) = try await session.bytes(
            for: request(path: path, body: body, base: base)
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 502
        guard status == 200 else {
            var collected = Data()
            for try await byte in bytes { collected.append(byte) }
            let message = Self.errorMessage(inBody: collected) ?? "no detail"
            throw BackendError.status(status, message)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                // A byte array rather than Data: Data's indices do not re-zero after
                // removeSubrange, which has bitten before; Array's always do.
                var buffer: [UInt8] = []
                do {
                    for try await byte in bytes {
                        buffer.append(byte)
                        // Frames end at a blank line. Scanning only at a newline keeps this
                        // linear: a boundary can only complete at the newest byte.
                        if byte == UInt8(ascii: "\n"), let frame = Self.takeFrame(from: &buffer) {
                            continuation.yield(frame)
                        }
                    }
                    if !buffer.isEmpty {
                        // A final frame without its blank line still counts (some servers
                        // close right after [DONE]).
                        continuation.yield(Data(buffer))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Cuts one complete frame off the front of the buffer if a boundary just formed.
    private static func takeFrame(from buffer: inout [UInt8]) -> Data? {
        let newline = UInt8(ascii: "\n")
        let carriage = UInt8(ascii: "\r")
        let count = buffer.count
        guard count >= 2 else { return nil }

        var frameEnd: Int?
        if buffer[count - 1] == newline, buffer[count - 2] == newline {
            frameEnd = count - 2
        } else if count >= 4,
                  buffer[count - 1] == newline, buffer[count - 2] == carriage,
                  buffer[count - 3] == newline, buffer[count - 4] == carriage {
            frameEnd = count - 4
        }
        guard let frameEnd else { return nil }
        guard frameEnd > 0 else {
            buffer.removeAll(keepingCapacity: true)
            return nil
        }
        let frame = Data(buffer[0..<frameEnd])
        buffer.removeAll(keepingCapacity: true)
        return frame
    }

    static func errorMessage(inBody body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return String(data: body.prefix(200), encoding: .utf8) }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = json["message"] as? String { return message }
        return String(data: body.prefix(200), encoding: .utf8)
    }
}

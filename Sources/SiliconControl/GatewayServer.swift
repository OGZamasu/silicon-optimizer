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
    private let ledger: GatewayLedger?
    private var listener: NWListener?
    public private(set) var port: Int = 0

    public init(host: any GatewayHost, ledger: GatewayLedger? = nil) {
        self.host = host
        self.ledger = ledger
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
        let waitBudget = GatewayAPI.waitBudget(fromHeader: request.headers["x-silicon-wait"])
        let isNode: Bool = {
            if case .node = GatewayAPI.parseModelID(modelID) { return true }
            return false
        }()
        let (preview, promptChars) = GatewayAPI.promptPreview(inBody: request.body)
        let entry = await ledger?.begin(
            endpoint: "chat", modelID: modelID, stream: wantsStream,
            promptChars: promptChars, promptPreview: preview
        )

        if wantsStream {
            let stream = SSEConnection(connection: connection)
            guard await stream.sendHead() else {
                await finishLedger(entry, ok: false, detail: "client gone before headers")
                return
            }
            let backend: GatewayReadyBackend
            do {
                backend = try await ensureWithHeartbeat(
                    modelID: modelID, waitBudget: waitBudget, stream: stream
                )
                if let entry { await ledger?.noteEnsured(entry, backendModel: backend.backendModel) }
            } catch {
                await stream.send(GatewayAPI.sseErrorPayload(error.localizedDescription))
                await stream.send(GatewayAPI.sseDone)
                await finishLedger(entry, ok: false, detail: error.localizedDescription)
                return
            }
            var body = GatewayAPI.rewritingModel(inBody: request.body, to: backend.backendModel)
            body = GatewayAPI.normalizingThinking(inBody: body, forNode: isNode)
            await pipeChatStream(body: body, backend: backend, to: stream, ledgerEntry: entry)
        } else {
            do {
                let backend = try await ensureRespectingWait(
                    modelID: modelID, budget: waitBudget, onStage: { _ in }
                )
                if let entry { await ledger?.noteEnsured(entry, backendModel: backend.backendModel) }
                var body = GatewayAPI.rewritingModel(
                    inBody: request.body, to: backend.backendModel
                )
                body = GatewayAPI.normalizingThinking(inBody: body, forNode: isNode)
                let (status, data) = try await BackendClient.send(
                    path: "chat/completions", body: body, to: backend.baseURL
                )
                let warning = status == 200
                    ? GatewayAPI.emptyContentWarning(inResponseBody: data) : nil
                let out = warning.map {
                    GatewayAPI.attachingWarning(toResponseBody: data, warning: $0)
                } ?? data
                try? await HTTPResponse(status: status, body: out).write(to: connection)

                let audit = GatewayStreamAudit()
                if let compact = String(data: data, encoding: .utf8) {
                    // The buffered body has the same shape as one stream payload —
                    // the audit reads choices[0].message instead of a delta.
                    audit.feed(payload: compact.replacingOccurrences(of: "\n", with: ""))
                }
                await finishLedger(
                    entry, ok: status == 200,
                    detail: status == 200 ? nil : "backend answered \(status)",
                    warning: warning, audit: audit
                )
            } catch {
                try? await HTTPResponse.error(502, error.localizedDescription)
                    .write(to: connection)
                await finishLedger(entry, ok: false, detail: error.localizedDescription)
            }
        }
    }

    private func finishLedger(
        _ entry: String?, ok: Bool, detail: String? = nil,
        warning: String? = nil, audit: GatewayStreamAudit? = nil
    ) async {
        guard let entry else { return }
        await ledger?.finish(
            entry, ok: ok, detail: detail, warning: warning,
            responsePreview: audit?.responsePreview,
            promptTokens: audit?.promptTokens, outputTokens: audit?.outputTokens
        )
    }

    /// Streams the backend's SSE bytes through untouched, frame by frame. The harness's
    /// adapter parses them exactly as it would parse llama-server directly.
    ///
    /// One thing is added: a backend that hangs up without `[DONE]` — the node engine
    /// dying mid-prefill does exactly this — gets its death narrated as an in-stream
    /// error the client can show, instead of a bare "stream closed".
    private func pipeChatStream(
        body: Data, backend: GatewayReadyBackend, to stream: SSEConnection,
        ledgerEntry: String? = nil
    ) async {
        var sawDone = false
        let audit = GatewayStreamAudit()
        do {
            let frames = try await BackendClient.streamFrames(
                path: "chat/completions", body: body, to: backend.baseURL
            )
            for try await frame in frames {
                if !sawDone, GatewayAPI.frameCarriesDone(frame) { sawDone = true }
                for payload in Self.dataPayloads(inFrame: frame) {
                    audit.feed(payload: payload)
                }
                await stream.send(frame + Data("\n\n".utf8))
            }
            if !sawDone {
                await stream.send(GatewayAPI.sseErrorPayload(
                    "The model's server closed the connection mid-answer — on "
                    + "silicon-node this usually means its engine died on a large prompt "
                    + "(a known node issue). Try a model on This Mac."
                ))
                await stream.send(GatewayAPI.sseDone)
                await finishLedger(
                    ledgerEntry, ok: false, detail: "stream ended without [DONE]",
                    audit: audit
                )
                return
            }
            // An answer that streamed nothing but reasoning deserves its diagnosis on
            // the wire (as a comment — invisible to parsers, visible to anyone looking)
            // and in the ledger, where the Fleet tab makes it loud.
            if let warning = audit.warning {
                await stream.send(GatewayAPI.sseComment("silicon-warning: \(warning)"))
            }
            await finishLedger(ledgerEntry, ok: true, warning: audit.warning, audit: audit)
        } catch {
            await stream.send(GatewayAPI.sseErrorPayload(error.localizedDescription))
            await stream.send(GatewayAPI.sseDone)
            await finishLedger(
                ledgerEntry, ok: false, detail: error.localizedDescription, audit: audit
            )
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
        let waitBudget = GatewayAPI.waitBudget(fromHeader: request.headers["x-silicon-wait"])
        let isNode: Bool = {
            if case .node = GatewayAPI.parseModelID(modelID) { return true }
            return false
        }()
        let entry = await ledger?.begin(
            endpoint: "responses", modelID: modelID, stream: wantsStream,
            promptChars: request.body.count, promptPreview: nil
        )

        let stream = SSEConnection(connection: connection)
        if wantsStream {
            guard await stream.sendHead() else {
                await finishLedger(entry, ok: false, detail: "client gone before headers")
                return
            }
            await stream.send(translator.opening())
        }

        let backend: GatewayReadyBackend
        do {
            if wantsStream {
                backend = try await ensureWithHeartbeat(
                    modelID: modelID, waitBudget: waitBudget, stream: stream
                )
            } else {
                backend = try await ensureRespectingWait(
                    modelID: modelID, budget: waitBudget, onStage: { _ in }
                )
            }
            if let entry { await ledger?.noteEnsured(entry, backendModel: backend.backendModel) }
        } catch {
            if wantsStream {
                for frame in translator.failure(message: error.localizedDescription) {
                    await stream.send(frame)
                }
            } else {
                try? await HTTPResponse.error(502, error.localizedDescription)
                    .write(to: connection)
            }
            await finishLedger(entry, ok: false, detail: error.localizedDescription)
            return
        }

        let audit = GatewayStreamAudit()
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
            chatBody = GatewayAPI.normalizingThinking(inBody: chatBody, forNode: isNode)

            let frames = try await BackendClient.streamFrames(
                path: "chat/completions", body: chatBody, to: backend.baseURL
            )
            var sawPayload = false
            for try await frame in frames {
                for payload in Self.dataPayloads(inFrame: frame) {
                    sawPayload = true
                    audit.feed(payload: payload)
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
                await finishLedger(entry, ok: false, detail: message, audit: audit)
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
            await finishLedger(entry, ok: true, warning: audit.warning, audit: audit)
        } catch {
            if wantsStream {
                for frame in translator.failure(message: error.localizedDescription) {
                    await stream.send(frame)
                }
            } else {
                try? await HTTPResponse.error(502, error.localizedDescription)
                    .write(to: connection)
            }
            await finishLedger(
                entry, ok: false, detail: error.localizedDescription, audit: audit
            )
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
        modelID: String, waitBudget: TimeInterval, stream: SSEConnection
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
        return try await ensureRespectingWait(modelID: modelID, budget: waitBudget) { line in
            Task { await stage.set(line) }
        }
    }

    /// The host's ensure step, with the `X-Silicon-Wait` contract on top: a waitable
    /// refusal (the node's GPU rendering, a model mid-answer) is retried until the
    /// caller's budget runs out; everything else — and everyone without a budget —
    /// gets the error at once.
    private func ensureRespectingWait(
        modelID: String, budget: TimeInterval,
        onStage: @escaping @Sendable (String) -> Void
    ) async throws -> GatewayReadyBackend {
        let deadline = Date().addingTimeInterval(budget)
        while true {
            do {
                return try await host.gatewayEnsureReady(modelID: modelID, onStage: onStage)
            } catch {
                guard budget > 0, (error as? GatewayWaitableError)?.isWaitable == true,
                      Date().addingTimeInterval(10) <= deadline
                else { throw error }
                onStage("waiting it out (X-Silicon-Wait): \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(10))
            }
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

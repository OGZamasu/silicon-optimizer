import Foundation
import Network

/// A small HTTP/JSON server bound to loopback, so external tools can drive the app.
///
/// This exists so an MCP bridge — and therefore Claude or ChatGPT — can use the model this app
/// already has loaded, instead of launching a second copy and doubling the memory bill. It is
/// intentionally tiny: no routing framework, no dependencies, no TLS. Loopback plus a bearer
/// token is the right amount of security for something that only ever talks to processes running
/// as the same user.
public actor ControlServer {

    private let host: any ControlHost
    private var listener: NWListener?
    private var activeConnections = 0
    private static let maximumConnections = 64
    // Durable video waits must not occupy every socket needed to inspect or
    // control the queue. Reject overflow before the host can enqueue anything.
    static let maximumSynchronousVideos = 8
    private var activeSynchronousVideos = 0
    private let handshakeURL: URL
    private let token: String
    private var port: Int = 0
    /// The shared swarm secret, accepted alongside the per-launch token when set.
    private var swarmToken: String?
    /// Whether the listener is actually reachable beyond loopback.
    public private(set) var isExposedOnLAN = false

    /// The owner's paired phones and tablets, and the one open pairing code.
    private let buddy: BuddyRegistry
    /// Where `/events` subscribers read from.
    private let events: BuddyEventHub
    /// The second listener, on this Mac's tailscale address. Nil unless the owner has
    /// turned Silicon Buddy on and this Mac is actually on a tailnet.
    private var buddyListener: NWListener?
    private var buddyAddress: String?
    private var buddyPortOverride: Int?
    /// Why the tailnet listener is not up, when it was asked for and could not be.
    public private(set) var tailnetError: String?
    private var activeEventStreams = 0

    /// Streams hold a connection for minutes or hours, so they get their own ceiling well
    /// under the connection limit — a phone that reconnects on every screen wake must not
    /// be able to starve the MCP bridge of sockets.
    public static let maximumEventStreams = 16

    /// How often an idle `/events` stream says it is still there. One goes out as soon as
    /// the stream opens, so a client knows immediately that it is connected.
    static let heartbeatInterval: Duration = .seconds(15)

    /// The port peers dial when the server is on the LAN. Fixed rather than ephemeral,
    /// because the registry lists explicit base URLs.
    public static let lanPort = 8788

    /// The address to paste into an OBS Browser Source. Carries the token in the URL
    /// because a browser source cannot send headers; nil until the server is listening.
    public var overlayURL: URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/overlay?token=\(token)")
    }

    public init(
        host: any ControlHost, handshakeURL: URL = ControlAPI.handshakeURL,
        buddy: BuddyRegistry = .shared, events: BuddyEventHub = .shared
    ) {
        self.host = host
        self.handshakeURL = handshakeURL
        self.buddy = buddy
        self.events = events
        // A fresh token each launch: it is only meaningful for the lifetime of the process.
        self.token = UUID().uuidString
    }

    /// Starts listening. The hard rule from the swarm design holds here: without a swarm
    /// token there is no non-loopback bind, whatever the caller asked for — an
    /// unauthenticated jobs API is an unauthenticated remote-execution service.
    public func start(
        preferredPort: Int = 0, exposeOnLAN: Bool = false, swarmToken: String? = nil
    ) throws {
        let lan = exposeOnLAN && !(swarmToken ?? "").isEmpty
        self.swarmToken = swarmToken
        self.isExposedOnLAN = lan

        let parameters = NWParameters.tcp
        if !lan {
            // Loopback only. This must never be reachable from the network.
            parameters.requiredInterfaceType = .loopback
        }
        parameters.allowLocalEndpointReuse = true

        let chosenPort = lan ? Self.lanPort : preferredPort
        let listener = try NWListener(
            using: parameters,
            on: chosenPort > 0 ? NWEndpoint.Port(rawValue: UInt16(chosenPort))! : .any
        )
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            Task { await self?.publishHandshake() }
        }
        listener.start(queue: .global(qos: .userInitiated))

        // The control server is restarted whenever swarm settings change, so this is also
        // what brings the tailnet listener back afterwards.
        Task { [weak self] in await self?.refreshTailnetAccess() }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        closeTailnetListener()
        try? FileManager.default.removeItem(at: handshakeURL)
    }

    /// Writes the port and token where clients can find them.
    private func publishHandshake() {
        guard let resolved = listener?.port?.rawValue else { return }
        port = Int(resolved)

        let handshake = ControlAPI.Handshake(
            port: port, pid: ProcessInfo.processInfo.processIdentifier,
            token: token, version: "0.1.0"
        )
        let url = handshakeURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.deletingLastPathComponent().path
        )
        guard let data = try? JSONEncoder().encode(handshake) else { return }
        try? data.write(to: url, options: .atomic)
        // The token is a credential; keep it out of other users' reach.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
        // The tailnet listener needs this port, so a request that arrived before the bind
        // was possible is applied here instead of being dropped.
        syncTailnetListener()
    }

    // MARK: - The tailnet listener

    /// The address the companion apps reach this Mac on, or nil when they cannot.
    public var tailnetListenerAddress: String? {
        buddyListener == nil ? nil : buddyAddress
    }

    /// The port both listeners answer on. Zero until the primary listener is ready — which
    /// is also why a pairing QR cannot be drawn before then.
    public var listeningPort: Int { port }

    /// Brings the second listener into line with `buddy.json`: up on this Mac's tailscale
    /// address when the owner has allowed their own devices, down otherwise.
    ///
    /// Discovery shells out to the tailscale CLI, so it runs off the actor — a `Process`
    /// round trip on the executor would stall every request in flight.
    public nonisolated func refreshTailnetAccess(
        discoveringAddressWith discover: @escaping @Sendable () -> String? = {
            SwarmPairing.tailnetIPv4()
        }
    ) async {
        let allowed = await buddy.allowsTailnetDevices
        guard allowed else {
            try? await setTailnetAccess(address: nil)
            return
        }
        let address = await Task.detached(priority: .userInitiated) { discover() }.value
        guard let address else {
            await noteTailnetError(
                "This Mac has no tailscale address. Join the tailnet first — "
                    + "Silicon Buddy rides on it."
            )
            return
        }
        try? await setTailnetAccess(address: address)
    }

    /// Asks for (or withdraws) the tailnet listener. The port parameter exists for tests,
    /// which reach the second listener over loopback rather than over a tailnet.
    public func setTailnetAccess(address: String?, port overridePort: Int? = nil) throws {
        guard let address else {
            buddyAddress = nil
            buddyPortOverride = nil
            tailnetError = nil
            closeTailnetListener()
            return
        }
        guard Self.isBindableTailnetAddress(address) else {
            throw TailnetBindError.unacceptableAddress(address)
        }
        buddyAddress = address
        buddyPortOverride = overridePort
        tailnetError = nil
        syncTailnetListener()
    }

    /// The only addresses this second listener may take: a tailnet IPv4 (100.64/10), or
    /// loopback, which is where the tests reach it. Anything else — a LAN address, a
    /// wildcard, an IPv6 any — is refused here, because binding one of those is exactly how
    /// a private API becomes a public one.
    public static func isBindableTailnetAddress(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        if SwarmPairing.isTailnetIPv4(trimmed) { return true }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, let first = Int(parts[0]), first == 127,
              parts.dropFirst().allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false })
        else { return false }
        return true
    }

    public enum TailnetBindError: Error, LocalizedError, Equatable {
        case unacceptableAddress(String)

        public var errorDescription: String? {
            switch self {
            case .unacceptableAddress(let address):
                "\(address) is not a tailnet address. Silicon Buddy binds the tailnet "
                    + "interface only, never the whole network."
            }
        }
    }

    private func syncTailnetListener() {
        guard let address = buddyAddress else { return closeTailnetListener() }
        // Swarm exposure already binds every interface on the fixed LAN port, so a second
        // listener there would be shadowed by the first. The device tokens still work.
        guard !isExposedOnLAN else { return closeTailnetListener() }
        let wanted = buddyPortOverride ?? port
        guard (1...65_535).contains(wanted), buddyListener == nil,
              let boundPort = NWEndpoint.Port(rawValue: UInt16(wanted))
        else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(address), port: boundPort
        )
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed(let error) = state else { return }
                Task { await self?.noteTailnetError(error.localizedDescription) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            buddyListener = listener
        } catch {
            tailnetError = error.localizedDescription
        }
    }

    /// Records why the listener is down and leaves it down. Clearing the address matters:
    /// without it the next handshake would retry a bind that has already failed once, in a
    /// loop, for as long as the app runs.
    private func noteTailnetError(_ message: String) {
        tailnetError = message
        buddyAddress = nil
        closeTailnetListener()
    }

    public func closeTailnetListener() {
        buddyListener?.cancel()
        buddyListener = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        guard activeConnections < Self.maximumConnections else {
            connection.cancel()
            return
        }
        activeConnections += 1
        connection.start(queue: .global(qos: .userInitiated))
        Task { await serve(connection) }
    }

    private func serve(_ connection: NWConnection) async {
        defer {
            connection.cancel()
            activeConnections -= 1
        }
        do {
            let request = try await HTTPRequest.read(from: connection)
            let caller = await identify(request)

            switch streamRoute(request, as: caller) {
            case .stream(let source):
                await deliver(source, over: connection)
                return
            case .refused(let response):
                try await response.write(to: connection)
                return
            case .notStreaming:
                break
            }

            let source = Self.remoteAddress(of: connection)
            let response: HTTPResponse
            if request.method == "POST", request.path == "/video/generate" {
                // One request per connection: after its body, EOF/error means
                // this client no longer wants the synchronous response. Keep a
                // receive outstanding so Network.framework notices a FIN/RST
                // while the route is waiting, not only at response.write().
                let waiting = Task { await route(request, as: caller, from: source) }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, complete, error in
                    if complete || error != nil || !(data?.isEmpty ?? true) { waiting.cancel() }
                }
                response = await waiting.value
                guard !waiting.isCancelled else { return }
            } else {
                response = await route(request, as: caller, from: source)
            }
            try await response.write(to: connection)
        } catch {
            // A client that hangs up mid-request is routine, not worth surfacing.
        }
    }

    // MARK: - Who is asking

    /// The three credentials this server accepts. They are not equals: a paired phone may
    /// use every working route, but revoking another phone is the Mac's own business, so
    /// only the control token reaches `/buddy/devices`.
    enum Caller: Sendable, Equatable {
        case control
        case swarm
        case device(String)
    }

    private func identify(_ request: HTTPRequest) async -> Caller? {
        guard let bearer = request.bearerToken else { return nil }
        if bearer == token { return .control }
        if let swarmToken, !swarmToken.isEmpty, bearer == swarmToken { return .swarm }
        // Stamps last-seen as a side effect, which is the only place it could come from:
        // a device is "seen" exactly when it uses its token.
        if let device = await buddy.authorize(bearer: bearer) { return .device(device.id) }
        return nil
    }

    /// The peer's address, for rate-limiting pairing attempts. Shapes we cannot read collapse
    /// into one bucket rather than each escaping the limit as its own source.
    static func remoteAddress(of connection: NWConnection) -> String {
        guard case .hostPort(let host, _) = connection.endpoint else { return "unknown" }
        switch host {
        case .ipv4(let address):
            return "\(address)".split(separator: "%").first.map(String.init) ?? "unknown"
        case .ipv6(let address):
            return "\(address)".split(separator: "%").first.map(String.init) ?? "unknown"
        case .name(let name, _):
            return name
        @unknown default:
            return "unknown"
        }
    }

    // MARK: - Streaming routes

    private enum StreamRouting {
        case notStreaming
        case refused(HTTPResponse)
        case stream(EventSource)
    }

    /// Separated from `route` because the reply is not one buffer but a conversation. The
    /// slot taken here is released in `deliver`, once the stream is actually over.
    private func streamRoute(_ request: HTTPRequest, as caller: Caller?) -> StreamRouting {
        let segments = request.path.split(separator: "/").map(String.init)
        let host = self.host
        let hub = self.events

        let body: EventSource
        if request.method == "POST", segments == ["chat", "stream"] {
            guard caller != nil else { return .refused(unauthorized) }
            guard let chat = try? request.decode(ControlAPI.ChatRequest.self) else {
                return .refused(.error(400, "Could not read the chat request."))
            }
            body = EventSource { writer in
                await Self.pumpChat(writer) { try await host.chatStream(chat) }
            }
        } else if request.method == "POST",
                  let id = Self.parameter(segments, matching: ["conversations", "*", "messages"]) {
            guard caller != nil else { return .refused(unauthorized) }
            guard let message = try? request.decode(ControlAPI.NewMessageRequest.self) else {
                return .refused(.error(400, "Could not read the message."))
            }
            body = EventSource { writer in
                await Self.pumpChat(writer) {
                    try await host.replyInConversation(id: id, to: message)
                }
            }
        } else if request.method == "GET", segments == ["events"] {
            guard caller != nil else { return .refused(unauthorized) }
            body = EventSource { writer in
                await Self.pumpEvents(writer, hub: hub, host: host)
            }
        } else {
            return .notStreaming
        }

        guard activeEventStreams < Self.maximumEventStreams else {
            return .refused(.error(
                429,
                "Too many open streams. Close one before opening another."
            ))
        }
        activeEventStreams += 1
        return .stream(body)
    }

    private func deliver(_ source: EventSource, over connection: NWConnection) async {
        defer { activeEventStreams -= 1 }
        let writer = EventStreamWriter(connection: connection)
        let work = Task { await source.run(writer) }
        // A phone that walks out of range never sends anything we would notice while we are
        // only writing. Keeping a receive outstanding turns its FIN into a cancellation, so
        // the model stops generating into a dead socket instead of finishing the answer.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
            data, _, complete, error in
            if complete || error != nil || !(data?.isEmpty ?? true) { work.cancel() }
        }
        await work.value
    }

    /// Turns a chat stream into SSE frames. A failure becomes a final `error` event rather
    /// than a dropped connection, so a phone can show the sentence instead of guessing.
    private static func pumpChat(
        _ writer: EventStreamWriter,
        _ open: @Sendable () async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error>
    ) async {
        do {
            try await writer.open()
            for try await event in try await open() {
                try Task.checkCancellation()
                switch event {
                case .token(let text):
                    try await writer.send(event: "token", json: ControlAPI.StreamToken(text: text))
                case .reasoning(let text):
                    try await writer.send(event: "reasoning", json: ControlAPI.StreamToken(text: text))
                case .finished(let metrics):
                    try await writer.send(event: "finished", json: metrics)
                }
            }
        } catch is CancellationError {
            // The client hung up. There is nobody left to tell.
        } catch {
            try? await writer.send(
                event: "error", json: ControlAPI.ErrorResponse(error: error.localizedDescription)
            )
        }
    }

    private static func pumpEvents(
        _ writer: EventStreamWriter, hub: BuddyEventHub, host: any ControlHost
    ) async {
        guard (try? await writer.open()) != nil else { return }
        let subscription = await hub.subscribe()
        // Strictly after subscribing: a host that starts watching its own state and finds
        // no subscribers would stop again before this reader ever registered.
        await host.beginEventUpdates()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    for await event in subscription.stream {
                        guard (try? await writer.send(event)) != nil else { return }
                    }
                } onCancel: {
                    // Finishing the continuation is the only thing that breaks the reader
                    // above out of its `for await`.
                    Task { await hub.cancel(subscription.id) }
                }
            }
            group.addTask {
                var beat = ControlAPI.HeartbeatEvent(at: ControlAPI.timestamp(Date()))
                while !Task.isCancelled {
                    guard (try? await writer.send(.heartbeat(beat))) != nil else { return }
                    guard (try? await Task.sleep(for: heartbeatInterval)) != nil else { return }
                    beat = ControlAPI.HeartbeatEvent(at: ControlAPI.timestamp(Date()))
                }
            }
            // Whichever half ends first ends the response: a broken write means the socket
            // is gone, and a finished hub means there is nothing left to forward.
            await group.next()
            group.cancelAll()
        }
        await hub.cancel(subscription.id)
    }

    private var unauthorized: HTTPResponse {
        .error(401, "Invalid or missing control token.")
    }

    /// Matches a path shape with one wildcard — `["conversations", "*"]` — and hands back
    /// what the wildcard caught. Swift cannot pattern-match array literals with bindings,
    /// and a routing framework for four routes would be worse than this.
    static func parameter(_ segments: [String], matching shape: [String]) -> String? {
        guard segments.count == shape.count else { return nil }
        var captured: String?
        for (segment, expected) in zip(segments, shape) {
            if expected == "*" {
                guard !segment.isEmpty else { return nil }
                captured = segment
            } else if segment != expected {
                return nil
            }
        }
        return captured
    }

    private func route(
        _ request: HTTPRequest, as caller: Caller?, from source: String
    ) async -> HTTPResponse {
        // /health is unauthenticated so a client can tell "app not running" from "bad token".
        if request.path == "/health" {
            return .json(["status": "ok", "version": "0.1.0"])
        }
        // The OBS overlay is a browser source: it can carry a token in its URL but
        // cannot set headers, so these three routes accept the token either way. They
        // are read-only and serve nothing but the character currently on screen.
        if request.path.hasPrefix("/overlay") {
            guard request.query["token"] == token || request.bearerToken == token else {
                return .error(401, "Invalid or missing control token.")
            }
            switch request.path {
            case "/overlay":
                return .html(OverlayPage.html(token: token))
            case "/overlay/state":
                return (try? .encode(OverlayBroadcast.shared.state))
                    ?? .error(400, "Could not read the overlay state.")
            case "/overlay/portrait":
                guard let portrait = OverlayBroadcast.shared.portrait else {
                    return .error(404, "No persona portrait is set.")
                }
                return HTTPResponse(status: 200, body: portrait, contentType: "image/png")
            case "/overlay/portrait-eyes":
                guard let portrait = OverlayBroadcast.shared.closedEyesPortrait else {
                    return .error(404, "This persona has no closed-eyes drawing.")
                }
                return HTTPResponse(status: 200, body: portrait, contentType: "image/png")
            case "/overlay/portrait-open":
                guard let portrait = OverlayBroadcast.shared.openMouthPortrait else {
                    return .error(404, "This persona has no mouth-open drawing.")
                }
                return HTTPResponse(status: 200, body: portrait, contentType: "image/png")
            default:
                return .error(404, "Unknown endpoint \(request.method) \(request.path)")
            }
        }

        // Pairing is the one unauthenticated POST: a device that has nothing yet cannot
        // present anything. What stands in for a credential is the six-digit code the owner
        // is looking at, plus the rate limit that makes guessing it pointless.
        if request.method == "POST", request.path == "/buddy/pair" {
            guard let pairing = try? request.decode(ControlAPI.BuddyPairRequest.self) else {
                return .error(400, "Could not read the pairing request.")
            }
            let macName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            switch await buddy.pair(pairing, from: source, macName: macName, port: port) {
            case .paired(let response):
                return (try? .encode(response)) ?? .error(500, "Could not encode the pairing.")
            case .refused(let status, let message):
                return .error(status, message)
            }
        }

        guard let caller else { return unauthorized }

        let segments = request.path.split(separator: "/").map(String.init)
        if request.method == "GET", segments == ["buddy", "devices"] {
            guard caller == .control else {
                return .error(403, "Only this Mac can list paired devices.")
            }
            return (try? .encode(await buddy.devices()))
                ?? .error(500, "Could not encode the device list.")
        }
        if request.method == "DELETE",
           let id = Self.parameter(segments, matching: ["buddy", "devices", "*"]) {
            guard caller == .control else {
                return .error(403, "Only this Mac can revoke a paired device.")
            }
            guard await buddy.revoke(deviceID: id) else {
                return .error(404, "No paired device with id \(id).")
            }
            return .json(["status": "revoked"])
        }
        if request.method == "GET",
           let id = Self.parameter(segments, matching: ["conversations", "*"]) {
            do {
                return try .encode(await host.conversation(id: id))
            } catch {
                return .error(404, error.localizedDescription)
            }
        }

        do {
            switch (request.method, request.path) {
            case ("GET", "/conversations"):
                return try .encode(await host.conversationList())
            case ("POST", "/conversations"):
                let body = (try? request.decode(ControlAPI.NewConversationRequest.self))
                    ?? ControlAPI.NewConversationRequest()
                return try .encode(await host.createConversation(title: body.title))
            case ("GET", "/profile"):
                return try .encode(await host.profile())
            case ("GET", "/metrics"):
                return try .encode(await host.metrics())
            case ("GET", "/status"):
                return try .encode(await host.status())
            case ("GET", "/installed"):
                return try .encode(await host.installed())
            case ("GET", "/catalog"):
                return try .encode(await host.catalog(
                    category: request.query["category"],
                    onlyRunnable: request.query["onlyRunnable"] != "false"
                ))
            case ("GET", "/recommend"):
                guard let pick = await host.recommend(category: request.query["category"]) else {
                    return .error(404, "No model in the catalog fits this machine.")
                }
                return try .encode(pick)
            case ("POST", "/plan"):
                return try .encode(await host.plan(try request.decode(ControlAPI.PlanRequest.self)))
            case ("POST", "/install"):
                let message = try await host.install(request.decode(ControlAPI.LoadRequest.self))
                return .json(["status": message])
            case ("POST", "/load"):
                return try .encode(await host.load(try request.decode(ControlAPI.LoadRequest.self)))
            case ("POST", "/unload"):
                await host.unload()
                return .json(["status": "unloaded"])
            case ("GET", "/image/models"):
                return try .encode(await host.imageModels())
            case ("POST", "/image/plan"):
                return try .encode(await host.planImage(
                    try request.decode(ControlAPI.ImageRequest.self)
                ))
            case ("POST", "/image/generate"):
                return try .encode(await host.generateImage(
                    try request.decode(ControlAPI.ImageRequest.self)
                ))
            case ("GET", "/swarm"):
                return try .encode(await host.swarm())
            case ("GET", "/v1/node"):
                return try .encode(await host.nodeAdvertisement())
            case ("GET", "/mesh/models"):
                return try .encode(await host.meshModels())
            case ("GET", "/video/models"):
                return try .encode(await host.videoModels())
            case ("GET", "/video/queue"):
                return try .encode(await host.videoQueue())
            case ("POST", "/video/queue"):
                return try .encode(await host.enqueueVideos(
                    try request.decode(ControlAPI.VideoQueueRequest.self)
                ))
            case ("POST", "/video/queue/control"):
                return try .encode(await host.controlVideoQueue(
                    try request.decode(ControlAPI.VideoQueueControl.self)
                ))
            case ("POST", "/video/generate"):
                guard activeSynchronousVideos < Self.maximumSynchronousVideos else {
                    return .error(429, "Too many synchronous video requests. No clip was added. Use POST /video/queue to save work without holding a connection, then GET /video/queue to follow it.")
                }
                activeSynchronousVideos += 1
                defer { activeSynchronousVideos -= 1 }
                return try .encode(await host.generateVideo(
                    try request.decode(ControlAPI.VideoGenerateRequest.self)
                ))
            case ("POST", "/mesh/plan"):
                return try .encode(await host.planMesh(
                    try request.decode(ControlAPI.MeshRequest.self)
                ))
            case ("POST", "/mesh/generate"):
                return try .encode(await host.generateMesh(
                    try request.decode(ControlAPI.MeshRequest.self)
                ))
            case ("POST", "/benchmark"):
                return try .encode(await host.benchmark())
            case ("POST", "/chat"):
                return try .encode(await host.chat(try request.decode(ControlAPI.ChatRequest.self)))
            case ("POST", "/decide"), ("POST", "/v1/systemone"):
                // The second path is TypeSafe's own, so a client written for Jev can be
                // pointed here with only its base URL changed.
                return try .encode(await host.decide(try request.decode(ControlAPI.DecideRequest.self)))
            default:
                return .error(404, "Unknown endpoint \(request.method) \(request.path)")
            }
        } catch {
            return .error(400, error.localizedDescription)
        }
    }
}

// MARK: - Minimal HTTP

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    var bearerToken: String? {
        guard let value = headers["authorization"] else { return nil }
        let parts = value.split(
            maxSplits: 1, omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard parts.count == 2,
              parts[0].caseInsensitiveCompare("Bearer") == .orderedSame
        else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }

    enum ParseError: Error, LocalizedError {
        case malformed
        case closed

        var errorDescription: String? {
            switch self {
            case .malformed: "Malformed HTTP request."
            case .closed: "Connection closed."
            }
        }
    }

    /// Reads one request. Bodies are small JSON payloads, so a simple accumulate-until-complete
    /// loop is sufficient and avoids pulling in a whole HTTP stack.
    static func read(from connection: NWConnection) async throws -> HTTPRequest {
        // Absolute request-header/body deadline. Canceling the connection unblocks any
        // pending Network.framework receive, so a byte-at-a-time client cannot retain a
        // listener slot forever.
        let deadline = Task<Void, Never> {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard !Task.isCancelled else { return }
            connection.cancel()
        }
        defer { deadline.cancel() }

        var buffer = Data()
        var headerEnd: Range<Data.Index>?

        while headerEnd == nil {
            buffer.append(try await receive(from: connection))
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if buffer.count > 1_048_576 { throw ParseError.malformed }
        }
        guard let headerEnd else { throw ParseError.malformed }

        let headerText = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw ParseError.malformed }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { throw ParseError.malformed }
        let method = String(requestLine[0])
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { throw ParseError.malformed }
            let key = line[..<separator].lowercased().trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, headers[key] == nil else { throw ParseError.malformed }
            headers[key] = value
        }

        var body = buffer[headerEnd.upperBound...]
        guard headers["transfer-encoding"] == nil else { throw ParseError.malformed }
        if let lengthValue = headers["content-length"] {
            guard let length = Int(lengthValue), (0...16_777_216).contains(length),
                  body.count <= length
            else { throw ParseError.malformed }
            while body.count < length {
                body.append(try await receive(from: connection))
                if body.count > 16_777_216 { throw ParseError.malformed }
            }
        } else if !body.isEmpty {
            // This minimal server intentionally does not infer body framing from a socket
            // close. Reject ambiguous bytes instead of treating a pipelined request as data.
            throw ParseError.malformed
        }

        let components = URLComponents(string: "http://localhost\(target)")
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value
        }

        return HTTPRequest(
            method: method,
            path: components?.path ?? target,
            query: query,
            headers: headers,
            body: Data(body)
        )
    }

    private static func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: ParseError.closed)
                } else {
                    // A zero-byte read on a still-open connection would otherwise send the
                    // header loop spinning at full tilt against a slow client.
                    continuation.resume(throwing: ParseError.closed)
                }
            }
        }
    }
}

struct HTTPResponse {
    var status: Int
    var body: Data
    var contentType = "application/json"
    /// Additional headers, for the responses that need them (media ranges).
    var extraHeaders: [String: String] = [:]

    static func encode(_ value: some Encodable) throws -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return HTTPResponse(status: 200, body: try encoder.encode(value))
    }

    static func html(_ text: String) -> HTTPResponse {
        HTTPResponse(status: 200, body: Data(text.utf8), contentType: "text/html; charset=utf-8")
    }

    static func json(_ dictionary: [String: String]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: dictionary)) ?? Data()
        return HTTPResponse(status: 200, body: data)
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(ControlAPI.ErrorResponse(error: message))) ?? Data()
        return HTTPResponse(status: status, body: data)
    }

    func write(to connection: NWConnection) async throws {
        var headerLines = [
            "HTTP/1.1 \(status) \(Self.reason(status))",
            "Content-Type: \(contentType)",
            "Cache-Control: no-store",
            "Content-Length: \(body.count)",
            "Connection: close",
        ]
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            headerLines.append("\(name): \(value)")
        }
        let head = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 429: "Too Many Requests"
        default: "Error"
        }
    }
}

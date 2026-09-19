import Foundation
import Network
import os

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
    /// Whether the owner has asked for the swarm to reach this Mac, and a swarm token
    /// exists for it to authenticate with. Exposure without one is refused outright.
    public private(set) var swarmExposureRequested = false

    /// The owner's paired phones and tablets, and the one open pairing code.
    private let buddy: BuddyRegistry
    /// Where `/events` subscribers read from.
    private let events: BuddyEventHub
    /// The one listener that is not loopback, on this Mac's tailscale address. Nil unless
    /// somebody has asked for it and this Mac is actually on a tailnet.
    private var tailnetListener: NWListener?
    private var tailnetAddress: String?
    private var tailnetPortOverride: Int?
    /// Who currently needs it. Both features want the same address and the same port, so
    /// this is ownership of one socket rather than a second listener each.
    private var tailnetOwners: TailnetOwners = []
    /// What the live tailnet listener is actually bound to — set when the kernel says the
    /// listener is ready, never before — so a changed address or port rebinds instead of
    /// being quietly ignored, and nothing claims to be reachable until it is.
    private var boundEndpoint: TailnetEndpoint?
    /// What a bind in flight asked for. A listener waiting on an address this Mac does not
    /// hold sits here rather than in `boundEndpoint`, which is the difference between "not
    /// up yet" and "up".
    private var pendingEndpoint: TailnetEndpoint?
    /// Why the tailnet listener is not up, when it was asked for and could not be.
    public private(set) var tailnetError: String?
    private var activeEventStreams = 0
    /// How long one SSE frame may take to leave, and how this Mac's tailnet address is
    /// found. Both are injected so the tests can drive them without a tailnet or a stall.
    private let eventWriteDeadline: Duration
    private let discoverTailnetAddress: @Sendable () -> String?
    /// Called with the endpoint every time a tailnet listener becomes ready, and with nil
    /// every time one is closed. Nil in the app; the tests count these to prove that two
    /// features asking for the listener produce one socket and not two.
    private let tailnetBindObserver: (@Sendable (TailnetEndpoint?) -> Void)?

    /// Streams open right now. Read by the tests that prove a dead client is reaped.
    public var openEventStreams: Int { activeEventStreams }

    /// How long one SSE frame may take to leave before the connection is given up on.
    ///
    /// Twenty seconds is chosen against the heartbeat, not against a model: a reader that
    /// has not taken one frame in that long is gone, whatever it was sent. It is a
    /// per-frame budget, and frames are not coalesced — a token is written the moment the
    /// runtime yields it. That keeps latency honest and means a slow reader is detected by
    /// the first frame it fails to take rather than by a backlog; if the token rate ever
    /// outruns a phone's link, coalescing belongs here, not in a longer deadline.
    public static let defaultEventWriteDeadline: Duration = .seconds(20)

    /// Streams hold a connection for minutes or hours, so they get their own ceiling well
    /// under the connection limit — a phone that reconnects on every screen wake must not
    /// be able to starve the MCP bridge of sockets.
    public static let maximumEventStreams = 16

    /// How often an idle `/events` stream says it is still there. One goes out as soon as
    /// the stream opens, so a client knows immediately that it is connected.
    static let heartbeatInterval: Duration = .seconds(15)

    /// The port peers and phones dial on this Mac's tailnet address. Fixed rather than
    /// ephemeral, because the registry lists explicit base URLs and a paired phone has to
    /// find the Mac again after a relaunch.
    public static let tailnetPort = 8788

    private static let log = Logger(
        subsystem: "dev.siliconoptimizer", category: "control-server"
    )

    /// The address to paste into an OBS Browser Source. Carries the token in the URL
    /// because a browser source cannot send headers; nil until the server is listening.
    public var overlayURL: URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/overlay?token=\(token)")
    }

    public init(
        host: any ControlHost, handshakeURL: URL = ControlAPI.handshakeURL,
        buddy: BuddyRegistry = .shared, events: BuddyEventHub = .shared,
        eventWriteDeadline: Duration = ControlServer.defaultEventWriteDeadline,
        discoverTailnetAddress: @escaping @Sendable () -> String? = {
            SwarmPairing.tailnetIPv4()
        },
        tailnetBindObserver: (@Sendable (TailnetEndpoint?) -> Void)? = nil
    ) {
        self.host = host
        self.handshakeURL = handshakeURL
        self.buddy = buddy
        self.events = events
        self.eventWriteDeadline = eventWriteDeadline
        self.discoverTailnetAddress = discoverTailnetAddress
        self.tailnetBindObserver = tailnetBindObserver
        // A fresh token each launch: it is only meaningful for the lifetime of the process.
        self.token = UUID().uuidString
    }

    /// Starts listening. The primary listener is loopback and nothing else, always: what
    /// peers and phones reach is the tailnet listener, and only ever that one.
    ///
    /// The hard rule from the swarm design holds here: without a swarm token there is no
    /// non-loopback bind, whatever the caller asked for — an unauthenticated jobs API is an
    /// unauthenticated remote-execution service. `tailnetPort` exists for the tests, which
    /// reach the shared listener over loopback rather than over a tailnet.
    public func start(
        preferredPort: Int = 0, exposeToTailnet: Bool = false, swarmToken: String? = nil,
        tailnetPort: Int? = nil
    ) async throws {
        // A token that is only whitespace is not a token — the same rule `SwarmConfig`
        // applies to the file. It must not satisfy the bind rule, and a caller must not be
        // able to present one and be believed.
        let secret = (swarmToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let exposed = exposeToTailnet && !secret.isEmpty
        self.swarmToken = secret.isEmpty ? nil : secret
        self.swarmExposureRequested = exposed
        if let tailnetPort { self.tailnetPortOverride = tailnetPort }
        // The swarm's half of the ownership, set here and nowhere else — `refreshTailnetAccess`
        // owns Silicon Buddy's bit and leaves this one alone.
        setTailnetOwners(exposed ? tailnetOwners.union(.swarm) : tailnetOwners.subtracting(.swarm))

        let parameters = NWParameters.tcp
        // Loopback only. This must never be reachable from the network — an exposed swarm
        // binds the tailnet listener below, which is a different socket with a different
        // address and its own rules about which bearers mean anything on it.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(
            using: parameters,
            on: preferredPort > 0 ? NWEndpoint.Port(rawValue: UInt16(preferredPort))! : .any
        )
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection, from: .primary) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            Task { await self?.publishHandshake() }
        }
        listener.start(queue: .global(qos: .userInitiated))

        if exposeToTailnet {
            // One line, at startup, for an owner whose swarm.json predates this: the
            // setting still says the same thing, it just cannot mean 0.0.0.0 any more.
            Self.log.notice("""
                Swarm exposure is tailnet-only: the control API binds this Mac's tailscale \
                address on port \(self.tailnetPortOverride ?? Self.tailnetPort, privacy: .public), \
                never 0.0.0.0. Existing swarm settings need no change.
                """)
        }

        // The control server is restarted whenever swarm settings change, so this is also
        // what brings the tailnet listener back afterwards. Awaited rather than detached:
        // a caller that turns Silicon Buddy on straight after starting the server must not
        // race a refresh that is still deciding the listener should be down.
        await refreshTailnetAccess()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        tailnetOwners = []
        tailnetAddress = nil
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
    }

    // MARK: - The tailnet listener

    /// Who is asking for the one non-loopback listener.
    ///
    /// The swarm exposes the control API to this Mac's peers; Silicon Buddy serves the
    /// owner's phones. They want the same address on the same port, so they get one socket
    /// and this says who is still holding it — the last one to let go closes it.
    public struct TailnetOwners: OptionSet, Sendable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let swarm = TailnetOwners(rawValue: 1 << 0)
        public static let buddy = TailnetOwners(rawValue: 1 << 1)
    }

    /// Where the shared listener is bound right now.
    public struct TailnetEndpoint: Sendable, Equatable {
        public var address: String
        public var port: Int

        public init(address: String, port: Int) {
            self.address = address
            self.port = port
        }
    }

    /// The live endpoint, or nil when the listener is not up.
    public var tailnetEndpoint: TailnetEndpoint? {
        tailnetListener == nil ? nil : boundEndpoint
    }

    /// The address peers and companion apps reach this Mac on, or nil when they cannot.
    public var tailnetListenerAddress: String? { tailnetEndpoint?.address }

    /// The port they dial there. Separate from `listeningPort`, which is loopback's and
    /// changes every launch — a pairing QR has to carry this one.
    public var tailnetListenerPort: Int? { tailnetEndpoint?.port }

    /// Which features are holding the shared listener open. Read by the tests that prove
    /// there is exactly one of it.
    public var tailnetOwnership: TailnetOwners { tailnetOwners }

    /// The loopback port. Zero until the primary listener is ready.
    public var listeningPort: Int { port }

    /// What Settings and `GET /swarm` say about reaching this Mac from elsewhere.
    ///
    /// "Listening" means the kernel has handed us the port, not that a listener object
    /// exists: one waiting on an address this Mac does not hold is an object with nothing
    /// behind it, and reporting that as reachable is how a QR code ends up pointing at a
    /// dead port.
    public var exposure: ControlAPI.SwarmView.Exposure {
        ControlAPI.SwarmView.Exposure(
            requested: swarmExposureRequested,
            listening: tailnetEndpoint != nil,
            address: tailnetEndpoint?.address,
            port: tailnetEndpoint?.port,
            problem: tailnetError
        )
    }

    /// Said once, here, because Settings, the Buddy sheet and `GET /swarm` all report it.
    public static let noTailnetAddress =
        "This Mac has no tailscale address. Join the tailnet first — "
            + "the swarm and Silicon Buddy both ride on it."

    /// Brings the shared listener into line with what the two features are asking for: up
    /// on this Mac's tailscale address when the swarm is exposed or the owner has allowed
    /// their own devices, down when neither is.
    ///
    /// This is also the retry path. A bind that failed because tailscale was down clears
    /// the address but keeps the ownership, so the next refresh — a swarm poll, the Buddy
    /// toggle, a restart — discovers again and tries again.
    ///
    /// Discovery shells out to the tailscale CLI, so it runs off the actor — a `Process`
    /// round trip on the executor would stall every request in flight.
    public nonisolated func refreshTailnetAccess() async {
        let allowed = await buddy.allowsTailnetDevices
        guard await claimTailnetListener(forBuddy: allowed) else { return }
        let discover = await discovery()
        let address = await Task.detached(priority: .userInitiated) { discover() }.value
        guard let address else {
            await noteTailnetError(Self.noTailnetAddress)
            return
        }
        // Re-read the ownership rather than trusting what it was before the CLI ran: a
        // toggle flipped during that round trip must not be overruled by a stale answer.
        let owners = await currentOwners()
        guard !owners.isEmpty else { return }
        try? await setTailnetAccess(address: address, for: owners)
    }

    /// The retry the swarm's own poll carries. Rediscovery costs a `Process` round trip, so
    /// a poll that runs every twenty seconds only pays for it while the listener is down —
    /// which is the only state a retry could improve on.
    public nonisolated func refreshTailnetAccessIfDown() async {
        guard await tailnetEndpoint == nil else { return }
        await refreshTailnetAccess()
    }

    private func currentOwners() -> TailnetOwners { tailnetOwners }

    /// The one place ownership changes, so "who wants the listener" and "is the listener
    /// up" can never disagree. Everything else computes the set it wants and comes here.
    ///
    /// Closing here — rather than wherever an address happens to arrive — is what lets the
    /// two features share the socket: turning Silicon Buddy off while the swarm is exposed
    /// leaves it up and only stops device bearers meaning anything on it.
    @discardableResult
    private func setTailnetOwners(_ owners: TailnetOwners) -> Bool {
        tailnetOwners = owners
        guard owners.isEmpty else { return true }
        tailnetAddress = nil
        tailnetError = nil
        closeTailnetListener()
        return false
    }

    /// Silicon Buddy's half of the ownership, from `buddy.json`.
    ///
    /// Only its own bit: the swarm's is claimed in `start` and released there or through
    /// `setTailnetAccess`, and a refresh that recomputed it would quietly undo a claim it
    /// knows nothing about — which is one feature deciding another feature's business.
    private func claimTailnetListener(forBuddy wantedByBuddy: Bool) -> Bool {
        var owners = tailnetOwners
        if wantedByBuddy { owners.insert(.buddy) } else { owners.remove(.buddy) }
        return setTailnetOwners(owners)
    }

    private func discovery() -> @Sendable () -> String? { discoverTailnetAddress }

    /// Asks for (or withdraws) the shared listener on one feature's behalf. The port
    /// parameter exists for tests, which reach it over loopback rather than a tailnet.
    ///
    /// Withdrawing is per-owner: the listener only actually closes when the last holder
    /// lets go, which is what keeps the swarm up while Silicon Buddy goes off and back on.
    public func setTailnetAccess(
        address: String?, port overridePort: Int? = nil, for owner: TailnetOwners = .buddy
    ) throws {
        guard let address else {
            setTailnetOwners(tailnetOwners.subtracting(owner))
            return
        }
        guard Self.isBindableTailnetAddress(address) else {
            throw TailnetBindError.unacceptableAddress(address)
        }
        setTailnetOwners(tailnetOwners.union(owner))
        tailnetAddress = address
        if let overridePort { tailnetPortOverride = overridePort }
        tailnetError = nil
        syncTailnetListener()
    }

    /// The only addresses the shared listener may take: a tailnet IPv4 (100.64/10), or
    /// loopback, which is where the tests reach it. Anything else — a LAN address, a
    /// wildcard, an IPv6 any — is refused here, because binding one of those is exactly how
    /// a private API becomes a public one. The swarm goes through this gate too: "expose to
    /// the swarm" means the tailnet and nothing else, so there is no 0.0.0.0 path left.
    public static func isBindableTailnetAddress(_ address: String) -> Bool {
        // Parsed as an address, never scanned for numbers. `NWEndpoint.Host` will happily
        // take a name, so "100.64.0.1.evil.example.com" getting this far would turn a bind
        // rule into a DNS lookup someone else controls.
        guard let bytes = SwarmPairing.ipv4Bytes(address) else { return false }
        if bytes[0] == 127 { return true }
        return bytes[0] == 100 && (64...127).contains(bytes[1])
    }

    public enum TailnetBindError: Error, LocalizedError, Equatable {
        case unacceptableAddress(String)

        public var errorDescription: String? {
            switch self {
            case .unacceptableAddress(let address):
                "\(address) is not a tailnet address. This Mac binds the tailnet "
                    + "interface only, never the whole network."
            }
        }
    }

    private func syncTailnetListener() {
        guard !tailnetOwners.isEmpty, let address = tailnetAddress else {
            return closeTailnetListener()
        }
        let wanted = tailnetPortOverride ?? Self.tailnetPort
        guard (1...65_535).contains(wanted),
              let boundPort = NWEndpoint.Port(rawValue: UInt16(wanted))
        else { return }
        let endpoint = TailnetEndpoint(address: address, port: wanted)
        // One listener, whoever asked: a second `NWListener` on the same address and port
        // fails with EADDRINUSE while the first one holds it, so asking twice would turn a
        // working feature into an error message.
        //
        // A tailscale address can change under the app — a re-auth, a different tailnet. A
        // listener still bound to yesterday's endpoint is a feature that silently stopped.
        // `pendingEndpoint` counts here too: a bind that has not finished is still a bind
        // in progress, and starting a second one beside it is how two listeners happen.
        if let existing = boundEndpoint ?? pendingEndpoint {
            guard existing != endpoint else { return }
            closeTailnetListener()
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(address), port: boundPort
        )
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection, from: .tailnet) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { await self?.noteTailnetReady(endpoint) }
                case .waiting(let error), .failed(let error):
                    // `.waiting` is not "nearly there": asked for an address this Mac does
                    // not hold, Network.framework waits on EADDRNOTAVAIL forever while
                    // nothing listens. Treating it as the failure it is keeps the retry
                    // armed instead of leaving a dead port in a QR code.
                    Task {
                        await self?.noteTailnetError(
                            "Could not bind \(endpoint.address):\(endpoint.port) — "
                                + error.localizedDescription,
                            from: endpoint
                        )
                    }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            tailnetListener = listener
            // Not bound yet — only the `.ready` above may claim that, because until the
            // kernel says so there is nothing on the other end of this port.
            pendingEndpoint = endpoint
        } catch {
            tailnetError = error.localizedDescription
        }
    }

    /// The kernel has actually given us the port. Only now is anything reachable, and only
    /// now may `exposure` say so.
    private func noteTailnetReady(_ endpoint: TailnetEndpoint) {
        // A callback from a listener we have since cancelled must not resurrect it.
        guard tailnetListener != nil, pendingEndpoint == endpoint else { return }
        pendingEndpoint = nil
        boundEndpoint = endpoint
        tailnetError = nil
        tailnetBindObserver?(endpoint)
    }

    /// Records why the listener is down and leaves it down until something asks again.
    /// Clearing the address matters: without it a retry would repeat a bind that has
    /// already failed, in a loop, for as long as the app runs. The ownership stays, so the
    /// next refresh rediscovers the address and tries once more — which is what brings the
    /// listener up by itself after tailscale comes back.
    private func noteTailnetError(_ message: String, from endpoint: TailnetEndpoint? = nil) {
        // A late failure from a listener that has already been replaced says nothing about
        // the one that is up now.
        if let endpoint, endpoint != (boundEndpoint ?? pendingEndpoint) { return }
        tailnetError = message
        tailnetAddress = nil
        closeTailnetListener()
    }

    public func closeTailnetListener() {
        let wasThere = tailnetListener != nil
        tailnetListener?.cancel()
        tailnetListener = nil
        boundEndpoint = nil
        pendingEndpoint = nil
        if wasThere { tailnetBindObserver?(nil) }
    }

    // MARK: - Connection handling

    /// Which listener a connection came in on.
    ///
    /// This is a security boundary, not bookkeeping. The primary listener is loopback,
    /// always; the tailnet one is this Mac's tailscale address and nothing else. A device
    /// token must never be honoured on loopback — a phone that leaves the house, or is lost
    /// with its token on it, would otherwise authenticate through any local process — and
    /// the shared swarm secret is only a credential out there while the owner has actually
    /// asked for the swarm to reach this Mac.
    enum Origin: Sendable, Equatable {
        case primary
        case tailnet
    }

    private func accept(_ connection: NWConnection, from origin: Origin) {
        guard activeConnections < Self.maximumConnections else {
            connection.cancel()
            return
        }
        activeConnections += 1
        connection.start(queue: .global(qos: .userInitiated))
        Task { await serve(connection, from: origin) }
    }

    private func serve(_ connection: NWConnection, from origin: Origin) async {
        defer {
            connection.cancel()
            activeConnections -= 1
        }
        do {
            let request: HTTPRequest
            do {
                request = try await HTTPRequest.read(from: connection) { headers in
                    await self.bodyLimit(forHeaders: headers, from: origin)
                }
            } catch HTTPRequest.ParseError.bodyTooLarge(let limit) {
                await refuse(.error(
                    413, "That request body is larger than this device may send (\(limit) bytes)."
                ), on: connection)
                return
            } catch HTTPRequest.ParseError.lengthRequired {
                await refuse(.error(
                    411, "This server needs a Content-Length. Chunked bodies are not read."
                ), on: connection)
                return
            }

            let caller = await identify(request, from: origin)
            if let refusal = Self.scopeRefusal(for: request, as: caller) {
                try await refusal.write(to: connection)
                return
            }

            switch streamRoute(request, as: caller) {
            case .stream(let events):
                await deliver(events, as: caller, over: connection)
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
                let waiting = Task {
                    await route(request, as: caller, from: source, on: origin)
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, complete, error in
                    if complete || error != nil || !(data?.isEmpty ?? true) { waiting.cancel() }
                }
                response = await waiting.value
                guard !waiting.isCancelled else { return }
            } else {
                response = await route(request, as: caller, from: source, on: origin)
            }
            try await response.write(to: connection)
        } catch {
            // A client that hangs up mid-request is routine, not worth surfacing.
        }
    }

    /// Answers a request that was refused before its body arrived.
    ///
    /// Closing the socket on a client that is still uploading hands it a connection reset
    /// instead of the status we just wrote, which is how "your request is too large" becomes
    /// "the network went away". Reading and dropping what is still coming, briefly, is what
    /// lets the status get read.
    private func refuse(_ response: HTTPResponse, on connection: NWConnection) async {
        try? await response.write(to: connection)
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            guard let more = try? await HTTPRequest.receive(from: connection),
                  !more.isEmpty
            else { return }
        }
    }

    // MARK: - Who is asking

    /// The three credentials this server accepts, and what each one is worth. They are not
    /// equals: revoking a phone is the Mac's own business, so only the control token reaches
    /// `/buddy/devices` — and a phone the owner paired for chat gets less again.
    enum Caller: Sendable, Equatable {
        case control
        case swarm
        case device(id: String, scope: BuddyScope)

        var deviceID: String? {
            guard case .device(let id, _) = self else { return nil }
            return id
        }

        /// A chat-only device may read what the Mac is and talk to the model it has loaded.
        /// Anything that spends the machine — a download, a load, a render — or that
        /// administers other devices is the owner's own business.
        func mayReach(method: String, path: String) -> Bool {
            guard case .device(_, .chat) = self else { return true }
            return Self.chatOnlyRoutes.contains("\(method) \(path)")
                || path == "/conversations" || path.hasPrefix("/conversations/")
        }

        /// Listed rather than derived. "Read-only" is not the rule — `/benchmark` reads
        /// nothing and costs the machine minutes — so the set is written out, and a route
        /// added later is closed to chat-only devices until someone decides otherwise.
        ///
        /// `GET /recommend`, `/v1/node` and `/plan` are in it for the opposite reason: they
        /// read and advise and spend nothing, and a phone that cannot ask "would this fit
        /// here?" is blinkered for no gain.
        ///
        /// `POST /recommend` is deliberately *not* in it, and that is the whole distinction:
        /// ranking the catalogue against a described job asks Jev, which costs the owner
        /// money per distinct description, and a paired phone is not who decides what this
        /// Mac spends. The free verb stays open; the paid one takes full control.
        static let chatOnlyRoutes: Set<String> = [
            "GET /health", "GET /status", "GET /profile", "GET /metrics", "GET /catalog",
            "GET /installed", "GET /swarm", "GET /video/models", "GET /image/models",
            "GET /mesh/models", "GET /video/queue", "GET /events", "GET /recommend",
            "GET /v1/node", "POST /plan",
            "POST /chat", "POST /chat/stream", "POST /decide", "POST /v1/systemone",
        ]
    }

    /// The one place scope is enforced, before anything looks at the path — streaming and
    /// buffered routes alike, so there is exactly one message and no dead branch behind it.
    ///
    /// Pairing is exempt: it is unauthenticated, and a device re-pairing to be given more
    /// than chat would otherwise be refused by the very token it is replacing.
    static func scopeRefusal(for request: HTTPRequest, as caller: Caller?) -> HTTPResponse? {
        guard let caller else { return nil }
        guard !(request.method == "POST" && request.path == "/buddy/pair") else { return nil }
        guard !caller.mayReach(method: request.method, path: request.path) else { return nil }
        return .error(403, chatOnlyRefusal)
    }

    /// Why a task in the query string is refused. Exported so the contract fixture and the
    /// server cannot drift into promising different sentences.
    public static let taskBelongsInAPost =
        "Send the task in the body of POST /recommend, not in the URL. "
        + "GET /recommend takes only a category."

    /// Exported in the contract fixtures, so it is written once and read from there.
    public static let chatOnlyRefusal =
        "This device is paired for chat only. Pair it again with full control from "
            + "Settings → Silicon Buddy on the Mac."

    /// Likewise: the one sentence `POST /jev` refuses with, so the fixture and the server
    /// cannot say different things.
    public static let jevWriteRefusal =
        "Only this Mac can change the Jev settings. They govern what it spends, so they "
            + "are set in Settings → TypeSafe (Jev) on the Mac."

    /// And the one `POST /jev/calibrate` refuses with. Its own sentence rather than the
    /// one above, because the thing being refused is different: not a setting, a run.
    public static let jevCalibrateRefusal =
        "Only this Mac can start a calibration run. It spends Jev tokens and holds the "
            + "loaded model, so it is started from Settings → TypeSafe (Jev) on the Mac."

    /// What `GET /jev/calibration` says before there has ever been a run. A 404 with a
    /// sentence, rather than an empty body a client has to guess at.
    public static let noCalibrationYet =
        "This Mac has not calibrated its local decision lane yet. Run one from "
            + "Settings → TypeSafe (Jev), or POST /jev/calibrate."

    /// Whether the shared swarm secret is a credential on this listener.
    ///
    /// On loopback it always is — the MCP bridge and this Mac's own tools use it. Out on
    /// the tailnet it is one only while the swarm is the reason (or part of the reason) the
    /// listener is up: otherwise "let other Silicon nodes reach this Mac", turned off, would
    /// still let them, the moment Silicon Buddy raised the same socket for its own devices.
    private func honoursSwarmToken(from origin: Origin) -> Bool {
        origin == .primary || tailnetOwners.contains(.swarm)
    }

    private func identify(_ request: HTTPRequest, from origin: Origin) async -> Caller? {
        guard let bearer = request.bearerToken else { return nil }
        // The control token is this Mac's own: minted per launch, published in a 0600
        // handshake file, and meaningful only to processes that can read it. It is not a
        // remote credential, so it is not one out on the tailnet — the designed ones there
        // are the swarm token and a paired device's. That is what makes "only this Mac"
        // — on `/buddy/devices`, on `POST /jev`, on `POST /jev/calibrate` — literally true
        // rather than nearly true:
        // a phone or a peer cannot hold the token those routes ask for.
        if bearer == token { return origin == .primary ? .control : nil }
        if let swarmToken, !swarmToken.isEmpty, bearer == swarmToken,
           honoursSwarmToken(from: origin) {
            return .swarm
        }
        // The one door a device token opens. On the primary listener it is not a credential
        // at all, whatever it says.
        guard origin == .tailnet else { return nil }
        // Stamps last-seen as a side effect, which is the only place it could come from:
        // a device is "seen" exactly when it uses its token. Returns nil while the owner
        // has the toggle off, so suspending devices suspends the tokens too.
        guard let device = await buddy.authorize(bearer: bearer) else { return nil }
        return .device(
            id: device.id, scope: BuddyScope(rawValue: device.scope) ?? .full
        )
    }

    /// How much body this caller may send. A phone sends prompts and photographs; the local
    /// bridge installs models and posts whole images, so it keeps the original ceiling.
    private func bodyLimit(forHeaders headers: [String: String], from origin: Origin) async -> Int {
        guard origin == .tailnet else { return HTTPRequest.maximumBody }
        guard let bearer = HTTPRequest.bearerToken(in: headers) else {
            // No bearer on the tailnet means `/buddy/pair`, the one route with nothing to
            // check before the body is read — so the throttle cannot run until the upload
            // is over. A pairing request is a hundred bytes.
            return BuddyLimits.unauthenticatedBodyBytes
        }
        // Not `bearer == token`: out here the control token buys nothing at all, so it
        // must not buy a bigger body either.
        if swarmToken.map({ !$0.isEmpty && bearer == $0 }) ?? false,
           honoursSwarmToken(from: origin) {
            return HTTPRequest.maximumBody
        }
        return BuddyLimits.requestBodyBytes
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
            guard let caller else { return .refused(unauthorized) }
            let buddy = self.buddy
            // A stream opened this morning must not outlive the credential that opened it,
            // so the heartbeat asks again every time round rather than trusting the token
            // it was handed once.
            let stillAuthorized: @Sendable () async -> Bool = {
                guard let id = caller.deviceID else { return true }
                return await buddy.isKnown(deviceID: id)
            }
            body = EventSource { writer in
                await Self.pumpEvents(
                    writer, hub: hub, host: host, stillAuthorized: stillAuthorized
                )
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

    private func deliver(
        _ source: EventSource, as caller: Caller?, over connection: NWConnection
    ) async {
        defer { activeEventStreams -= 1 }
        let writer = EventStreamWriter(connection: connection, deadline: eventWriteDeadline)
        let work = Task { await source.run(writer) }
        // A phone that walks out of range never sends anything we would notice while we are
        // only writing. Keeping a receive outstanding turns its FIN into a cancellation, so
        // the model stops generating into a dead socket instead of finishing the answer.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
            data, _, complete, error in
            if complete || error != nil || !(data?.isEmpty ?? true) { work.cancel() }
        }
        // Revoking a device, or turning the whole feature off, ends what it is holding now.
        // Waiting for the next request would leave an answer streaming to a phone whose
        // access the owner has just taken away.
        var ticket: UUID?
        if let id = caller?.deviceID {
            ticket = await buddy.registerStream(deviceID: id) { work.cancel() }
            // Nil means the device stopped being one between `identify` and here. Chat
            // streams have no heartbeat to re-check them, so this is their only backstop.
            if ticket == nil { work.cancel() }
        }
        await work.value
        if let id = caller?.deviceID, let ticket {
            await buddy.releaseStream(deviceID: id, ticket: ticket)
        }
    }

    /// Turns a chat stream into SSE frames. A failure becomes a final `error` event rather
    /// than a dropped connection, so a phone can show the sentence instead of guessing.
    private static func pumpChat(
        _ writer: EventStreamWriter,
        _ open: @Sendable () async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error>
    ) async {
        do {
            // Nothing is written until the host agrees to start. A conversation that does
            // not exist, or is mid-answer, is then a 404 or a 409 the phone can act on
            // rather than a 200 whose first frame says otherwise.
            let stream = try await open()
            try await writer.open()
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .token(let text):
                    try await writer.send(event: "token", json: ControlAPI.StreamToken(text: text))
                case .reasoning(let text):
                    try await writer.send(event: "reasoning", json: ControlAPI.StreamToken(text: text))
                case .finished(let metrics):
                    try await writer.send(event: "finished", json: metrics)
                case .verdict(let verdict):
                    try await writer.send(event: "verdict", json: verdict)
                }
            }
        } catch is CancellationError {
            // The client hung up. There is nobody left to tell.
        } catch let error as BuddyHostError {
            await writer.refuse(
                status: error.status, message: error.localizedDescription
            )
        } catch {
            await writer.refuse(status: 400, message: error.localizedDescription)
        }
    }

    private static func pumpEvents(
        _ writer: EventStreamWriter, hub: BuddyEventHub, host: any ControlHost,
        stillAuthorized: @escaping @Sendable () async -> Bool = { true }
    ) async {
        guard (try? await writer.open()) != nil else { return }
        let subscription = await hub.subscribe()
        // Strictly after subscribing: a host that starts watching its own state and finds
        // no subscribers would stop again before this reader ever registered.
        await host.beginEventUpdates(postingTo: hub)

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
                    guard await stillAuthorized() else { return }
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
        _ request: HTTPRequest, as caller: Caller?, from source: String, on origin: Origin
    ) async -> HTTPResponse {
        // /health is unauthenticated so a client can tell "app not running" from "bad token".
        if request.path == "/health" {
            return .json(["status": "ok", "version": "0.1.0"])
        }
        // The OBS overlay is a browser source: it can carry a token in its URL but
        // cannot set headers, so these three routes accept the token either way. They
        // are read-only and serve nothing but the character currently on screen.
        if request.path.hasPrefix("/overlay") {
            // Loopback only, like the token it asks for. OBS runs on this Mac, and a token
            // in a URL is the one credential that leaks through a browser's history, logs
            // and referrers — it must not be a way back in from the tailnet.
            guard origin == .primary else {
                return .error(404, "Unknown endpoint \(request.method) \(request.path)")
            }
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
            // The port a device should keep dialling is the one it just reached us on —
            // the tailnet listener's, which is fixed across launches precisely so a paired
            // phone can find this Mac again. The tests bind it somewhere else so they can
            // tell the two listeners apart.
            let reachablePort = boundEndpoint?.port ?? port
            switch await buddy.pair(
                pairing, from: source, macName: macName, port: reachablePort
            ) {
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
                // A job description does not belong in a URL — it is the owner's prose
                // about their own work, and a URL is the part of a request that survives
                // in histories and logs. It is also the paid half of this route, and this
                // verb is the free one a chat-only phone may reach. Refused with somewhere
                // to go rather than silently ignored, which would look like the feature
                // being off.
                guard request.query["task"] == nil else {
                    return .error(400, Self.taskBelongsInAPost)
                }
                guard let pick = await host.recommend(
                    category: request.query["category"], task: nil
                ) else {
                    return .error(404, "No model in the catalog fits this machine.")
                }
                return try .encode(pick)
            case ("POST", "/recommend"):
                let body = try request.decode(ControlAPI.RecommendRequest.self)
                guard let pick = await host.recommend(
                    category: body.category, task: body.task
                ) else {
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
            case ("GET", "/jev"):
                return try .encode(await host.jevStatus())
            case ("GET", "/jev/guardrails/recent"):
                // Reachable by the Mac's own token, a full-control device, and — like every
                // route that is not listed as control-only — the swarm secret. A phone that
                // approves tool calls needs to see what the guardrail has been deciding;
                // the route carries verdicts and question ids and never what was screened,
                // which is what makes that sharing safe. A chat-only device is refused
                // before it gets here, because the path is not in `chatOnlyRoutes`.
                return try .encode(await host.recentGuardrailScreenings())
            case ("POST", "/jev"):
                // Reading what Jev costs is one thing; changing what this Mac will spend
                // is another. A full-control phone may look, only the Mac may set.
                guard caller == .control else {
                    return .error(403, Self.jevWriteRefusal)
                }
                return try .encode(await host.updateJev(
                    try request.decode(ControlAPI.JevUpdate.self)
                ))
            case ("GET", "/jev/calibration"):
                guard let result = await host.jevCalibration() else {
                    return .error(404, Self.noCalibrationYet)
                }
                return try .encode(result)
            case ("POST", "/jev/calibrate"):
                // Spends Jev tokens and holds the loaded model for a minute. Same rule as
                // POST /jev, for the same reason: a phone may read what this Mac spends but
                // not start it spending.
                guard caller == .control else {
                    return .error(403, Self.jevCalibrateRefusal)
                }
                return try .encode(await host.calibrateJev())
            default:
                return .error(404, "Unknown endpoint \(request.method) \(request.path)")
            }
        } catch let error as any ControlStatusError {
            // A host that knows what status it means gets to say so. Everything else is a
            // 400, which is right for "you asked wrong" and wrong for anything a client
            // could act on — which is why this branch exists.
            return .error(error.status, error.localizedDescription)
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

    /// The ceiling for a local caller. A device's is much lower — see `BuddyLimits`.
    static let maximumBody = 16_777_216

    var bearerToken: String? { Self.bearerToken(in: headers) }

    /// Also read before the body, to decide how much body this caller may send.
    static func bearerToken(in headers: [String: String]) -> String? {
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
        /// Declared or delivered more body than this caller is allowed.
        case bodyTooLarge(Int)
        /// A framing this server does not read — chunked, above all. Answered rather than
        /// dropped, because a client that gets nothing back cannot tell that from a crash.
        case lengthRequired

        var errorDescription: String? {
            switch self {
            case .malformed: "Malformed HTTP request."
            case .closed: "Connection closed."
            case .bodyTooLarge(let limit): "Request body over \(limit) bytes."
            case .lengthRequired: "A Content-Length is required."
            }
        }
    }

    /// Reads one request. Bodies are small JSON payloads, so a simple accumulate-until-complete
    /// loop is sufficient and avoids pulling in a whole HTTP stack.
    static func read(
        from connection: NWConnection,
        maximumBody limit: @Sendable ([String: String]) async -> Int = { _ in maximumBody }
    ) async throws -> HTTPRequest {
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
        guard headers["transfer-encoding"] == nil else { throw ParseError.lengthRequired }
        let allowed = min(await limit(headers), maximumBody)
        if let lengthValue = headers["content-length"] {
            guard let length = Int(lengthValue), length >= 0, body.count <= length else {
                throw ParseError.malformed
            }
            // Refused on the declared length, before a byte of it is read: the point of a
            // cap is not to receive the thing and then disapprove of it.
            guard length <= allowed else { throw ParseError.bodyTooLarge(allowed) }
            while body.count < length {
                body.append(try await receive(from: connection))
                if body.count > allowed { throw ParseError.bodyTooLarge(allowed) }
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

    static func receive(from connection: NWConnection) async throws -> Data {
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
        case 409: "Conflict"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        default: "Error"
        }
    }
}

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
    /// The id→path table behind `GET /media`, and the thing that turns the paths in a
    /// render's answer into something a phone can fetch. Shared by default with the event
    /// pump, so the `mediaID` on a finished `job` frame is the one the queue published.
    private let media: MediaDecoration
    /// Where a device's uploads land. Injected only so a test can keep them out of the
    /// tester's own Application Support.
    private let uploadsRoot: URL
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
    /// When expired uploads were last taken out. Nil until the first sweep.
    private var lastUploadSweep: Date?
    private let uploadSweepInterval: TimeInterval
    /// How long one SSE frame may take to leave, and how this Mac's tailnet address is
    /// found. Both are injected so the tests can drive them without a tailnet or a stall.
    private let eventWriteDeadline: Duration
    private let discoverTailnetAddress: @Sendable () -> String?
    /// Runs `POST /load` detached from the request that asked for it, and refuses a second
    /// load rather than throwing away the first. Injected only in the sense that its
    /// patience is: a test cannot wait 25 seconds to see what a slow load answers.
    private let loads = LoadDispatcher()
    private let loadPatience: Duration
    /// Called with the endpoint every time a tailnet listener becomes ready, and with nil
    /// every time one is closed. Nil in the app; the tests count these to prove that two
    /// features asking for the listener produce one socket and not two.
    private let tailnetBindObserver: (@Sendable (TailnetEndpoint?) -> Void)?
    /// Where `/ondevice/models` is answered from, when a test hands one in. Nil in the app,
    /// which asks its host — see `phoneModelSource()`.
    private let phoneModelOverride: (any PhoneModelProvider)?

    /// Streams open right now. Read by the tests that prove a dead client is reaped.
    public var openEventStreams: Int { activeEventStreams }

    /// Connections open right now, of `maximumConnections`. Read by the test that proves a
    /// reader which stops reading mid-file does not keep one of them for ever.
    public var openConnections: Int { activeConnections }

    /// How long one SSE frame may take to leave before the connection is given up on.
    ///
    /// Twenty seconds is chosen against the heartbeat, not against a model: a reader that
    /// has not taken one frame in that long is gone, whatever it was sent. It is a
    /// per-frame budget, and frames are not coalesced — a token is written the moment the
    /// runtime yields it. That keeps latency honest and means a slow reader is detected by
    /// the first frame it fails to take rather than by a backlog; if the token rate ever
    /// outruns a phone's link, coalescing belongs here, not in a longer deadline.
    public static let defaultEventWriteDeadline: Duration = .seconds(20)

    /// How long `POST /load` holds the connection before answering with the load still in
    /// flight.
    ///
    /// Longer than any load worth blocking on — a small model is up in a few seconds — and
    /// shorter than the request timeout of every HTTP client likely to call this, which is
    /// the actual constraint: an answer nobody is still listening for is not an answer. The
    /// load is unaffected either way; this only decides when the caller stops watching.
    public static let defaultLoadPatience: Duration = .seconds(25)

    /// How the tailnet listener's connections notice a peer that has gone.
    ///
    /// A phone that walks out of range does not close its socket; it simply stops
    /// answering. `/events` writes a heartbeat every fifteen seconds, and left to the
    /// kernel's defaults an unanswered one is retransmitted for many minutes before the
    /// connection is given up — minutes in which the stream holds one of sixteen slots and
    /// the Chat tab's badge says the phone is still watching. So retransmissions that go
    /// unanswered for `droppedAfter` seconds end the connection, and a connection with
    /// nothing in flight is probed after `keepaliveIdle` seconds of silence. Either way a
    /// vanished phone is gone within the minute. A peer that is merely slow, or a swarm
    /// node holding a long render request open, answers both and is left alone.
    enum TailnetLiveness {
        static let keepaliveIdle = 10
        static let keepaliveInterval = 5
        static let keepaliveCount = 3
        static let droppedAfter = 30
    }

    /// The tailnet listener's parameters: this Mac's tailnet address and nothing else, and
    /// the liveness rule above. Loopback's listener does not get it — a local process that
    /// vanishes closes its socket with it.
    static func tailnetParameters(address: String, port: NWEndpoint.Port) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = TailnetLiveness.keepaliveIdle
        tcp.keepaliveInterval = TailnetLiveness.keepaliveInterval
        tcp.keepaliveCount = TailnetLiveness.keepaliveCount
        tcp.connectionDropTime = TailnetLiveness.droppedAfter
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(address), port: port
        )
        return parameters
    }

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
        media: MediaRegistry = .shared,
        uploadsRoot: URL = BuddyUploads.root,
        postersRoot: URL = BuddyPosters.root,
        uploadSweepInterval: TimeInterval = ControlServer.defaultUploadSweepInterval,
        eventWriteDeadline: Duration = ControlServer.defaultEventWriteDeadline,
        loadPatience: Duration = ControlServer.defaultLoadPatience,
        discoverTailnetAddress: @escaping @Sendable () -> String? = {
            SwarmPairing.tailnetIPv4()
        },
        tailnetBindObserver: (@Sendable (TailnetEndpoint?) -> Void)? = nil,
        phoneModels: (any PhoneModelProvider)? = nil
    ) {
        self.host = host
        self.phoneModelOverride = phoneModels
        self.handshakeURL = handshakeURL
        self.buddy = buddy
        self.events = events
        self.uploadsRoot = uploadsRoot
        self.uploadSweepInterval = uploadSweepInterval
        self.media = MediaDecoration(
            registry: media, host: host,
            uploadsRoot: uploadsRoot, postersRoot: postersRoot
        )
        self.eventWriteDeadline = eventWriteDeadline
        self.loadPatience = loadPatience
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

        let parameters = Self.tailnetParameters(address: address, port: boundPort)
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
                request = try await HTTPRequest.read(from: connection) { method, path, headers in
                    await self.bodyLimit(
                        forMethod: method, path: path, headers: headers, from: origin
                    )
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
            // `/media/{id}` is per-id rather than a fixed path, so it is matched by shape.
            // A chat-only device may fetch a result for the same reason it may read
            // `GET /video/queue`, which has told it about that result since the queue
            // existed: looking at what the Mac already made spends nothing.
            if method == "GET", path.hasPrefix("/media/"), path.count > "/media/".count {
                return true
            }
            return Self.chatOnlyRoutes.contains("\(method) \(path)")
                || path == "/conversations" || path.hasPrefix("/conversations/")
        }

        /// Whether this caller may be shown a runtime's own log.
        ///
        /// `GET /status` is open to every credential this server honours, and it now carries
        /// the tail of a failed runtime's output. That text is the runtime's raw log — it
        /// names files, and on a Mac a file name is a path through somebody's folders. A
        /// device paired for chat was deliberately given less than full control, and the
        /// swarm secret is a node's credential rather than a person's; both are answered the
        /// whole failure *except* its log, which is the part that describes the owner's disk
        /// rather than what happened.
        var seesRuntimeLogs: Bool {
            switch self {
            case .control: true
            case .swarm: false
            case .device(_, let scope): scope == .full
            }
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

    /// A status as this caller may see it. Nil — a caller we could not identify — is given
    /// the narrow one, because the only safe reading of "who is this?" with no answer is
    /// "not somebody with full control".
    static func narrowed(_ status: ControlAPI.Status, for caller: Caller?) -> ControlAPI.Status {
        guard caller?.seesRuntimeLogs == true else { return status.withoutPrivilegedDetail }
        return status
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

    /// What `POST /buddy/invitations` says when a code would have nowhere to point.
    ///
    /// A pairing code is an address and a deadline as much as it is six digits. With the
    /// tailnet listener down there is nothing for a device to dial, and with Silicon Buddy
    /// switched off the token the code mints would be refused the moment it was used — so
    /// both answer with this one sentence, because the owner's next move is the same
    /// either way and a code nobody can spend is worse than a plain no.
    public static let buddyListenerDown =
        "Silicon Buddy's tailnet listener is not up, so a pairing code would have nowhere "
            + "to dial. Turn Silicon Buddy on in Settings → Silicon Buddy on the Mac and "
            + "wait for it to report an address."

    /// The one sentence for a scope this server does not have. It names the two it does,
    /// so a caller that guessed wrong does not have to go and find them.
    public static let unknownScopeRefusal =
        "A pairing code grants either \"full\" or \"chat\". Leave the scope out for full "
            + "control, which is what the Mac's own Settings window offers by default."

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

    /// The three sentences the decision routes refuse with. Each says what the thing being
    /// refused actually is, rather than one shared "only the Mac may": a phone told it
    /// cannot change lanes and a phone told it cannot start a download are in different
    /// situations and their owner's next move is different.
    public static let decisionLanesRefusal =
        "Only this Mac can change which lane answers a decision. It decides what the Mac "
        + "spends and whether what it is reasoning about leaves the machine, so it is set "
        + "in Settings → Decisions on the Mac."

    public static let decisionInstallRefusal =
        "Only this Mac can install a decision lane. It downloads about a gigabyte into the "
        + "Mac's model library, so it is started from Settings → Decisions on the Mac."

    public static let decisionTestRefusal =
        "Only this Mac can run the decision test bench. It can be pointed at Jev, which "
        + "costs money, so it is run from Settings → Decisions on the Mac."

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
    ///
    /// The route matters for exactly one of them. `POST /uploads` exists so a phone can make
    /// a mesh out of a picture it took, and a picture a phone took is bigger than any prompt
    /// — so that one route gets 24 MiB and every other route a device can reach keeps the
    /// 4 MiB it always had. Raised per route rather than across the board, because the cap
    /// is what stops an authenticated phone from spending this Mac's memory a request at a
    /// time, and a route that does not write files has no use for a larger one.
    private func bodyLimit(
        forMethod method: String, path: String, headers: [String: String], from origin: Origin
    ) async -> Int {
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
        // The raised ceiling is a property of a *caller*, not of a path. Asked here rather
        // than after the body, and asked of the registry rather than of the request: an
        // unknown bearer, a revoked device and a chat-only one all get the ordinary 4 MiB,
        // so pointing 24 MiB at this route with a guessed token buys nothing. It costs one
        // token lookup on one route.
        if method == "POST", path == "/uploads",
           let device = await buddy.authorize(bearer: bearer),
           BuddyScope(rawValue: device.scope) == .full {
            return BuddyUploads.maximumBytes
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
            // Who is reading decides what they are sent. The hub keeps agent frames from
            // everyone the agent routes refuse — a device paired for chat, and the swarm —
            // and counts the full-control devices for the Chat tab's badge.
            let audience: BuddyEventHub.Audience = switch caller {
            case .control: .thisMac
            case .device(let id, let scope): .device(id: id, scope: scope)
            case .swarm: .peer
            }
            body = EventSource { writer in
                await Self.pumpEvents(
                    writer, hub: hub, host: host, audience: audience,
                    stillAuthorized: stillAuthorized
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
        audience: BuddyEventHub.Audience,
        stillAuthorized: @escaping @Sendable () async -> Bool = { true }
    ) async {
        guard (try? await writer.open()) != nil else { return }
        let subscription = await hub.subscribe(as: audience)
        // Strictly after subscribing: a host that starts watching its own state and finds
        // no subscribers would stop again before this reader ever registered.
        await host.beginEventUpdates(postingTo: hub)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    await Self.forward(subscription, from: hub) { try await writer.send($0) }
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

    /// Sends one subscription's frames down its stream, and says so at the gap when some
    /// were dropped.
    ///
    /// The hub drops a slow subscriber's *oldest* frames, so whatever was lost is older
    /// than the frame just taken off the stream. The `resync` therefore goes out in front
    /// of that frame: exactly where the gap is, one per gap, before anything newer. The
    /// cursor a phone holds when it reads the `resync` is the one from the last frame it
    /// read before the gap — which is precisely where fetching again has to start.
    ///
    /// A drop that happens while this frame is being taken, just after it, is counted
    /// here too. That errs in the safe direction: the phone fetches from an older cursor
    /// than it strictly needed, and the fetch is authoritative.
    static func forward(
        _ subscription: (id: UUID, stream: AsyncStream<BuddyEvent.Frame>),
        from hub: BuddyEventHub,
        to send: @Sendable (BuddyEvent.Frame) async throws -> Void
    ) async {
        for await frame in subscription.stream {
            let lost = await hub.takeDropped(subscription.id)
            if lost > 0 {
                guard let data = try? BuddyEvent.resync(.init(dropped: lost)).encoded(),
                      (try? await send(.init(name: "resync", data: data))) != nil
                else { return }
            }
            guard (try? await send(frame)) != nil else { return }
        }
    }

    private var unauthorized: HTTPResponse {
        .error(401, "Invalid or missing control token.")
    }

    /// What scope a mint asked for: nothing at all means full control, which is the
    /// default the Settings window offers and the one the product is about. An empty string
    /// is nothing said too — a client that writes `""` for a field it has no answer for
    /// means the same as one that leaves the key out. Nil — and only nil — means the caller
    /// named a scope this server does not have, which is a 400 rather than a quiet fall
    /// back to the more powerful of the two.
    static func invitationScope(_ asked: String?) -> BuddyScope? {
        guard let asked, !asked.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .full
        }
        return BuddyScope(rawValue: asked)
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
        // The results themselves. Before everything else because it is the only route that
        // answers bytes rather than JSON, and the only one whose path is an id.
        if request.method == "GET", let id = Self.parameter(segments, matching: ["media", "*"]) {
            return await serveMedia(id: id, headers: request.headers, as: caller)
        }
        if request.method == "POST", segments == ["uploads"] {
            return await acceptUpload(request, as: caller)
        }
        if request.method == "GET",
           let name = Self.parameter(segments, matching: ["swarm", "peers", "*", "status"]) {
            do {
                return try .encode(await host.controlPeerStatus(name: name))
            } catch let error as any ControlStatusError {
                return .error(error.status, error.localizedDescription)
            } catch {
                return .error(400, error.localizedDescription)
            }
        }
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
        // Minting a pairing code is admitting the next device to this Mac, so it is gated
        // exactly as the device list is: `caller == .control`, which `identify` grants only
        // to this Mac's own token arriving on this Mac's own loopback listener. A phone
        // that could mint could pair the phone after it without the owner ever seeing a
        // code, and a peer that could mint could pair itself — neither is a tailnet's
        // business, so neither is reachable from out there at any scope.
        //
        // It exists so tests and scripts can pair without a human at the Settings window;
        // everything it hands back is what BuddyCenter's "Pair a device" would have shown.
        if request.method == "POST", segments == ["buddy", "invitations"] {
            guard caller == .control else {
                return .error(403, "Only this Mac can mint a pairing code.")
            }
            // No body at all is the ordinary shape of this request from a shell, and it
            // means what `{}` means: full control.
            let asked: ControlAPI.BuddyInvitationRequest
            if request.body.isEmpty {
                asked = ControlAPI.BuddyInvitationRequest()
            } else if let decoded = try? request.decode(ControlAPI.BuddyInvitationRequest.self) {
                asked = decoded
            } else {
                return .error(400, "Could not read the invitation request.")
            }
            // Read before anything is minted, so a typo in the scope cannot burn the code
            // the owner is already looking at.
            guard let scope = Self.invitationScope(asked.scope) else {
                return .error(400, Self.unknownScopeRefusal)
            }
            // Asked of the live listener rather than of the settings file: the code carries
            // the address a device will keep dialling, and the only honest answer to
            // "where?" is where something is actually listening as this is answered.
            guard let endpoint = tailnetEndpoint, await buddy.allowsTailnetDevices else {
                return .error(409, Self.buddyListenerDown)
            }
            // The registry's own mint, so a code from here is the same credential as one
            // from the Settings window in every way that matters — five minutes, one use,
            // ten wrong guesses and it burns — and it replaces whatever was on screen,
            // because two live codes would mean the owner cannot tell which admitted what.
            let invitation = await buddy.invite(
                host: endpoint.address, port: endpoint.port, scope: scope
            )
            // The response is the only place this code exists. Nothing here logs it, and
            // nothing can read it back: the next request for it mints a different one.
            return (try? .encode(ControlAPI.BuddyInvitationResponse(
                code: invitation.code, host: invitation.host, port: invitation.port,
                expiresAt: ControlAPI.timestamp(invitation.expiresAt),
                scope: invitation.scope.rawValue
            ))) ?? .error(500, "Could not encode the invitation.")
        }
        if request.method == "DELETE", segments == ["buddy", "invitations"] {
            guard caller == .control else {
                return .error(403, "Only this Mac can cancel a pairing code.")
            }
            // Idempotent on purpose. A caller that cancels a code already spent, expired or
            // never opened wants what it asked for — no live code — and has it. Answering
            // 404 would hand a script a race it cannot win against a five-minute clock.
            await buddy.cancelInvitation()
            return .json(["status": "cancelled"])
        }
        if request.method == "GET",
           let id = Self.parameter(segments, matching: ["conversations", "*"]) {
            do {
                return try .encode(await host.conversation(id: id))
            } catch {
                return .error(404, error.localizedDescription)
            }
        }
        // The models a phone runs by itself when this Mac is out of reach. Their own block
        // because every path under it shares the same gates.
        if segments.first == "ondevice" {
            return await routePhoneModels(request, segments: segments, as: caller, on: origin)
        }
        // The Chat tab's agent engines. Their own block because every path here has an
        // engine in it and two of them have a second parameter as well.
        if segments.first == "agent" {
            return await routeAgent(request, segments: segments, as: caller, on: origin)
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
                return try .encode(Self.narrowed(await host.status(), for: caller))
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
                let install = try request.decode(ControlAPI.LoadRequest.self)
                guard install.directory == nil || Self.mayNamePaths(caller) else {
                    return .error(403, "Only this Mac can choose a model download directory. Omit directory to use the configured model library.")
                }
                let message = try await host.install(install)
                return .json(["status": message])
            case ("POST", "/load"):
                // The load is detached from this request: a phone that locks its screen
                // must not abort a load the Mac was told to do. Either answer is a
                // `Status`, because "still loading" is a status — the same one `GET /status`
                // would give, and the same one this route gave while a load was in progress
                // before any of this existed.
                switch try await loads.load(
                    try request.decode(ControlAPI.LoadRequest.self),
                    on: host, patience: loadPatience
                ) {
                case .finished(let status):
                    return try .encode(Self.narrowed(status, for: caller))
                case .stillLoading:
                    return try .encode(Self.narrowed(await host.status(), for: caller))
                }
            case ("POST", "/unload"):
                await host.unload()
                return .json(["status": "unloaded"])
            case ("GET", "/image/models"):
                return try .encode(await host.imageModels())
            case ("POST", "/image/plan"):
                // Through the same gate as the render it plans. Skipping it here let a
                // device send an `initImagePath` that the planner then reported on — and
                // "no image at that path" versus a plan is a yes/no oracle for any path on
                // this Mac. Its `uploadID` and `mediaID` were being ignored, too.
                return try .encode(await host.planImage(
                    try await resolvedImage(request.decode(ControlAPI.ImageRequest.self),
                                            as: caller)
                ))
            case ("POST", "/image/generate"):
                return try .encode(await media.decorated(
                    await host.generateImage(
                        try await resolvedImage(request.decode(ControlAPI.ImageRequest.self),
                                                as: caller)
                    )
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
                // The one thing a phone keeps doing, and so the right place to hang a
                // sweep that would otherwise only ever run when something new arrives.
                await sweepUploadsIfDue()
                return try .encode(await media.decorated(await host.videoQueue()))
            case ("POST", "/video/queue"):
                return try .encode(await media.decorated(await host.enqueueVideos(
                    try request.decode(ControlAPI.VideoQueueRequest.self)
                )))
            case ("POST", "/video/queue/control"):
                return try .encode(await media.decorated(await host.controlVideoQueue(
                    try request.decode(ControlAPI.VideoQueueControl.self)
                )))
            case ("POST", "/video/generate"):
                guard activeSynchronousVideos < Self.maximumSynchronousVideos else {
                    return .error(429, "Too many synchronous video requests. No clip was added. Use POST /video/queue to save work without holding a connection, then GET /video/queue to follow it.")
                }
                activeSynchronousVideos += 1
                defer { activeSynchronousVideos -= 1 }
                return try .encode(await media.decorated(
                    await host.generateVideo(
                        try await resolvedVideo(
                            request.decode(ControlAPI.VideoGenerateRequest.self), as: caller
                        )
                    )
                ))
            case ("POST", "/mesh/plan"):
                return try .encode(await host.planMesh(
                    try await resolvedMesh(request.decode(ControlAPI.MeshRequest.self),
                                           as: caller)
                ))
            case ("POST", "/mesh/generate"):
                return try .encode(await media.decorated(
                    await host.generateMesh(
                        try await resolvedMesh(request.decode(ControlAPI.MeshRequest.self),
                                               as: caller)
                    )
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
                // `?lane=` is additive: without it this is the route it has always been,
                // answering for the lane that used to be the only one there was.
                guard let result = await host.decisionCalibration(
                    lane: request.query["lane"]
                ) else {
                    return .error(404, Self.noCalibrationYet)
                }
                return try .encode(result)
            case ("POST", "/jev/calibrate"), ("POST", "/decisions/calibrate"):
                // Spends Jev tokens and holds a model for a minute. Same rule as POST /jev,
                // for the same reason: a phone may read what this Mac spends but not start
                // it spending.
                guard caller == .control else {
                    return .error(403, Self.jevCalibrateRefusal)
                }
                // The lane may come from the query or from a body, and an empty body is
                // still the old route — which is what keeps every existing caller working.
                return try .encode(await host.calibrateDecisionLane(
                    request.query["lane"]
                        ?? (try? request.decode(ControlAPI.DecisionCalibrateRequest.self))?.lane
                ))
            case ("GET", "/decisions"):
                // Readable by the Mac and by a full-control device, like `GET /jev`: it
                // carries no key, no state and no question text — lane names, switches,
                // thresholds and totals. A chat-only device is refused before it gets here,
                // because the path is not in `chatOnlyRoutes`.
                return try .encode(await host.decisionsStatus())
            case ("POST", "/decisions/lanes"):
                // Control token only, and this is the route that most needs it: it decides
                // whether this Mac pays for its decisions and whether the state it reasons
                // about leaves the machine. Neither is a paired phone's to decide.
                guard caller == .control else {
                    return .error(403, Self.decisionLanesRefusal)
                }
                return try .encode(await host.updateDecisionLanes(
                    try request.decode(ControlAPI.DecisionLanesUpdate.self)
                ))
            case ("POST", "/decisions/install"):
                // Downloads about a gigabyte onto this Mac's model library. The owner's
                // disk, the owner's decision.
                guard caller == .control else {
                    return .error(403, Self.decisionInstallRefusal)
                }
                return try .encode(await host.installDecisionLane(
                    (try? request.decode(ControlAPI.DecisionInstallRequest.self)) ?? .init()
                ))
            case ("POST", "/decisions/test"):
                // Can be pointed at Jev, so it can spend money — same rule as everything
                // else here that can.
                guard caller == .control else {
                    return .error(403, Self.decisionTestRefusal)
                }
                return try .encode(await host.runDecisionTest(
                    try request.decode(ControlAPI.DecisionTestRequest.self)
                ))
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

    // MARK: - The Chat tab's agent sessions

    /// What a node is told when it reaches for `/agent`.
    ///
    /// The swarm secret is a credential everywhere else on this server, because everywhere
    /// else it buys rendering and model lists — things a peer is *for*. These routes run
    /// commands on this Mac and approve file changes to it, and a node is a machine with a
    /// token in a config file, not a person with a phone in their hand. So this is the one
    /// family the shared secret does not open, and it is refused by name rather than by
    /// 404: the owner debugging their own swarm should read why, not wonder where the
    /// route went.
    public static let agentsAreNotForPeers =
        "A swarm node may not drive this Mac's agent sessions. These routes run commands "
        + "here, so they are for the owner's own devices: pair one from "
        + "Settings → Silicon Buddy."

    /// What a loopback caller with the wrong `Host` is told on an agent route. The control
    /// token already keeps a web page out — a page cannot read it — so this is the second
    /// lock rather than the first: a page that rebinds its own name to 127.0.0.1 is still
    /// a page, and it has no business on the routes that run commands.
    public static let agentsAreForLoopbackHosts =
        "Only loopback clients may use the agent sessions on this listener."

    /// `/agent/...`, in one place because every path under it shares its gates — full
    /// control, never the swarm, a loopback `Host` on the loopback listener — and because
    /// the shapes are parameterised twice.
    private func routeAgent(
        _ request: HTTPRequest, segments: [String], as caller: Caller, on origin: Origin
    ) async -> HTTPResponse {
        // Scope has already refused a chat-only device before anything looked at the path:
        // none of these are in `chatOnlyRoutes`, which is what makes a route added here
        // full-scope by default rather than by remembering to say so.
        guard caller != .swarm else { return .error(403, Self.agentsAreNotForPeers) }
        // The gateway's own DNS-rebinding check, applied where it matters most. Phones
        // reach this Mac on the tailnet listener, where there is no browser to rebind.
        if origin == .primary {
            guard GatewayServer.isValidLoopbackHost(request.headers["host"]),
                  GatewayServer.isTrustedLoopbackOrigin(request.headers["origin"])
            else { return .error(403, Self.agentsAreForLoopbackHosts) }
        }
        // Noted before the route runs, refusals included: a phone that tried is a phone
        // that is there, and the badge on the Mac is about who is there.
        if case .device(let id, .full) = caller {
            await events.noteAgentActivity(deviceID: id)
        }

        do {
            if request.method == "GET", segments == ["agent", "sessions"] {
                return try .encode(await host.agentSessions(), compact: true)
            }
            if request.method == "GET",
               let engine = Self.parameter(segments, matching: ["agent", "sessions", "*"]) {
                return try .encode(await host.agentSession(
                    engine: engine, query: try Self.agentQuery(request.query)
                ), compact: true)
            }
            if request.method == "DELETE",
               let engine = Self.parameter(segments, matching: ["agent", "sessions", "*"]) {
                return try .encode(await host.stopAgentSession(engine: engine), compact: true)
            }
            if request.method == "POST",
               let engine = Self.parameter(
                   segments, matching: ["agent", "sessions", "*", "start"]
               ) {
                return try .encode(await host.startAgentSession(engine: engine), compact: true)
            }
            if request.method == "POST",
               let engine = Self.parameter(
                   segments, matching: ["agent", "sessions", "*", "new"]
               ) {
                return try .encode(await host.newAgentThread(engine: engine), compact: true)
            }
            if request.method == "POST",
               let engine = Self.parameter(
                   segments, matching: ["agent", "sessions", "*", "interrupt"]
               ) {
                return try .encode(
                    await host.interruptAgentSession(engine: engine), compact: true
                )
            }
            if request.method == "POST",
               let engine = Self.parameter(
                   segments, matching: ["agent", "sessions", "*", "messages"]
               ) {
                let body = try request.decode(ControlAPI.AgentMessageRequest.self)
                // 202 rather than 200: the turn has been handed to the engine and the
                // answer arrives on `/events`, which is a different promise from "here is
                // what it said".
                return try .encode(
                    await host.sendAgentMessage(engine: engine, body), status: 202,
                    compact: true
                )
            }
            if request.method == "POST",
               let (engine, id) = Self.parameters(
                   segments, matching: ["agent", "sessions", "*", "approvals", "*"]
               ) {
                let body = try request.decode(ControlAPI.AgentApprovalDecision.self)
                return try .encode(await host.answerAgentApproval(
                    engine: engine, id: id, decision: body.decision
                ), compact: true)
            }
            return .error(404, "Unknown endpoint \(request.method) \(request.path)")
        } catch let error as any ControlStatusError {
            return .error(error.status, error.localizedDescription)
        } catch {
            return .error(400, error.localizedDescription)
        }
    }

    /// `?since=&epoch=&limit=`, read strictly. A `since` that is not a number is a 400
    /// rather than "the whole transcript": the one client that would send one is a client
    /// resuming from an item id, which this contract does not take, and answering it with
    /// the whole thread every time would hide the bug behind a working screen.
    static func agentQuery(_ query: [String: String]) throws -> ControlAPI.AgentSessionQuery {
        func number(_ name: String) throws -> Int? {
            guard let text = query[name], !text.isEmpty else { return nil }
            guard let value = Int(text) else { throw AgentSessionError.badQuery(name) }
            return value
        }
        return ControlAPI.AgentSessionQuery(
            since: try number("since"), epoch: query["epoch"], limit: try number("limit")
        )
    }

    /// `parameter`'s two-wildcard sibling, for `/agent/sessions/{engine}/approvals/{id}`.
    /// Written out rather than generalised into "return every wildcard": two callers, two
    /// bindings, and a `[String]` result would hand every caller an index to get wrong.
    static func parameters(
        _ segments: [String], matching shape: [String]
    ) -> (String, String)? {
        guard segments.count == shape.count else { return nil }
        var captured: [String] = []
        for (segment, expected) in zip(segments, shape) {
            if expected == "*" {
                guard !segment.isEmpty else { return nil }
                captured.append(segment)
            } else if segment != expected {
                return nil
            }
        }
        guard captured.count == 2 else { return nil }
        return (captured[0], captured[1])
    }

    // MARK: - Models for the phone

    /// The provider `/ondevice/models` answers from: a test's, or the host's.
    private func phoneModelSource() async -> (any PhoneModelProvider)? {
        if let phoneModelOverride { return phoneModelOverride }
        return await host.phoneModelProvider()
    }

    /// `/ondevice/models/...`, in one place because every path under it shares its gates:
    /// full control, never the swarm, a loopback `Host` on the loopback listener.
    ///
    /// Nothing from the path is ever a path. The `{id}` segment is handed to the provider,
    /// which looks it up in the catalogue and answers 404 for anything that is not a key
    /// there — a traversal, a file name and a typo alike.
    private func routePhoneModels(
        _ request: HTTPRequest, segments: [String], as caller: Caller, on origin: Origin
    ) async -> HTTPResponse {
        // A chat-only device never gets here: none of these is in `chatOnlyRoutes`, so the
        // scope gate has already answered it — which is what makes a route added here full
        // scope by default rather than by remembering to say so.
        guard caller != .swarm else { return .error(403, Self.phoneModelsAreNotForPeers) }
        // Starting a multi-gigabyte download and deleting files are worth the same second
        // lock as the agent routes. Phones reach this Mac on the tailnet listener, where
        // there is no browser to rebind a name.
        if origin == .primary {
            guard GatewayServer.isValidLoopbackHost(request.headers["host"]),
                  GatewayServer.isTrustedLoopbackOrigin(request.headers["origin"])
            else { return .error(403, Self.phoneModelsAreForLoopbackHosts) }
        }
        let provider = await phoneModelSource()

        do {
            if request.method == "GET", segments == ["ondevice", "models"] {
                return try .encode(
                    await provider?.phoneModels() ?? ControlAPI.PhoneModelList(models: [])
                )
            }
            if request.method == "POST",
               let id = Self.parameter(segments, matching: ["ondevice", "models", "*", "prepare"]) {
                guard let provider else { throw PhoneModelError.unknownModel(id) }
                // `?verify=1` hashes a ready copy again before it is served — what a phone
                // asks for once when the file it fetched did not hash to the pin.
                let verify: Bool
                switch request.query["verify"]?.lowercased() {
                case nil, "0", "false": verify = false
                case "1", "true": verify = true
                default: return .error(400, Self.phoneModelVerifyValues)
                }
                let prepared = try await provider.preparePhoneModel(id: id, verify: verify)
                // 202 for a fetch that is on its way, started now or already; 200 for a
                // model that was ready before anyone asked. Either way the body is the entry,
                // so a phone learns the state from the same answer.
                return try .encode(prepared.model, status: prepared.wasReady ? 200 : 202)
            }
            if request.method == "GET",
               let id = Self.parameter(segments, matching: ["ondevice", "models", "*", "file"]) {
                guard let provider else { throw PhoneModelError.unknownModel(id) }
                return servePhoneModelFile(
                    try await provider.phoneModelFile(id: id), request: request.headers
                )
            }
            if request.method == "DELETE",
               let id = Self.parameter(segments, matching: ["ondevice", "models", "*"]) {
                guard let provider else { throw PhoneModelError.unknownModel(id) }
                return try .encode(await provider.removePhoneModel(id: id))
            }
            return .error(404, "Unknown endpoint \(request.method) \(request.path)")
        } catch let error as any ControlStatusError {
            return .error(error.status, error.localizedDescription)
        } catch {
            return .error(400, error.localizedDescription)
        }
    }

    /// The verified file, as bytes. The same machinery as `GET /media/{id}` — ranges,
    /// `If-None-Match`, `If-Range`, chunks under the slow-reader deadline — with the digest
    /// as the tag, because the digest is exactly what identifies these bytes.
    ///
    /// `no-store` rather than the media family's hour: a multi-gigabyte model is written
    /// into the phone's own storage by the app that asked for it, and no cache on the way
    /// has any business keeping a second copy.
    private func servePhoneModelFile(
        _ file: ControlAPI.PhoneModelFile, request: [String: String]
    ) -> HTTPResponse {
        let tag = "\"\(file.sha256)\""
        // The pinned file's own name, which says nothing about this Mac's folders; filtered
        // anyway, because a header is the wrong place to find out a catalogue entry had a
        // quote in it.
        let name = file.fileName.filter { $0.isASCII && $0 != "\"" && !$0.isNewline }
        let headers = [
            "Accept-Ranges": "bytes",
            "X-Content-Type-Options": "nosniff",
            "ETag": tag,
            "X-Content-SHA256": file.sha256,
            "Content-Disposition": "attachment; filename=\"\(name)\"",
        ]
        return Self.fileResponse(
            file.url, size: Int(file.sizeBytes), tag: tag,
            contentType: "application/octet-stream", headers: headers, cacheControl: "no-store",
            request: request, writeDeadline: eventWriteDeadline
        )
    }

    // MARK: - Serving what this Mac made

    /// `GET /media/{id}`.
    ///
    /// The id is looked up, never parsed. There is no path in this request and no way to
    /// put one in it: an id that is not in the table is a 404 that says the same thing
    /// whether the file never existed, was deleted, or belongs to a folder this Mac does
    /// not serve from — a caller learns nothing from the difference, because there is
    /// nothing it could do with it.
    private func serveMedia(
        id: String, headers: [String: String], as caller: Caller
    ) async -> HTTPResponse {
        // The roots are handed in so the registry can check them *now*, against the path
        // re-resolved now — an id is a promise about a file, and this is where it is
        // rechecked rather than remembered.
        let roots = await media.roots()
        guard let entry = await media.registry.entry(id: id, within: roots) else {
            return .error(404, Self.noSuchMedia)
        }
        // A file under the uploads root belongs to the device that sent it. Answered 404
        // rather than 403 for another device's id: "that is not yours" and "that does not
        // exist" have to look the same, or the route is an oracle for what other phones
        // have uploaded.
        guard mayUse(path: entry.path, as: caller) else {
            return .error(404, Self.noSuchMedia)
        }
        // Scope, per id rather than per route. A chat-only device may see what the Mac has
        // made — a poster is a few kilobytes and is what a list is — but pulling the
        // renders themselves down is a different permission, and it is the one the owner
        // withheld when they paired this device for chat.
        if case .device(_, .chat) = caller, !entry.isPoster {
            return .error(403, Self.fullResultsNeedFullControl)
        }

        let url = URL(fileURLWithPath: entry.path)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: entry.path))?[.size]
            as? NSNumber
        else { return .error(404, Self.noSuchMedia) }
        let total = size.intValue
        let tag = MediaRegistry.etag(for: entry.path)

        // A poster or an image is fetched once per list and then again on every scroll;
        // answering "you already have it" costs a header instead of a megabyte. That only
        // works if the answer is cacheable at all, which is why these are the one family of
        // responses this server does not mark `no-store`: they are a device's own results,
        // addressed by an unguessable id, so `private` is the accurate word for them.
        var extra = [
            "Accept-Ranges": "bytes",
            // The content type is read off the extension, inside folders this Mac writes.
            // Saying so stops a browser deciding a .png is something more interesting.
            "X-Content-Type-Options": "nosniff",
        ]
        if let tag { extra["ETag"] = tag }
        // Pictures and clips are meant to be shown. A mesh, an OBJ or a sound file is not
        // something a viewer should render in place, and the id is the only name it needs.
        if !entry.contentType.hasPrefix("image/"), !entry.contentType.hasPrefix("video/") {
            let suffix = URL(fileURLWithPath: entry.path).pathExtension
            extra["Content-Disposition"] =
                "attachment; filename=\"\(id)\(suffix.isEmpty ? "" : ".\(suffix)")\""
        }

        return Self.fileResponse(
            url, size: total, tag: tag, contentType: entry.contentType, headers: extra,
            cacheControl: Self.mediaCacheControl, request: headers,
            writeDeadline: eventWriteDeadline
        )
    }

    // MARK: - Answering with a file

    /// A file, answered the one way this server answers files, whichever route found it.
    ///
    /// `GET /media/{id}` and `GET /ondevice/models/{id}/file` differ in what they serve and
    /// who may have it. How the bytes go out is the same, and is written here once: `304`
    /// for an `If-None-Match` that names the current tag, `206` for one `Range`, `416` with
    /// the real end for a range outside the file, and the whole file otherwise — never read
    /// into memory, but sent in chunks, each under the slow-reader deadline.
    ///
    /// `If-Range` is honoured: a range asked on condition that the file is still the one
    /// the client started on is served as a range only while the tag matches, and as the
    /// whole file when it does not. That is what makes resuming safe — a client holding the
    /// first half of one file must never be handed the second half of another.
    static func fileResponse(
        _ url: URL, size total: Int, tag: String?, contentType: String,
        headers: [String: String], cacheControl: String, request: [String: String],
        writeDeadline: Duration
    ) -> HTTPResponse {
        var extra = headers
        if let tag, let asked = request["if-none-match"], entityTag(tag, isNamedIn: asked) {
            var unchanged = HTTPResponse(
                status: 304, body: Data(), contentType: contentType, extraHeaders: extra
            )
            // A 304 has no body, and a framing header for a body that cannot exist is one
            // more thing for a proxy to disagree with.
            unchanged.omitsContentLength = true
            unchanged.cacheControl = cacheControl
            return unchanged
        }

        // Players probe with `bytes=0-1` before they will play anything, and seeking is
        // ranges all the way down; a video endpoint without them plays nothing at all. A
        // phone resuming a download asks for `bytes=N-` and must get exactly the rest.
        //
        // One range only. A multi-range request wants `multipart/byteranges`, which this
        // server does not write, and answering the first range as though it were the whole
        // ask would hand a player bytes it did not request under a header saying otherwise.
        // Ignoring the header and sending the file is the behaviour RFC 9110 allows — and
        // it is what a failed `If-Range` requires.
        var ranged = request["range"]
        if let condition = request["if-range"], !strongMatch(condition, tag) {
            ranged = nil
        }
        if let asked = ranged, !asked.contains(","), let spec = byteRangeSpec(asked) {
            guard let range = GatewayAPI.byteRange(header: "bytes=" + spec, fileSize: total)
            else {
                // With where the end actually is, so a player that guessed can correct
                // itself instead of retrying the same range.
                var refusal = HTTPResponse.error(416, Self.rangeOutsideFile)
                extra["Content-Range"] = "bytes */\(total)"
                refusal.extraHeaders = extra
                return refusal
            }
            extra["Content-Range"] =
                "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)"
            var partial = HTTPResponse(
                status: 206, file: url, range: range,
                contentType: contentType, extraHeaders: extra
            )
            partial.cacheControl = cacheControl
            partial.writeDeadline = writeDeadline
            return partial
        }
        var whole = HTTPResponse(
            status: 200, file: url, range: 0..<total,
            contentType: contentType, extraHeaders: extra
        )
        whole.cacheControl = cacheControl
        whole.writeDeadline = writeDeadline
        return whole
    }

    /// The part after `bytes=` of a `Range` header, or nil for a range in any other unit —
    /// which RFC 9110 says a server ignores rather than refuses, so the whole file goes out.
    /// The unit is compared without regard to case, as the RFC has it.
    static func byteRangeSpec(_ header: String) -> String? {
        guard let equals = header.firstIndex(of: "=") else { return nil }
        let unit = header[..<equals].trimmingCharacters(in: .whitespaces)
        guard unit.caseInsensitiveCompare("bytes") == .orderedSame else { return nil }
        return String(header[header.index(after: equals)...])
    }

    /// An entity tag without its weakness marker and its quotes. A client that sends the
    /// bare digest it read from `X-Content-SHA256` means the same tag as one that quotes it.
    private static func opaque(_ tag: String) -> (weak: Bool, value: String) {
        var value = tag.trimmingCharacters(in: .whitespaces)
        let weak = value.hasPrefix("W/")
        if weak { value = String(value.dropFirst(2)) }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return (weak, value)
    }

    /// Whether an `If-None-Match` names this tag: `*`, or the tag anywhere in its list,
    /// compared weakly as RFC 9110 has it for this header.
    static func entityTag(_ tag: String, isNamedIn header: String) -> Bool {
        let wanted = opaque(tag).value
        return header.split(separator: ",").contains { candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            return trimmed == "*" || opaque(trimmed).value == wanted
        }
    }

    /// `If-Range`'s comparison, which is strong: a weak tag never matches, and neither does
    /// a date, because this server does not send `Last-Modified` for one to be copied from.
    static func strongMatch(_ condition: String, _ tag: String?) -> Bool {
        guard let tag else { return false }
        let asked = opaque(condition), current = opaque(tag)
        return !asked.weak && !current.weak && asked.value == current.value
    }

    /// The one family of responses this server lets a client keep.
    ///
    /// `private` because it is one device's own results and no shared cache has any
    /// business with them; an hour because that is long enough for a list to scroll and
    /// short enough that a revoked device's cached copy is not a standing grant. The
    /// `ETag` is what makes it correct rather than merely cheap.
    static let mediaCacheControl = "private, max-age=3600"

    /// A file under the uploads root belongs to exactly one device. Everything else — a
    /// render this Mac made — belongs to the owner, and any of their devices may have it.
    private func mayUse(path: String, as caller: Caller) -> Bool {
        guard let root = MediaRegistry.resolve(uploadsRoot.path),
              MediaRegistry.isInside(path, roots: [root])
        else { return true }
        guard let mine = MediaRegistry.resolve(
            BuddyUploads.deviceRoot(Self.bucket(for: caller), at: uploadsRoot).path
        ) else { return false }
        return MediaRegistry.isInside(path, roots: [mine])
    }

    /// The verbs `POST /video/queue/control` has, in the one sentence it refuses an
    /// unknown one with. Here rather than beside the switch that implements them because
    /// the contract export has to publish the same list, and two hand-written copies of a
    /// six-item set drift the first time a seventh is added.
    public static let unknownQueueAction =
        "Use pause, resume, retry, remove, stop_following, or clear_finished."

    /// What a chat-only device is told when it asks for a render rather than a poster.
    /// Its own sentence, not the general chat-only one, because the route it is being
    /// refused on is a route it may otherwise use.
    public static let fullResultsNeedFullControl =
        "This device is paired for chat only, so it may fetch preview images but not the "
            + "renders themselves. Pair it again with full control from Settings → Silicon "
            + "Buddy on the Mac."

    /// What a `Range` outside the file is answered with, alongside a `Content-Range`
    /// saying where the end is.
    public static let rangeOutsideFile = "That byte range is not inside this file."

    /// The one sentence `GET /media` refuses with. Exported so the fixture and the server
    /// cannot promise different words.
    public static let noSuchMedia =
        "No file with that media id. Ids are issued by this Mac with each result and stop "
            + "working when the file is deleted."

    /// What `POST /uploads` refuses a body it will not keep.
    public static let unreadableUpload =
        "That upload is not an image or a short video this Mac will keep. Send a PNG, JPEG, "
            + "GIF, WebP, MP4, MOV or WebM."

    /// Deletes expired uploads, at most once an hour unless the caller insists.
    ///
    /// On arrival *and* on a queue poll. Arrival alone was wrong: a device that uploads a
    /// picture, makes its mesh and never uploads again leaves that picture there for good,
    /// and the one thing a phone does keep doing is polling the queue. A timer would be
    /// the other answer, and a worse one — it would run in an app nobody is talking to.
    private func sweepUploadsIfDue(force: Bool = false) async {
        let now = Date()
        if !force, let last = lastUploadSweep,
           now.timeIntervalSince(last) < uploadSweepInterval {
            return
        }
        lastUploadSweep = now
        guard BuddyUploads.sweep(at: uploadsRoot, now: now) > 0 else { return }
        await media.registry.forgetMissingFiles()
    }

    /// How often the sweep is worth running. An hour, because what it is looking for is a
    /// week old: running it on every poll would be a directory walk a second for nothing.
    /// Injected only so a test can compress the week into a moment.
    public static let defaultUploadSweepInterval: TimeInterval = 3600

    /// What a device is told when the bytes could not be written. Deliberately says
    /// nothing about this Mac's disk.
    public static let uploadNotSaved =
        "This Mac could not save that upload. Check the Mac has free space, then try again."

    /// Which folder a caller's uploads go in.
    ///
    /// A device's own id, so revoking a phone and deleting what it sent are one gesture.
    /// The Mac's own token and the swarm secret are not devices and get their own buckets
    /// rather than sharing one with whichever phone paired first.
    private static func bucket(for caller: Caller) -> String {
        switch caller {
        case .control: "mac"
        case .swarm: "swarm"
        case .device(let id, _): id
        }
    }

    /// `POST /uploads` — the only route on this server that takes bytes rather than JSON.
    ///
    /// What arrives is decided by what it *is*, never by what it says it is: the magic
    /// bytes choose the type and the extension, and `X-Filename` and `Content-Type` are
    /// read for nothing but the error message. A body that is not an image or a short
    /// video is refused before anything is written.
    private func acceptUpload(_ request: HTTPRequest, as caller: Caller) async -> HTTPResponse {
        guard let payload = UploadBody.payload(
            of: request.body, contentType: request.headers["content-type"]
        ), !payload.isEmpty else {
            return .error(400, "That upload has no body in it.")
        }
        guard let kind = MediaSniffer.kind(of: payload) else {
            return .error(415, Self.unreadableUpload)
        }
        let uploadID = UUID().uuidString
        let destination: URL
        do {
            destination = try BuddyUploads.destination(
                forBucket: Self.bucket(for: caller), uploadID: uploadID,
                fileExtension: kind.fileExtension, at: uploadsRoot
            )
            // User-only from the moment the bytes exist, not chmodded afterwards.
            try MediaRegistry.writeUserOnly(payload, to: destination)
        } catch {
            // A full disk, a read-only volume, a folder the owner moved: all real, none of
            // them a device's business. The reason goes to the log with the path in it;
            // the device gets the one sentence it can act on, and no filesystem layout.
            Self.log.error(
                "Could not save an upload: \(error.localizedDescription, privacy: .public)"
            )
            return .error(500, Self.uploadNotSaved)
        }
        await sweepUploadsIfDue(force: true)

        guard let mediaID = await media.registry.register(
            path: destination.path, within: await media.roots()
        ) else {
            try? FileManager.default.removeItem(at: destination)
            return .error(500, Self.uploadNotSaved)
        }
        await media.registry.persist()
        return (try? .encode(ControlAPI.UploadResponse(
            uploadID: uploadID, mediaID: mediaID, bytes: payload.count,
            contentType: kind.contentType, mediaURL: MediaDecoration.url(for: mediaID),
            expiresAt: ControlAPI.timestamp(Date().addingTimeInterval(BuddyUploads.lifetime))
        ))) ?? .error(500, "Could not encode the upload.")
    }

    // MARK: - Naming a picture without naming a path

    /// What a render says about an id that named nothing — nearly always an upload that
    /// has been swept, which is why it says so rather than "no image given".
    public static let expiredSubject =
        "That uploadID or mediaID does not name a file on this Mac any more. Uploads are "
            + "kept for seven days; send the picture again."

    /// The sentence every request that needs a subject image refuses with.
    public static let noSubjectImage =
        "Name the image to work from: an uploadID from POST /uploads, a mediaID this Mac "
            + "issued, or — from this Mac's own token — an absolute imagePath."

    /// Turns an `uploadID` or a `mediaID` into a path on this Mac, for the caller that sent
    /// it. Nil when neither names anything this caller may use.
    ///
    /// An upload is resolved inside the caller's own folder, so one device's id is not a
    /// key to another's photographs even if it somehow learns one.
    private func resolvedPath(
        uploadID: String?, mediaID: String?, as caller: Caller
    ) async -> String? {
        // Both branches come back through the same normalization, so an upload named by
        // its `uploadID` and the same file named by its `mediaID` are one string by the
        // time a render sees them — and not two spellings of one path.
        if let uploadID, !uploadID.isEmpty {
            if let url = BuddyUploads.resolve(
                uploadID: uploadID, bucket: Self.bucket(for: caller), at: uploadsRoot
            ) { return MediaRegistry.resolve(url.path) }
        }
        if let mediaID, !mediaID.isEmpty {
            if let path = await media.path(forID: mediaID, within: await media.roots()),
               // The same rule `GET /media` applies: a file under the uploads root belongs
               // to the device that sent it, whichever kind of id is used to name it.
               mayUse(path: path, as: caller) {
                return MediaRegistry.resolve(path)
            }
        }
        return nil
    }

    /// Whether this caller may name a path on the Mac at all.
    ///
    /// Only the per-launch local control credential grants filesystem authority. A swarm
    /// peer has authority over its own machine, not this Mac: accepting its paths would
    /// let it send this Mac's private files to a rendering node as image inputs. Peers and
    /// paired devices use uploads or registered media IDs instead. Local MCP clients keep
    /// using the control token from the private handshake file.
    private static func mayNamePaths(_ caller: Caller) -> Bool {
        caller == .control
    }

    private func resolvedMesh(
        _ request: ControlAPI.MeshRequest, as caller: Caller
    ) async throws -> ControlAPI.MeshRequest {
        if request.imagePath != nil, !Self.mayNamePaths(caller) {
            throw ControlAPI.MissingSubject()
        }
        var copy = request
        if let resolved = await resolvedPath(
            uploadID: request.uploadID, mediaID: request.mediaID, as: caller
        ) {
            copy.imagePath = resolved
            return copy
        }
        // An id that was sent and did not resolve is a mistake worth naming, rather than
        // falling through to "no image given".
        if request.uploadID != nil || request.mediaID != nil {
            throw ControlAPI.UnreadableSubject()
        }
        guard let path = request.imagePath, !path.isEmpty else {
            throw ControlAPI.MissingSubject()
        }
        return copy
    }

    private func resolvedImage(
        _ request: ControlAPI.ImageRequest, as caller: Caller
    ) async throws -> ControlAPI.ImageRequest {
        if request.initImagePath != nil, !Self.mayNamePaths(caller) {
            throw ControlAPI.MissingSubject()
        }
        var copy = request
        if let resolved = await resolvedPath(
            uploadID: request.uploadID, mediaID: request.mediaID, as: caller
        ) {
            copy.initImagePath = resolved
            return copy
        }
        if request.uploadID != nil || request.mediaID != nil {
            throw ControlAPI.UnreadableSubject()
        }
        // Unlike a mesh, an image does not need a subject at all — text to image is the
        // ordinary case. Raw paths were rejected before any ID could be resolved.
        return copy
    }

    private func resolvedVideo(
        _ request: ControlAPI.VideoGenerateRequest, as caller: Caller
    ) async throws -> ControlAPI.VideoGenerateRequest {
        if request.imagePath != nil, !Self.mayNamePaths(caller) {
            throw ControlAPI.MissingSubject()
        }
        var copy = request
        if let resolved = await resolvedPath(
            uploadID: request.uploadID, mediaID: request.mediaID, as: caller
        ) {
            copy.imagePath = resolved
            return copy
        }
        if request.uploadID != nil || request.mediaID != nil {
            throw ControlAPI.UnreadableSubject()
        }
        return copy
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
    /// `limit` is asked with the method and path as well as the headers, because one route
    /// — `POST /uploads` — has a different ceiling from every other, and the decision has
    /// to be made before a byte of body is read rather than after.
    ///
    /// What it answers is **the** limit. `maximumBody` is the default for a caller that
    /// supplies no closure, not a ceiling clamped over one that does: a route whose whole
    /// point is a larger body cannot have its own number quietly reduced to the general
    /// one, least of all while the refusal it produces still quotes the larger figure.
    static func read(
        from connection: NWConnection,
        maximumBody limit: @Sendable (String, String, [String: String]) async -> Int
            = { _, _, _ in maximumBody }
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
        // The path without its query, which is what a route is: `/uploads?x=1` must get the
        // upload ceiling and `/uploads/../load` must not.
        let requestPath = URLComponents(string: "http://localhost\(target)")?.path ?? target
        let allowed = await limit(method, requestPath, headers)
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

    /// Where the bytes come from.
    ///
    /// Almost everything this server answers is a small JSON buffer. A rendered clip is
    /// not: it can be hundreds of megabytes, a phone asks for it in ranges, and reading the
    /// whole thing into memory to send a two-byte probe would be absurd. So a file answers
    /// as a file — opened, seeked, and sent in chunks — and nothing else changes.
    enum Payload: Sendable {
        case data(Data)
        /// The file, and the byte range of it to send.
        case file(URL, Range<Int>)

        var count: Int {
            switch self {
            case .data(let data): data.count
            case .file(_, let range): range.count
            }
        }
    }

    var status: Int
    var payload: Payload
    var contentType = "application/json"
    /// Additional headers, for the responses that need them (media ranges).
    var extraHeaders: [String: String] = [:]
    /// `no-store` for everything this server says about itself, which is nearly all of it.
    /// The media routes are the exception and say so themselves.
    var cacheControl = "no-store"
    /// A 304 carries no body, and a framing header for a body that cannot exist is one
    /// more thing for a proxy to disagree with.
    var omitsContentLength = false
    /// How long one `send` may take before the connection is given up on. Nil is the old
    /// behaviour — wait indefinitely — which is right for a JSON buffer that fits in the
    /// socket's own send buffer and cannot stall. A file does not fit and can.
    var writeDeadline: Duration?

    /// What everything but the media routes uses, unchanged.
    var body: Data {
        guard case .data(let data) = payload else { return Data() }
        return data
    }

    init(
        status: Int, body: Data, contentType: String = "application/json",
        extraHeaders: [String: String] = [:]
    ) {
        self.status = status
        self.payload = .data(body)
        self.contentType = contentType
        self.extraHeaders = extraHeaders
    }

    init(
        status: Int, file: URL, range: Range<Int>, contentType: String,
        extraHeaders: [String: String] = [:]
    ) {
        self.status = status
        self.payload = .file(file, range)
        self.contentType = contentType
        self.extraHeaders = extraHeaders
    }

    /// - Parameters:
    ///   - status: 200 unless the route means something else by answering. The one caller
    ///     that passes anything is `POST .../messages`, which is a 202: the turn has been
    ///     accepted, not answered.
    ///   - compact: no indentation. The agent routes answer transcripts, which are the
    ///     largest JSON this server sends a phone and the most often fetched; the
    ///     whitespace pretty-printing adds is a fifth of a transcript's bytes and no client
    ///     reads it. The older routes keep the shape their callers have always had.
    static func encode(
        _ value: some Encodable, status: Int = 200, compact: Bool = false
    ) throws -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = compact ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
        return HTTPResponse(status: status, body: try encoder.encode(value))
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

    /// How much of a file goes out in one `send`. Big enough that a 200 MB clip is not ten
    /// thousand round trips, small enough that serving one does not cost 200 MB of memory.
    static let fileChunkBytes = 512 * 1024

    func write(to connection: NWConnection) async throws {
        var headerLines = [
            "HTTP/1.1 \(status) \(Self.reason(status))",
            "Content-Type: \(contentType)",
            "Cache-Control: \(cacheControl)",
        ]
        if !omitsContentLength { headerLines.append("Content-Length: \(payload.count)") }
        headerLines.append("Connection: close")
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            headerLines.append("\(name): \(value)")
        }
        let head = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        let deadline = writeDeadline

        switch payload {
        case .data(let data):
            var buffer = Data(head.utf8)
            buffer.append(data)
            try await Self.send(buffer, over: connection, within: deadline)
        case .file(let url, let range):
            try await Self.send(Data(head.utf8), over: connection, within: deadline)
            guard range.count > 0 else { return }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            var remaining = range.count
            while remaining > 0 {
                let wanted = min(remaining, Self.fileChunkBytes)
                guard let chunk = try handle.read(upToCount: wanted), !chunk.isEmpty else {
                    // The file shrank under us. The length is already promised, so there is
                    // nothing honest left to do but stop and let the client see a short
                    // body on a connection that closes.
                    return
                }
                try await Self.send(chunk, over: connection, within: deadline)
                remaining -= chunk.count
            }
        }
    }

    /// One `send`, with a deadline when the caller set one.
    ///
    /// A reader that stops reading is not a reader that disconnects: the socket stays open,
    /// its window closes, and `send` neither completes nor errors. `Task.cancel` cannot
    /// reach into Network.framework, so the only thing that ends it is cancelling the
    /// connection — which is exactly what the SSE writer already does for the same reason,
    /// and for the same stake: a connection slot, of which there are sixty-four.
    private static func send(
        _ bytes: Data, over connection: NWConnection, within deadline: Duration?
    ) async throws {
        guard let deadline else {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
            return
        }
        let timer = Task {
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            connection.cancel()
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
        // Cancelling a connection completes its outstanding send *successfully* on some
        // paths, so the deadline having fired is what decides whether this went out —
        // not the completion handler's error.
        if timer.isCancelled == false, case .cancelled = connection.state {
            throw EventStreamError.writeTimedOut
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 304: "Not Modified"
        case 409: "Conflict"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 416: "Range Not Satisfiable"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        case 507: "Insufficient Storage"
        default: "Error"
        }
    }
}

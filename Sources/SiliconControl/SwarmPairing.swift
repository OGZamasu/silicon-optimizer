import Foundation
import Network

/// Bluetooth-style swarm membership: a would-be member's app finds this app on the
/// tailnet, asks to join, both screens show the same six-digit code, and the swarm
/// owner accepts or denies. On accept, the joiner receives the swarm configuration —
/// token and node registry — over the tailnet's own encrypted wire and writes its
/// `swarm.json`.
///
/// The pairing listener follows a strict discoverability rule: it exists only while
/// the owner's invite sheet is open, and it binds to the tailscale interface address
/// specifically — never 0.0.0.0, so the coffee-shop LAN cannot see it. It serves
/// exactly three routes and holds at most one pending request.
public enum SwarmPairing {

    /// The fixed pairing port every Silicon Optimizer probes. Fixed because discovery
    /// means probing; ephemeral ports cannot be found.
    public static let port = 8791

    /// Six digits, spaced for reading aloud. Crypto-strength randomness is free here.
    public static func makeCode() -> String {
        let value = Int.random(in: 0...999_999)
        let digits = String(format: "%06d", value)
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    /// This machine's tailscale IPv4, found by interface scan: the CGNAT range
    /// 100.64.0.0/10 is tailscale's and effectively nobody else's on a Mac.
    public static func tailnetIPv4() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let ip = String(cString: host)
            if isTailnetIPv4(ip) { return ip }
        }
        return nil
    }

    /// 100.64.0.0/10 membership — 100.64.x.x through 100.127.x.x.
    public static func isTailnetIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts[0] == 100 else { return false }
        return (64...127).contains(parts[1])
    }

    /// Parses `tailscale status --json` into probe targets. Pure so it is testable;
    /// running the CLI is the caller's business.
    public static func peers(inStatusJSON data: Data) -> [TailscalePeerInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peerMap = json["Peer"] as? [String: [String: Any]]
        else { return [] }
        return peerMap.values.compactMap { peer in
            guard let ips = peer["TailscaleIPs"] as? [String],
                  let ipv4 = ips.first(where: { isTailnetIPv4($0) })
            else { return nil }
            return TailscalePeerInfo(
                hostName: peer["HostName"] as? String ?? ipv4,
                ip: ipv4,
                online: peer["Online"] as? Bool ?? false
            )
        }.sorted { $0.hostName < $1.hostName }
    }
}

public struct TailscalePeerInfo: Sendable, Equatable, Identifiable {
    public var hostName: String
    public var ip: String
    public var online: Bool
    public var id: String { ip }

    public init(hostName: String, ip: String, online: Bool) {
        self.hostName = hostName
        self.ip = ip
        self.online = online
    }
}

// MARK: - Wire shapes

/// What an open invite answers to anyone who probes: enough to list it in a join
/// picker, nothing more.
public struct PairingHello: Codable, Sendable, Equatable {
    public var service: String
    public var name: String
    public var accepting: Bool

    enum CodingKeys: String, CodingKey {
        case service, name, accepting
    }

    public init(name: String, accepting: Bool) {
        self.service = "silicon-optimizer-pairing"
        self.name = name
        self.accepting = accepting
    }
}

public struct PairingJoinRequest: Codable, Sendable {
    public var name: String

    public init(name: String) { self.name = name }
}

public struct PairingReceipt: Codable, Sendable, Equatable {
    public var requestID: String
    public var code: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case code
    }

    public init(requestID: String, code: String) {
        self.requestID = requestID
        self.code = code
    }
}

public struct PairingStatus: Codable, Sendable {
    /// pending | approved | denied | expired
    public var state: String
    /// Present exactly once, on the first approved poll — then gone for good.
    public var swarm: SwarmConfig?

    public init(state: String, swarm: SwarmConfig? = nil) {
        self.state = state
        self.swarm = swarm
    }
}

/// One join request as the owner's sheet shows it.
public struct PendingPairing: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var code: String
    public var receivedAt: Date

    public init(id: String, name: String, code: String, receivedAt: Date) {
        self.id = id
        self.name = name
        self.code = code
        self.receivedAt = receivedAt
    }
}

// MARK: - The owner's listener

/// The invite-mode server. Lives exactly as long as the invite sheet; releases the
/// swarm config exactly once per approved request.
public actor PairingServer {

    public enum RequestState: String, Sendable {
        case pending, approved, denied, expired, delivered
    }

    private struct Slot {
        var request: PendingPairing
        var state: RequestState
    }

    private let hostName: String
    private let release: SwarmConfig
    private var listener: NWListener?
    private var slot: Slot?
    private let requestLifetime: TimeInterval

    public init(hostName: String, release: SwarmConfig, requestLifetime: TimeInterval = 300) {
        self.hostName = hostName
        self.release = release
        self.requestLifetime = requestLifetime
    }

    /// Binds to the given address (the tailscale interface) on the fixed pairing port.
    /// The port parameter exists for tests, which pair over loopback.
    public func start(on address: String, port: Int = SwarmPairing.port) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(address),
            port: NWEndpoint.Port(rawValue: UInt16(port))!
        )
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            Task { await self?.serve(connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        slot = nil
    }

    // MARK: Owner-side controls

    public func pending() -> PendingPairing? {
        expireIfStale()
        guard let slot, slot.state == .pending else { return nil }
        return slot.request
    }

    public func approve(_ id: String) {
        guard var slot, slot.request.id == id, slot.state == .pending else { return }
        slot.state = .approved
        self.slot = slot
    }

    public func deny(_ id: String) {
        guard var slot, slot.request.id == id, slot.state == .pending else { return }
        slot.state = .denied
        self.slot = slot
    }

    /// True once an approved request has actually collected its payload — the sheet's
    /// cue to show success and close up.
    public func wasDelivered() -> Bool {
        slot?.state == .delivered
    }

    // MARK: Serving

    private func serve(_ connection: NWConnection) async {
        defer { connection.cancel() }
        guard let request = try? await HTTPRequest.read(from: connection) else { return }
        let response = handle(request)
        try? await response.write(to: connection)
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        expireIfStale()
        switch (request.method, request.path) {
        case ("GET", "/swarm/hello"):
            return (try? HTTPResponse.encode(
                PairingHello(name: hostName, accepting: slot == nil)
            )) ?? HTTPResponse.error(500, "encode")

        case ("POST", "/swarm/pair/request"):
            guard slot == nil else {
                return .error(409, "Another pairing request is already being decided.")
            }
            guard let join = try? request.decode(PairingJoinRequest.self),
                  !join.name.trimmingCharacters(in: .whitespaces).isEmpty
            else { return .error(400, "The request names no device.") }
            let pending = PendingPairing(
                id: UUID().uuidString,
                name: String(join.name.prefix(64)),
                code: SwarmPairing.makeCode(),
                receivedAt: Date()
            )
            slot = Slot(request: pending, state: .pending)
            return (try? HTTPResponse.encode(
                PairingReceipt(requestID: pending.id, code: pending.code)
            )) ?? HTTPResponse.error(500, "encode")

        case ("GET", "/swarm/pair/status"):
            guard let id = request.query["id"], let slot, slot.request.id == id else {
                return .error(404, "No such pairing request.")
            }
            switch slot.state {
            case .pending:
                return (try? HTTPResponse.encode(PairingStatus(state: "pending")))
                    ?? HTTPResponse.error(500, "encode")
            case .approved:
                // The one moment the credentials cross the wire — then the slot burns.
                self.slot?.state = .delivered
                return (try? HTTPResponse.encode(
                    PairingStatus(state: "approved", swarm: release)
                )) ?? HTTPResponse.error(500, "encode")
            case .denied:
                self.slot = nil
                return (try? HTTPResponse.encode(PairingStatus(state: "denied")))
                    ?? HTTPResponse.error(500, "encode")
            case .expired, .delivered:
                return (try? HTTPResponse.encode(PairingStatus(state: "expired")))
                    ?? HTTPResponse.error(500, "encode")
            }

        default:
            return .error(404, "Unknown endpoint \(request.method) \(request.path)")
        }
    }

    private func expireIfStale() {
        guard let current = slot, current.state == .pending,
              Date().timeIntervalSince(current.request.receivedAt) > requestLifetime
        else { return }
        slot = nil
    }
}

// MARK: - The joiner's client

/// The would-be member's half: probe, request, poll. Plain URLSession against tailnet
/// addresses — the tailnet's WireGuard layer is the transport security.
public enum PairingClient {

    static func session(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    static func url(host: String, port: Int, path: String, query: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        components.query = query
        return components.url
    }

    /// A quick knock: is anyone at this address holding an open invite?
    public static func hello(host: String, port: Int = SwarmPairing.port) async -> PairingHello? {
        guard let url = url(host: host, port: port, path: "/swarm/hello") else { return nil }
        guard let (data, response) = try? await session(timeout: 2).data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        let hello = try? JSONDecoder().decode(PairingHello.self, from: data)
        return hello?.service == "silicon-optimizer-pairing" ? hello : nil
    }

    public static func requestJoin(
        host: String, name: String, port: Int = SwarmPairing.port
    ) async throws -> PairingReceipt {
        guard let url = url(host: host, port: port, path: "/swarm/pair/request") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairingJoinRequest(name: name))
        let (data, response) = try await session(timeout: 10).data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PairingError.refused(Self.errorText(in: data))
        }
        return try JSONDecoder().decode(PairingReceipt.self, from: data)
    }

    public static func status(
        host: String, requestID: String, port: Int = SwarmPairing.port
    ) async throws -> PairingStatus {
        guard let url = url(
            host: host, port: port, path: "/swarm/pair/status", query: "id=\(requestID)"
        ) else { throw URLError(.badURL) }
        let (data, response) = try await session(timeout: 10).data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PairingError.refused(Self.errorText(in: data))
        }
        return try JSONDecoder().decode(PairingStatus.self, from: data)
    }

    static func errorText(in data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? String { return error }
        return String(data: data.prefix(200), encoding: .utf8) ?? "no detail"
    }

    public enum PairingError: Error, LocalizedError {
        case refused(String)

        public var errorDescription: String? {
            switch self {
            case .refused(let text): "The other side refused: \(text)"
            }
        }
    }
}

// MARK: - Config adoption

extension SwarmConfig {

    /// What a joiner does with the received configuration: adopt the swarm's token and
    /// union the peers with anything it already had (received entries win a name
    /// collision — the swarm's registry is the fresher truth).
    public func adopting(_ received: SwarmConfig) -> SwarmConfig {
        var merged = self
        merged.swarmToken = received.effectiveToken ?? merged.swarmToken
        var byName: [String: SwarmPeer] = [:]
        for peer in peers { byName[peer.name] = peer }
        for peer in received.peers { byName[peer.name] = peer }
        merged.peers = byName.values.sorted { $0.name < $1.name }
        return merged
    }

    /// Writes this config where the app reads it, with the credential-file permissions
    /// the token demands.
    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: Self.configURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: Self.configURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Self.configURL.path
        )
    }
}
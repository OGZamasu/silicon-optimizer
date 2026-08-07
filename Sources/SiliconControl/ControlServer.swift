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
    private let token: String
    private var port: Int = 0

    public init(host: any ControlHost) {
        self.host = host
        // A fresh token each launch: it is only meaningful for the lifetime of the process.
        self.token = UUID().uuidString
    }

    public func start(preferredPort: Int = 0) throws {
        let parameters = NWParameters.tcp
        // Loopback only. This must never be reachable from the network.
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
            Task { await self?.publishHandshake() }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: ControlAPI.handshakeURL)
    }

    /// Writes the port and token where clients can find them.
    private func publishHandshake() {
        guard let resolved = listener?.port?.rawValue else { return }
        port = Int(resolved)

        let handshake = ControlAPI.Handshake(
            port: port, pid: ProcessInfo.processInfo.processIdentifier,
            token: token, version: "0.1.0"
        )
        let url = ControlAPI.handshakeURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(handshake) else { return }
        try? data.write(to: url, options: .atomic)
        // The token is a credential; keep it out of other users' reach.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        Task { await serve(connection) }
    }

    private func serve(_ connection: NWConnection) async {
        do {
            let request = try await HTTPRequest.read(from: connection)
            let response = await route(request)
            try await response.write(to: connection)
        } catch {
            // A client that hangs up mid-request is routine, not worth surfacing.
        }
        connection.cancel()
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        // /health is unauthenticated so a client can tell "app not running" from "bad token".
        if request.path == "/health" {
            return .json(["status": "ok", "version": "0.1.0"])
        }
        guard request.bearerToken == token else {
            return .error(401, "Invalid or missing control token.")
        }

        do {
            switch (request.method, request.path) {
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
            case ("POST", "/benchmark"):
                return try .encode(await host.benchmark())
            case ("POST", "/chat"):
                return try .encode(await host.chat(try request.decode(ControlAPI.ChatRequest.self)))
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
        headers["authorization"]?
            .replacingOccurrences(of: "Bearer ", with: "")
            .trimmingCharacters(in: .whitespaces)
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
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].lowercased().trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        var body = buffer[headerEnd.upperBound...]
        if let lengthValue = headers["content-length"], let length = Int(lengthValue) {
            while body.count < length {
                body.append(try await receive(from: connection))
                if body.count > 16_777_216 { throw ParseError.malformed }
            }
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

    static func encode(_ value: some Encodable) throws -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return HTTPResponse(status: 200, body: try encoder.encode(value))
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
        let head = """
            HTTP/1.1 \(status) \(Self.reason(status))\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r\n
            """
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
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        default: "Error"
        }
    }
}

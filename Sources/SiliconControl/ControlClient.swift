import Foundation

/// Talks to a running Silicon Optimizer instance.
public struct ControlClient: Sendable {

    public enum ClientError: Error, LocalizedError {
        case appNotRunning
        case server(Int, String)

        public var errorDescription: String? {
            switch self {
            case .appNotRunning:
                "Silicon Optimizer is not running. Open the app, then try again."
            case .server(_, let message):
                message
            }
        }
    }

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        // Loading a large model can legitimately take minutes.
        configuration.timeoutIntervalForRequest = 900
        self.session = URLSession(configuration: configuration)
    }

    /// Reads the handshake the running app publishes. Absent file means the app is not running.
    private func handshake() throws -> ControlAPI.Handshake {
        guard let data = try? Data(contentsOf: ControlAPI.handshakeURL),
              let handshake = try? JSONDecoder().decode(ControlAPI.Handshake.self, from: data)
        else { throw ClientError.appNotRunning }

        // `kill(pid, 0)` performs the permission and existence checks without sending a
        // signal — the standard way to ask "is this process still alive?".
        if let pid = handshake.pid, kill(pid, 0) != 0, errno == ESRCH {
            throw ClientError.appNotRunning
        }
        return handshake
    }

    public func isAppRunning() async -> Bool {
        (try? await get("/health", authenticated: false) as [String: String]) != nil
    }

    // MARK: - Requests

    public func get<T: Decodable>(_ path: String, authenticated: Bool = true) async throws -> T {
        try await send(path: path, method: "GET", body: Optional<Never>.none, authenticated: authenticated)
    }

    public func post<Body: Encodable, T: Decodable>(_ path: String, _ body: Body) async throws -> T {
        try await send(path: path, method: "POST", body: body, authenticated: true)
    }

    public func postEmpty<T: Decodable>(_ path: String) async throws -> T {
        try await send(path: path, method: "POST", body: Optional<Never>.none, authenticated: true)
    }

    private func send<Body: Encodable, T: Decodable>(
        path: String, method: String, body: Body?, authenticated: Bool
    ) async throws -> T {
        let handshake = try handshake()
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(handshake.port)\(path)")!
        )
        request.httpMethod = method
        if authenticated {
            request.setValue("Bearer \(handshake.token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // A refused connection means the handshake file is stale — the app has quit.
            throw ClientError.appNotRunning
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: data))?
                .error ?? "HTTP \(status)"
            throw ClientError.server(status, message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

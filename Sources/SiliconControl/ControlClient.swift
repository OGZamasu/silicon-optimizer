import Foundation

/// Talks to a running Silicon Optimizer instance.
public struct ControlClient: Sendable {

    public enum ClientError: Error, LocalizedError {
        case appNotRunning
        case server(Int, String)
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .appNotRunning:
                "Silicon Optimizer is not running. Open the app, then try again."
            case .server(_, let message):
                message
            case .transport(let message):
                message
            }
        }
    }

    private let session: URLSession
    private let handshakeURL: URL

    public init() {
        self.init(handshakeURL: ControlAPI.handshakeURL)
    }

    /// A client of whichever control server published `handshakeURL` — a test's own.
    init(handshakeURL: URL) {
        self.session = URLSession(configuration: Self.sessionConfiguration())
        self.handshakeURL = handshakeURL
    }

    /// Requests that may be open at once. The MCP bridge runs up to eight tool calls side by
    /// side, and a render or a conversation holds its connection for minutes; URLSession's
    /// default of six per host would leave a seventh call queued inside it, unsent.
    public static let maximumConnections = 8

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // The app holds /video/generate open through the node's queue and render.
        configuration.timeoutIntervalForRequest = TimeInterval(VideoGenerationBudget.controlSeconds)
        configuration.timeoutIntervalForResource = TimeInterval(VideoGenerationBudget.controlSeconds)
        configuration.httpMaximumConnectionsPerHost = maximumConnections
        return configuration
    }

    static func requestTimeout(for path: String) -> TimeInterval {
        path == "/video/generate" ? TimeInterval(VideoGenerationBudget.controlSeconds) : 1800
    }

    /// Reads the handshake the running app publishes. Absent file means the app is not running.
    private func handshake() throws -> ControlAPI.Handshake {
        guard let data = try? Data(contentsOf: handshakeURL),
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
        request.timeoutInterval = Self.requestTimeout(for: path)
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
            throw Self.transportError(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: data))?
                .error ?? "HTTP \(status)"
            throw ClientError.server(status, message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func transportError(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost:
            return ClientError.appNotRunning
        case .networkConnectionLost:
            // What a control server out of connections looks like from here: past its budget it
            // closes a connection unread. (A request still running when the app quits ends the
            // same way.)
            return ClientError.transport(
                "Silicon Optimizer closed the connection without answering. It is most likely "
                + "busy, with too many requests open at once (each MCP bridge can hold eight): "
                + "wait for some to finish, then try again. If this keeps happening, check that "
                + "the app is still running."
            )
        case .timedOut:
            return ClientError.transport(
                "The request exceeded its time limit. The app or node may still be working; "
                + "check its job status before submitting again."
            )
        default:
            return ClientError.transport("The connection to Silicon Optimizer failed: \(urlError.localizedDescription)")
        }
    }
}

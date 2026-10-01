import Foundation

/// Opens ElevenLabs' realtime sockets for one linked account: streaming text-to-speech (one
/// context or several), realtime speech-to-text, and a conversation with an agent.
///
/// It runs on the same client the REST calls use, so a session reaches exactly the region the
/// client does and reads the key from the same credential source. The key goes only on the
/// upgrade request of the speech and transcription sockets, in `xi-api-key`. An agent's socket
/// never gets the key: a public agent is reached by its id, any other by a signed URL minted
/// over REST (`get_conversation_signed_link`) and used once, straight away, without being kept.
///
/// Session policy, the same for all four: one socket per session; nothing reconnects on its
/// own, because a second connection is a second billed session and would replay audio; an
/// ended session reports how it ended and what it used, and a new one is the caller's choice.
public struct ElevenLabsRealtime: Sendable {
    public let client: ElevenLabsClient
    public let connector: any ElevenLabsSocketConnector
    public var limits: Limits

    public struct Limits: Sendable {
        /// The largest message accepted from the server.
        public var maximumMessageSize = ElevenLabsSocketRequest.defaultMaximumMessageSize
        /// How long the opening handshake may take.
        public var openTimeout: TimeInterval = 20
        /// How long an agent may take to send `conversation_initiation_metadata`.
        public var agentStartTimeout: TimeInterval = 20

        public init() {}
    }

    public init(client: ElevenLabsClient, connector: any ElevenLabsSocketConnector, limits: Limits = Limits()) {
        self.client = client
        self.connector = connector
        self.limits = limits
    }

    public var region: ElevenLabsRegion { client.region }

    // MARK: - Speech

    /// Opens `stream-input` and sends its first message. Billable as text is sent.
    public func speechStream(_ config: ElevenLabsSpeechStreamConfig) async throws -> ElevenLabsSpeechStream {
        let problems = config.problems()
        guard problems.isEmpty else { throw ElevenLabsRealtimeError.invalidConfiguration(problems) }
        let request = try await keyedRequest(
            path: "/v1/text-to-speech/\(config.voiceID)/stream-input", query: config.queryItems()
        )
        let socket = try await open(request)
        return try await ElevenLabsSpeechStream.start(on: socket, config: config)
    }

    /// Opens `multi-stream-input`: up to five contexts on one socket. Billable as text is sent.
    public func multiContextSpeechStream(
        _ config: ElevenLabsSpeechStreamConfig
    ) async throws -> ElevenLabsSpeechMultiStream {
        let problems = config.problems()
        guard problems.isEmpty else { throw ElevenLabsRealtimeError.invalidConfiguration(problems) }
        let request = try await keyedRequest(
            path: "/v1/text-to-speech/\(config.voiceID)/multi-stream-input", query: config.queryItems()
        )
        let socket = try await open(request)
        return ElevenLabsSpeechMultiStream.start(on: socket, config: config)
    }

    // MARK: - Transcription

    /// Opens realtime speech-to-text. Billable by the audio sent.
    public func transcriptionStream(
        _ config: ElevenLabsTranscriptionStreamConfig
    ) async throws -> ElevenLabsTranscriptionStream {
        let problems = config.problems()
        guard problems.isEmpty else { throw ElevenLabsRealtimeError.invalidConfiguration(problems) }
        let request = try await keyedRequest(path: "/v1/speech-to-text/realtime", query: config.queryItems())
        let socket = try await open(request)
        return ElevenLabsTranscriptionStream.start(on: socket, config: config)
    }

    // MARK: - Agents

    /// What starting a conversation needs to know about an agent, read with the free
    /// `get_agent_route`: whether it needs a signed URL, and whether it can be text-only.
    /// Throws the client's `ElevenLabsError` when the read fails.
    public func agentPreflight(agentID: String) async throws -> ElevenLabsAgentPreflight {
        let problems = ElevenLabsAgentConversationConfig.idProblems(agentID)
        guard problems.isEmpty else { throw ElevenLabsRealtimeError.invalidConfiguration(problems) }
        // A REST read: its failure is the client's own error (a 404 stays a 404), already redacted.
        let answer = try await client.call("get_agent_route", arguments: ["agent_id": .string(agentID)])
        guard case .json(let agent, _) = answer else {
            throw ElevenLabsRealtimeError.network("the agent's settings did not come back as JSON")
        }
        return ElevenLabsAgentPreflight(agentID: agentID, json: agent)
    }

    /// Opens a conversation with an agent, sends its initiation data, and returns once the
    /// agent has answered with `conversation_initiation_metadata` (the negotiated formats).
    ///
    /// - Parameter preflight: The agent as `agentPreflight` read it; read here when not given.
    public func agentConversation(
        _ config: ElevenLabsAgentConversationConfig, preflight given: ElevenLabsAgentPreflight? = nil
    ) async throws -> ElevenLabsAgentConversation {
        let problems = config.problems()
        guard problems.isEmpty else { throw ElevenLabsRealtimeError.invalidConfiguration(problems) }
        let preflight: ElevenLabsAgentPreflight?
        switch config.auth {
        case .automatic:
            if let given {
                preflight = given
            } else {
                preflight = try await agentPreflight(agentID: config.agentID)
            }
        case .publicAgent, .signedURL:
            preflight = given
        }
        let initiation = try config.initiation(preflight: preflight)
        let needsSignature = switch config.auth {
        case .signedURL: true
        case .publicAgent: false
        case .automatic: preflight?.requiresAuthentication ?? true
        }
        let request: ElevenLabsSocketRequest
        if needsSignature {
            request = try await signedRequest(config)
        } else {
            request = ElevenLabsSocketRequest(
                url: try url(path: "/v1/convai/conversation", query: [URLQueryItem(name: "agent_id", value: config.agentID)]),
                maximumMessageSize: limits.maximumMessageSize, openTimeout: limits.openTimeout
            )
        }
        // The signed URL lives in `request` for the length of this call and nowhere else.
        let socket = try await open(request)
        // Cancelled while it opened: closed before anything is sent.
        if Task.isCancelled {
            await socket.close(code: ElevenLabsSocketClose.normalClosure, reason: "User ended conversation")
            throw ElevenLabsRealtimeError.cancelled
        }
        return try await ElevenLabsAgentConversation.start(
            on: socket, config: config, initiation: initiation, startTimeout: limits.agentStartTimeout
        )
    }

    /// The socket request a public agent would get — for tests and "Show connection".
    public func publicAgentRequest(agentID: String) throws -> ElevenLabsSocketRequest {
        let problems = ElevenLabsAgentConversationConfig.idProblems(agentID)
        guard problems.isEmpty else { throw ElevenLabsRealtimeError.invalidConfiguration(problems) }
        return ElevenLabsSocketRequest(
            url: try url(path: "/v1/convai/conversation", query: [URLQueryItem(name: "agent_id", value: agentID)]),
            maximumMessageSize: limits.maximumMessageSize, openTimeout: limits.openTimeout
        )
    }

    // MARK: - Requests

    /// A request for a socket that takes the key: the region's `wss` origin, the key in
    /// `xi-api-key`, nothing secret in the URL.
    func keyedRequest(path: String, query: [URLQueryItem]) async throws -> ElevenLabsSocketRequest {
        let url = try url(path: path, query: query)
        let key = try await readKey()
        return ElevenLabsSocketRequest(
            url: url, headers: ["xi-api-key": key],
            maximumMessageSize: limits.maximumMessageSize, openTimeout: limits.openTimeout
        )
    }

    func url(path: String, query: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = region.host
        // Path segments (the voice id) are encoded the way the SDKs do: nothing reserved left.
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map { segment in
            String(segment).addingPercentEncoding(withAllowedCharacters: Self.segmentCharacters) ?? ""
        }
        components.percentEncodedPath = segments.joined(separator: "/")
        if !query.isEmpty {
            components.percentEncodedQueryItems = query.map { item in
                URLQueryItem(
                    name: item.name,
                    value: item.value?.addingPercentEncoding(withAllowedCharacters: Self.queryValueCharacters)
                )
            }
        }
        guard let url = components.url else {
            throw ElevenLabsRealtimeError.invalidConfiguration(["The socket address could not be built."])
        }
        return url
    }

    static let segmentCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    static let queryValueCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    private func open(_ request: ElevenLabsSocketRequest) async throws -> any ElevenLabsSocket {
        do {
            return try await connector.connect(request)
        } catch {
            throw ElevenLabsRealtimeError(wrapping: error, redactingKey: request.header("xi-api-key"))
        }
    }

    private func readKey() async throws -> String {
        let key: String?
        do {
            key = try await client.credentials.apiKey()
        } catch let error as ElevenLabsError {
            throw ElevenLabsRealtimeError(wrapping: error)
        } catch {
            throw ElevenLabsRealtimeError.credentialUnavailable(ElevenLabsRealtimeRedaction.scrub((error as NSError).localizedDescription))
        }
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ElevenLabsRealtimeError.notLinked
        }
        return key
    }

    /// Mints a signed URL over REST and checks it before anything connects to it: `wss`, a region
    /// host, the conversation path. The URL is opaque otherwise (the docs disagree on the name of
    /// its signature), and it is used once and not kept.
    private func signedRequest(_ config: ElevenLabsAgentConversationConfig) async throws -> ElevenLabsSocketRequest {
        var arguments: [String: JSONValue] = ["agent_id": .string(config.agentID)]
        if let branch = config.branchID { arguments["branch_id"] = .string(branch) }
        if let environment = config.environment { arguments["environment"] = .string(environment) }
        let answer: ElevenLabsResult
        do {
            answer = try await client.call("get_conversation_signed_link", arguments: arguments)
        } catch {
            throw ElevenLabsRealtimeError.signedLink(ElevenLabsError(wrapping: error))
        }
        guard case .json(let json, _) = answer, let text = json["signed_url"].stringValue,
              let url = URL(string: text)
        else {
            throw ElevenLabsRealtimeError.signedLink(.api(
                status: answer.meta.status, code: "unexpected_answer",
                message: "The answer had no signed URL.", requestID: answer.meta.requestID
            ))
        }
        guard Self.isAcceptableSignedURL(url) else {
            throw ElevenLabsRealtimeError.refusedHost(url.host.map { ElevenLabsRedaction.redact($0) } ?? "an unnamed host")
        }
        return ElevenLabsSocketRequest(
            url: url, maximumMessageSize: limits.maximumMessageSize, openTimeout: limits.openTimeout
        )
    }

    /// `wss`, one of the region hosts (not necessarily this client's: ElevenLabs may route the
    /// conversation elsewhere), the conversation path, and no user or password in it.
    static func isAcceptableSignedURL(_ url: URL) -> Bool {
        guard url.scheme == "wss", let host = url.host, ElevenLabsRegion.allowedHosts.contains(host),
              url.port == nil || url.port == 443, url.user == nil, url.password == nil
        else { return false }
        return url.path == "/v1/convai/conversation"
    }
}

// MARK: - Usage

/// What a session has used so far: what the owner is billed by, measured on this side.
public struct ElevenLabsRealtimeUsage: Sendable, Equatable {
    public var startedAt: Date
    /// When the server said the session is under way (an agent's metadata, the first answer).
    public var connectedAt: Date?
    public var endedAt: Date?
    /// Text characters sent to be spoken (the space every speech message ends with is not
    /// counted, and neither are keepalives).
    public var charactersSent = 0
    /// Seconds of audio sent (microphone or file).
    public var audioSecondsSent: Double = 0
    /// Seconds of audio received, for the headerless encodings; bytes otherwise.
    public var audioSecondsReceived: Double = 0
    public var audioBytesReceived = 0
    /// Typed messages sent to an agent.
    public var messagesSent = 0
    /// Transcripts committed by hand.
    public var commits = 0

    public init(startedAt: Date = Date()) { self.startedAt = startedAt }

    /// How long the session has lasted, or lasted.
    public func duration(now: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(connectedAt ?? startedAt))
    }
}

/// A thread-safe usage record a session updates as it goes.
final class UsageMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var usage = ElevenLabsRealtimeUsage()

    var snapshot: ElevenLabsRealtimeUsage { lock.withLock { usage } }

    func update(_ change: (inout ElevenLabsRealtimeUsage) -> Void) {
        lock.withLock { change(&usage) }
    }
}

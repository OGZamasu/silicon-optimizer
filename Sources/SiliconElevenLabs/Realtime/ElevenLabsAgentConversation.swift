import Foundation

// MARK: - Settings

/// A conversation with an Agents Platform agent over its WebSocket.
public struct ElevenLabsAgentConversationConfig: Sendable, Hashable {
    /// How the socket is reached. The key never goes on it.
    public enum Auth: Sendable, Hashable {
        /// Reads the agent's settings (free) and uses its id when it is public, a signed URL
        /// when it has authentication switched on.
        case automatic
        /// The bare `agent_id`: agents with authentication off.
        case publicAgent
        /// A signed URL minted over REST with the key, used once.
        case signedURL
    }

    public var agentID: String
    public var auth: Auth = .automatic
    /// No audio either way: text in, text out. Cheaper, and what the MCP tool uses.
    public var textOnly = false
    /// Further `conversation_config_override` sections, as the agent allows them
    /// (`agent.first_message`, `agent.prompt.prompt`, `tts.voice_id`…).
    public var overrides: JSONValue?
    /// Values for the agent's `{{variables}}`.
    public var dynamicVariables: [String: JSONValue] = [:]
    public var userID: String?
    public var branchID: String?
    public var environment: String?
    /// `asr.keywords`, at most 50; ignored by ElevenLabs unless the agent allows the override.
    public var keywords: [String] = []

    public init(agentID: String, auth: Auth = .automatic, textOnly: Bool = false) {
        self.agentID = agentID
        self.auth = auth
        self.textOnly = textOnly
    }

    static func idProblems(_ id: String) -> [String] {
        ElevenLabsRealtimeValidation.idProblems(id, name: "agent_id")
    }

    public func problems() -> [String] {
        var problems = Self.idProblems(agentID)
        if let overrides, overrides != .null, overrides.objectValue == nil {
            problems.append("overrides must be an object of conversation_config_override sections.")
        }
        if keywords.count > 50 { problems.append("At most 50 keywords.") }
        if let branchID { problems += ElevenLabsRealtimeValidation.idProblems(branchID, name: "branch_id") }
        if let environment { problems += ElevenLabsRealtimeValidation.idProblems(environment, name: "environment") }
        for key in dynamicVariables.keys where key.isEmpty || key.count > 200 {
            problems.append("A dynamic variable needs a name of at most 200 characters.")
            break
        }
        return problems
    }

    /// `conversation_initiation_client_data`, the first message. Only the sections actually
    /// overridden are sent, and `source_info` is left out: this app is none of ElevenLabs' SDKs.
    ///
    /// Text-only needs the agent to be text-only already, or to allow the override: an override
    /// the agent does not allow ends the conversation with an error, so it is refused here, before
    /// anything is opened, with what to change.
    func initiation(preflight: ElevenLabsAgentPreflight?) throws -> JSONValue {
        var override = overrides?.objectValue ?? [:]
        if textOnly {
            if preflight?.textOnlyByDefault == true {
                // Already text-only: no override needed, and none that could be refused.
            } else if preflight == nil || preflight?.textOnlyOverrideAllowed == true {
                var conversation = override["conversation"]?.objectValue ?? [:]
                conversation["text_only"] = true
                override["conversation"] = .object(conversation)
            } else {
                throw ElevenLabsRealtimeError.invalidConfiguration([
                    "This agent does not allow text-only conversations. Turn on the “Text only” override "
                        + "in the agent's security settings (or make the agent text-only), then try again.",
                ])
            }
        }
        if !keywords.isEmpty {
            var asr = override["asr"]?.objectValue ?? [:]
            asr["keywords"] = .array(keywords.map(JSONValue.string))
            override["asr"] = .object(asr)
        }
        var message: [String: JSONValue] = ["type": "conversation_initiation_client_data"]
        if !override.isEmpty { message["conversation_config_override"] = .object(override) }
        if !dynamicVariables.isEmpty { message["dynamic_variables"] = .object(dynamicVariables) }
        if let userID { message["user_id"] = .string(userID) }
        if let branchID { message["branch_id"] = .string(branchID) }
        if let environment { message["environment"] = .string(environment) }
        return .object(message)
    }
}

/// An agent's settings as far as starting a conversation needs them.
public struct ElevenLabsAgentPreflight: Sendable, Hashable {
    public var agentID: String
    public var name: String?
    /// `platform_settings.auth.enable_auth`: a signed URL is needed.
    public var requiresAuthentication: Bool
    /// `conversation_config.conversation.text_only`.
    public var textOnlyByDefault: Bool
    /// `platform_settings.overrides.conversation_config_override.conversation.text_only`.
    public var textOnlyOverrideAllowed: Bool
    /// The formats the agent is configured with (the metadata event has the final word).
    public var outputAudioFormat: String?
    public var inputAudioFormat: String?
    /// The tools the agent has, for naming what it may do before a conversation starts.
    public var tools: [ElevenLabsAgentToolSummary]

    public init(
        agentID: String, name: String? = nil, requiresAuthentication: Bool, textOnlyByDefault: Bool = false,
        textOnlyOverrideAllowed: Bool = false, outputAudioFormat: String? = nil, inputAudioFormat: String? = nil,
        tools: [ElevenLabsAgentToolSummary] = []
    ) {
        self.agentID = agentID
        self.name = name
        self.requiresAuthentication = requiresAuthentication
        self.textOnlyByDefault = textOnlyByDefault
        self.textOnlyOverrideAllowed = textOnlyOverrideAllowed
        self.outputAudioFormat = outputAudioFormat
        self.inputAudioFormat = inputAudioFormat
        self.tools = tools
    }

    /// From a `get_agent_route` answer. An agent whose answer does not say whether it needs
    /// authentication is treated as needing it: a signed URL works either way, a bare id does not.
    public init(agentID: String, json agent: JSONValue) {
        self.agentID = agentID
        name = agent["name"].stringValue
        let auth = agent["platform_settings"]["auth"]["enable_auth"]
        requiresAuthentication = auth.looseBool ?? true
        let conversation = agent["conversation_config"]["conversation"]
        textOnlyByDefault = conversation["text_only"].looseBool ?? false
        textOnlyOverrideAllowed = agent["platform_settings"]["overrides"]["conversation_config_override"]["conversation"]["text_only"].looseBool ?? false
        outputAudioFormat = agent["conversation_config"]["tts"]["agent_output_audio_format"].stringValue
        inputAudioFormat = agent["conversation_config"]["asr"]["user_input_audio_format"].stringValue
        tools = ElevenLabsAgentToolSummary.all(in: agent["conversation_config"]["agent"]["prompt"])
    }

    /// The tools that can reach outside the conversation on ElevenLabs' side.
    public var realWorldTools: [ElevenLabsAgentToolSummary] { tools.filter(\.actsInTheRealWorld) }
}

/// One of an agent's tools, as far as saying what it may do needs it.
public struct ElevenLabsAgentToolSummary: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// Calls a URL from ElevenLabs' servers.
        case webhook
        /// Asks this app to run something (it runs nothing; see the live screen).
        case client
        /// A built-in system tool: end call, transfer, keypad tones, language…
        case system
        /// A tool on an outside MCP server.
        case mcp
        /// An integration (a connected account) ElevenLabs calls.
        case integration
        /// A workspace tool, by id: what it does is not in the agent's settings.
        case workspace
        case other
    }

    public var name: String
    public var kind: Kind
    /// Where it reaches: a webhook's host, an MCP server's name or id.
    public var host: String?
    /// Whether running it reaches outside the conversation: a URL, a phone call or transfer,
    /// keypad tones, an MCP server, or a workspace tool this app cannot see into.
    public var actsInTheRealWorld: Bool

    public init(name: String, kind: Kind, host: String? = nil, actsInTheRealWorld: Bool) {
        self.name = name
        self.kind = kind
        self.host = host
        self.actsInTheRealWorld = actsInTheRealWorld
    }

    /// System tools that act beyond the conversation itself.
    static let realWorldSystemTools: Set<String> = [
        "transfer_to_number", "transfer_to_agent", "play_keypad_touch_tone", "voicemail_detection",
    ]

    /// Every tool an agent's `prompt` names: inline tools, built-in tools, workspace tool ids and
    /// MCP servers.
    static func all(in prompt: JSONValue) -> [ElevenLabsAgentToolSummary] {
        var tools: [ElevenLabsAgentToolSummary] = []
        for tool in prompt["tools"].arrayValue ?? [] {
            let name = tool["name"].stringValue ?? "unnamed tool"
            switch tool["type"].stringValue ?? "" {
            case "webhook":
                tools.append(.init(name: name, kind: .webhook, host: host(of: tool["api_schema"]["url"].stringValue),
                                   actsInTheRealWorld: true))
            case "client":
                tools.append(.init(name: name, kind: .client, actsInTheRealWorld: false))
            case "system":
                let type = tool["params"]["system_tool_type"].stringValue ?? name
                tools.append(.init(name: name, kind: .system, actsInTheRealWorld: realWorldSystemTools.contains(type)))
            case "mcp":
                tools.append(.init(name: tool["mcp_tool_name"].stringValue ?? name, kind: .mcp,
                                   host: tool["mcp_server_name"].stringValue ?? tool["mcp_server_id"].stringValue,
                                   actsInTheRealWorld: true))
            case "api_integration_webhook":
                tools.append(.init(name: name, kind: .integration, actsInTheRealWorld: true))
            default:
                tools.append(.init(name: name, kind: .other, actsInTheRealWorld: true))
            }
        }
        for (name, config) in (prompt["built_in_tools"].objectValue ?? [:]).sorted(by: { $0.key < $1.key })
        where config != .null {
            tools.append(.init(name: name, kind: .system, actsInTheRealWorld: realWorldSystemTools.contains(name)))
        }
        for id in (prompt["tool_ids"].arrayValue ?? []).compactMap(\.stringValue) {
            tools.append(.init(name: id, kind: .workspace, actsInTheRealWorld: true))
        }
        for key in ["mcp_server_ids", "native_mcp_server_ids"] {
            for id in (prompt[key].arrayValue ?? []).compactMap(\.stringValue) {
                tools.append(.init(name: "tools of MCP server \(id)", kind: .mcp, host: id, actsInTheRealWorld: true))
            }
        }
        return tools
    }

    /// The host of a URL written with `{placeholders}` (which `URL` refuses).
    static func host(of url: String?) -> String? {
        guard let url, let range = url.range(of: "://") else { return nil }
        let authority = url[range.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let host = authority.split(separator: "@").last.map(String.init) ?? ""
        let bare = host.hasPrefix("[") ? host : String(host.prefix { $0 != ":" })
        return bare.isEmpty ? nil : bare.lowercased()
    }
}

// MARK: - Events

/// The negotiated formats and the conversation's id, from `conversation_initiation_metadata`.
public struct ElevenLabsAgentMetadata: Sendable, Equatable, Hashable {
    public var conversationID: String?
    public var agentOutputAudioFormat: String
    public var userInputAudioFormat: String

    public var outputEncoding: ElevenLabsAudioEncoding? { ElevenLabsAudioEncoding(name: agentOutputAudioFormat) }
    public var inputEncoding: ElevenLabsAudioEncoding? { ElevenLabsAudioEncoding(name: userInputAudioFormat) }
}

/// A tool the agent asks this app to run (`client_tool_call`).
public struct ElevenLabsClientToolCall: Sendable, Equatable, Hashable {
    public var toolCallID: String
    public var toolName: String
    public var parameters: JSONValue
    public var eventID: Int?
    /// Whether the agent waits for a result. Nil when ElevenLabs did not say — answered anyway.
    public var expectsResponse: Bool?
}

/// A tool the agent runs on ElevenLabs' side (webhooks, system tools such as transfer or
/// end call), reported for visibility: this app cannot stop it.
public struct ElevenLabsAgentToolActivity: Sendable, Equatable, Hashable {
    public var toolCallID: String?
    public var toolName: String
    public var toolType: String?
    public var eventID: Int?
    /// For a response: `success`, `error`, `blocked`, `skipped`, when ElevenLabs says.
    public var status: String?
    public var isError: Bool?
    /// The whole result, when the agent is set to send it (`agent_tool_response_full_payload`).
    public var fullResult: String?
    public var truncated: Bool?
}

/// An MCP server's tool call, and, while `state` is `awaiting_approval`, a question only the
/// owner can answer.
public struct ElevenLabsMCPToolCall: Sendable, Equatable, Hashable {
    public var toolCallID: String
    public var serviceID: String?
    public var toolName: String
    public var toolDescription: String?
    public var parameters: JSONValue
    /// `loading`, `awaiting_approval`, `success` or `failure` (kept as sent).
    public var state: String
    /// How long ElevenLabs waits for the answer (default 300 s).
    public var approvalTimeout: TimeInterval?
    public var result: JSONValue
    public var errorMessage: String?

    public var isAwaitingApproval: Bool { state == "awaiting_approval" }
}

/// An error the agent socket reported (`client_error` or `error`).
public struct ElevenLabsAgentError: Sendable, Equatable, Hashable {
    public var code: Int?
    /// `error_name` or `error_type`: `max_duration_exceeded`, `override_error`…
    public var name: String?
    public var message: String
}

/// What the agent socket hands back. `.ended` is always last. Pings are answered before they are
/// reported. Audio interrupted by the user is dropped before it is reported (see `interruption`).
public enum ElevenLabsAgentEvent: Sendable, Equatable {
    case started(ElevenLabsAgentMetadata)
    case ping(eventID: Int?, latencyMs: Int?)
    /// Agent audio in `agentOutputAudioFormat`, with its character timings when sent.
    case audio(Data, eventID: Int?, alignment: ElevenLabsAlignment?, isFinal: Bool?)
    /// The user spoke over the agent: stop playing now. Audio of this response already queued
    /// should be dropped too; this session drops what arrives after.
    case interruption(eventID: Int?, reason: String?)
    case userTranscript(String, eventID: Int?)
    case tentativeUserTranscript(String, eventID: Int?)
    case agentResponse(String, eventID: Int?, responseID: String?)
    case agentResponseCorrection(original: String, corrected: String, eventID: Int?)
    /// Streamed response text: `start`, `delta`, `stop`.
    case agentResponsePart(text: String, kind: String, eventID: Int?, responseID: String?)
    case agentResponseComplete(eventID: Int?)
    case agentResponseMetadata(JSONValue, eventID: Int?)
    case contextUsage(model: String?, tokens: Int?, limit: Int?)
    case vadScore(Double)
    case clientToolCall(ElevenLabsClientToolCall)
    case agentToolRequest(ElevenLabsAgentToolActivity)
    case agentToolResponse(ElevenLabsAgentToolActivity)
    case mcpToolCall(ElevenLabsMCPToolCall)
    case mcpConnectionStatus(JSONValue)
    /// `waiting`, `admitted` or `timed_out` (after which the socket closes with 4300).
    case queueStatus(String)
    case error(ElevenLabsAgentError)
    case guardrailTriggered(String?)
    /// Experimental or internal events, by type, kept as data.
    case other(type: String, payload: JSONValue)
    case unknown(String)
    case ended(ElevenLabsSocketClose)
}

extension ElevenLabsAgentEvent {
    /// Every event type the sources list, for the spec-fidelity test.
    public static let knownTypes: Set<String> = [
        "conversation_initiation_metadata", "ping", "audio", "interruption", "user_transcript",
        "tentative_user_transcript", "agent_response", "agent_response_correction",
        "agent_chat_response_part", "agent_response_complete", "agent_response_metadata", "context_usage",
        "vad_score", "client_tool_call", "agent_tool_request", "agent_tool_response",
        "agent_tool_response_full_payload", "mcp_tool_call", "mcp_connection_status", "queue_status",
        "client_error", "error", "guardrail_triggered", "asr_initiation_metadata",
        "internal_turn_probability", "internal_tentative_agent_response", "agent_reasoning_response_part",
        "rich_content", "agent_typing", "external_agent_connected", "external_agent_disconnected",
        "dtmf_request",
    ]

    /// The payload under its documented key, or the frame itself when a server sends it flat.
    static func payload(_ frame: JSONValue, _ key: String) -> JSONValue {
        frame[key].objectValue != nil ? frame[key] : frame
    }

    static func decode(_ frame: JSONValue) -> ElevenLabsAgentEvent {
        let type = frame["type"].stringValue ?? ""
        switch type {
        case "conversation_initiation_metadata":
            let body = payload(frame, "conversation_initiation_metadata_event")
            return .started(ElevenLabsAgentMetadata(
                conversationID: body["conversation_id"].stringValue,
                agentOutputAudioFormat: body["agent_output_audio_format"].stringValue ?? "pcm_16000",
                userInputAudioFormat: body["user_input_audio_format"].stringValue ?? "pcm_16000"
            ))
        case "ping":
            let body = payload(frame, "ping_event")
            return .ping(eventID: body["event_id"].looseInt, latencyMs: body["ping_ms"].looseInt)
        case "audio":
            let body = payload(frame, "audio_event")
            let audio = body.first("audio_base_64", "audio_base64", "audio").stringValue.flatMap { Data(looseBase64: $0) } ?? Data()
            return .audio(
                audio, eventID: body["event_id"].looseInt, alignment: ElevenLabsAlignment(json: body["alignment"]),
                isFinal: body.first("is_final", "isFinal").looseBool
            )
        case "interruption":
            let body = payload(frame, "interruption_event")
            return .interruption(eventID: body["event_id"].looseInt, reason: body["reason"].stringValue)
        case "user_transcript":
            let body = payload(frame, "user_transcription_event")
            return .userTranscript(body["user_transcript"].stringValue ?? "", eventID: body["event_id"].looseInt)
        case "tentative_user_transcript":
            let body = payload(frame, "tentative_user_transcription_event")
            return .tentativeUserTranscript(body["user_transcript"].stringValue ?? "", eventID: body["event_id"].looseInt)
        case "agent_response":
            let body = payload(frame, "agent_response_event")
            return .agentResponse(
                body["agent_response"].stringValue ?? "", eventID: body["event_id"].looseInt,
                responseID: body["response_id"].stringValue
            )
        case "agent_response_correction":
            let body = payload(frame, "agent_response_correction_event")
            return .agentResponseCorrection(
                original: body["original_agent_response"].stringValue ?? "",
                corrected: body["corrected_agent_response"].stringValue ?? "", eventID: body["event_id"].looseInt
            )
        case "agent_chat_response_part":
            let body = payload(frame, "text_response_part")
            return .agentResponsePart(
                text: body["text"].stringValue ?? "", kind: body["type"].stringValue ?? "delta",
                eventID: body["event_id"].looseInt, responseID: body["response_id"].stringValue
            )
        case "agent_response_complete":
            return .agentResponseComplete(eventID: payload(frame, "agent_response_complete_event")["event_id"].looseInt)
        case "agent_response_metadata":
            let body = payload(frame, "agent_response_metadata_event")
            return .agentResponseMetadata(body["metadata"], eventID: body["event_id"].looseInt)
        case "context_usage":
            let body = payload(frame, "context_usage_event")
            return .contextUsage(
                model: body["model"].stringValue, tokens: body["context_tokens"].looseInt,
                limit: body["context_limit_tokens"].looseInt
            )
        case "vad_score":
            return .vadScore(payload(frame, "vad_score_event")["vad_score"].looseDouble ?? 0)
        case "client_tool_call":
            let body = payload(frame, "client_tool_call")
            // Without an id it cannot be answered; it is still shown, as data.
            guard let id = body["tool_call_id"].stringValue else { return .other(type: type, payload: frame) }
            return .clientToolCall(ElevenLabsClientToolCall(
                toolCallID: id, toolName: body["tool_name"].stringValue ?? "", parameters: body["parameters"],
                eventID: body["event_id"].looseInt, expectsResponse: body["expects_response"].looseBool
            ))
        case "agent_tool_request":
            return .agentToolRequest(activity(payload(frame, "agent_tool_request")))
        case "agent_tool_response":
            return .agentToolResponse(activity(payload(frame, "agent_tool_response")))
        case "agent_tool_response_full_payload":
            return .agentToolResponse(activity(payload(frame, "agent_tool_response_full_payload")))
        case "mcp_tool_call":
            let body = payload(frame, "mcp_tool_call")
            // Without an id it cannot be answered; it is still shown, as data.
            guard let id = body["tool_call_id"].stringValue else { return .other(type: type, payload: frame) }
            return .mcpToolCall(ElevenLabsMCPToolCall(
                toolCallID: id, serviceID: body["service_id"].stringValue,
                toolName: body["tool_name"].stringValue ?? "", toolDescription: body["tool_description"].stringValue,
                parameters: body["parameters"], state: body["state"].stringValue ?? "",
                approvalTimeout: body["approval_timeout_secs"].looseDouble, result: body["result"],
                errorMessage: body["error_message"].stringValue
            ))
        case "mcp_connection_status":
            return .mcpConnectionStatus(payload(frame, "mcp_connection_status"))
        case "queue_status":
            return .queueStatus(payload(frame, "queue_status_event")["status"].stringValue ?? "")
        case "client_error", "error":
            let body = payload(frame, "error_event")
            let message = body.first("message", "reason", "debug_message").stringValue ?? ""
            return .error(ElevenLabsAgentError(
                code: body["code"].looseInt, name: body.first("error_name", "error_type").stringValue,
                message: ElevenLabsRedaction.redact(message)
            ))
        case "guardrail_triggered":
            return .guardrailTriggered(payload(frame, "guardrail_triggered_event")["guardrail_name"].stringValue)
        case let other where knownTypes.contains(other):
            return .other(type: other, payload: frame)
        default:
            return .unknown(type)
        }
    }

    static func activity(_ body: JSONValue) -> ElevenLabsAgentToolActivity {
        ElevenLabsAgentToolActivity(
            toolCallID: body["tool_call_id"].stringValue, toolName: body["tool_name"].stringValue ?? "",
            toolType: body["tool_type"].stringValue, eventID: body["event_id"].looseInt,
            status: body["status"].stringValue, isError: body["is_error"].looseBool,
            fullResult: body["full_tool_result"].stringValue, truncated: body["truncated"].looseBool
        )
    }
}

// MARK: - Session

/// A conversation with an agent. The initiation data goes first; the agent's
/// `conversation_initiation_metadata` names the conversation and the audio formats; then audio
/// and text flow both ways until either side ends it.
///
/// Rules this session keeps so its caller cannot forget them:
/// - every `ping` is answered with a `pong` at once, ahead of any queued audio;
/// - after an `interruption`, audio of the interrupted response (`event_id` at or below the
///   interrupted one, as ElevenLabs' Python and Node clients drop it) is dropped;
/// - an MCP tool approval is answered at most once, only while ElevenLabs is still waiting for
///   it, and only an explicit approval approves; ending the conversation declines every approval
///   still waiting — a decline is sent, never silence;
/// - a client tool call is answered at most once.
public final class ElevenLabsAgentConversation: @unchecked Sendable {
    /// Whether audio at the interrupted `event_id` itself is dropped too. The sources differ
    /// (Python and Node: yes; the browser client: no); the brief follows Python and Node, and
    /// the owner's live check settles it.
    public static let dropsAudioAtTheInterruptedEvent = true

    public let config: ElevenLabsAgentConversationConfig
    public let events: AsyncStream<ElevenLabsAgentEvent>
    private let continuation: AsyncStream<ElevenLabsAgentEvent>.Continuation
    private let channel: ElevenLabsRealtimeChannel
    private let meter = UsageMeter()
    private let lock = NSLock()
    private var metadata: ElevenLabsAgentMetadata?
    private var started: CheckedContinuation<ElevenLabsAgentMetadata, any Error>?
    private var startResult: Result<ElevenLabsAgentMetadata, ElevenLabsRealtimeError>?
    private var interruptedThrough: Int?
    private var droppedAudio = 0
    /// MCP tool calls waiting for the owner's answer, by id.
    private var awaitingApproval: Set<String> = []
    /// Tool calls already answered, so a second answer is refused.
    private var answered: Set<String> = []
    private var pendingClientTools: Set<String> = []
    private var ending = false

    private init(channel: ElevenLabsRealtimeChannel, config: ElevenLabsAgentConversationConfig) {
        self.channel = channel
        self.config = config
        (events, continuation) = AsyncStream<ElevenLabsAgentEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    static func start(
        on socket: any ElevenLabsSocket, config: ElevenLabsAgentConversationConfig, initiation: JSONValue,
        startTimeout: TimeInterval
    ) async throws -> ElevenLabsAgentConversation {
        let conversation = ElevenLabsAgentConversation(channel: ElevenLabsRealtimeChannel(socket: socket), config: config)
        conversation.channel.start(
            onFrame: { [weak conversation] frame in conversation?.receive(frame) },
            onEnd: { [weak conversation] failure in conversation?.end(failure) }
        )
        do {
            try await conversation.channel.send(json: initiation)
            _ = try await conversation.waitForMetadata(timeout: startTimeout)
        } catch {
            await conversation.close()
            throw ElevenLabsRealtimeError(wrapping: error)
        }
        return conversation
    }

    /// The negotiated formats and the conversation's id.
    public var startedWith: ElevenLabsAgentMetadata? { lock.withLock { metadata } }
    public var usage: ElevenLabsRealtimeUsage { meter.snapshot }
    /// Agent audio dropped after interruptions.
    public var droppedAudioChunks: Int { lock.withLock { droppedAudio } }
    /// MCP tool calls ElevenLabs is waiting on the owner for.
    public var approvalsWaiting: Set<String> { lock.withLock { awaitingApproval } }

    // MARK: Sending

    /// Microphone audio in `userInputAudioFormat`. Refused before the metadata has named it.
    public func sendAudio(_ audio: Data) async throws {
        guard let format = lock.withLock({ metadata })?.inputEncoding else {
            throw ElevenLabsRealtimeError.invalidConfiguration(["The conversation has not started; no audio format yet."])
        }
        try checkOpen()
        try await channel.send(json: ["user_audio_chunk": .string(audio.base64EncodedString())])
        if let seconds = format.seconds(inBytes: audio.count) { meter.update { $0.audioSecondsSent += seconds } }
    }

    /// A typed message, treated like something said.
    public func sendUserMessage(_ text: String) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ElevenLabsRealtimeError.invalidConfiguration(["The message is empty."]) }
        try checkOpen()
        try await channel.send(json: ["type": "user_message", "text": .string(text)])
        meter.update { $0.messagesSent += 1 }
    }

    /// Background context the agent reads without being interrupted. A later update with the
    /// same `contextID` replaces this one.
    public func sendContextualUpdate(_ text: String, contextID: String? = nil) async throws {
        guard !text.isEmpty else { throw ElevenLabsRealtimeError.invalidConfiguration(["The update is empty."]) }
        try checkOpen()
        var message: [String: JSONValue] = ["type": "contextual_update", "text": .string(text)]
        if let contextID { message["context_id"] = .string(contextID) }
        try await channel.send(json: .object(message))
    }

    /// Tells the agent the user is active, so it does not take the turn after silence.
    public func sendUserActivity() async throws {
        try checkOpen()
        try await channel.send(json: ["type": "user_activity"])
    }

    /// Rates an agent response (`like`, `dislike`, or nil to clear).
    public func sendFeedback(eventID: Int, liked: Bool?) async throws {
        try checkOpen()
        try await channel.send(json: [
            "type": "feedback", "event_id": .number(Double(eventID)),
            "score": liked.map { .string($0 ? "like" : "dislike") } ?? .null,
        ])
    }

    /// A message with files already uploaded to this conversation over REST (at most 5).
    public func sendMultimodal(text: String, fileIDs: [String]) async throws {
        guard !fileIDs.isEmpty, fileIDs.count <= 5 else {
            throw ElevenLabsRealtimeError.invalidConfiguration(["A message takes 1 to 5 files."])
        }
        try checkOpen()
        let files = fileIDs.map { JSONValue.object(["type": "file_input", "file_id": .string($0)]) }
        try await channel.send(json: [
            "type": "multimodal_message",
            "text": ["type": "user_message", "text": .string(text)],
            "files": .array(files),
        ])
        meter.update { $0.messagesSent += 1 }
    }

    /// Answers a client tool call once. `result` is a string (JSON as text for anything else);
    /// `errorType` marks it failed (`user_rejected` also says the tool was not run).
    public func answerClientTool(
        _ toolCallID: String, result: String, isError: Bool = false, errorType: String? = nil
    ) async throws {
        let allowed = lock.withLock { () -> Bool in
            guard pendingClientTools.contains(toolCallID), !answered.contains(toolCallID) else { return false }
            pendingClientTools.remove(toolCallID)
            answered.insert(toolCallID)
            return true
        }
        guard allowed else {
            throw ElevenLabsRealtimeError.invalidConfiguration(["That tool call is not waiting for an answer."])
        }
        var message: [String: JSONValue] = [
            "type": "client_tool_result", "tool_call_id": .string(toolCallID), "result": .string(result),
            "is_error": .bool(isError || errorType != nil),
        ]
        if let errorType { message["error_type"] = .string(errorType) }
        try await channel.send(json: .object(message))
    }

    /// Answers an MCP tool approval once, while ElevenLabs still waits for it. Returns false —
    /// and sends nothing — when it is no longer waiting (answered, moved on, or the conversation
    /// ended).
    @discardableResult
    public func answerApproval(_ toolCallID: String, approved: Bool) async -> Bool {
        let allowed = lock.withLock { () -> Bool in
            guard awaitingApproval.contains(toolCallID), !answered.contains(toolCallID) else { return false }
            awaitingApproval.remove(toolCallID)
            answered.insert(toolCallID)
            return true
        }
        guard allowed else { return false }
        do {
            try await channel.send(json: [
                "type": "mcp_tool_approval_result", "tool_call_id": .string(toolCallID),
                "is_approved": .bool(approved),
            ])
            return true
        } catch {
            return false
        }
    }

    /// Ends the conversation: every approval still waiting is declined (sent), then the socket
    /// closes with 1000.
    public func end() async {
        let waiting: [String] = lock.withLock {
            ending = true
            let waiting = awaitingApproval.subtracting(answered).sorted()
            answered.formUnion(waiting)
            awaitingApproval = []
            return waiting
        }
        for id in waiting where !channel.hasEnded {
            try? await channel.send(json: [
                "type": "mcp_tool_approval_result", "tool_call_id": .string(id), "is_approved": false,
            ])
        }
        await channel.close(reason: "User ended conversation")
    }

    /// Closes at once, without the courtesy declines (the socket is failing anyway).
    func close() async {
        lock.withLock { ending = true }
        await channel.close(reason: "User ended conversation", discardingQueued: true)
    }

    public func waitUntilEnded() async {
        await channel.waitForReader()
    }

    private func checkOpen() throws {
        if lock.withLock({ ending }) || channel.hasEnded { throw ElevenLabsRealtimeError.ended }
    }

    // MARK: Receiving

    private func waitForMetadata(timeout: TimeInterval) async throws -> ElevenLabsAgentMetadata {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(max(timeout, 0.1) * 1_000)))
            self?.settleStart(.failure(.timedOut("the agent did not start the conversation within \(Int(timeout)) seconds")))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let known: Result<ElevenLabsAgentMetadata, ElevenLabsRealtimeError>? = lock.withLock {
                if let startResult { return startResult }
                started = continuation
                return nil
            }
            if let known { continuation.resume(with: known.mapError { $0 as any Error }) }
        }
    }

    private func settleStart(_ result: Result<ElevenLabsAgentMetadata, ElevenLabsRealtimeError>) {
        let waiter: CheckedContinuation<ElevenLabsAgentMetadata, any Error>? = lock.withLock {
            guard startResult == nil else { return nil }
            startResult = result
            defer { started = nil }
            return started
        }
        waiter?.resume(with: result.mapError { $0 as any Error })
    }

    private func receive(_ message: ElevenLabsSocketMessage) {
        guard let frame = message.json, frame.objectValue != nil else {
            continuation.yield(.unknown(""))
            return
        }
        let event = ElevenLabsAgentEvent.decode(frame)
        switch event {
        case .started(let metadata):
            lock.withLock { self.metadata = metadata }
            meter.update { $0.connectedAt = $0.connectedAt ?? Date() }
            settleStart(.success(metadata))
        case .ping(let eventID, _):
            // At once, and ahead of queued audio: a late pong can end the conversation.
            var pong: [String: JSONValue] = ["type": "pong"]
            if let eventID { pong["event_id"] = .number(Double(eventID)) }
            channel.post(.text(JSONValue.object(pong).jsonString()), urgent: true)
        case .interruption(let eventID, _):
            if let eventID { lock.withLock { interruptedThrough = max(interruptedThrough ?? eventID, eventID) } }
        case .audio(let data, let eventID, _, _):
            let drop: Bool = lock.withLock {
                guard let eventID, let through = interruptedThrough else { return false }
                let dropped = Self.dropsAudioAtTheInterruptedEvent ? eventID <= through : eventID < through
                if dropped { droppedAudio += 1 }
                return dropped
            }
            if drop { return }
            let format = lock.withLock { metadata }?.outputEncoding
            meter.update { usage in
                usage.audioBytesReceived += data.count
                if let seconds = format?.seconds(inBytes: data.count) { usage.audioSecondsReceived += seconds }
            }
        case .clientToolCall(let call):
            lock.withLock { if !answered.contains(call.toolCallID) { pendingClientTools.insert(call.toolCallID) } }
        case .mcpToolCall(let call):
            lock.withLock {
                if call.isAwaitingApproval, !answered.contains(call.toolCallID), !ending {
                    awaitingApproval.insert(call.toolCallID)
                } else if !call.isAwaitingApproval {
                    // It has moved on (running, done, failed): an answer now would be stale.
                    awaitingApproval.remove(call.toolCallID)
                }
            }
        default:
            break
        }
        continuation.yield(event)
    }

    private func end(_ failure: ElevenLabsRealtimeError) {
        meter.update { $0.endedAt = Date() }
        let close: ElevenLabsSocketClose = if case .closed(let close) = failure {
            close
        } else {
            ElevenLabsSocketClose(code: 0, reason: failure.description)
        }
        // Closed before the agent said it started: say so with the close, as the browser client does.
        settleStart(.failure(.closed(close)))
        lock.withLock {
            awaitingApproval = []
            pendingClientTools = []
        }
        continuation.yield(.ended(close))
        continuation.finish()
    }
}

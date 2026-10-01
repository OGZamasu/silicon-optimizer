import Foundation

// MARK: - A text conversation with an ElevenLabs agent, over the control API

/// `POST /elevenlabs/agents/converse`: a short, text-only conversation with one of the owner's
/// Agents Platform agents over its WebSocket, run by the app, answered with the transcript and
/// the tools the agent used.
///
/// MCP is request/response, so this is the form of the realtime APIs an agent can use; live
/// transcription and streaming speech are already served by the REST operations
/// (`speech_to_text`, `text_to_speech_stream`) through `POST /elevenlabs/call`.
///
/// Body: `{"agent_id": …, "messages": ["…", …], "overrides": {…}, "dynamic_variables": {…},
/// "max_turns": n, "confirm": true}`. An agent can run its own server tools (webhooks, transfers,
/// phone numbers) during the conversation, so the route is real-world: it runs only with
/// `confirm: true` and the owner's switch (`ElevenLabsControl.riskySwitch`), and otherwise sends
/// nothing — no REST call, no socket. The answer never carries a signed URL or a token.
extension ElevenLabsControl {
    public static let agentConversePath = "/elevenlabs/agents/converse"

    /// The fields of a converse body. Anything else is refused by name.
    public static let converseFields: Set<String> = [
        "agent_id", "messages", "overrides", "dynamic_variables", "max_turns", "confirm",
    ]

    /// At most this many messages in one call, each at most `maximumConverseMessageLength`.
    public static let maximumConverseMessages = 20
    public static let maximumConverseMessageLength = 4_000

    /// How long the agent may take to answer one message before the conversation is ended.
    public static let converseTurnSeconds = 90

    /// Said with every conversation's answer.
    public static let converseCostNote =
        "ElevenLabs bills agent conversations by their length, and the agent's LLM usage; this "
        + "one ran text-only (no audio). Check the balance with elevenlabs_account."

    /// What an MCP tool approval gets over MCP: declined, because only the owner, in the app,
    /// may let an agent's outside tool server act.
    public static let converseApprovalDeclined =
        "declined: MCP tool approvals are given by the owner in the app (ElevenLabs → Talk to an agent)"

    /// What a client tool call gets over MCP: nothing runs on the Mac for it.
    public static let converseClientToolAnswer =
        "This conversation runs from the Silicon Optimizer app over MCP, which runs no client tools; nothing was done."
}

extension ControlServer {
    /// `POST /elevenlabs/agents/converse`, as `elevenLabsRoute` finds it.
    static func elevenLabsRealtimeRoute(method: String, segments: [String], body: Data) -> ElevenLabsControlRequest.Route? {
        if method == "POST", segments == ["elevenlabs", "agents", "converse"] { return .agentConverse(body: body) }
        return nil
    }
}

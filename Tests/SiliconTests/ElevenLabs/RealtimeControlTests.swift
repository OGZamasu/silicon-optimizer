import Foundation
import Testing
import SiliconElevenLabs
@testable import SiliconControl
@testable import SiliconUI

/// `POST /elevenlabs/agents/converse`: the route, the gate (real-world: confirm and the owner's
/// switch, before anything is read or opened), the link, the body, and a whole conversation with
/// a fake agent — what is sent, what is declined on the owner's behalf, and what comes back.
/// Nothing here opens a network connection: the client runs on the in-memory transport, the
/// socket is the in-memory fake.
@Suite("ElevenLabs realtime over control: agent conversations")
struct RealtimeControlTests {

    static let key = "sk_" + String(repeating: "conversefixture", count: 3)
    static let signature = "sig_ONLY_FOR_THE_SOCKET_42"

    // MARK: - Route

    @Test func theRouteIsPostAgentsConverseAndNothingNear() {
        func route(_ method: String, _ path: String) -> ElevenLabsControlRequest.Route? {
            ControlServer.elevenLabsRoute(method: method, segments: path.split(separator: "/").map(String.init),
                                          query: [:], body: Data("{}".utf8))
        }
        #expect(route("POST", "/elevenlabs/agents/converse") == .agentConverse(body: Data("{}".utf8)))
        #expect(route("POST", "/elevenlabs/agents/converse/") == .agentConverse(body: Data("{}".utf8)))
        #expect(route("GET", "/elevenlabs/agents/converse") == nil)
        #expect(route("POST", "/elevenlabs/agents") == nil)
        #expect(route("POST", "/elevenlabs/converse") == nil)
        #expect(ElevenLabsControl.isElevenLabsPath(ElevenLabsControl.agentConversePath))
        // A phone or a peer never reaches it: it is under /elevenlabs, whose rule is by first segment.
        for caller: ControlServer.Caller in [.swarm, .device(id: "p", scope: .full), .device(id: "c", scope: .chat)] {
            #expect(!caller.mayReach(method: "POST", path: ElevenLabsControl.agentConversePath))
        }
        #expect(ControlServer.Caller.control.mayReach(method: "POST", path: ElevenLabsControl.agentConversePath))
    }

    /// On the wire: this Mac's control token on loopback reaches the host with the body as sent;
    /// a full-scope phone, a chat phone and a swarm peer are refused with the one sentence, and
    /// the host never hears of them.
    @MainActor
    @Test func onlyThisMacsTokenReachesTheConversationRoute() async throws {
        let swarmSecret = "swarm-fixture-secret"
        let host = BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false)
        await ElevenLabsControlHostLog.shared.clear(host)
        let body = #"{"agent_id":"agent_1","messages":["Hi"],"confirm":true}"#
        try await withServer(host: host, swarmToken: swarmSecret) { fixture in
            let full = try await fixture.pair(name: "Full phone", scope: .full).token
            let chat = try await fixture.pair(name: "Chat phone", scope: .chat).token
            try await fixture.server.setTailnetAccess(address: "127.0.0.1", port: fixture.phone.port, for: .swarm)
            for (token, client) in [(full, fixture.phone), (chat, fixture.phone), (swarmSecret, fixture.phone), (swarmSecret, fixture.local)] {
                let (status, answer) = try await client.call("POST", ElevenLabsControl.agentConversePath, token: token, body: body)
                #expect(status == 403)
                let refusal = try JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: answer)
                #expect(refusal.error == ElevenLabsControl.onlyThisMac)
            }
            #expect(await ElevenLabsControlHostLog.shared.requests(for: host).isEmpty)
            let (status, answer) = try await fixture.local.call(
                "POST", ElevenLabsControl.agentConversePath, token: fixture.local.token, body: body
            )
            #expect(status == 200)
            #expect(String(decoding: answer, as: UTF8.self).contains(#""route":"agentConverse""#))
            let seen = await ElevenLabsControlHostLog.shared.requests(for: host)
            #expect(seen.map(\.route) == [.agentConverse(body: Data(body.utf8))])
        }
    }

    // MARK: - Gate and link

    /// Real-world: only confirm: true with the owner's switch on proceeds; every other
    /// combination is a 403 naming the switch, and nothing — no REST read, no socket — happens.
    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func theGateNeedsConfirmAndTheOwnersSwitch(allowed: Bool, confirm: Bool) async throws {
        let rig = ConverseRig(allowRisky: allowed, server: ConverseRig.agent(answers: ["Hi."]))
        defer { rig.clean() }
        let (status, answer) = await rig.converse(["agent_id": "agent_1", "messages": ["Hello"], "confirm": .bool(confirm)])
        if allowed && confirm {
            #expect(status == 200, "\(answer)")
        } else {
            #expect(status == 403)
            let error = answer["error"].stringValue ?? ""
            #expect(error.contains(ElevenLabsControl.riskySwitch))
            #expect(error.contains("Nothing was sent."))
            #expect(answer["risk"] == "realWorld")
            #expect(answer["setting"] == .string(ElevenLabsControl.riskySwitch))
            #expect(rig.transport.requests.isEmpty)
            #expect(rig.connector.requests.isEmpty)
            #expect(rig.credentials.reads == 0)
        }
    }

    @Test func unlinkedIsAConflictOnlyOnceTheGateIsPassed() async throws {
        let refused = ConverseRig(linked: false, allowRisky: false)
        defer { refused.clean() }
        #expect(await refused.converse(["agent_id": "agent_1", "messages": ["Hi"], "confirm": true]).status == 403)
        let unlinked = ConverseRig(linked: false, allowRisky: true)
        defer { unlinked.clean() }
        let (status, answer) = await unlinked.converse(["agent_id": "agent_1", "messages": ["Hi"], "confirm": true])
        #expect(status == 409)
        #expect(answer["error"] == .string(ElevenLabsControl.notConnected))
    }

    @Test func aBadBodyIsRefusedByNameAndSendsNothing() async throws {
        let rig = ConverseRig(allowRisky: true)
        defer { rig.clean() }
        let cases: [(JSONValue, String)] = [
            (["agent_id": "a", "messages": ["x"], "confirm": true, "agentId": "b"], "Unknown field \"agentId\""),
            (["messages": ["x"], "confirm": true], "agent_id must name an agent"),
            (["agent_id": "a", "confirm": true], "messages must be a list of strings"),
            (["agent_id": "a", "messages": [], "confirm": true], "at least one message"),
            (["agent_id": "a", "messages": ["ok", 3], "confirm": true], "messages[1] must be a non-empty string"),
            (["agent_id": "a", "messages": .array((0...20).map { .string("m\($0)") }), "confirm": true], "At most 20 messages"),
            (["agent_id": "a", "messages": [.string(String(repeating: "x", count: 4_001))], "confirm": true], "longer than 4000"),
            (["agent_id": "a", "messages": ["x"], "max_turns": 0, "confirm": true], "max_turns"),
            (["agent_id": "a", "messages": ["x"], "max_turns": 1.5, "confirm": true], "max_turns"),
            (["agent_id": "a", "messages": ["x"], "confirm": "yes"], "confirm must be true or false"),
            (["agent_id": "a", "messages": ["x"], "dynamic_variables": ["n": ["deep": 1]], "confirm": true], "dynamic_variables.n"),
            (["agent_id": "a/../b", "messages": ["x"], "confirm": true], "agent_id must be an id"),
        ]
        for (body, words) in cases {
            let (status, answer) = await rig.converse(body)
            #expect(status == 400, "\(body)")
            #expect((answer["error"].stringValue ?? "").contains(words), "\(answer["error"])")
        }
        #expect(rig.transport.requests.isEmpty)
        #expect(rig.connector.requests.isEmpty)
    }

    // MARK: - A conversation

    @Test func aConversationComesBackAsItsTranscriptAndItsTools() async throws {
        let rig = ConverseRig(allowRisky: true, auth: true, server: { socket in
            guard let first = await socket.nextSent(), first["type"] == "conversation_initiation_client_data" else { return }
            socket.push(ConverseRig.metadata)
            socket.push(ConverseRig.response("Hello, how can I help?", 1))
            guard await socket.nextSent(ofType: "user_message") != nil else { return }
            socket.push(["type": "agent_tool_request", "agent_tool_request": [
                "tool_name": "lookup_hours", "tool_call_id": "srv_1", "tool_type": "webhook", "event_id": 2]])
            socket.push(["type": "agent_tool_response", "agent_tool_response": [
                "tool_name": "lookup_hours", "tool_call_id": "srv_1", "tool_type": "webhook", "is_error": false,
                "status": "success", "event_id": 2]])
            socket.push(["type": "client_tool_call", "client_tool_call": [
                "tool_name": "open_page", "tool_call_id": "cli_1", "event_id": 3, "expects_response": true,
                "parameters": ["url": "https://example.com/hours", "api_key": "abc123", "note": .string("key " + Self.key)]]])
            socket.push(["type": "mcp_tool_call", "mcp_tool_call": [
                "service_id": "mcp_1", "tool_call_id": "mcp_call_1", "tool_name": "send_email", "state": "awaiting_approval",
                "parameters": ["to": "someone@example.com"], "approval_timeout_secs": 300]])
            socket.push(ConverseRig.response("We open at nine.", 4))
            guard await socket.nextSent(ofType: "user_message") != nil else { return }
            socket.push(ConverseRig.response("You're welcome.", 5))
        })
        defer { rig.clean() }
        let (status, answer) = await rig.converse([
            "agent_id": "agent_2", "messages": ["What are your hours?", "Thanks"],
            "dynamic_variables": ["user_name": "Ada"], "confirm": true,
        ])
        #expect(status == 200, "\(answer)")
        #expect(answer["agent_id"] == "agent_2")
        #expect(answer["agent_name"] == "Support")
        #expect(answer["conversation_id"] == "conv_7")
        #expect(answer["messages_sent"] == 2)
        #expect(answer["transcript"] == [
            ["role": "agent", "text": "Hello, how can I help?"],
            ["role": "user", "text": "What are your hours?"],
            ["role": "agent", "text": "We open at nine."],
            ["role": "user", "text": "Thanks"],
            ["role": "agent", "text": "You're welcome."],
        ])
        let tools = answer["tool_calls"].arrayValue ?? []
        #expect(tools.count == 3)
        let server = try #require(tools.first { $0["kind"] == "server" })
        #expect(server["name"] == "lookup_hours")
        #expect(server["status"] == "success")
        #expect(server["note"].stringValue?.contains("cannot stop") == true)
        let client = try #require(tools.first { $0["kind"] == "client" })
        #expect(client["parameters"]["api_key"] == .string(ElevenLabsRedaction.placeholder))
        #expect(client["parameters"]["url"] == "https://example.com/hours")
        let mcp = try #require(tools.first { $0["kind"] == "mcp" })
        #expect(mcp["handled"] == .string(ElevenLabsControl.converseApprovalDeclined))
        #expect(answer["ended"] == "by this app, after the last message")
        #expect(answer["cost_note"] == .string(ElevenLabsControl.converseCostNote))

        // What went over the socket: text-only initiation, the two messages, the decline and the
        // "nothing ran" answer, then a normal close.
        let socket = try #require(rig.connector.sockets.first)
        let sent = socket.sentJSON
        #expect(sent.first?["conversation_config_override"]["conversation"]["text_only"] == true)
        #expect(sent.first?["dynamic_variables"] == ["user_name": "Ada"])
        #expect(sent.contains(["type": "mcp_tool_approval_result", "tool_call_id": "mcp_call_1", "is_approved": false]))
        #expect(sent.contains(["type": "client_tool_result", "tool_call_id": "cli_1",
                               "result": .string(ElevenLabsControl.converseClientToolAnswer),
                               "is_error": true, "error_type": "user_rejected"]))
        #expect(!sent.contains { $0["is_approved"] == true })
        #expect(socket.closedByClient?.code == 1000)
        // The key went to REST only, the signature to the socket only, and neither comes back.
        #expect(rig.transport.requests.map(\.operationID) == ["get_agent_route", "get_conversation_signed_link"])
        #expect(socket.request.headers.isEmpty)
        #expect(socket.request.url.absoluteString.contains(Self.signature))
        let bytes = String(decoding: answer.encoded(), as: UTF8.self)
        #expect(!bytes.contains(Self.signature))
        #expect(!bytes.contains(Self.key))
        #expect(!bytes.contains("signed_url"))
    }

    @Test func anAgentThatDoesNotAllowTextOnlyStartsNothing() async throws {
        let rig = ConverseRig(allowRisky: true, textOnlyAllowed: false, server: ConverseRig.agent(answers: ["Hi"]))
        defer { rig.clean() }
        let (status, answer) = await rig.converse(["agent_id": "agent_1", "messages": ["Hello"], "confirm": true])
        #expect(status == 409)
        #expect((answer["error"].stringValue ?? "").contains("does not allow text-only"))
        #expect(rig.connector.requests.isEmpty)
        #expect(rig.transport.requests.map(\.operationID) == ["get_agent_route"])
    }

    @Test func anUnknownAgentIsNotFoundAndOpensNothing() async throws {
        let rig = ConverseRig(allowRisky: true, replies: { _ in .jsonText(#"{"detail":"Agent not found"}"#, status: 404) })
        defer { rig.clean() }
        let (status, answer) = await rig.converse(["agent_id": "agent_x", "messages": ["Hello"], "confirm": true])
        #expect(status == 404)
        #expect(answer["upstreamStatus"] == 404)
        #expect((answer["error"].stringValue ?? "").contains("Agent not found"))
        #expect(rig.connector.requests.isEmpty)
    }

    @Test func aFailedSignedLinkSaysItMayHaveStarted() async throws {
        let rig = ConverseRig(allowRisky: true, replies: { request in
            request.operationID == "get_agent_route"
                ? ConverseRig.agentJSON(auth: true, textOnlyAllowed: true)
                : .jsonText(#"{"detail":"unavailable"}"#, status: 503)
        })
        defer { rig.clean() }
        let (status, answer) = await rig.converse(["agent_id": "agent_1", "messages": ["Hello"], "confirm": true])
        #expect(status == 502)
        #expect((answer["error"].stringValue ?? "").contains("may have started"))
        #expect(rig.connector.requests.isEmpty)
    }

    @Test func maxTurnsSendsOnlyThatManyMessages() async throws {
        let rig = ConverseRig(allowRisky: true, server: ConverseRig.agent(answers: ["One.", "Two.", "Three."]))
        defer { rig.clean() }
        let (status, answer) = await rig.converse([
            "agent_id": "agent_1", "messages": ["a", "b", "c"], "max_turns": 1, "confirm": true,
        ])
        #expect(status == 200)
        #expect(answer["messages_sent"] == 1)
        #expect((answer["note"].stringValue ?? "").contains("max_turns stopped it after 1 of 3"))
        let socket = try #require(rig.connector.sockets.first)
        #expect(socket.sentJSON.filter { $0["type"] == "user_message" }.count == 1)
    }

    @Test func anAgentThatStopsAnsweringIsEndedAndSaysSo() async throws {
        var rig = ConverseRig(allowRisky: true, server: { socket in
            _ = await socket.nextSent()
            socket.push(ConverseRig.metadata)
        })
        defer { rig.clean() }
        rig.timing.turn = .milliseconds(300)
        let (status, answer) = await rig.converse(["agent_id": "agent_1", "messages": ["Hello?", "Anyone?"], "confirm": true])
        #expect(status == 200)
        #expect((answer["note"].stringValue ?? "").contains("did not answer"))
        #expect(answer["messages_sent"] == 1)
        let socket = try #require(rig.connector.sockets.first)
        #expect(socket.closedByClient?.code == 1000)
    }

    @Test func theAgentEndingItIsReported() async throws {
        let rig = ConverseRig(allowRisky: true, server: { socket in
            _ = await socket.nextSent()
            socket.push(ConverseRig.metadata)
            _ = await socket.nextSent(ofType: "user_message")
            socket.push(ConverseRig.response("Goodbye.", 2))
            socket.serverClose(code: 1000, reason: "")
        })
        defer { rig.clean() }
        let (status, answer) = await rig.converse(["agent_id": "agent_1", "messages": ["Bye", "Wait"], "confirm": true])
        #expect(status == 200)
        #expect(answer["ended"] == "by the agent")
        #expect(answer["messages_sent"] == 1)
        #expect((answer["note"].stringValue ?? "").contains("It ended after 1 of 2 messages"))
    }

    @Test func aConversationClosedBeforeItStartedIsAnUpstreamFailure() async throws {
        let rig = ConverseRig(allowRisky: true, server: { socket in
            _ = await socket.nextSent()
            socket.serverClose(code: 1008, reason: "Override for field text_only is not allowed")
        })
        defer { rig.clean() }
        let (status, answer) = await rig.converse(["agent_id": "agent_1", "messages": ["Hi"], "confirm": true])
        #expect(status == 502)
        #expect((answer["error"].stringValue ?? "").contains("1008"))
        #expect((answer["error"].stringValue ?? "").contains("may have started"))
    }
}

/// A converse handler on the in-memory transport and socket.
struct ConverseRig {
    let transport: FakeElevenLabsTransport
    let sink = TemporaryFileSink()
    let credentials = FakeCredentialSource(key: RealtimeControlTests.key)
    let connector: FakeElevenLabsSocketConnector
    let linked: Bool
    let allowRisky: Bool
    let realtime: ElevenLabsRealtime
    var timing = ElevenLabsConverseHandler.Timing(greeting: .milliseconds(300), settle: .milliseconds(150), turn: .seconds(5))

    init(
        linked: Bool = true, allowRisky: Bool, auth: Bool = false, textOnlyAllowed: Bool = true,
        replies: (@Sendable (ElevenLabsRequest) async throws -> FakeElevenLabsTransport.Reply)? = nil,
        server: @escaping FakeElevenLabsSocketConnector.Server = { _ in }
    ) {
        self.linked = linked
        self.allowRisky = allowRisky
        let signed = "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=agent_2&conversation_signature="
            + RealtimeControlTests.signature
        transport = FakeElevenLabsTransport(handler: replies ?? { request in
            switch request.operationID {
            case "get_agent_route": ConverseRig.agentJSON(auth: auth, textOnlyAllowed: textOnlyAllowed)
            case "get_conversation_signed_link": .json(["signed_url": .string(signed)])
            default: .jsonText(#"{"detail":"not scripted"}"#, status: 404)
            }
        })
        var limits = ElevenLabsClient.Limits()
        limits.firstBackoff = 0.01
        limits.longestRetryWait = 0.02
        let client = ElevenLabsClient(credentials: credentials, region: .global, transport: transport, sink: sink, limits: limits)
        connector = FakeElevenLabsSocketConnector(server: server)
        realtime = ElevenLabsRealtime(client: client, connector: connector)
    }

    func converse(_ body: JSONValue) async -> (status: Int, answer: JSONValue) {
        let handler = ElevenLabsConverseHandler(
            state: .init(linked: linked, allowRiskyForAgents: allowRisky), realtime: linked ? realtime : nil, timing: timing
        )
        let response = await handler.handle(body.encoded())
        return (response.status, (try? JSONValue.parse(response.body)) ?? .null)
    }

    func clean() {
        sink.removeAll()
        transport.removeTemporaryFiles()
    }

    static func agentJSON(auth: Bool, textOnlyAllowed: Bool) -> FakeElevenLabsTransport.Reply {
        .json([
            "agent_id": "agent_2", "name": "Support",
            "platform_settings": [
                "auth": ["enable_auth": .bool(auth), "shareable_token": "share_SECRET"],
                "overrides": ["conversation_config_override": ["conversation": ["text_only": .bool(textOnlyAllowed)]]],
            ],
            "conversation_config": ["conversation": ["text_only": false]],
        ])
    }

    static let metadata: JSONValue = ["type": "conversation_initiation_metadata", "conversation_initiation_metadata_event": [
        "conversation_id": "conv_7", "agent_output_audio_format": "pcm_16000", "user_input_audio_format": "pcm_16000",
    ]]

    static func response(_ text: String, _ id: Int) -> JSONValue {
        ["type": "agent_response", "agent_response_event": ["agent_response": .string(text), "event_id": .number(Double(id))]]
    }

    /// An agent that starts, then answers each user message with the next of `answers`.
    static func agent(answers: [String]) -> FakeElevenLabsSocketConnector.Server {
        { socket in
            guard await socket.nextSent() != nil else { return }
            socket.push(metadata)
            for (index, answer) in answers.enumerated() {
                guard await socket.nextSent(ofType: "user_message") != nil else { return }
                socket.push(response(answer, index + 1))
            }
        }
    }
}

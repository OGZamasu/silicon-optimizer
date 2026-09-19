import Foundation
import Network
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

/// Silicon Buddy's agent sessions: the Chat tab's Codex and Pi engines as a phone meets
/// them.
///
/// Nothing here starts Codex, Pi, npm or a model. The engine events are recorded fixtures —
/// written from what the existing handlers in `AppModel+Codex.swift` and `AppModel+Pi.swift`
/// already expect, which is the point: they are driven through those handlers, so a rename
/// on either side fails here rather than on somebody's phone. The server is a loopback
/// socket with a private handshake file, and the "phone" is a second loopback listener
/// standing in for the tailnet one.
@Suite("Silicon Buddy agent sessions", .serialized, .redirectedConversationStore)
@MainActor
struct BuddyAgentSessionTests {

    // MARK: - Normalisation

    /// Codex's app-server notifications, as recorded, through the app's own handler and out
    /// the other side as the one shape both engines share.
    ///
    /// The fixtures are the protocol's own spellings — `aggregatedOutput`, `itemId`,
    /// `mcpToolCall` — because that is what a rename would change. Driving them through
    /// `handleCodexEvent` rather than through a second copy of the mapping is what makes
    /// this a test of the app rather than of the test.
    @Test func codexNotificationsBecomeOneNormalisedTranscript() throws {
        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        model.codexState = .ready(endpoint: URL(string: "codex://app-server")!)

        for (method, params) in Self.codexTurn {
            model.handleCodexEvent(.notification(method: method, params: try Self.json(params)))
        }

        let session = try #require(model.agentSnapshot(engine: "codex"))
        #expect(session.state == "running")
        // `turn/completed` arrived, so the turn is over — and `thread/started` named the
        // thread, which is what a phone reconnecting needs to know it is the same one.
        #expect(session.turnActive == false)
        #expect(session.threadID == "th_01HZY")

        #expect(session.rows == [
            .init(id: "item_msg_1", kind: "assistant", text: "Running the suite."),
            .init(id: "item_reason_1", kind: "reasoning", text: "Check the tests first."),
            // The one engine that reports the command and its output separately, so the
            // wire keeps them separate too.
            .init(
                id: "item_cmd_1", kind: "command", text: "swift test --filter Lisbon",
                output: "1 test failed: itineraryFitsInThreeDays\n", status: "completed"
            ),
            .init(
                id: "item_patch_1", kind: "fileChange",
                text: "Sources/Lisbon/Itinerary.swift"
            ),
            // Three Codex item types collapse into `tool`; a phone learns one word.
            .init(
                id: "item_tool_1", kind: "tool",
                text: "silicon-optimizer · generate_image", status: "completed"
            ),
            .init(id: "item_web_1", kind: "tool", text: "web search: lisbon tram 28"),
            .init(
                id: "item_err_1", kind: "error",
                text: "The model stopped mid-turn.", status: "failed"
            ),
        ])
    }

    /// The same thing from the other engine, whose events look nothing alike on the wire
    /// and have to look identical afterwards.
    @Test func piEventsBecomeTheSameShape() throws {
        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        model.piState = .ready

        for event in Self.piTurn {
            model.handlePiEvent(try Self.object(event))
        }

        let session = try #require(model.agentSnapshot(engine: "pi"))
        #expect(session.state == "running")
        #expect(session.turnActive == false)
        // Pi's RPC hands a client no thread id, and the contract says null rather than
        // inventing one out of the session file's name.
        #expect(session.threadID == nil)

        let rows = session.rows
        #expect(rows.map(\.kind) == ["reasoning", "assistant", "tool"])
        #expect(rows[0].text == "Check the tests first.")
        // `message_end` replaces the streamed assembly with the authoritative text.
        #expect(rows[1].text == "Running the suite.")
        // Pi overwrites a tool row's text with its result, so `text` is the tool and
        // `output` is whichever of the two Pi currently holds.
        #expect(rows[2].text == "bash")
        #expect(rows[2].output == "1 test failed: itineraryFitsInThreeDays")
        #expect(rows[2].status == "completed")
        // `agent_end` settles everything that was running; nothing is left claiming to be
        // in flight after the turn is over.
        #expect(rows.allSatisfy { $0.status != "running" })
    }

    /// Both engines' approvals, side by side on the wire.
    ///
    /// Injected rather than driven through the guardrail on purpose: a screening asks
    /// `JevService.shared`, and a unit test must not depend on whether the person running
    /// it has TypeSafe switched on. What is under test here is the mapping and the wire
    /// shape, which is the part Silicon Buddy owns.
    @Test func approvalsFromBothEnginesLookAlikeOnTheWire() async throws {
        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        model.codexState = .ready(endpoint: URL(string: "codex://app-server")!)
        model.piState = .ready

        model.codexApprovals = [
            CodexApproval(
                rpcID: .number(7), kind: .command("rm -rf build"),
                reason: "Codex asks before running a command in this folder."
            ),
            CodexApproval(rpcID: .number(8), kind: .fileChange("Sources/Lisbon/Itinerary.swift")),
        ]
        model.piItems = [
            AppModel.PiItem(
                kind: .approval(requestID: "ui-1", tool: "bash"),
                text: #"{"command":"swift test"}"#, running: true
            ),
        ]

        let codex = try await model.agentSession(engine: "codex", since: nil)
        #expect(codex.approvals.map(\.kind) == ["command", "fileChange"])
        #expect(codex.approvals[0].summary == "rm -rf build")
        #expect(codex.approvals[0].reason?.isEmpty == false)
        // Codex sometimes says why; Pi's gate is this app's own extension and never does,
        // so the field is absent rather than filled with a sentence nobody said.
        #expect(codex.approvals[1].reason == nil)
        #expect(codex.session.pendingApprovals == 2)

        let pi = try await model.agentSession(engine: "pi", since: nil)
        #expect(pi.approvals.map(\.kind) == ["tool"])
        #expect(pi.approvals[0].summary == #"bash {"command":"swift test"}"#)
        // The held call is in the transcript too, saying it is waiting — which is what the
        // Mac shows, and so what the phone shows.
        #expect(pi.items.map(\.status) == ["running"])

        // Answered, and now a row that says which way it went. `declined` is a real answer
        // here rather than a shape with nothing behind it.
        model.answerPiApproval(model.piItems[0], allow: false)
        let after = try await model.agentSession(engine: "pi", since: nil)
        #expect(after.approvals.isEmpty)
        #expect(after.items.map(\.status) == ["declined"])
    }

    /// Timestamps and the model are the two things the app does not keep and a phone needs.
    @Test func everyRowCarriesWhenItArrivedAndWhatSentIt() async throws {
        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        model.codexState = .ready(endpoint: URL(string: "codex://app-server")!)
        model.codexItems = [
            CodexChatItem(id: "u1", kind: .user("Fix the failing test.")),
            CodexChatItem(id: "a1", kind: .assistant("On it.")),
        ]

        let detail = try await model.agentSession(engine: "codex", since: nil)
        #expect(detail.items.allSatisfy { ControlAPI.date(fromTimestamp: $0.at) != nil })
        // Knowable exactly once — when the row appears — and only about the row that was
        // the sending. Guessing it for the rest would be putting a model's name on prose
        // an older one wrote.
        #expect(detail.items.filter { $0.model != nil }.map(\.id) == ["u1"])
    }

    // MARK: - The routes, over a real socket

    /// Every new route reaches the host it is supposed to, with the parameters out of its
    /// path — and `POST .../messages` answers 202 rather than 200, because the turn was
    /// accepted and not answered.
    @Test func everyRouteReachesTheHostWithItsParameters() async throws {
        try await withAgentServer { fixture in
            let phone = try await fixture.pair()
            await AgentCallLog.shared.clear()

            #expect(try await fixture.phone.status(
                "GET", "/agent/sessions", token: phone.token
            ) == 200)
            #expect(try await fixture.phone.status(
                "GET", "/agent/sessions/codex?since=12", token: phone.token
            ) == 200)
            #expect(try await fixture.phone.status(
                "POST", "/agent/sessions/codex/start", token: phone.token, body: "{}"
            ) == 200)
            #expect(try await fixture.phone.status(
                "POST", "/agent/sessions/pi/new", token: phone.token, body: "{}"
            ) == 200)
            #expect(try await fixture.phone.status(
                "POST", "/agent/sessions/codex/interrupt", token: phone.token, body: "{}"
            ) == 200)
            #expect(try await fixture.phone.status(
                "DELETE", "/agent/sessions/pi", token: phone.token
            ) == 200)

            let (sent, body) = try await fixture.phone.call(
                "POST", "/agent/sessions/codex/messages", token: phone.token,
                body: #"{"text":"Fix the failing test.","model":"local/qwen3"}"#
            )
            #expect(sent == 202)
            #expect(try JSONDecoder().decode(
                ControlAPI.AgentMessageAccepted.self, from: body
            ).itemID == AgentCallLog.acceptedItemID)

            #expect(try await fixture.phone.status(
                "POST", "/agent/sessions/codex/approvals/appr-1", token: phone.token,
                body: #"{"decision":"decline"}"#
            ) == 200)

            #expect(await AgentCallLog.shared.calls == [
                "sessions",
                "session codex since=12",
                "start codex",
                "new pi",
                "interrupt codex",
                "stop pi",
                "send codex text=Fix the failing test. model=local/qwen3",
                "answer codex appr-1 decline",
            ])

            // An engine this Mac does not run is a 404 with a sentence, not a route that
            // quietly matched nothing.
            let (missing, refusal) = try await fixture.phone.call(
                "GET", "/agent/sessions/claude", token: phone.token
            )
            #expect(missing == 404)
            #expect(String(decoding: refusal, as: UTF8.self).contains("codex and pi"))
        }
    }

    /// The gate, on every one of them: full control only, never a chat-only phone, never a
    /// peer, never an unauthenticated caller.
    @Test func theAgentRoutesAreFullScopeAndNeverThePeers() async throws {
        try await withAgentServer(swarmToken: Self.swarmSecret) { fixture in
            let full = try await fixture.pair(name: "Studio phone")
            let chat = try await fixture.pair(name: "Lent out", scope: .chat)

            for (method, path, body) in Self.everyAgentRoute {
                // A phone paired for chat is refused by the scope gate before the path is
                // ever looked at — the same 403 it gets for POST /load.
                let refusedForChat = try await fixture.phone.call(
                    method, path, token: chat.token, body: body
                )
                #expect(refusedForChat.0 == 403, "\(method) \(path)")
                #expect(
                    String(decoding: refusedForChat.1, as: UTF8.self)
                        .contains("paired for chat only"),
                    "\(method) \(path)"
                )

                // The swarm secret is a credential everywhere else on this server. A node
                // is a machine with a token in a config file, and these routes run
                // commands here.
                let refusedForPeers = try await fixture.local.call(
                    method, path, token: Self.swarmSecret, body: body
                )
                #expect(refusedForPeers.0 == 403, "\(method) \(path)")
                #expect(
                    String(decoding: refusedForPeers.1, as: UTF8.self)
                        .contains("swarm node"),
                    "\(method) \(path)"
                )

                // No token at all, and a token that is not one.
                #expect(try await fixture.phone.status(
                    method, path, token: nil, body: body
                ) == 401, "\(method) \(path)")
                #expect(try await fixture.phone.status(
                    method, path, token: "guessed", body: body
                ) == 401, "\(method) \(path)")

                // And the two credentials that do pass: a full-control phone out on the
                // tailnet, and this Mac's own token on its own listener.
                #expect(try await fixture.phone.status(
                    method, path, token: full.token, body: body
                ) != 403, "\(method) \(path)")
                #expect(try await fixture.local.status(
                    method, path, token: fixture.local.token, body: body
                ) != 403, "\(method) \(path)")
            }
        }
    }

    // MARK: - The race

    /// The one that matters: the owner answers an approval at the Mac, the phone's tap is
    /// already in flight, and the runtime must be told exactly once.
    ///
    /// `forwardedAnswers` counts every time a device's answer is forwarded to a runtime —
    /// `CodexRuntime.respond`, or Pi's `extension_ui_response` — and
    /// `answerAgentApproval` is the only path a device has to either. A change that let
    /// the second answer through moves that number, and this fails.
    @Test func anApprovalAnsweredAtTheMacIsNeverForwardedTwice() async throws {
        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        model.codexState = .ready(endpoint: URL(string: "codex://app-server")!)
        let approval = CodexApproval(rpcID: .number(7), kind: .command("rm -rf build"))
        model.codexApprovals = [approval]

        // The phone has seen the card and is about to answer it.
        let waiting = try await model.agentSession(engine: "codex", since: nil)
        #expect(waiting.approvals.map(\.id) == [approval.id.uuidString])

        // The owner gets there first.
        model.answerCodexApproval(approval, accept: true)
        #expect(model.codexApprovals.isEmpty)

        await #expect(throws: AgentSessionError.answeredOnTheMac(approval.id.uuidString)) {
            try await model.answerAgentApproval(
                engine: "codex", id: approval.id.uuidString, decision: "decline"
            )
        }
        // Nothing was sent. Not "sent and ignored" — not sent.
        #expect(BuddyAgentSessions.shared.forwardedAnswers(of: model) == 0)
    }

    /// The other way round, and the second tap after it.
    @Test func aPhonesAnswerIsForwardedOnceAndThenTheCardIsGone() async throws {
        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        model.codexState = .ready(endpoint: URL(string: "codex://app-server")!)
        let approval = CodexApproval(rpcID: .number(7), kind: .command("swift test"))
        model.codexApprovals = [approval]
        let id = approval.id.uuidString

        let answered = try await model.answerAgentApproval(
            engine: "codex", id: id, decision: "accept"
        )
        #expect(answered.decision == "accepted")
        #expect(answered.session.pendingApprovals == 0)
        #expect(BuddyAgentSessions.shared.forwardedAnswers(of: model) == 1)
        // The card goes at once, on the Mac as well: a decision has been made, and a card
        // still on screen would be a lie about what is still pending.
        #expect(model.codexApprovals.isEmpty)

        // A second tap — a retry on a bad connection, a stale screen. Not 409: the Mac did
        // not answer this, the last request did, and nothing else was decided here.
        await #expect(throws: AgentSessionError.unknownApproval(id)) {
            try await model.answerAgentApproval(engine: "codex", id: id, decision: "accept")
        }
        #expect(BuddyAgentSessions.shared.forwardedAnswers(of: model) == 1)

        // A decision that is not one never reaches the approval at all.
        await #expect(throws: AgentSessionError.unknownDecision("maybe")) {
            try await model.answerAgentApproval(engine: "codex", id: id, decision: "maybe")
        }
        #expect(BuddyAgentSessions.shared.forwardedAnswers(of: model) == 1)
    }

    /// A card that goes away without anybody answering it — a stopped engine, a restart, a
    /// sidecar that died. Nothing will run, so the phone's card comes down saying
    /// `declined`; but nobody answered first, so a tap that lands afterwards is a 404 and
    /// not a 409 about a decision that was never made.
    @Test func anApprovalTheEngineTookWithItIsGoneRatherThanAnswered() async throws {
        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        model.codexState = .ready(endpoint: URL(string: "codex://app-server")!)
        let approval = CodexApproval(rpcID: .number(9), kind: .command("swift build"))
        model.codexApprovals = [approval]
        let id = approval.id.uuidString
        _ = Self.settle(model, engine: "codex")

        // What `handleCodexEvent(.terminated)` does when the sidecar exits under a turn.
        model.codexApprovals.removeAll()
        model.codexTurnActive = false
        #expect(Self.states(Self.settle(model, engine: "codex")) == ["declined"])

        await #expect(throws: AgentSessionError.unknownApproval(id)) {
            try await model.answerAgentApproval(engine: "codex", id: id, decision: "accept")
        }
        #expect(BuddyAgentSessions.shared.forwardedAnswers(of: model) == 0)
    }

    /// Pi's half of the same rule. Its cards stay in the transcript once answered, so the
    /// race is detected differently and has to come out the same.
    @Test func piApprovalsFollowTheSameRule() async throws {
        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        model.piState = .ready
        let card = AppModel.PiItem(
            kind: .approval(requestID: "ui-1", tool: "bash"),
            text: #"{"command":"rm -rf build"}"#, running: true
        )
        model.piItems = [card]
        let id = card.id.uuidString

        _ = try await model.agentSession(engine: "pi", since: nil)
        model.answerPiApproval(card, allow: false)

        await #expect(throws: AgentSessionError.answeredOnTheMac(id)) {
            try await model.answerAgentApproval(engine: "pi", id: id, decision: "accept")
        }
        #expect(BuddyAgentSessions.shared.forwardedAnswers(of: model) == 0)
    }

    // MARK: - Catching up

    /// A phone that lost its stream asks for what it missed, and gets that and nothing
    /// else — by sequence or by the id of the last row it actually has.
    @Test func sinceHandsBackOnlyWhatAPhoneHasNotSeen() async throws {
        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        model.codexState = .ready(endpoint: URL(string: "codex://app-server")!)
        model.codexItems = [CodexChatItem(id: "a1", kind: .assistant("First."))]

        let first = try await model.agentSession(engine: "codex", since: nil)
        #expect(first.items.map(\.id) == ["a1"])
        #expect(first.complete)

        model.codexItems.append(CodexChatItem(id: "a2", kind: .assistant("Second.")))
        let caught = try await model.agentSession(
            engine: "codex", since: String(first.seq)
        )
        #expect(caught.items.map(\.id) == ["a2"])
        #expect(caught.complete == false)
        #expect(caught.seq > first.seq)

        // An id works as well as a number, which is what a phone has after a plain GET.
        let byID = try await model.agentSession(engine: "codex", since: "a1")
        #expect(byID.items.map(\.id) == ["a2"])

        // A row that changes is newer again — text that grew while the phone was away is
        // not "already seen" because its id is.
        model.codexItems[0].kind = .assistant("First, revised.")
        let revised = try await model.agentSession(
            engine: "codex", since: String(caught.seq)
        )
        #expect(revised.items.map(\.id) == ["a1"])
        #expect(revised.items.first?.text == "First, revised.")

        // Nothing moved since: an empty slice, not the transcript again.
        let quiet = try await model.agentSession(
            engine: "codex", since: String(revised.seq)
        )
        #expect(quiet.items.isEmpty)
        #expect(quiet.complete == false)

        // A sequence this session never reached, and an id it does not know, are both a
        // caller asking to continue from nowhere. The honest answer is the whole
        // transcript, and `complete` is how it says so rather than leaving a silent gap.
        for nonsense in ["99999", "no-such-item", "-4"] {
            let whole = try await model.agentSession(engine: "codex", since: nonsense)
            #expect(whole.items.map(\.id) == ["a1", "a2"], "since=\(nonsense)")
            #expect(whole.complete, "since=\(nonsense)")
        }

        // And a new thread is the same situation: what came before cannot be caught up,
        // only replaced.
        let beforeTheNewThread = try await model.agentSession(engine: "codex", since: nil)
        model.newCodexThread()
        model.codexItems = [CodexChatItem(id: "b1", kind: .assistant("Fresh."))]
        let afterwards = try await model.agentSession(
            engine: "codex", since: String(beforeTheNewThread.seq)
        )
        #expect(afterwards.items.map(\.id) == ["b1"])
        #expect(afterwards.complete)
    }

    // MARK: - Frames

    /// A model writing a hundred tokens a second must not become a hundred frames a second.
    ///
    /// The rule is the sampling, so this is what it looks like: the ledger is reconciled as
    /// often as anything asks — routes do, constantly — and the watcher emits one frame per
    /// row per reading. Twenty deltas between two readings are one frame carrying the row
    /// whole, which is also why a phone that misses one has missed nothing.
    @Test func streamedProseIsCoalescedIntoOneFramePerReading() throws {
        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        model.codexState = .ready(endpoint: URL(string: "codex://app-server")!)
        model.codexItems = [CodexChatItem(id: "a1", kind: .assistant(""))]

        // The first reading is the opening one: state and turn, so a phone that has just
        // connected has something true before any delta means anything.
        let opening = try #require(model.agentSnapshot(engine: "codex"))
        BuddyAgentSessions.shared.reconcile(opening)
        let first = BuddyAgentSessions.shared.frames(from: opening)
        #expect(Self.kinds(first) == ["state", "turn"])

        var text = ""
        for token in ["Start ", "in ", "Alfama, ", "early."] {
            text += token
            model.codexItems[0].kind = .assistant(text)
            // Every route that touches this engine reconciles; none of them posts.
            BuddyAgentSessions.shared.reconcile(
                try #require(model.agentSnapshot(engine: "codex"))
            )
        }

        let sampled = try #require(model.agentSnapshot(engine: "codex"))
        BuddyAgentSessions.shared.reconcile(sampled)
        let frames = BuddyAgentSessions.shared.frames(from: sampled)
        #expect(Self.kinds(frames) == ["item"])
        guard case .agent(let event) = frames[0] else {
            Issue.record("expected an agent frame")
            return
        }
        // The row whole, not the last delta.
        #expect(event.item?.text == "Start in Alfama, early.")
        #expect(event.item?.id == "a1")
        // And the sampling rate is the promise: ten readings a second, per engine.
        #expect(AgentEventPump.interval == .milliseconds(100))

        // Nothing moved: nothing said.
        BuddyAgentSessions.shared.reconcile(sampled)
        #expect(BuddyAgentSessions.shared.frames(from: sampled).isEmpty)
    }

    /// The Mac's own doing, on the phone: the owner's send, the owner's approval, the
    /// turn starting and ending.
    @Test func whatTheOwnerDoesAtTheMacBecomesFramesToo() throws {
        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        model.codexState = .ready(endpoint: URL(string: "codex://app-server")!)
        _ = Self.settle(model, engine: "codex")

        // The owner types into the Mac's own window.
        model.codexItems.append(CodexChatItem(id: "u1", kind: .user("Fix the test.")))
        model.codexTurnActive = true
        let typed = Self.settle(model, engine: "codex")
        #expect(Self.kinds(typed) == ["turn", "item"])

        // Codex asks, and the card appears on both screens.
        let approval = CodexApproval(rpcID: .number(7), kind: .command("swift test"))
        model.codexApprovals = [approval]
        let asked = Self.settle(model, engine: "codex")
        #expect(Self.kinds(asked) == ["approval"])
        #expect(Self.states(asked) == ["pending"])

        // The owner answers it at the Mac. The phone's card has to go away by itself, and
        // say which way it went — that frame is the whole of "answered on either side
        // resolves on both".
        model.answerCodexApproval(approval, accept: true)
        let answered = Self.settle(model, engine: "codex")
        #expect(Self.kinds(answered) == ["approval"])
        #expect(Self.states(answered) == ["accepted"])

        // A declined one says so too, rather than both ending as "gone".
        let second = CodexApproval(rpcID: .number(8), kind: .command("rm -rf build"))
        model.codexApprovals = [second]
        _ = Self.settle(model, engine: "codex")
        model.answerCodexApproval(second, accept: false)
        #expect(Self.states(Self.settle(model, engine: "codex")) == ["declined"])

        // And the engine going down is one frame, not a silence a phone has to time out on.
        model.codexTurnActive = false
        model.codexState = .failed(message: "Codex exited unexpectedly.")
        let died = Self.settle(model, engine: "codex")
        #expect(Self.kinds(died) == ["state", "turn"])
        #expect(Self.states(died) == ["failed"])
    }

    // MARK: - What a phone may not do

    /// The folder is the owner's to pick. A device that could name one could name any
    /// folder on this Mac — and Codex is trusted inside whatever it is given.
    @Test func aPhoneMayDriveCodexButNotChooseWhereItRuns() async throws {
        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        #expect(model.hasExplicitCodexWorkingDirectory == false)

        await #expect(throws: AgentSessionError.noWorkingDirectory) {
            try await model.startAgentSession(engine: "codex")
        }
        // Nothing was started, and the reason says where to go rather than what to send.
        #expect(model.codexState == .idle)
        #expect(AgentSessionError.workingDirectoryIsTheMacsToPick.contains("on the Mac"))

        // The session is still listed while it is stopped — a phone that cannot see it
        // cannot offer to start it — and it carries a model list to pick from.
        let sessions = await model.agentSessions()
        #expect(sessions.sessions.map(\.engine) == ControlAPI.agentEngines)
        #expect(sessions.sessions.allSatisfy { $0.state == "stopped" })
        #expect(sessions.sessions.allSatisfy { !$0.cwd.isEmpty })
    }

    /// A model that is not on the list is refused before the engine is asked, rather than
    /// a turn quietly answered by a different model than the one on screen.
    @Test func aTurnCannotBeSentWithAModelThisSessionDoesNotHave() async throws {
        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        model.codexState = .ready(endpoint: URL(string: "codex://app-server")!)

        await #expect(throws: AgentSessionError.unknownModel("gpt-5")) {
            try await model.sendAgentMessage(
                engine: "codex", .init(text: "Hello", model: "gpt-5")
            )
        }
        await #expect(throws: AgentSessionError.emptyMessage) {
            try await model.sendAgentMessage(engine: "codex", .init(text: "   \n "))
        }
        // Nothing reached the transcript on either refusal.
        #expect(model.codexItems.isEmpty)

        // And a stopped engine is a 409 that says how to start it, not a silent nothing.
        model.codexState = .idle
        await #expect(throws: AgentSessionError.notRunning("codex")) {
            try await model.sendAgentMessage(engine: "codex", .init(text: "Hello"))
        }
        await #expect(throws: AgentSessionError.unknownEngine("claude")) {
            try await model.sendAgentMessage(engine: "claude", .init(text: "Hello"))
        }
    }

    /// An engine that says it is running but whose sidecar has gone underneath it drops the
    /// message. Handing back the id of the row that happened to be last would tell a phone
    /// its turn was accepted and point it at somebody else's row.
    @Test func aSendThatReachedNothingIsRefusedRatherThanGivenSomebodyElsesRow() async throws {
        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        // Ready, and no runtime behind it: `sendPiMessage` has nothing to send to.
        model.piState = .ready
        model.piItems = [AppModel.PiItem(kind: .assistant, text: "Earlier.")]

        await #expect(throws: AgentSessionError.notRunning("pi")) {
            try await model.sendAgentMessage(engine: "pi", .init(text: "Hello"))
        }
        #expect(model.piItems.count == 1)
    }

    /// A new thread from the phone is the Mac's own New Thread: the transcript it clears is
    /// the one on screen, and the session it hands back is the one both sides now have.
    @Test func aNewThreadFromThePhoneIsTheMacsOwnNewThread() async throws {
        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        model.codexState = .ready(endpoint: URL(string: "codex://app-server")!)
        model.codexThreadID = "th_01HZY"
        model.codexItems = [CodexChatItem(id: "a1", kind: .assistant("Earlier."))]
        model.codexApprovals = [CodexApproval(rpcID: .number(1), kind: .command("ls"))]
        model.codexTurnActive = true

        let fresh = try await model.newAgentThread(engine: "codex")
        #expect(fresh.itemCount == 0)
        #expect(fresh.threadID == nil)
        #expect(fresh.turnActive == false)
        #expect(fresh.pendingApprovals == 0)
        // The Mac's own window, not a copy of it.
        #expect(model.codexItems.isEmpty)

        // Pi's is a real RPC command rather than a restart, so it needs a Pi to send it to.
        model.piState = .ready
        await #expect(throws: AgentSessionError.notRunning("pi")) {
            try await model.newAgentThread(engine: "pi")
        }
    }

    // MARK: - The badge

    /// What the Chat tab's badge counts, and what it does not.
    @Test func onlyAFullControlDeviceLightsTheWatchingBadge() async throws {
        let hub = BuddyEventHub()
        let mac = await hub.subscribe()
        #expect(await hub.watchingDeviceCount == 0)

        let chatOnly = await hub.subscribe(scope: .chat)
        // A chat-only phone reading `/events` cannot reach an agent session at all, so
        // telling the owner one is watching *this* would be stronger than the truth.
        #expect(await hub.watchingDeviceCount == 0)

        let phone = await hub.subscribe(scope: .full)
        #expect(await hub.watchingDeviceCount == 1)
        #expect(await hub.subscriberCount == 3)
        #expect(BuddyWatchingBadge.caption(1) == "Silicon Buddy is watching")

        let tablet = await hub.subscribe(scope: .full)
        #expect(await hub.watchingDeviceCount == 2)
        #expect(BuddyWatchingBadge.caption(2).contains("2 Silicon Buddies"))

        await hub.cancel(tablet.id)
        await hub.cancel(phone.id)
        #expect(await hub.watchingDeviceCount == 0)
        await hub.cancel(chatOnly.id)
        await hub.cancel(mac.id)
    }

    // MARK: - Fixtures

    /// A placeholder, never a real one: this string ends up in nothing but a refusal.
    static let swarmSecret = "swarm-secret-for-the-fixture"

    /// One Codex turn, exactly as its app-server writes it. Recorded from what
    /// `handleCodexNotification` already reads, not from running the CLI.
    static let codexTurn: [(String, String)] = [
        ("thread/started", #"{"thread":{"id":"th_01HZY"}}"#),
        ("turn/started", #"{}"#),
        ("item/started", #"{"item":{"id":"item_msg_1","type":"agentMessage","text":""}}"#),
        ("item/agentMessage/delta", #"{"itemId":"item_msg_1","delta":"Running "}"#),
        ("item/agentMessage/delta", #"{"itemId":"item_msg_1","delta":"the suite."}"#),
        ("item/started", #"{"item":{"id":"item_reason_1","type":"reasoning","summary":""}}"#),
        (
            "item/reasoning/summaryTextDelta",
            #"{"itemId":"item_reason_1","delta":"Check the tests first."}"#
        ),
        (
            "item/started",
            #"""
            {"item":{"id":"item_cmd_1","type":"commandExecution",
            "command":"swift test --filter Lisbon","aggregatedOutput":""}}
            """#
        ),
        (
            "item/commandExecution/outputDelta",
            #"{"itemId":"item_cmd_1","delta":"1 test failed: itineraryFitsInThreeDays\n"}"#
        ),
        (
            "item/completed",
            #"""
            {"item":{"id":"item_cmd_1","type":"commandExecution",
            "command":"swift test --filter Lisbon",
            "aggregatedOutput":"1 test failed: itineraryFitsInThreeDays\n"}}
            """#
        ),
        (
            "item/completed",
            #"""
            {"item":{"id":"item_patch_1","type":"fileChange",
            "changes":[{"path":"Sources/Lisbon/Itinerary.swift"}]}}
            """#
        ),
        (
            "item/completed",
            #"""
            {"item":{"id":"item_tool_1","type":"mcpToolCall",
            "server":"silicon-optimizer","tool":"generate_image"}}
            """#
        ),
        (
            "item/completed",
            #"{"item":{"id":"item_web_1","type":"webSearch","query":"lisbon tram 28"}}"#
        ),
        (
            "item/completed",
            #"""
            {"item":{"id":"item_err_1","type":"error",
            "message":"The model stopped mid-turn."}}
            """#
        ),
        ("turn/completed", #"{"turn":{}}"#),
    ]

    /// The same turn as Pi's RPC reports it. Nothing here looks like the list above, which
    /// is the reason both are normalised at all.
    static let piTurn: [String] = [
        #"{"type":"agent_start"}"#,
        #"{"type":"message_start","message":{"role":"assistant"}}"#,
        #"""
        {"type":"message_update","assistantMessageEvent":
        {"type":"thinking_delta","delta":"Check the tests first."}}
        """#,
        #"""
        {"type":"message_update","assistantMessageEvent":
        {"type":"text_delta","delta":"Running "}}
        """#,
        #"""
        {"type":"message_update","assistantMessageEvent":
        {"type":"text_delta","delta":"the suite."}}
        """#,
        #"""
        {"type":"message_update","assistantMessageEvent":{"type":"toolcall_end",
        "toolCall":{"id":"call_1","name":"bash",
        "arguments":{"command":"swift test --filter Lisbon"}}}}
        """#,
        #"""
        {"type":"tool_execution_end","toolName":"bash","result":{"content":
        [{"type":"text","text":"1 test failed: itineraryFitsInThreeDays"}]}}
        """#,
        #"""
        {"type":"message_end","message":{"role":"assistant","content":
        [{"type":"text","text":"Running the suite."}]}}
        """#,
        #"{"type":"agent_end"}"#,
    ]

    /// Every route this milestone adds, with a body where one is needed — so the scope test
    /// covers all of them rather than a representative sample.
    static let everyAgentRoute: [(String, String, String?)] = [
        ("GET", "/agent/sessions", nil),
        ("GET", "/agent/sessions/codex", nil),
        ("DELETE", "/agent/sessions/codex", nil),
        ("POST", "/agent/sessions/codex/start", "{}"),
        ("POST", "/agent/sessions/codex/new", "{}"),
        ("POST", "/agent/sessions/codex/interrupt", "{}"),
        ("POST", "/agent/sessions/codex/messages", #"{"text":"hello"}"#),
        ("POST", "/agent/sessions/codex/approvals/appr-1", #"{"decision":"accept"}"#),
    ]

    static func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    static func object(_ text: String) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }

    /// One reading of an engine, reconciled and turned into frames — what the watcher does
    /// on each tick, without the clock.
    static func settle(_ model: AppModel, engine: String) -> [BuddyEvent] {
        guard let snapshot = model.agentSnapshot(engine: engine) else { return [] }
        BuddyAgentSessions.shared.reconcile(snapshot)
        return BuddyAgentSessions.shared.frames(from: snapshot)
    }

    static func kinds(_ events: [BuddyEvent]) -> [String] {
        events.compactMap {
            guard case .agent(let event) = $0 else { return nil }
            return event.kind
        }
    }

    static func states(_ events: [BuddyEvent]) -> [String] {
        events.compactMap {
            guard case .agent(let event) = $0 else { return nil }
            return event.state
        }
    }

}

/// The one agent test that opens a real `/events` stream, and so the one that has to share
/// a suite with the other live one.
///
/// `BuddyEventPump` and `AgentEventPump` are process-wide singletons — `AppModel` is
/// `@Observable`, so an extension cannot hold their task — and a singleton watches one hub.
/// Two suites each opening a stream against their own hub would take the pumps off each
/// other, and whichever lost would wait for frames that were being posted somewhere else.
/// `BuddyLiveEventTests` is `.serialized` for exactly that reason, so this joins it rather
/// than racing it.
extension BuddyLiveEventTests {

    /// The whole chain once: a real `AppModel` as the host, a real control server, a real
    /// socket, and a phone's token — so the agent routes are proved to dispatch to the app
    /// rather than to the protocol's "this host runs no agents" default.
    @Test func aPhoneSeesTheMacsOwnSessionsOverTheWire() async throws {
        AgentEventPump.shared.stop()
        BuddyEventPump.shared.stop()
        defer {
            AgentEventPump.shared.stop()
            BuddyEventPump.shared.stop()
        }

        let model = AppModel(settings: .init())
        BuddyAgentSessions.shared.forget(model)
        model.codexState = .ready(endpoint: URL(string: "codex://app-server")!)
        model.codexItems = [CodexChatItem(id: "a1", kind: .assistant("Ready."))]

        try await withServer(host: model) { fixture in
            let phone = try await fixture.pair()
            let (status, body) = try await fixture.phone.call(
                "GET", "/agent/sessions", token: phone.token
            )
            #expect(status == 200)
            let list = try JSONDecoder().decode(ControlAPI.AgentSessionList.self, from: body)
            #expect(list.sessions.map(\.engine) == ControlAPI.agentEngines)
            let codex = try #require(list.sessions.first { $0.engine == "codex" })
            #expect(codex.state == "running")
            #expect(codex.itemCount == 1)

            let (detailStatus, detailBody) = try await fixture.phone.call(
                "GET", "/agent/sessions/codex", token: phone.token
            )
            #expect(detailStatus == 200)
            let detail = try JSONDecoder().decode(
                ControlAPI.AgentSessionDetail.self, from: detailBody
            )
            #expect(detail.items.map(\.text) == ["Ready."])

            // And the frames reach a subscriber, which is the wiring `beginEventUpdates`
            // is responsible for: a change made while the stream is open, not a snapshot
            // taken at connect.
            let changing = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                model.codexItems.append(
                    CodexChatItem(id: "a2", kind: .assistant("Working on it."))
                )
            }
            defer { changing.cancel() }

            let frames = try await fixture.phone.events(
                "GET", "/events", token: phone.token, body: nil,
                until: { frames in
                    frames.contains { $0.name == "agent" && $0.data.contains("a2") }
                }
            )
            let agent = try #require(
                frames.last { $0.name == "agent" && $0.data.contains("a2") }
            )
            let event = try JSONDecoder().decode(
                ControlAPI.AgentEvent.self, from: Data(agent.data.utf8)
            )
            #expect(event.engine == "codex")
            #expect(event.kind == "item")
            #expect(event.item?.text == "Working on it.")
            #expect(event.seq > 0)
        }
    }

}

// MARK: - The fixture

// At file scope rather than inside the suite: the live half of these tests lives in
// `BuddyLiveEventTests` (see the extension at the bottom of this file) and needs the same
// loopback server, the same private handshake file and the same standing-in-for-a-tailnet
// second listener.

struct AgentFixture {
    let server: ControlServer
    let local: TestClient
    let phone: TestClient
    let registry: BuddyRegistry

    func pair(
        name: String = "Galaxy S24 Ultra", scope: BuddyScope = .full
    ) async throws -> ControlAPI.BuddyPairResponse {
        let invitation = await registry.invite(
            host: "127.0.0.1", port: phone.port, scope: scope
        )
        let (status, body) = try await phone.call(
            "POST", "/buddy/pair", token: nil,
            body: #"{"code":"\#(invitation.code)","deviceName":"\#(name)","platform":"android"}"#
        )
        #expect(status == 200)
        return try JSONDecoder().decode(ControlAPI.BuddyPairResponse.self, from: body)
    }
}

/// The recording double. `BuddyTestHost` already answers everything else a control
/// server can be asked, so the agent half is bolted onto it rather than a thirty-method
/// conformance being written out again.
@MainActor
func withAgentServer(
    swarmToken: String? = nil, _ body: (AgentFixture) async throws -> Void
) async throws {
    try await withServer(
        host: BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false),
        swarmToken: swarmToken, body
    )
}

@MainActor
func withServer(
    host: any ControlHost, swarmToken: String? = nil,
    _ body: (AgentFixture) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("buddy-agents-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let handshakeURL = directory.appendingPathComponent("control.json")
    let registry = BuddyRegistry(url: directory.appendingPathComponent("buddy.json"))
    let server = ControlServer(
        host: host, handshakeURL: handshakeURL, buddy: registry,
        events: BuddyEventHub(),
        // Never the real CLI: a test must not bind whatever tailnet this machine is on.
        discoverTailnetAddress: { nil }
    )

    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpMaximumConnectionsPerHost = 64
    configuration.timeoutIntervalForRequest = 20
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    try await server.start(swarmToken: swarmToken)
    defer { Task { await server.stop() } }
    let deadline = ContinuousClock.now + .seconds(5)
    while !FileManager.default.fileExists(atPath: handshakeURL.path) {
        guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
        try await Task.sleep(for: .milliseconds(20))
    }
    let handshake = try JSONDecoder().decode(
        ControlAPI.Handshake.self, from: try Data(contentsOf: handshakeURL)
    )
    await registry.setAllowsTailnetDevices(true)
    let tailnetPort = try await BuddyControlTests.bindTailnetListener(
        on: server, avoiding: handshake.port
    )

    try await body(AgentFixture(
        server: server,
        local: TestClient(port: handshake.port, token: handshake.token, session: session),
        phone: TestClient(port: tailnetPort, token: handshake.token, session: session),
        registry: registry
    ))
    await server.stop()
}

// MARK: - The double's agent half

/// What the fake host was asked, in order. An actor of its own because `BuddyTestHost` is
/// one and an extension cannot give it a stored property.
actor AgentCallLog {
    static let shared = AgentCallLog()

    /// The row a send is answered with, so the route test can check the body rather than
    /// only the status.
    static let acceptedItemID = "item_accepted_1"

    private(set) var calls: [String] = []

    func note(_ call: String) { calls.append(call) }
    func clear() { calls.removeAll() }
}

/// The agent half of the control-server double.
///
/// Bolted onto `BuddyTestHost` rather than written as a second thirty-method conformance:
/// it already answers everything else a control server can be asked, and the witness the
/// compiler picks for a conformance in this module is the concrete method here rather than
/// the protocol's "this host runs no agents" default.
extension BuddyTestHost {

    private func summary(_ engine: String) -> ControlAPI.AgentSessionSummary {
        ControlAPI.AgentSessionSummary(
            engine: engine, state: "running", model: "local/qwen3",
            modelChoices: [.init(id: "local/qwen3", label: "Qwen3", where: "This Mac")],
            cwd: "/tmp/fixture", updatedAt: "2026-09-19T10:00:00Z"
        )
    }

    public func agentSessions() async -> ControlAPI.AgentSessionList {
        await AgentCallLog.shared.note("sessions")
        return ControlAPI.AgentSessionList(
            sessions: ControlAPI.agentEngines.map { summary($0) }
        )
    }

    public func agentSession(
        engine: String, since: String?
    ) async throws -> ControlAPI.AgentSessionDetail {
        guard ControlAPI.agentEngines.contains(engine) else {
            throw AgentSessionError.unknownEngine(engine)
        }
        await AgentCallLog.shared.note("session \(engine) since=\(since ?? "-")")
        return ControlAPI.AgentSessionDetail(
            session: summary(engine), items: [], approvals: [], seq: 12
        )
    }

    public func startAgentSession(
        engine: String
    ) async throws -> ControlAPI.AgentSessionSummary {
        await AgentCallLog.shared.note("start \(engine)")
        return summary(engine)
    }

    public func newAgentThread(engine: String) async throws -> ControlAPI.AgentSessionSummary {
        await AgentCallLog.shared.note("new \(engine)")
        return summary(engine)
    }

    public func stopAgentSession(engine: String) async throws -> ControlAPI.AgentSessionSummary {
        await AgentCallLog.shared.note("stop \(engine)")
        return summary(engine)
    }

    public func sendAgentMessage(
        engine: String, _ request: ControlAPI.AgentMessageRequest
    ) async throws -> ControlAPI.AgentMessageAccepted {
        await AgentCallLog.shared.note(
            "send \(engine) text=\(request.text) model=\(request.model ?? "-")"
        )
        return ControlAPI.AgentMessageAccepted(itemID: AgentCallLog.acceptedItemID)
    }

    public func interruptAgentSession(
        engine: String
    ) async throws -> ControlAPI.AgentSessionSummary {
        await AgentCallLog.shared.note("interrupt \(engine)")
        return summary(engine)
    }

    public func answerAgentApproval(
        engine: String, id: String, decision: String
    ) async throws -> ControlAPI.AgentApprovalResult {
        await AgentCallLog.shared.note("answer \(engine) \(id) \(decision)")
        return ControlAPI.AgentApprovalResult(
            id: id, decision: decision == "accept" ? "accepted" : "declined",
            session: summary(engine)
        )
    }
}

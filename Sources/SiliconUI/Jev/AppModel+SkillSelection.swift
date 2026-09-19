import Foundation
import SiliconControl
import SiliconRuntime

// MARK: - Suggesting

/// The two-call skill suggestion, start to finish: ask, read, apply the policy, ask again.
///
/// Free of the app so a test can drive it against a loopback TypeSafe, and because it has no
/// business touching an engine: by the time it is called the roster has already been built and
/// the turn already trimmed. It cannot fail a turn — every path out returns a suggestion or
/// nothing, and "nothing" is a perfectly ordinary answer.
public enum SkillSelector {

    /// What one turn's selection cost and concluded, for the caller that wants to show it.
    public struct Outcome: Sendable, Equatable {
        public var suggestion: SkillSelectionPolicy.Suggestion?
        /// How many requests actually went to TypeSafe: 0 when the feature could not answer,
        /// 1 when the gate closed on the first call, 2 when the shortlist was read properly.
        public var calls: Int
        /// The names the first call shortlisted, in order.
        public var shortlist: [String]

        public init(
            suggestion: SkillSelectionPolicy.Suggestion?, calls: Int, shortlist: [String]
        ) {
            self.suggestion = suggestion
            self.calls = calls
            self.shortlist = shortlist
        }

        /// The one line that goes into the turn's system prompt, or nil when there is
        /// nothing to say — in which case the engine's prompt is left exactly as it was,
        /// byte for byte, and the model's KV cache over it survives the turn.
        public var promptBlock: String? {
            suggestion.map(SkillSelectionPolicy.promptBlock)
        }
    }

    public static func suggest(
        turn: SkillSelectionTurn,
        roster: [SkillCandidate],
        using service: JevService = .shared
    ) async -> Outcome {
        let roster = SkillCandidate.roster(roster)
        // Nothing to choose between, or nothing to choose about. Neither is worth a request,
        // and a turn with no text in it is the tool-result round trip an agent makes between
        // a person's sentences.
        guard !roster.isEmpty, !turn.turn.isEmpty else {
            return Outcome(suggestion: nil, calls: 0, shortlist: [])
        }
        // Off, no key, or the month's budget is spent. Not an error: the owner decided this.
        guard await service.isAvailable(.skillSelection) else {
            return Outcome(suggestion: nil, calls: 0, shortlist: [])
        }

        let wideResponse: ControlAPI.DecideResponse
        do {
            wideResponse = try await SkillSelectionQuestions.askWide(
                turn, roster: roster, using: service
            )
        } catch {
            return Outcome(suggestion: nil, calls: 0, shortlist: [])
        }
        let wide = SkillSelectionAnswers.Wide.read(from: wideResponse)
        let shortlist = SkillSelectionPolicy.shortlist(wide, roster: roster)
        guard !shortlist.isEmpty else {
            // The gate closed, or the choice declined. One call, and the right answer is a
            // sentence saying nothing here fits — which is not the same as saying nothing.
            return Outcome(suggestion: nil, calls: 1, shortlist: [])
        }

        let closeResponse: ControlAPI.DecideResponse
        do {
            closeResponse = try await SkillSelectionQuestions.askShortlist(
                turn, shortlist: shortlist, using: service
            )
        } catch {
            // The ranking on its own is the thing this design exists not to trust, so a
            // second call that did not happen suggests nothing.
            return Outcome(
                suggestion: nil, calls: 1, shortlist: shortlist.map(\.name)
            )
        }
        let close = SkillSelectionAnswers.Close.read(
            from: closeResponse, shortlist: shortlist
        )
        return Outcome(
            suggestion: SkillSelectionPolicy.suggest(
                wide: wide, roster: roster, close: close
            ),
            calls: 2,
            shortlist: shortlist.map(\.name)
        )
    }
}

// MARK: - Pruning

/// One request's pruning, start to finish. Same shape as `SkillSelector` and for the same
/// reasons: free of the app, and unable to fail the request it is about.
public enum ContextPruner {

    public static func prune(
        body: Data,
        contextWindow: Int,
        aboveFraction: Double,
        using service: JevService = .shared
    ) async -> GatewayPruning? {
        guard let plan = ContextPruning.plan(
            body: body, contextWindow: contextWindow, aboveFraction: aboveFraction
        ) else { return nil }
        // No user turn means nothing to judge "still needed" against, and the question would
        // be answered on the system prompt — the one piece of text most likely to be the
        // same every turn and to contain somebody's private preamble.
        guard let turn = ContextPruning.latestUserTurn(inBody: body) else { return nil }
        guard await service.isAvailable(.skillSelection) else { return nil }

        let response: ControlAPI.DecideResponse
        do {
            response = try await ContextPruning.ask(
                latestTurn: turn, candidates: plan.candidates, using: service
            )
        } catch {
            // TypeSafe down, a 429 that outlasted its retries, a budget that ran out between
            // the check and the call. The request goes out whole, which is what it would
            // have done anyway.
            return nil
        }

        let dropped = ContextPruning.dropped(from: response, candidates: plan.candidates)
        guard !dropped.isEmpty else { return nil }
        return GatewayPruning(
            body: ContextPruning.applying(dropped, to: body, candidates: plan.candidates),
            droppedSteps: dropped,
            reason: "dropped \(dropped.count) of \(plan.toolResultCount) tool results "
                + "(steps \(dropped.map(String.init).joined(separator: ", "))) — the prompt "
                + "was about \(plan.estimatedPromptTokens) tokens of a "
                + "\(plan.contextWindow)-token window"
        )
    }
}

// MARK: - The app's end

extension AppModel {

    // MARK: GatewayHost

    /// Offers one chat request for pruning, once the model that will answer it is known.
    ///
    /// Four gates before anything is asked, in the order that makes the common case free:
    /// the target has to be running on hardware the owner owns, the owner has to have asked
    /// for this, the model's window has to be known, and the prompt has to be crowding it.
    public func gatewayPrune(modelID: String, body: Data) async -> GatewayPruning? {
        await gatewayPrune(modelID: modelID, body: body, using: .shared)
    }

    /// `using` is the seam a test points at a loopback server instead of TypeSafe.
    func gatewayPrune(
        modelID: String, body: Data, using service: JevService
    ) async -> GatewayPruning? {
        let settings = await service.settings()
        let window = gatewayContextWindow(of: modelID)
        guard Self.shouldConsiderPruning(
            modelID: modelID, pruneToolHistory: settings.pruneToolHistory,
            contextWindow: window
        ), let window else { return nil }
        return await ContextPruner.prune(
            body: body, contextWindow: window,
            aboveFraction: settings.pruneAboveFraction,
            using: service
        )
    }

    /// The three things code knows before anything is asked, as one predicate.
    ///
    /// Pure and separate so the gates can be checked on their own, without a model library
    /// behind them — and so that none of them can be removed without a test noticing, which
    /// is not true of three `guard`s that all happen to return nil.
    ///
    /// - The target must run on hardware the owner owns. A cloud model's window is large,
    ///   its history is what the bill is for, and quietly sending a provider less than the
    ///   client wrote is not this app's call to make. The gateway checks this too, before it
    ///   ever crosses to the main actor; this is the second lock on the same door, the same
    ///   arrangement `gatewayRoute` has for the virtual model id.
    /// - The owner must have asked for it. Off is the default.
    /// - The window has to be known. A node model that is not serving yet reports none, and
    ///   an unknown window is not a window to measure a fraction of.
    static func shouldConsiderPruning(
        modelID: String, pruneToolHistory: Bool, contextWindow: Int?
    ) -> Bool {
        GatewayAPI.isPrunableTarget(modelID) && pruneToolHistory && contextWindow != nil
    }

    /// The target model's context window, as the gateway's own model list reports it. Nil for
    /// a node model that is not serving yet, which reports none — and an unknown window is
    /// not a window to measure a fraction of.
    func gatewayContextWindow(of modelID: String) -> Int? {
        gatewayModelSnapshot().first { $0.id == modelID }?.contextWindow
    }

    // MARK: Pi

    /// One turn Pi is holding at the prompt hook.
    ///
    /// Pi's extension API has a real seam for this: `before_agent_start` fires after the user
    /// submits and before the agent loop, and what it returns replaces the system prompt for
    /// that turn. The extension this app writes into Pi's workspace uses it, and asks the Mac
    /// through `ctx.ui.input` — which in RPC mode is an `extension_ui_request` on stdout
    /// waiting for an `extension_ui_response` on stdin, the same channel the guardrail's
    /// confirm dialog uses and the only one an RPC client can answer.
    ///
    /// Unlike the guardrail, this one fails **open**: the extension carries a timeout, an
    /// answer of `cancelled` leaves the prompt alone, and a suggestion that never arrives
    /// costs nothing but the suggestion. A gate that times out into "allowed" is not a gate;
    /// a hint that times out into "no hint" is exactly right.
    struct PiSkillSuggestionRequest {
        /// The title the extension's dialog carries, matched exactly. The other half of this
        /// constant is `RELEVANCE_MARKER` in `Resources/pi-silicon/silicon.ts`.
        static let marker = "silicon.skillselect.v1"

        var requestID: String
        var turn: String
        var lastToolResult: String?
        var roster: [SkillCandidate]
    }

    /// The extension sends `{v, turn, lastToolResult, roster:[{name,kind,description}]}` as
    /// the dialog's placeholder. A payload that will not parse suggests nothing rather than
    /// suggesting something about a turn nobody read.
    static func parsePiSuggestionRequest(
        _ payload: String, requestID: String
    ) -> PiSkillSuggestionRequest {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return PiSkillSuggestionRequest(
                requestID: requestID, turn: "", lastToolResult: nil, roster: []
            )
        }
        let roster = (object["roster"] as? [[String: Any]] ?? []).compactMap {
            entry -> SkillCandidate? in
            guard let name = entry["name"] as? String else { return nil }
            let kind = SkillCandidate.Kind(rawValue: entry["kind"] as? String ?? "tool") ?? .tool
            return SkillCandidate.make(
                name: name, kind: kind,
                description: entry["description"] as? String ?? name
            )
        }
        return PiSkillSuggestionRequest(
            requestID: requestID,
            turn: object["turn"] as? String ?? "",
            lastToolResult: object["lastToolResult"] as? String,
            roster: roster
        )
    }

    /// The app's own half of the extension's `RELEVANCE_TIMEOUT_MS`.
    ///
    /// The extension gives up after twenty seconds and the turn goes ahead. Past that point
    /// an answer from here is not late, it is *wrong*: the id it quotes belongs to a dialog
    /// Pi has already resolved, and the transcript row it would annotate belongs to a turn
    /// that has already been answered. So this side stops too, at the same figure, and two
    /// Jev deadlines of `SkillSelectionQuestions.deadlineSeconds` each fit inside it with
    /// room for the round trips.
    static let piSuggestionTimeout: TimeInterval = 20

    /// Answers one held turn, and puts what was suggested into the transcript.
    ///
    /// The annotation goes on the turn the suggestion was made *about*, found by the request
    /// id stamped on it when the dialog arrived — not on whatever the newest user row happens
    /// to be when the answer lands. Those are different rows the moment somebody types again
    /// while Jev is thinking, and hanging one turn's suggestion on the next turn is a lie
    /// about what the model was told.
    ///
    /// A notice row says it out loud as well, because a suggestion that changed the system
    /// prompt and left no trace is the kind of help nobody can audit. Neither row is written
    /// when there is nothing to suggest, or when this gave up.
    func suggestPiTools(
        _ request: PiSkillSuggestionRequest, using service: JevService = .shared
    ) async {
        // Ordinarily already done by the event handler, synchronously, the instant the
        // dialog arrived; this covers a caller that came straight here.
        stampPiSuggestionTurn(request.requestID)

        let work = Task { [request] () -> SkillSelector.Outcome? in
            await SkillSelector.suggest(
                turn: SkillSelectionTurn(
                    turn: request.turn, lastToolResult: request.lastToolResult
                ),
                roster: request.roster,
                using: service
            )
        }
        // The same relay the streaming verdict uses, for the same reason: `await
        // work.value` does not come back early when the waiter is cancelled, so a deadline
        // has to be a mailbox both sides post to rather than a race in a task group.
        guard let outcome = await VerdictRelay.result(
            of: work, within: .seconds(Self.piSuggestionTimeout)
        ) else {
            // Pi has stopped listening, or is about to. Answering `cancelled` is what tells
            // the extension to leave the system prompt alone; nothing goes in the transcript,
            // because nothing reached the model.
            answerPiSuggestion(request.requestID, block: nil)
            return
        }

        answerPiSuggestion(request.requestID, block: outcome.promptBlock)
        guard let suggestion = outcome.suggestion else { return }
        piItems.first(where: { $0.suggestionRequestID == request.requestID })?
            .suggestion = suggestion.name
        piItems.append(PiItem(
            kind: .notice,
            text: "Jev suggests the \(suggestion.kind.rawValue) \(suggestion.name) for this "
                + "turn — \(suggestion.reason). Pi can ignore it."
        ))
    }

    /// Marks the transcript row this suggestion request is about, at the moment the request
    /// arrives rather than when its answer lands.
    ///
    /// Synchronous and called from the event handler on purpose: between the dialog arriving
    /// and the suggestion coming back, the person can type again, and then "the newest user
    /// row" is somebody else's turn. Idempotent, so calling it twice for one request is
    /// harmless.
    func stampPiSuggestionTurn(_ requestID: String) {
        guard !piItems.contains(where: { $0.suggestionRequestID == requestID }) else { return }
        piItems.last { $0.kind == .user }?.suggestionRequestID = requestID
    }

    /// Sends the answer back. An empty or absent block is `cancelled`, which the extension
    /// reads as "leave the prompt alone" — a session where this app said nothing must be a
    /// session whose system prompt is what Pi built.
    func answerPiSuggestion(_ requestID: String, block: String?) {
        guard let block, !block.isEmpty else {
            piSend(["type": "extension_ui_response", "id": requestID, "cancelled": true])
            return
        }
        piSend(["type": "extension_ui_response", "id": requestID, "value": block])
    }

    /// The last finished tool result, as one line — what `is_follow_up_to_previous_tool_result`
    /// is read against when the extension did not carry one.
    func lastPiToolResult() -> String? {
        recentPiToolResults().last
    }
}

import Foundation
import SiliconControl
import SiliconRuntime

/// One screening's outcome.
///
/// `.unavailable` is not a quiet yes. It means nothing was judged — Jev is off, there is no
/// key, the budget is spent, or the request failed — and the caller's only correct move is
/// to ask the person. Every hook in this app does that, and a new one must too.
public enum GuardrailScreening: Sendable, Equatable {

    /// Jev answered. The verdict is the policy's; the whole response is kept so a caller
    /// can look at a probability the policy only compared — through the typed accessors,
    /// which say so by name when a question is missing or answered as the wrong kind.
    case screened(
        verdict: GuardrailVerdict,
        latencyMS: Double,
        response: ControlAPI.DecideResponse,
        facts: GuardrailFacts
    )

    /// Nothing was judged, and why. Fall back to the human.
    case unavailable(reason: String)

    public var verdict: GuardrailVerdict? {
        if case .screened(let verdict, _, _, _) = self { return verdict }
        return nil
    }

    public var latencyMS: Double? {
        if case .screened(_, let latency, _, _) = self { return latency }
        return nil
    }

    /// The response Jev sent, for a caller that wants a probability rather than a verdict.
    public var response: ControlAPI.DecideResponse? {
        if case .screened(_, _, let response, _) = self { return response }
        return nil
    }

    /// What code worked out about the call before it was sent.
    public var facts: GuardrailFacts {
        if case .screened(_, _, _, let facts) = self { return facts }
        return GuardrailFacts()
    }

    public var answers: [String: ControlAPI.SystemOneAnswer] { response?.answers ?? [:] }

    public var reasons: [String] { verdict?.reasons ?? [] }

    /// Where each question landed. Empty when nothing was screened.
    public var signals: [String: GuardrailQuestions.Signal] {
        guard let response else { return [:] }
        return GuardrailPolicy.signals(for: response, facts: facts)
    }

    /// The line an approval card shows.
    public var summary: String {
        switch self {
        case .screened(let verdict, _, _, _): verdict.summary
        case .unavailable(let reason): "Jev: not screened — \(reason)"
        }
    }

    /// True only for a verdict of `.act`. Written as one property because "not blocked" and
    /// "safe" are different things, and a caller that confuses them auto-approves an
    /// unavailable screening.
    public var isSafe: Bool {
        if case .screened(.act, _, _, _) = self { return true }
        return false
    }

    public var isBlocked: Bool {
        if case .screened(.block, _, _, _) = self { return true }
        return false
    }

    /// The screening as the control API and the phones carry it.
    ///
    /// An unavailable screening is carried too, as the verdict `unavailable` with no
    /// reasons — not the reason text, which is a sentence for a person and the one place a
    /// hostname or an error string could leak into a buffer a phone can read. A log that
    /// silently omits the calls nobody screened would say the guardrail was working on a
    /// day it was not.
    public var wire: ControlAPI.GuardrailScreening {
        guard case .screened(let verdict, let latency, _, _) = self else {
            return ControlAPI.GuardrailScreening(verdict: "unavailable", reasons: [])
        }
        return ControlAPI.GuardrailScreening(
            verdict: verdict.name, reasons: verdict.reasons, latencyMS: latency
        )
    }
}

/// The guardrail, as the rest of the app uses it: one call in, one verdict out.
///
/// Main-actor because every caller is — the engines' event handlers, the approval cards —
/// and because the ring buffer below is read while drawing. The work inside is a single
/// `await` on the Jev actor, so nothing blocks the main thread while it waits.
@MainActor
public enum JevGuardrails {

    /// Which engine asked. A fixed label the app chooses, never anything the user or a model
    /// wrote — see `recentScreenings` for why that matters.
    public enum Engine: String, Sendable, CaseIterable {
        case codex
        case pi
        case harness
        case buddy
    }

    /// Screens one tool call before it runs.
    ///
    /// The parameters are the state builder's, and they are all the guardrail ever sees:
    /// the request, the call, the directory, and the last few results. Nothing reads the
    /// environment, opens a file or sends a transcript.
    /// - Parameter service: the Jev door to ask through. The app leaves it at the shared
    ///   one; a test hands over a service pointed at a loopback double.
    public static func screen(
        engine: Engine,
        request: String,
        userIntent: String? = nil,
        tool: String,
        arguments: String,
        workingDirectory: String,
        recentTranscript: [String] = [],
        protecting: [String] = [],
        autoApproveArmed: Bool = false,
        using service: JevService = .shared
    ) async -> GuardrailScreening {
        if let reason = await unavailableReason(from: service) {
            // Not recorded: the feature being off is not a screening that went wrong, and
            // a buffer full of "guardrails are off" tells nobody anything.
            return .unavailable(reason: reason)
        }

        // Off the main actor: the builder resolves paths and runs the redaction patterns,
        // which is real work on a big argument, and the caller is a view's event handler.
        let prepared = await Task.detached(priority: .userInitiated) {
            GuardrailState.prepare(
                request: request, userIntent: userIntent, tool: tool, arguments: arguments,
                workingDirectory: workingDirectory, recentTranscript: recentTranscript,
                protecting: protecting
            )
        }.value

        let started = Date()
        do {
            // One request, nine questions, through the one governed door.
            let response = try await GuardrailQuestions.ask(
                state: prepared.state, using: service
            )
            // Wall clock rather than the response's own figure: what matters to a person
            // watching an approval card is how long the app made them wait, which includes
            // the queueing and the retries.
            let latency = Date().timeIntervalSince(started) * 1_000
            let screening = GuardrailScreening.screened(
                verdict: GuardrailPolicy.verdict(
                    for: response, facts: prepared.facts, autoApproveArmed: autoApproveArmed
                ),
                latencyMS: latency,
                response: response,
                facts: prepared.facts
            )
            record(screening, engine: engine)
            return screening
        } catch {
            // Including a refusal this call raced: the settings can change between the
            // check above and the request.
            let screening = GuardrailScreening.unavailable(reason: error.localizedDescription)
            record(screening, engine: engine)
            return screening
        }
    }

    /// Whether the owner has switched the guardrail on at all — Jev enabled, this feature
    /// enabled — regardless of whether it could answer right now.
    ///
    /// Separate from `isAvailable` because the two mean different things to a caller. A
    /// guardrail that is *off* leaves its engine exactly as it was: Pi ran unattended
    /// before this existed and must keep doing so for anyone who never turned it on. A
    /// guardrail that is on but *cannot answer* is a different situation, and it falls back
    /// to the person rather than to silence.
    public static func isTurnedOn(using service: JevService = .shared) async -> Bool {
        let settings = await service.settings()
        return settings.enabled && settings.isOn(.guardrails)
    }

    /// Why a screening would not happen, or nil when it would.
    ///
    /// Asked before building the state so a disabled guardrail costs nothing, and phrased
    /// for a person: these strings end up on an approval card.
    static func unavailableReason(from service: JevService) async -> String? {
        if await DecisionRouter.router(for: service).canAnswer(.guardrails) { return nil }
        let settings = await service.settings()
        if !settings.enabled { return "Jev is off in Settings → TypeSafe (Jev)." }
        if !settings.isOn(.guardrails) {
            return "Guardrails are off in Settings → TypeSafe (Jev)."
        }
        // The two remaining conditions are deliberately not distinguished here: telling a
        // caller which one it is would mean reading the Keychain to find out, and drawing a
        // card must not put a consent dialog on screen.
        return "Jev has no key on this Mac, or this month's budget is spent."
    }

    // MARK: - What is remembered

    /// The last fifty screenings, for the UI and for `GET /jev/guardrails/recent`.
    ///
    /// Question ids, bands, the verdict and how long it took. Not the command, not the
    /// arguments, not the request, not the directory, not the tool's name — nothing a person
    /// or a model wrote. Two reasons. The commands an agent runs are the most sensitive
    /// thing this app touches, and a buffer a phone can read is the wrong place to keep them;
    /// and a screening's value in a list is the pattern — "six blocks, all `exfiltrates`" —
    /// which the ids give you and the content does not.
    ///
    /// In memory only. It is not written to disk and does not survive a relaunch.
    public private(set) static var recentScreenings: [ControlAPI.GuardrailScreeningRecord] = []

    public static let maximumRecent = 50

    /// Internal rather than private so a test can prove the cap without paying for fifty
    /// screenings to reach it.
    static func record(_ screening: GuardrailScreening, engine: Engine) {
        recentScreenings.append(ControlAPI.GuardrailScreeningRecord(
            at: ControlAPI.timestamp(Date()),
            engine: engine.rawValue,
            screening: screening.wire,
            bands: screening.signals.mapValues(\.rawValue)
        ))
        if recentScreenings.count > maximumRecent {
            recentScreenings.removeFirst(recentScreenings.count - maximumRecent)
        }
    }

    /// For the tests, and for a "clear" button if one is ever wanted.
    public static func forgetRecentScreenings() { recentScreenings.removeAll() }

    /// What `GET /jev/guardrails/recent` answers.
    public static func recent(
        using service: JevService = .shared
    ) async -> ControlAPI.GuardrailScreenings {
        ControlAPI.GuardrailScreenings(
            available: await DecisionRouter.router(for: service).canAnswer(.guardrails),
            questions: GuardrailQuestions.ID.allCases.map(\.rawValue),
            screenings: recentScreenings
        )
    }
}

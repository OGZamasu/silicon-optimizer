import Foundation
import SiliconControl
import SiliconRuntime

/// One screening's outcome.
///
/// `.unavailable` is not a quiet yes. It means nothing was judged — Jev is off, there is no
/// key, the budget is spent, or the request failed — and the caller's only correct move is
/// to ask the person. Every hook in this app does that, and a new one must too.
public enum GuardrailScreening: Sendable, Equatable {

    /// Jev answered. The verdict is the policy's; the answers are kept so a caller can look
    /// at a probability the policy only compared.
    case screened(
        verdict: GuardrailVerdict,
        latencyMS: Double,
        answers: [String: ControlAPI.SystemOneAnswer]
    )

    /// Nothing was judged, and why. Fall back to the human.
    case unavailable(reason: String)

    public var verdict: GuardrailVerdict? {
        if case .screened(let verdict, _, _) = self { return verdict }
        return nil
    }

    public var latencyMS: Double? {
        if case .screened(_, let latency, _) = self { return latency }
        return nil
    }

    public var answers: [String: ControlAPI.SystemOneAnswer] {
        if case .screened(_, _, let answers) = self { return answers }
        return [:]
    }

    public var reasons: [String] { verdict?.reasons ?? [] }

    /// Where each question landed. Empty when nothing was screened.
    public var signals: [String: GuardrailQuestions.Signal] {
        GuardrailPolicy.signals(for: answers)
    }

    /// The line an approval card shows.
    public var summary: String {
        switch self {
        case .screened(let verdict, _, _): verdict.summary
        case .unavailable(let reason): "Jev: not screened — \(reason)"
        }
    }

    /// True only for a verdict of `.act`. Written as one property because "not blocked" and
    /// "safe" are different things, and a caller that confuses them auto-approves an
    /// unavailable screening.
    public var isSafe: Bool {
        if case .screened(.act, _, _) = self { return true }
        return false
    }

    public var isBlocked: Bool {
        if case .screened(.block, _, _) = self { return true }
        return false
    }

    /// The screening as the control API and the phones carry it.
    public var wire: ControlAPI.GuardrailScreening? {
        guard case .screened(let verdict, let latency, _) = self else { return nil }
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
        using service: JevService = .shared
    ) async -> GuardrailScreening {
        if let reason = await unavailableReason(from: service) {
            return .unavailable(reason: reason)
        }

        let state = GuardrailState.make(
            request: request, userIntent: userIntent, tool: tool, arguments: arguments,
            workingDirectory: workingDirectory, recentTranscript: recentTranscript
        )

        let started = Date()
        do {
            // The same door `JevQuestionSet.ask` opens — the feature switch, the budget,
            // the cache and the ledger all apply — named explicitly because this call has a
            // service to hand rather than always the shared one.
            let response = try await service.ask(
                GuardrailQuestions.feature, state: state,
                questions: GuardrailQuestions.questions
            )
            // Wall clock rather than the response's own figure: what matters to a person
            // watching an approval card is how long the app made them wait, which includes
            // the queueing and the retries.
            let latency = Date().timeIntervalSince(started) * 1_000
            let screening = GuardrailScreening.screened(
                verdict: GuardrailPolicy.verdict(for: response.answers),
                latencyMS: latency,
                answers: response.answers
            )
            record(screening, engine: engine)
            return screening
        } catch {
            // Including a refusal this call raced: the settings can change between the
            // check above and the request.
            return .unavailable(reason: error.localizedDescription)
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
        if await service.isAvailable(.guardrails) { return nil }
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
        guard let wire = screening.wire else { return }
        recentScreenings.append(ControlAPI.GuardrailScreeningRecord(
            at: ControlAPI.timestamp(Date()),
            engine: engine.rawValue,
            screening: wire,
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
            available: await service.isAvailable(.guardrails),
            questions: GuardrailQuestions.ID.allCases.map(\.rawValue),
            screenings: recentScreenings
        )
    }
}

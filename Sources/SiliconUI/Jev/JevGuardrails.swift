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

    /// The line an approval card shows, naming who screened the call — a card saying "Jev"
    /// over a verdict Laya reached would be the Decisions panel's old mistake the other way
    /// round.
    public var summary: String {
        switch self {
        case .screened(let verdict, _, let response, _):
            guard !Self.isJevAnswer(response),
                  let lane = response.provider.flatMap(DecisionLaneID.named)
            else { return verdict.summary }
            let screener = switch lane {
            case .laya: "Laya"
            case .node: "Laya on a node"
            case .oneToken: "The loaded model"
            case .jev: "Jev"
            }
            return verdict.summary(by: screener)
        case .unavailable(let reason):
            return "Jev: not screened — \(reason)"
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

    /// Whether Jev itself screened the call — the only verdict "Auto-approve calls Jev
    /// rates safe" may act on without the person.
    ///
    /// A free lane screens calls too now: Laya when the guardrail is pinned "Always local",
    /// or when Jev is not keyed, over budget or failing under Automatic. Its verdict goes
    /// on the card for the person to weigh. Answering for them on it would turn "no key,
    /// budget spent, TypeSafe unreachable" into a silent yes, which this feature promises
    /// never to do.
    public var answeredByJev: Bool {
        guard case .screened(_, _, let response, _) = self else { return false }
        return Self.isJevAnswer(response)
    }

    /// A free lane names itself in `provider` — that is part of what a `DecisionLane`
    /// promises — so anything else came through Jev's door.
    static func isJevAnswer(_ response: ControlAPI.DecideResponse) -> Bool {
        guard let provider = response.provider,
              let lane = DecisionLaneID.named(provider)
        else { return true }
        return lane.costsMoney
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
    /// - Parameter router: which lanes may answer. Nil — what the app passes — is the
    ///   router governing `service`; a test hands over one with its own lanes registered.
    /// - Parameter log: where the screening is remembered. The app's shared log, unless a
    ///   test that counts what was remembered hands over one of its own.
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
        using service: JevService = .shared,
        router: DecisionRouter? = nil,
        log: GuardrailScreeningLog = .shared
    ) async -> GuardrailScreening {
        let router = router ?? .router(for: service)
        if let reason = await unavailableReason(from: service, router: router) {
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
            // One request, nine questions, to whichever lane the owner's pin for this
            // ability allows — Jev only through the one governed door.
            let response = try await GuardrailQuestions.ask(
                state: prepared.state, via: router
            )
            // Wall clock rather than the response's own figure: what matters to a person
            // watching an approval card is how long the app made them wait, which includes
            // the queueing and the retries.
            let latency = Date().timeIntervalSince(started) * 1_000
            // Armed only for Jev's own answer: a free lane's verdict is never acted on
            // without the person — see `GuardrailScreening.answeredByJev` — so for the
            // policy nobody is about to answer in their place.
            let armed = autoApproveArmed && GuardrailScreening.isJevAnswer(response)
            let screening = GuardrailScreening.screened(
                verdict: GuardrailPolicy.verdict(
                    for: response, facts: prepared.facts, autoApproveArmed: armed
                ),
                latencyMS: latency,
                response: response,
                facts: prepared.facts
            )
            log.record(screening, engine: engine)
            return screening
        } catch {
            // Including a refusal this call raced: the settings can change between the
            // check above and the request.
            let screening = GuardrailScreening.unavailable(reason: error.localizedDescription)
            log.record(screening, engine: engine)
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
        await service.settings().isTurnedOn(.guardrails)
    }

    /// Why a screening would not happen, or nil when it would.
    ///
    /// Asked before building the state so a disabled guardrail costs nothing, and phrased
    /// for a person: these strings end up on an approval card.
    ///
    /// The switch is asked before the lanes. A local lane answers whatever ability it is
    /// asked about, so with a model loaded the lanes alone would screen every Codex call on
    /// a guardrail nobody switched on — and off by default, off means off, is this
    /// feature's promise.
    static func unavailableReason(
        from service: JevService, router: DecisionRouter? = nil
    ) async -> String? {
        let settings = await service.settings()
        if !settings.enabled { return "Jev is off in Settings → TypeSafe (Jev)." }
        if !settings.isOn(.guardrails) {
            return "Guardrails are off in Settings → TypeSafe (Jev)."
        }
        if await (router ?? .router(for: service)).canAnswer(.guardrails) { return nil }
        switch settings.laneOverride(.guardrails) {
        case .off:
            return "Guardrails are switched off in Settings → Decisions."
        case .alwaysLocal:
            return "Guardrails are set to Always local in Settings → Decisions, and no "
                + "local lane is ready."
        case .automatic, .alwaysJev:
            // The two remaining conditions are deliberately not distinguished here: telling
            // a caller which one it is would mean reading the Keychain to find out, and
            // drawing a card must not put a consent dialog on screen.
            return "Jev has no key on this Mac, or this month's budget is spent."
        }
    }

    // MARK: - What is remembered

    /// The app's recent screenings. See `GuardrailScreeningLog`.
    public static var recentScreenings: [ControlAPI.GuardrailScreeningRecord] {
        GuardrailScreeningLog.shared.records
    }

    public static let maximumRecent = GuardrailScreeningLog.maximum

    /// Remembers a screening in the app's log, or in `log`. Internal rather than private so a
    /// test can prove the cap without paying for fifty screenings to reach it.
    static func record(
        _ screening: GuardrailScreening, engine: Engine, in log: GuardrailScreeningLog = .shared
    ) {
        log.record(screening, engine: engine)
    }

    /// For a "clear" button if one is ever wanted.
    public static func forgetRecentScreenings() { GuardrailScreeningLog.shared.forget() }

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
///
/// An instance rather than a static list so a test that counts screenings can keep its own.
/// Every engine's screenings land in the app's shared one, and a suite elsewhere screening a
/// Pi call made "nothing was remembered" fail in a suite that had screened nothing — which
/// no amount of ordering inside that suite could prevent.
@MainActor
public final class GuardrailScreeningLog {

    /// The app's.
    public static let shared = GuardrailScreeningLog()

    public static let maximum = 50

    /// Oldest first.
    public private(set) var records: [ControlAPI.GuardrailScreeningRecord] = []

    public init() {}

    func record(_ screening: GuardrailScreening, engine: JevGuardrails.Engine) {
        records.append(ControlAPI.GuardrailScreeningRecord(
            at: ControlAPI.timestamp(Date()),
            engine: engine.rawValue,
            screening: screening.wire,
            bands: screening.signals.mapValues(\.rawValue)
        ))
        if records.count > Self.maximum {
            records.removeFirst(records.count - Self.maximum)
        }
    }

    public func forget() { records.removeAll() }
}

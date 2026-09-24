import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

// MARK: - Doubles

/// A lane that answers from a fixed map of answers, and counts.
///
/// `CountingLane` answers every question with one answer, which is fine for the router's own
/// tests and useless for a feature whose policy reads nine answers of two kinds. This one
/// hands back each question's own answer, so a guardrail or a verification asked through it
/// reaches a real verdict — which is the proof that the local lane was really the one asked.
actor ScriptedLane: DecisionLane {
    nonisolated let laneID: DecisionLaneID
    private let answers: [String: ControlAPI.SystemOneAnswer]
    private(set) var calls = 0

    init(_ laneID: DecisionLaneID, answers: [String: ControlAPI.SystemOneAnswer]) {
        self.laneID = laneID
        self.answers = answers
    }

    func count() -> Int { calls }

    nonisolated func isReady() async -> Bool { true }

    nonisolated func decide(
        _ request: ControlAPI.DecideRequest
    ) async throws -> ControlAPI.DecideResponse {
        try await answer(request)
    }

    private func answer(
        _ request: ControlAPI.DecideRequest
    ) throws -> ControlAPI.DecideResponse {
        calls += 1
        var picked: [String: ControlAPI.SystemOneAnswer] = [:]
        for name in request.questions.keys {
            guard let answer = answers[name] else {
                throw DecisionLaneError.missingAnswer(question: name)
            }
            picked[name] = answer
        }
        return ControlAPI.DecideResponse(
            model: laneID.wireName, usage: .init(inputTokens: 0, outputTokens: 0),
            answers: picked, provider: laneID.wireName, latencyMS: 1
        )
    }
}

extension VerificationAnswers {
    /// The seven answers as a lane would return them.
    var laneAnswers: [String: ControlAPI.SystemOneAnswer] {
        [
            "answers_the_question": .noul(answersTheQuestion),
            "claims_unavailable_information": .noul(claimsUnavailableInformation),
            "contradicts_context": .noul(contradictsContext),
            "follows_requested_format": .noul(followsRequestedFormat),
            "is_cut_off": .noul(isCutOff),
            "refuses_or_deflects": .noul(refusesOrDeflects),
            "answer_quality": .score(
                score: answerQuality, confidence: answerQualityConfidence,
                legend: [:], probabilities: ["2": 0.8]
            ),
        ]
    }
}

/// Jev switched on for everything, keyed, with no cap — the configuration most willing to
/// spend — pointed at a double that fails the test if anything reaches it.
func everythingOnHarness(
    _ comment: String
) async throws -> (harness: JevHarness, server: CapturingServer) {
    let server = try untouchedServer(comment)
    let harness = JevHarness()
    await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
    try await harness.service.update { settings in
        settings.enabled = true
        for feature in JevFeature.allCases { settings.features[feature] = true }
        settings.monthlyBudgetUSD = nil
        settings.cacheMinutes = 0
    }
    return (harness, server)
}

// MARK: - The door

/// "Always local" and "Off" enforced where the money is spent rather than where a caller
/// happened to remember to look.
@Suite("Lane pins at the paid door")
struct LanePinDoorTests {

    /// Every ability, pinned either way, with Jev as willing to spend as it can be: the
    /// door refuses by name, says it is not available, and nothing reaches TypeSafe.
    @Test func aPinnedAbilityCannotReachTypeSafeFromTheDoor() async throws {
        let (harness, server) = try await everythingOnHarness(
            "an ability pinned away from Jev was sent to it"
        )
        defer { server.stop(); harness.clean() }

        for feature in JevFeature.allCases {
            for pin in [DecisionLaneOverride.alwaysLocal, .off] {
                try await harness.service.update { $0.laneOverrides[feature] = pin }
                #expect(
                    await harness.service.isAvailable(feature) == false,
                    "\(feature) pinned \(pin) still reads as available"
                )
                await #expect(throws: JevError.pinnedAwayFromJev(feature, pin)) {
                    try await harness.service.ask(
                        feature, state: .string("a state"), questions: jevQuestions
                    )
                }
            }
            // The two pins that do allow Jev leave it exactly as available as it was.
            for pin in [DecisionLaneOverride.automatic, .alwaysJev] {
                try await harness.service.update { $0.laneOverrides[feature] = pin }
                #expect(await harness.service.isAvailable(feature))
            }
            try await harness.service.update { $0.laneOverrides[feature] = .alwaysLocal }
        }
        #expect(server.requests.isEmpty)
        #expect(await harness.service.ledger().month().total.calls == 0)
    }
}

// MARK: - Guardrails

@Suite("Guardrails honour the lane pin")
@MainActor
struct GuardrailLanePinTests {

    private func screen(
        _ harness: JevHarness, router: DecisionRouter, log: GuardrailScreeningLog
    ) async -> GuardrailScreening {
        await JevGuardrails.screen(
            engine: .codex, request: "list the files", tool: "shell", arguments: "ls -la",
            workingDirectory: "/tmp/project", using: harness.service, router: router,
            log: log
        )
    }

    /// The finding: pinned "Always local" with Laya ready, a tool call was still sent to
    /// TypeSafe — arguments and all — and billed. Now Laya screens it and Jev is not asked.
    @Test func alwaysLocalIsScreenedByTheLocalLaneAndNeverBilled() async throws {
        let (harness, server) = try await everythingOnHarness(
            "an Always-local guardrail sent a tool call to TypeSafe"
        )
        defer { server.stop(); harness.clean() }
        try await harness.service.update { $0.laneOverrides[.guardrails] = .alwaysLocal }
        let laya = ScriptedLane(.laya, answers: guardrailAnswers())
        let router = DecisionRouter(service: harness.service)
        await router.register(laya)
        let log = GuardrailScreeningLog()

        let screening = await screen(harness, router: router, log: log)

        #expect(screening.verdict == .act, "the local lane's answers reached the policy")
        #expect(screening.response?.provider == "laya")
        #expect(!screening.answeredByJev)
        #expect(screening.summary == "Laya: safe", "the card names the lane that screened it")
        #expect(await laya.count() == 1)
        #expect(server.requests.isEmpty)
        #expect(await harness.service.ledger().month().total.calls == 0)
        #expect(log.records.last?.screening.verdict == "act")
    }

    /// "Auto-approve calls Jev rates safe" means Jev. A free lane may screen a call — and
    /// its verdict goes on the card — but it never answers for the person: otherwise no key,
    /// a spent budget or TypeSafe being down would be a silent yes, which the guardrail
    /// promises never to be.
    @Test func aFreeLanesVerdictIsNeverAnsweredForThePerson() async throws {
        let (harness, server) = try await everythingOnHarness(
            "an Always-local guardrail sent a tool call to TypeSafe"
        )
        defer { server.stop(); harness.clean() }
        try await harness.service.update { settings in
            settings.laneOverrides[.guardrails] = .alwaysLocal
            settings.autoApproveSafeToolCalls = true
        }
        let router = DecisionRouter(service: harness.service)
        await router.register(ScriptedLane(.laya, answers: guardrailAnswers()))
        let model = AppModel(settings: .init())

        let approval = CodexApproval(rpcID: .number(7), kind: .command("ls -la"), reason: nil)
        model.codexItems.append(CodexChatItem(id: "u1", kind: .user("list the files")))
        model.codexApprovals.append(approval)
        await model.screenCodexApproval(approval.id, using: harness.service, router: router)
        #expect(model.codexApprovals.count == 1, "Codex was answered on a free lane's verdict")
        #expect(model.codexApprovals.first?.screening?.verdict == .act)

        await model.screenPiToolCall(
            .init(requestID: "ui-9", tool: "bash", arguments: #"{"command":"ls -la"}"#),
            using: harness.service, router: router
        )
        let card = try #require(model.piItems.last)
        #expect(card.screening?.verdict == .act)
        #expect(!card.answered, "Pi was answered on a free lane's verdict")
        #expect(server.requests.isEmpty)
    }

    /// "Off" asks nobody, and the card says which switch did it.
    @Test func offScreensNothingAndSaysWhere() async throws {
        let (harness, server) = try await everythingOnHarness(
            "a switched-off guardrail sent a tool call to TypeSafe"
        )
        defer { server.stop(); harness.clean() }
        try await harness.service.update { $0.laneOverrides[.guardrails] = .off }
        let laya = ScriptedLane(.laya, answers: guardrailAnswers())
        let router = DecisionRouter(service: harness.service)
        await router.register(laya)

        let screening = await screen(harness, router: router, log: GuardrailScreeningLog())

        guard case .unavailable(let reason) = screening else {
            Issue.record("an ability switched off was screened"); return
        }
        #expect(reason.contains("Settings → Decisions"))
        #expect(await laya.count() == 0)
        #expect(server.requests.isEmpty)
    }

    /// Routing the question through the lanes must not switch the guardrail on. A local
    /// lane answers any ability it is asked about, so a guardrail nobody turned on stays
    /// off however many lanes are ready — "off by default, off means off".
    @Test func aGuardrailNobodySwitchedOnIsNotScreenedByALocalLane() async throws {
        let (harness, server) = try await everythingOnHarness(
            "a switched-off guardrail sent a tool call to TypeSafe"
        )
        defer { server.stop(); harness.clean() }
        try await harness.service.update { $0.features[.guardrails] = false }
        let laya = ScriptedLane(.laya, answers: guardrailAnswers())
        let oneToken = ScriptedLane(.oneToken, answers: guardrailAnswers())
        let router = DecisionRouter(service: harness.service)
        await router.register(laya)
        await router.register(oneToken)

        let screening = await screen(harness, router: router, log: GuardrailScreeningLog())

        guard case .unavailable(let reason) = screening else {
            Issue.record("a guardrail nobody switched on screened a call"); return
        }
        #expect(reason.contains("Guardrails are off"))
        #expect(await laya.count() == 0)
        #expect(await oneToken.count() == 0)
        #expect(server.requests.isEmpty)
    }
}

// MARK: - What the panel says

@Suite("The Decisions panel names the lane that answers")
@MainActor
struct DecisionsPanelLaneTests {

    /// The other half of the finding: the panel said Laya answered guardrails while every
    /// screening went to Jev. Now that Laya does answer them, the panel must also stop naming
    /// a lane for a guardrail or a verification nobody switched on — nothing answers those.
    @Test func aSwitchGatedAbilityThatIsOffNamesNoLane() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(key: nil)
        let router = DecisionRouter(service: harness.service)
        await router.register(ScriptedLane(.laya, answers: [:]))
        var settings = await harness.service.settings()

        for feature in [JevFeature.guardrails, .verification] {
            #expect(feature.runsOnlyWhenSwitchedOn)
            #expect(await AppModel.answeringLane(
                for: feature, settings: settings, router: router
            ) == nil, "\(feature) is off and still names a lane")
            #expect(AppModel.whyNothingAnswers(feature, settings: settings)
                    .contains("Switched off"))
        }
        // An ability that is advice rather than a gate is answered by the free lane
        // whatever its Jev switch says, as before.
        #expect(await AppModel.answeringLane(
            for: .routing, settings: settings, router: router
        ) == .laya)

        settings.enabled = true
        settings.features[.guardrails] = true
        #expect(await AppModel.answeringLane(
            for: .guardrails, settings: settings, router: router
        ) == .laya)
    }
}

// MARK: - Verification

@Suite("Verification honours the lane pin")
@MainActor
struct VerificationLanePinTests {

    private func verifier(_ harness: JevHarness, router: DecisionRouter) -> JevVerifier {
        .judging(
            service: harness.service, router: router,
            escalationTarget: { _ in nil },
            escalate: { model, _, _ in throw JevVerificationError.escalationEmpty(model: model) }
        )
    }

    private let prompt = VerificationPrompt(messages: [
        .init(role: "user", content: "What is the capital of France?"),
    ])

    /// The finding, for the other paid feature behind the same default: a chat answer
    /// pinned "Always local" was sent to TypeSafe to be judged. Now Laya judges it.
    @Test func alwaysLocalIsJudgedByTheLocalLaneAndNeverBilled() async throws {
        let (harness, server) = try await everythingOnHarness(
            "an Always-local verification sent a chat answer to TypeSafe"
        )
        defer { server.stop(); harness.clean() }
        try await harness.service.update { $0.laneOverrides[.verification] = .alwaysLocal }
        let laya = ScriptedLane(.laya, answers: VerificationAnswers.clean.laneAnswers)
        let router = DecisionRouter(service: harness.service)
        await router.register(laya)

        let outcome = await verifier(harness, router: router).verify(
            prompt: prompt, reply: "Paris.", context: nil, truncated: false
        )

        #expect(outcome == .accepted, "the local lane's answers reached the policy")
        #expect(await laya.count() == 1)
        #expect(server.requests.isEmpty)
        #expect(await harness.service.ledger().month().total.calls == 0)
    }

    /// "Always local" is "never the cloud", and a re-run sends the whole conversation to
    /// whoever runs the model. So a flagged answer pinned Always local is re-run only on the
    /// owner's own serving node — never on a cloud model, even one named in Settings.
    @Test func alwaysLocalNeverReRunsAFlaggedAnswerOnTheCloud() async {
        let node = GatewayAPI.Model(
            id: "node/studio/qwen3.8-27b", displayName: "node", where_: "studio",
            contextWindow: nil, serving: true
        )
        var settings = JevSettings()
        settings.verificationEscalationModel = "cloud/open-router/gpt-5.5"

        // Unpinned, the owner's named cloud model is honoured, as it always was.
        #expect(await AppModel.verificationEscalationTarget(
            settings: settings, excluding: nil, peersAllowed: true, servable: { [node] }
        ) == "cloud/open-router/gpt-5.5")

        settings.laneOverrides[.verification] = .alwaysLocal
        #expect(await AppModel.verificationEscalationTarget(
            settings: settings, excluding: nil, peersAllowed: true, servable: { [node] }
        ) == nil, "a cloud model named in Settings was used under Always local")

        // The owner's own node is still a place a flagged answer may go.
        settings.verificationEscalationModel = nil
        #expect(await AppModel.verificationEscalationTarget(
            settings: settings, excluding: nil, peersAllowed: true, servable: { [node] }
        ) == "node/studio/qwen3.8-27b")
        settings.verificationEscalationModel = "node/studio/qwen3.8-27b"
        #expect(await AppModel.verificationEscalationTarget(
            settings: settings, excluding: nil, peersAllowed: true, servable: { [] }
        ) == "node/studio/qwen3.8-27b")
    }

    @Test func offJudgesNothing() async throws {
        let (harness, server) = try await everythingOnHarness(
            "a switched-off verification sent a chat answer to TypeSafe"
        )
        defer { server.stop(); harness.clean() }
        try await harness.service.update { $0.laneOverrides[.verification] = .off }
        let laya = ScriptedLane(.laya, answers: VerificationAnswers.clean.laneAnswers)
        let router = DecisionRouter(service: harness.service)
        await router.register(laya)

        let outcome = await verifier(harness, router: router).verify(
            prompt: prompt, reply: "Paris.", context: nil, truncated: false
        )

        #expect(outcome == .unavailable)
        #expect(await laya.count() == 0)
        #expect(server.requests.isEmpty)
    }

    /// Verification is off on every Mac by default, and routing it through the lanes must
    /// not change that: with a model loaded and nobody having switched it on, the loaded
    /// model is not asked to grade its own answers.
    @Test func verificationNobodySwitchedOnAsksNoLane() async throws {
        let (harness, server) = try await everythingOnHarness(
            "a switched-off verification sent a chat answer to TypeSafe"
        )
        defer { server.stop(); harness.clean() }
        try await harness.service.update { $0.features[.verification] = false }
        let oneToken = ScriptedLane(.oneToken, answers: VerificationAnswers.clean.laneAnswers)
        let router = DecisionRouter(service: harness.service)
        await router.register(oneToken)

        let outcome = await verifier(harness, router: router).verify(
            prompt: prompt, reply: "Paris.", context: nil, truncated: false
        )

        #expect(outcome == .unavailable)
        #expect(await oneToken.count() == 0)
        #expect(server.requests.isEmpty)
    }
}

// MARK: - /decide and calibration

/// `POST /decide`, driven through the static half of `AppModel.decide` with a service, a
/// router and a stand-in for the loaded model of the test's own.
@Suite("Decide honours the decide tool's pin")
@MainActor
struct DecideLanePinTests {

    private static let providers = ["auto", "local", "laya", "node", "typesafe"]

    /// A loaded model that is never sure: every question it answers sits in the middle of
    /// the band, so an `auto` cascade that was allowed to escalate would.
    private final class LoadedModel: @unchecked Sendable {
        let calls = Counter()
        func answer(
            _ request: ControlAPI.DecideRequest
        ) async throws -> ControlAPI.DecideResponse {
            await calls.bump()
            return ControlAPI.DecideResponse(
                model: "Test 1B", usage: .init(inputTokens: 0, outputTokens: 0),
                answers: request.questions.keys.reduce(into: [:]) { $0[$1] = .noul(0.5) },
                provider: DecisionLaneID.oneToken.wireName, latencyMS: 1
            )
        }
    }

    private func decide(
        _ provider: String, service: JevService, router: DecisionRouter,
        model: LoadedModel?
    ) async throws -> ControlAPI.DecideResponse {
        try await AppModel.decide(
            .init(state: .string("Charged twice."), questions: jevQuestions, provider: provider),
            hasLoadedModel: model != nil,
            oneToken: { asked in
                guard let model else { throw ControlHostError.noModelLoaded }
                return try await model.answer(asked)
            },
            floors: { _ in .init(confidence: 0.6, noulLow: 0.25, noulHigh: 0.75) },
            service: service, router: router
        )
    }

    private func refusal(_ body: () async throws -> ControlAPI.DecideResponse) async -> String? {
        do {
            _ = try await body()
            return nil
        } catch let error as ControlHostError {
            return error.localizedDescription
        } catch {
            return "not a ControlHostError: \(error)"
        }
    }

    /// The proof the cluster is about: with Jev switched on, keyed and uncapped, and the
    /// cascade armed, a decide tool pinned "Always local" or "Off" reaches TypeSafe through
    /// no provider, with or without a model loaded, with or without Laya.
    @Test func noProviderReachesTypeSafeForAPinnedDecideTool() async throws {
        for pin in [DecisionLaneOverride.alwaysLocal, .off] {
            for loaded in [false, true] {
                for layaReady in [false, true] {
                    let (harness, server) = try await everythingOnHarness(
                        "a decide tool pinned \(pin) sent a request to TypeSafe"
                    )
                    defer { server.stop(); harness.clean() }
                    try await harness.service.update { $0.laneOverrides[.decideTool] = pin }
                    let router = DecisionRouter(service: harness.service)
                    if layaReady {
                        await router.register(ScriptedLane(.laya, answers: ["refund": .noul(0.5)]))
                    }
                    for provider in Self.providers {
                        _ = try? await decide(
                            provider, service: harness.service, router: router,
                            model: loaded ? LoadedModel() : nil
                        )
                    }
                    #expect(server.requests.isEmpty)
                    #expect(await harness.service.ledger().month().total.calls == 0)
                }
            }
        }
    }

    /// "Always local": the free lanes answer, an unsure answer is not escalated, `typesafe`
    /// is refused by name, and with nothing local the refusal says so rather than asking
    /// for a TypeSafe key.
    @Test func alwaysLocalAnswersFromTheFreeLanesAndSaysWhyItWillNotAskJev() async throws {
        let (harness, server) = try await everythingOnHarness(
            "an Always-local decide tool sent a request to TypeSafe"
        )
        defer { server.stop(); harness.clean() }
        try await harness.service.update { $0.laneOverrides[.decideTool] = .alwaysLocal }
        let router = DecisionRouter(service: harness.service)

        let nothing = await refusal {
            try await decide("auto", service: harness.service, router: router, model: nil)
        }
        #expect(nothing == AppModel.decideLocalPinHasNoLane)

        let named = await refusal {
            try await decide("typesafe", service: harness.service, router: router, model: nil)
        }
        #expect(named?.contains("Always local") == true)
        #expect(named?.hasPrefix("not a") == false, "refused by the door, not by decide")

        let laya = ScriptedLane(.laya, answers: ["refund": .noul(0.5)])
        await router.register(laya)
        let answered = try await decide(
            "auto", service: harness.service, router: router, model: LoadedModel()
        )
        #expect(answered.provider == "laya", "an unsure local answer was not escalated")
        #expect(server.requests.isEmpty)
    }

    /// "Off" answers nothing — not the free lanes either — whichever provider is named.
    @Test func offAnswersNothingWhicheverLaneIsNamed() async throws {
        let (harness, server) = try await everythingOnHarness(
            "a switched-off decide tool sent a request to TypeSafe"
        )
        defer { server.stop(); harness.clean() }
        try await harness.service.update { $0.laneOverrides[.decideTool] = .off }
        let laya = ScriptedLane(.laya, answers: ["refund": .noul(0.9)])
        let router = DecisionRouter(service: harness.service)
        await router.register(laya)
        let model = LoadedModel()

        for provider in Self.providers {
            let why = await refusal {
                try await decide(provider, service: harness.service, router: router, model: model)
            }
            #expect(why?.contains("switched off") == true, "\(provider) answered: \(why ?? "nil")")
        }
        #expect(await model.calls.count == 0)
        #expect(await laya.count() == 0)
        #expect(server.requests.isEmpty)
    }

    /// "Always Jev": Jev answers alone, with no uncalibrated first pass, and a named local
    /// lane is refused.
    @Test func alwaysJevAsksJevAloneWithNoFreeFirstPass() async throws {
        let typeSafe = try CapturingServer { _, _ in .init(body: jevAnswer) }
        defer { typeSafe.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(typeSafe.port)")!)
        try await harness.enable()
        try await harness.service.update { $0.laneOverrides[.decideTool] = .alwaysJev }
        let laya = ScriptedLane(.laya, answers: ["refund": .noul(0.5)])
        let router = DecisionRouter(service: harness.service)
        await router.register(laya)
        let model = LoadedModel()

        let answered = try await decide(
            "auto", service: harness.service, router: router, model: model
        )
        #expect(try answered.noul("refund") == 0.93)
        #expect(typeSafe.requests.count == 1)
        #expect(await model.calls.count == 0)
        #expect(await laya.count() == 0)

        let why = await refusal {
            try await decide("local", service: harness.service, router: router, model: model)
        }
        #expect(why?.contains("Always Jev") == true)
    }

    /// And unpinned, nothing changed: the loaded model answers first and only the unsure
    /// answer goes to Jev, billed to the decide tool.
    @Test func automaticStillCascades() async throws {
        let typeSafe = try CapturingServer { _, _ in .init(body: jevAnswer) }
        defer { typeSafe.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(typeSafe.port)")!)
        try await harness.service.update { settings in
            settings.enabled = true
            settings.features[.decideTool] = true
            settings.features[.calibration] = true
        }
        let model = LoadedModel()

        let answered = try await decide(
            "auto", service: harness.service, router: DecisionRouter(service: harness.service),
            model: model
        )
        #expect(answered.provider == "local+typesafe")
        #expect(await model.calls.count == 1)
        #expect(typeSafe.requests.count == 1)
        #expect(await harness.service.ledger().month().features["decideTool"]?.calls == 1)
    }
}

@Suite("Calibration honours its pin")
struct CalibrationLanePinTests {

    /// A calibration is a comparison against Jev, billed to Decision calibration, so that
    /// ability pinned away from Jev cannot run one — and the refusal names the pin rather
    /// than asking for a TypeSafe key the owner already has.
    @Test func aCalibrationPinnedAwayFromJevIsRefusedByName() async throws {
        let (harness, server) = try await everythingOnHarness(
            "a calibration pinned away from Jev sent a request to TypeSafe"
        )
        defer { server.stop(); harness.clean() }

        try await harness.service.update { $0.laneOverrides[.calibration] = .off }
        let off = await AppModel.calibrationPinRefusal(using: harness.service)
        #expect(off?.contains("switched off") == true)

        try await harness.service.update { $0.laneOverrides[.calibration] = .alwaysLocal }
        let local = await AppModel.calibrationPinRefusal(using: harness.service)
        #expect(local?.contains("Always local") == true)

        for pin in [DecisionLaneOverride.automatic, .alwaysJev] {
            try await harness.service.update { $0.laneOverrides[.calibration] = pin }
            #expect(await AppModel.calibrationPinRefusal(using: harness.service) == nil)
        }
    }
}

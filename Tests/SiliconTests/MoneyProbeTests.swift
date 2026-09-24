import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

// Adversarial probes for the money rule, written by the review's critic against the lane
// pins: every way a pinned ability, or any ability with Jev off, might still reach TypeSafe.
// Hermetic: `JevHarness` temp dirs, loopback servers, injected lanes and a simulated consent
// dialog. Never the shared service, the Keychain or the running app.

/// A local lane that fails every question, counting.
actor FailingLane: DecisionLane {
    nonisolated let laneID: DecisionLaneID
    private(set) var calls = 0
    init(_ laneID: DecisionLaneID) { self.laneID = laneID }
    func count() -> Int { calls }
    nonisolated func isReady() async -> Bool { true }
    nonisolated func decide(
        _ request: ControlAPI.DecideRequest
    ) async throws -> ControlAPI.DecideResponse {
        await bump()
        throw DecisionLaneError.noLocalModel
    }
    private func bump() { calls += 1 }
}

@Suite("Adversarial money probes")
@MainActor
struct MoneyProbeTests {

    /// Jev's master switch off, every feature on, keyed, uncapped: no ability, under any
    /// pin, with or without a local lane (answering or failing), reaches TypeSafe — through
    /// the router, the bench (`ask(lane: .jev)`) or the door.
    @Test func jevOffReachesNothingUnderAnyPin() async throws {
        let (harness, server) = try await everythingOnHarness("Jev was off")
        defer { server.stop(); harness.clean() }
        try await harness.service.update { $0.enabled = false }

        for feature in JevFeature.allCases {
            for pin in DecisionLaneOverride.allCases {
                try await harness.service.update { $0.laneOverrides[feature] = pin }
                for lanes in 0..<3 {
                    let router = DecisionRouter(service: harness.service)
                    if lanes == 1 { await router.register(FailingLane(.laya)) }
                    if lanes == 2 {
                        await router.register(ScriptedLane(.laya, answers: ["refund": .noul(0.5)]))
                    }
                    #expect(await harness.service.isAvailable(feature) == false)
                    _ = try? await router.decide(
                        feature, state: .string("s"), questions: jevQuestions
                    )
                    _ = try? await router.ask(
                        lane: .jev, feature: feature, state: .string("s"), questions: jevQuestions
                    )
                    _ = try? await harness.service.ask(
                        feature, state: .string("s"), questions: jevQuestions
                    )
                }
            }
        }
        #expect(server.requests.isEmpty)
        #expect(await harness.service.ledger().month().total.calls == 0)
    }

    /// Jev on and willing: a pinned ability whose local lanes all fail never falls up to
    /// Jev, and the bench cannot name Jev for it either.
    @Test func aPinnedAbilityWhoseLocalLanesFailNeverFallsUpToJev() async throws {
        let (harness, server) = try await everythingOnHarness("a failing local lane fell up")
        defer { server.stop(); harness.clean() }
        for feature in JevFeature.allCases {
            for pin in [DecisionLaneOverride.alwaysLocal, .off] {
                try await harness.service.update { $0.laneOverrides[feature] = pin }
                let router = DecisionRouter(service: harness.service)
                let laya = FailingLane(.laya)
                let one = FailingLane(.oneToken)
                await router.register(laya)
                await router.register(one)
                _ = try? await router.decide(feature, state: .string("s"), questions: jevQuestions)
                _ = try? await router.ask(
                    lane: .jev, feature: feature, state: .string("s"), questions: jevQuestions
                )
                if pin == .alwaysLocal {
                    #expect(await laya.count() == 1)
                    #expect(await one.count() == 1)
                } else {
                    #expect(await laya.count() == 0)
                }
            }
        }
        #expect(server.requests.isEmpty)
    }

    /// The question sets as the features call them (the protocol default and the two
    /// hand-written ones used by the gateway), pinned away or with Jev off.
    @Test func theQuestionSetsThemselvesReachNothing() async throws {
        let (harness, server) = try await everythingOnHarness("a question set reached TypeSafe")
        defer { server.stop(); harness.clean() }
        let candidates = [ContextPruning.Candidate(messageIndex: 1, step: 1, excerpt: "ls output")]

        func askAll() async {
            _ = try? await GuardrailQuestions.ask(state: .string("s"), using: harness.service)
            _ = try? await VerificationQuestions.ask(state: .string("s"), using: harness.service)
            _ = try? await ContextPruning.ask(
                latestTurn: "fix the bug", candidates: candidates, using: harness.service
            )
        }
        for pin in [DecisionLaneOverride.alwaysLocal, .off] {
            try await harness.service.update { settings in
                for feature in JevFeature.allCases { settings.laneOverrides[feature] = pin }
            }
            await askAll()
        }
        try await harness.service.update { settings in
            settings.laneOverrides = [:]
            settings.enabled = false
        }
        await askAll()
        #expect(server.requests.isEmpty)
    }

    /// Automatic, Jev keyed but failing (HTTP 500): the guardrail falls down to Laya, the
    /// card names Laya, and "Auto-approve calls Jev rates safe" does not act on it.
    @Test func automaticFallbackFromAFailingJevIsNotAutoApproved() async throws {
        let typeSafe = try CapturingServer { _, _ in .init(status: 500, body: #"{"error":"x"}"#) }
        defer { typeSafe.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(typeSafe.port)")!)
        try await harness.service.update { settings in
            settings.enabled = true
            settings.features[.guardrails] = true
            settings.autoApproveSafeToolCalls = true
            settings.cacheMinutes = 0
        }
        let router = DecisionRouter(service: harness.service)
        let laya = ScriptedLane(.laya, answers: guardrailAnswers())
        await router.register(laya)
        let model = AppModel(settings: .init())
        let approval = CodexApproval(rpcID: .number(9), kind: .command("ls -la"), reason: nil)
        model.codexItems.append(CodexChatItem(id: "u1", kind: .user("list the files")))
        model.codexApprovals.append(approval)

        await model.screenCodexApproval(approval.id, using: harness.service, router: router)

        #expect(typeSafe.requests.count == 1, "automatic asks Jev first, once")
        #expect(await laya.count() == 1, "then falls down to Laya")
        #expect(model.codexApprovals.count == 1, "a Laya verdict was answered for the person")
        #expect(model.codexApprovals.first?.screening?.summary == "Laya: safe")
    }

    /// The master switch turned off while the dialog is up stops the request too.
    @Test func jevSwitchedOffWhileTheDialogIsUpStopsTheRequest() async throws {
        let server = try untouchedServer("Jev was switched off during the dialog")
        defer { server.stop() }
        let dialog = ConsentDialog()
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.service.configure(
            keyProvider: { dialog.read() },
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            keyIsSet: { true },
            configURL: harness.configURL
        )
        try await harness.enable()
        let asking = Task {
            try await harness.service.ask(
                .decideTool, state: .string("Charged twice."), questions: jevQuestions
            )
        }
        await dialog.waitUntilShown()
        try await harness.service.update { $0.enabled = false }
        dialog.answer()
        await #expect(throws: JevError.disabled(.decideTool)) { try await asking.value }
        #expect(server.requests.isEmpty)
    }

    /// While the key read's consent dialog is up, nothing on the actor asks the Keychain
    /// anything — not even the attributes-only "is a key stored?", which may itself queue
    /// behind the dialog and freeze the actor again. A read under way already says a key is
    /// listed, so `isAvailable` and a second ask are answered without one.
    @Test func theActorAsksTheKeychainNothingWhileTheDialogIsUp() async throws {
        let server = try CapturingServer { _, _ in .init(body: jevAnswer) }
        defer { server.stop() }
        let dialog = ConsentDialog()
        let harness = JevHarness()
        defer { harness.clean() }
        let calls = LockedCount()
        await harness.service.configure(
            keyProvider: { dialog.read() },
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            keyIsSet: { calls.bump(); return true },
            configURL: harness.configURL
        )
        try await harness.enable()
        let asking = Task {
            try await harness.service.ask(
                .decideTool, state: .string("Charged twice."), questions: jevQuestions
            )
        }
        await dialog.waitUntilShown()
        let before = calls.value
        #expect(await harness.service.isAvailable(.decideTool))
        let joining = Task {
            try await harness.service.ask(
                .decideTool, state: .string("Another question."), questions: jevQuestions
            )
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while await harness.service.joinedKeyReads == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(calls.value == before, "the actor queried the Keychain while the dialog was up")
        #expect(dialog.returned == 0)

        dialog.answer()
        _ = try await asking.value
        _ = try await joining.value
        #expect(dialog.reads == 1)
    }
}

@Suite("The node's decision answer decodes")
struct NodeDecisionAnswerDecodeTests {
    /// silicon-node's `/v1/systemone` answer, as `LayaEngine._shape` builds it from the
    /// laya 0.3.4 capture in the node's own tests (extra keys included), decodes with the
    /// decoder `NodeDecisionLane` uses.
    @Test func theNodesAnswerShapeDecodes() throws {
        let body = #"""
            {"answers":{"refund":{"type":"noul","noul":0.88,"confidence":0.88,
               "action":{"act_probability":1.0},"latency_ms":31.2},
             "tone":{"type":"choice","choice":"calm","probabilities":{"calm":0.5,"angry":0.5},
               "confidence":0.91,"action":{"act_probability":1.0},"latency_ms":31.2},
             "urgency":{"type":"score","score":1.45,"legend":{"0":"low","1":"mid","2":"high"},
               "probabilities":{"0":0.33,"1":0.33,"2":0.34},"confidence":0.15,
               "action":{"act_probability":1.0},"latency_ms":31.2}},
             "model":"english",
             "checkpoint":{"name":"english","repo":"convaiinnovations/laya",
               "revision":"1c5edc17a7acd8701df6fc341c0d179f1c62c982","encoder":"ModernBERT-large 421M"},
             "routing":{"model":"english","repo":"convaiinnovations/laya","reason":"English Latin text"},
             "usage":{"input_tokens":249,"output_tokens":0},
             "latency_ms":93.6,"latency_ms_per_question":31.2,"questions":3,"engine":"laya"}
            """#
        let decoded = try JSONDecoder().decode(ControlAPI.DecideResponse.self, from: Data(body.utf8))
        #expect(try decoded.noul("refund") == 0.88)
        #expect(try decoded.choice("tone").choice == "calm")
        #expect(decoded.model == "english")
    }
}

final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

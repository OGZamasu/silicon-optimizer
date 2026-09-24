import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

// MARK: - Doubles

/// A lane that answers from a script, and counts.
///
/// The counting is the point in most of these tests: "did anything reach Jev?" is not a
/// question you can answer by looking at a response, because a local answer and a paid one
/// are the same type by design.
actor CountingLane: DecisionLane {
    nonisolated let laneID: DecisionLaneID
    private var readyNow: Bool
    private(set) var calls = 0
    private var failures: Int
    private let answer: ControlAPI.SystemOneAnswer

    init(
        _ laneID: DecisionLaneID, ready: Bool = true, failFirst: Int = 0,
        answer: ControlAPI.SystemOneAnswer = .noul(0.9)
    ) {
        self.laneID = laneID
        self.readyNow = ready
        self.failures = failFirst
        self.answer = answer
    }

    func setReady(_ value: Bool) { readyNow = value }
    func count() -> Int { calls }

    nonisolated func isReady() async -> Bool { await ready() }
    private func ready() -> Bool { readyNow }

    nonisolated func decide(
        _ request: ControlAPI.DecideRequest
    ) async throws -> ControlAPI.DecideResponse {
        try await answer(request)
    }

    private func answer(
        _ request: ControlAPI.DecideRequest
    ) throws -> ControlAPI.DecideResponse {
        calls += 1
        if failures > 0 {
            failures -= 1
            throw LayaSidecarError.died(status: 1, detail: "scripted failure")
        }
        return ControlAPI.DecideResponse(
            model: laneID.wireName,
            usage: .init(inputTokens: 10, outputTokens: 0),
            answers: request.questions.keys.reduce(into: [:]) { $0[$1] = answer },
            provider: laneID.wireName, latencyMS: 1
        )
    }
}

extension ControlAPI.DecideRequest {
    static func fixture(
        _ name: String = "q", type: String = "noul"
    ) -> ControlAPI.DecideRequest {
        .init(
            state: .string("a state"),
            questions: [name: .init(
                type: type, instructions: .string("Is this true?"),
                criteria: type == "choice"
                    ? .object(["a": .string("one"), "b": .string("two")])
                    : (type == "score"
                       ? .array([.string("low"), .string("high")])
                       : nil)
            )]
        )
    }
}

// MARK: - The policy

@Suite("Decision lane routing policy")
struct DecisionLanePolicyTests {

    /// Every combination of the four flags against all four overrides — 64 cases, checked
    /// by the rules rather than by a table, because a table would only restate the code.
    @Test func everyCombinationRoutesWhereTheOwnerSaid() {
        for jev in [false, true] {
            for laya in [false, true] {
                for node in [false, true] {
                    for oneToken in [false, true] {
                        let available = DecisionLaneAvailability(
                            jev: jev, laya: laya, node: node, oneToken: oneToken
                        )
                        let local: DecisionLaneID? = laya ? .laya
                            : (node ? .node : (oneToken ? .oneToken : nil))

                        #expect(DecisionLanePolicy.lane(
                            override: .off, available: available
                        ) == nil, "off never answers")

                        #expect(DecisionLanePolicy.lane(
                            override: .alwaysJev, available: available
                        ) == (jev ? .jev : nil), "alwaysJev is Jev or nothing")

                        #expect(DecisionLanePolicy.lane(
                            override: .alwaysLocal, available: available
                        ) == local, "alwaysLocal prefers Laya, then a node, then the model")

                        #expect(DecisionLanePolicy.lane(
                            override: .automatic, available: available
                        ) == (jev ? .jev : local), "automatic takes Jev first when it is on")
                    }
                }
            }
        }
    }

    /// The load-bearing one. Whatever is installed and however the per-feature switch is
    /// set, a lane the owner has not turned on cannot be chosen — and `alwaysLocal` cannot
    /// reach Jev even when Jev is sitting there available.
    @Test func noCombinationReachesJevUnlessJevIsAvailable() {
        for laya in [false, true] {
            for node in [false, true] {
                for oneToken in [false, true] {
                    let off = DecisionLaneAvailability(
                        jev: false, laya: laya, node: node, oneToken: oneToken
                    )
                    for override in DecisionLaneOverride.allCases {
                        #expect(
                            DecisionLanePolicy.lane(override: override, available: off) != .jev,
                            "\(override) reached Jev with Jev unavailable"
                        )
                    }
                    // And with Jev fully available, the local pin still refuses it.
                    let on = DecisionLaneAvailability(
                        jev: true, laya: laya, node: node, oneToken: oneToken
                    )
                    #expect(
                        DecisionLanePolicy.lane(override: .alwaysLocal, available: on) != .jev,
                        "alwaysLocal reached Jev"
                    )
                }
            }
        }
    }

    @Test func nothingAvailableMeansNothingAnswers() {
        let none = DecisionLaneAvailability()
        for override in DecisionLaneOverride.allCases {
            #expect(DecisionLanePolicy.lane(override: override, available: none) == nil)
        }
    }

    /// A lane failing is not the owner deciding to start paying, so the fall-through never
    /// crosses into Jev — and never runs backwards into a lane already tried.
    @Test func fallbacksStayLocalAndMoveForwards() {
        let all = DecisionLaneAvailability(jev: true, laya: true, node: true, oneToken: true)
        #expect(DecisionLanePolicy.fallbacks(
            after: .laya, override: .automatic, available: all
        ) == [.node, .oneToken])
        #expect(DecisionLanePolicy.fallbacks(
            after: .node, override: .alwaysLocal, available: all
        ) == [.oneToken])
        #expect(DecisionLanePolicy.fallbacks(
            after: .oneToken, override: .automatic, available: all
        ).isEmpty)
        // A transient Jev failure under `automatic` falls DOWN to the free local lanes,
        // in preference order — a cloud hiccup must not fail the whole decision when Laya
        // is sitting there installed and ready.
        #expect(DecisionLanePolicy.fallbacks(
            after: .jev, override: .automatic, available: all
        ) == [.laya, .node, .oneToken])
        // But never when only some of them are actually available.
        #expect(DecisionLanePolicy.fallbacks(
            after: .jev, override: .automatic,
            available: .init(jev: true, laya: false, node: true, oneToken: true)
        ) == [.node, .oneToken])
        // `alwaysJev` named the calibrated lane on purpose: a bad moment for Jev does not
        // turn it into a request for whatever is free.
        #expect(DecisionLanePolicy.fallbacks(
            after: .jev, override: .alwaysJev, available: all
        ).isEmpty)
        #expect(DecisionLanePolicy.fallbacks(
            after: .laya, override: .alwaysJev, available: all
        ).isEmpty)
        // `alwaysLocal` and `off` never even reach `.jev` as the chosen lane, but the
        // function refuses to fall from it for them regardless of what is asked.
        #expect(DecisionLanePolicy.fallbacks(
            after: .jev, override: .alwaysLocal, available: all
        ).isEmpty)
        #expect(DecisionLanePolicy.fallbacks(
            after: .jev, override: .off, available: all
        ).isEmpty)
    }

    /// The wire words are the ones already on the wire, plus two new ones — not renames.
    @Test func laneNamesKeepTheSpellingsClientsAlreadyRead() {
        #expect(DecisionLaneID.jev.wireName == "typesafe")
        #expect(DecisionLaneID.oneToken.wireName == "local")
        #expect(DecisionLaneID.named("typesafe") == .jev)
        #expect(DecisionLaneID.named("local") == .oneToken)
        #expect(DecisionLaneID.named("laya") == .laya)
        // A node answer carries the peer's name and still parses as the node lane.
        #expect(DecisionLaneID.named("node:studio") == .node)
        #expect(DecisionLaneID.named("nonsense") == nil)
    }

    /// The vocabulary `SiliconControl` spells out by hand has to match the enums it cannot
    /// see. Pinned here because the two targets are deliberately unable to check it.
    @Test func theWireVocabularyMatchesTheEnums() {
        #expect(Set(ControlAPI.DecisionLaneVocabulary.lanes)
                == Set(DecisionLaneID.allCases.map(\.wireName)))
        #expect(Set(ControlAPI.DecisionLaneVocabulary.overrides)
                == Set(DecisionLaneOverride.allCases.map(\.rawValue)))
        #expect(Set(ControlAPI.DecisionLaneVocabulary.checkpoints)
                == Set(LayaCheckpoint.allCases.map(\.rawValue)))
    }
}

// MARK: - The router

@Suite("Decision router")
struct DecisionRouterTests {

    /// A router over a private settings file, with whichever lanes a test wants.
    private func harness() -> JevHarness { JevHarness() }

    @Test func withNoLanesRegisteredNothingChanges() async throws {
        let harness = harness()
        defer { harness.clean() }
        await harness.configure(key: nil)
        let router = DecisionRouter(service: harness.service)

        // Jev off, no key, no lanes: the error is the one this app has always given, in
        // the same type, so a caller's existing `catch` still reads.
        await #expect(throws: JevError.disabled(.decideTool)) {
            _ = try await router.decide(
                .decideTool, state: .string("s"),
                questions: ControlAPI.DecideRequest.fixture().questions
            )
        }
        #expect(await router.canAnswer(.decideTool) == false)
    }

    @Test func layaAnswersWhenJevIsOff() async throws {
        let harness = harness()
        defer { harness.clean() }
        await harness.configure(key: nil)
        let laya = CountingLane(.laya)
        let jev = CountingLane(.jev)
        let router = DecisionRouter(service: harness.service)
        await router.register(laya)
        await router.register(jev)

        let response = try await router.decide(
            .decideTool, state: .string("s"),
            questions: ControlAPI.DecideRequest.fixture().questions
        )
        #expect(response.provider == "laya")
        #expect(await laya.count() == 1)
        // The Jev lane object exists and was never touched: routing chose, it did not fall
        // back after trying.
        #expect(await jev.count() == 0)
    }

    /// The mutation test the brief asks for: with Jev off, drive every combination of
    /// override and installed lane through the router and assert that the *counter* on a
    /// lane standing in for TypeSafe never moves.
    ///
    /// A counter rather than a fake HTTP server on purpose. A server proves no bytes left
    /// the machine on the paths that reached it; a counter on the seam every paid call must
    /// pass through proves no path reached it at all, which is the stronger claim.
    @Test func noCloudCallHappensWhenJevIsOff() async throws {
        for layaReady in [false, true] {
            for oneTokenReady in [false, true] {
                for override in DecisionLaneOverride.allCases {
                    let harness = harness()
                    defer { harness.clean() }
                    // No key at all, and the master switch off: two independent reasons.
                    await harness.configure(key: nil)
                    let jev = CountingLane(.jev)
                    let router = DecisionRouter(service: harness.service)
                    await router.register(jev)
                    await router.register(CountingLane(.laya, ready: layaReady))
                    await router.register(CountingLane(.oneToken, ready: oneTokenReady))
                    try await harness.service.update { settings in
                        settings.laneOverrides[.decideTool] = override
                    }

                    _ = try? await router.decide(
                        .decideTool, state: .string("s"),
                        questions: ControlAPI.DecideRequest.fixture().questions
                    )
                    #expect(
                        await jev.count() == 0,
                        "override \(override), laya \(layaReady), model \(oneTokenReady) reached the cloud with Jev off"
                    )
                }
            }
        }
    }

    /// And the mutation in the other direction: a lane pinned local must not reach Jev even
    /// when Jev is switched on, keyed and in budget.
    @Test func alwaysLocalNeverPaysEvenWithJevFullyOn() async throws {
        let harness = harness()
        defer { harness.clean() }
        await harness.configure()
        try await harness.enable()
        let jev = CountingLane(.jev)
        let laya = CountingLane(.laya)
        let router = DecisionRouter(service: harness.service)
        await router.register(jev)
        await router.register(laya)
        try await harness.service.update { $0.laneOverrides[.decideTool] = .alwaysLocal }

        let response = try await router.decide(
            .decideTool, state: .string("s"),
            questions: ControlAPI.DecideRequest.fixture().questions
        )
        #expect(response.provider == "laya")
        #expect(await jev.count() == 0)

        // With the local lane gone as well, it refuses rather than quietly escalating.
        await router.unregister(.laya)
        await router.forgetReadiness()
        await #expect(throws: DecisionLaneError.nothingAvailable(.decideTool)) {
            _ = try await router.decide(
                .decideTool, state: .string("s"),
                questions: ControlAPI.DecideRequest.fixture().questions
            )
        }
        #expect(await jev.count() == 0)
    }

    @Test func offMeansNothingAnswersAndNothingIsSpent() async throws {
        let harness = harness()
        defer { harness.clean() }
        await harness.configure()
        try await harness.enable()
        let jev = CountingLane(.jev)
        let router = DecisionRouter(service: harness.service)
        await router.register(jev)
        await router.register(CountingLane(.laya))
        try await harness.service.update { $0.laneOverrides[.guardrails] = .off }

        #expect(await router.canAnswer(.guardrails) == false)
        await #expect(throws: JevError.disabled(.guardrails)) {
            _ = try await router.decide(
                .guardrails, state: .string("s"),
                questions: ControlAPI.DecideRequest.fixture().questions
            )
        }
        #expect(await jev.count() == 0)
    }

    /// A lane that fails hands the question to the next free one — and never upwards.
    @Test func aFailedLaneFallsThroughToTheNextFreeOneAndNotToJev() async throws {
        let harness = harness()
        defer { harness.clean() }
        await harness.configure()
        try await harness.enable()
        let jev = CountingLane(.jev)
        let laya = CountingLane(.laya, failFirst: 5)
        let oneToken = CountingLane(.oneToken)
        let router = DecisionRouter(service: harness.service)
        await router.register(jev)
        await router.register(laya)
        await router.register(oneToken)
        try await harness.service.update { $0.laneOverrides[.decideTool] = .alwaysLocal }

        let response = try await router.decide(
            .decideTool, state: .string("s"),
            questions: ControlAPI.DecideRequest.fixture().questions
        )
        #expect(response.provider == "local")
        #expect(await laya.count() == 1, "it tried Laya first")
        #expect(await oneToken.count() == 1)
        #expect(await jev.count() == 0)
    }

    /// The mutation this fix targets: a transient Jev failure under `automatic` must not
    /// fail the whole decision when a free local lane is installed and ready. It falls
    /// DOWN to Laya, never back up to Jev for a second try — one attempt at Jev, one
    /// answer from Laya, nothing billed twice.
    ///
    /// Points at the loopback address nothing answers on rather than a fake server: the
    /// point is that Jev *fails*, and a refused connection to 127.0.0.1 fails it without
    /// ever reaching a network or costing a real request.
    @Test func automaticFallsDownFromAFailedJevToTheFreeLocalLane() async throws {
        let harness = harness()
        defer { harness.clean() }
        await harness.configure()
        try await harness.enable()
        let jev = CountingLane(.jev)
        let laya = CountingLane(.laya)
        let router = DecisionRouter(service: harness.service)
        await router.register(jev)
        await router.register(laya)
        // `.automatic` is the default, but named for the reader: this is the case the
        // policy fix is about.
        try await harness.service.update { $0.laneOverrides[.decideTool] = .automatic }

        let response = try await router.decide(
            .decideTool, state: .string("s"),
            questions: ControlAPI.DecideRequest.fixture().questions
        )
        #expect(response.provider == "laya")
        #expect(await laya.count() == 1)
        // The counting lane never touches the real Jev path — this proves the *policy*
        // routed to Laya, not that Jev happened to answer.
        #expect(await jev.count() == 0)
    }

    /// `alwaysJev` is the opposite promise: it named the calibrated lane on purpose, so a
    /// bad moment for Jev must not quietly become a free answer instead.
    @Test func alwaysJevDoesNotFallToAFreeLaneWhenJevFails() async throws {
        let harness = harness()
        defer { harness.clean() }
        await harness.configure()
        try await harness.enable()
        let laya = CountingLane(.laya)
        let router = DecisionRouter(service: harness.service)
        await router.register(laya)
        try await harness.service.update { $0.laneOverrides[.decideTool] = .alwaysJev }

        await #expect(throws: (any Error).self) {
            _ = try await router.decide(
                .decideTool, state: .string("s"),
                questions: ControlAPI.DecideRequest.fixture().questions
            )
        }
        #expect(await laya.count() == 0, "alwaysJev must not spend a free answer on a Jev failure")
    }

    @Test func theBenchAsksTheLaneItWasToldToAndNotThePolicysChoice() async throws {
        let harness = harness()
        defer { harness.clean() }
        await harness.configure()
        try await harness.enable()
        let laya = CountingLane(.laya)
        let oneToken = CountingLane(.oneToken)
        let router = DecisionRouter(service: harness.service)
        await router.register(laya)
        await router.register(oneToken)

        // The policy would choose Laya; the bench is told `oneToken` and obeys.
        let response = try await router.ask(
            lane: .oneToken, feature: .decideTool, state: .string("s"),
            questions: ControlAPI.DecideRequest.fixture().questions
        )
        #expect(response.provider == "local")
        #expect(await laya.count() == 0)
        #expect(await oneToken.count() == 1)
    }

    @Test func theFreeLanePrefersLayaAndFallsBackInOrder() async throws {
        let harness = harness()
        defer { harness.clean() }
        await harness.configure()
        try await harness.enable()
        let router = DecisionRouter(service: harness.service)
        let laya = CountingLane(.laya, ready: false)
        await router.register(laya)
        await router.register(CountingLane(.oneToken))
        #expect(await router.localLane(for: .decideTool) == .oneToken)

        await laya.setReady(true)
        await router.forgetReadiness()
        #expect(await router.localLane(for: .decideTool) == .laya)

        // Pinned to Jev, there is no free lane at all — so the cascade does not quietly
        // acquire one behind a setting that says otherwise.
        try await harness.service.update { $0.laneOverrides[.decideTool] = .alwaysJev }
        #expect(await router.localLane(for: .decideTool) == nil)
    }

    /// Settings survive a round trip, including a lane word from a newer build.
    @Test func laneSettingsPersistAndTolerateAFileFromAnotherBuild() async throws {
        let harness = harness()
        defer { harness.clean() }
        await harness.configure()
        try await harness.service.update { settings in
            settings.laneOverrides[.routing] = .alwaysLocal
            settings.layaCheckpoint = .multilingual
            settings.nodeLaneEnabled = true
        }
        let reread = JevSettings.load(from: harness.configURL)
        #expect(reread.laneOverride(.routing) == .alwaysLocal)
        #expect(reread.laneOverride(.guardrails) == .automatic, "absent means automatic")
        #expect(reread.layaCheckpoint == .multilingual)
        #expect(reread.nodeLaneEnabled)

        // A file naming a lane word and a checkpoint this build has never heard of falls
        // back rather than failing the whole load — the same rule the feature switches use.
        var raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: harness.configURL)
        ) as! [String: Any]
        raw["laneOverrides"] = ["routing": "alwaysNode", "guardrails": "alwaysLocal"]
        raw["layaCheckpoint"] = "quantum"
        try JSONSerialization.data(withJSONObject: raw).write(to: harness.configURL)
        let tolerant = JevSettings.load(from: harness.configURL)
        #expect(tolerant.laneOverride(.routing) == .automatic)
        #expect(tolerant.laneOverride(.guardrails) == .alwaysLocal)
        #expect(tolerant.layaCheckpoint == .default)
    }
}

// MARK: - Calibration, per lane

@Suite("Per-lane calibration")
struct PerLaneCalibrationTests {

    /// Each lane's floors go in a file of its own, and the one-token lane keeps the name it
    /// has always had — so a Mac that calibrated before Laya existed keeps its floors
    /// across the upgrade with no migration step.
    @Test func eachLaneKeepsItsOwnFileAndTheOldOneIsUnmoved() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure()

        let oneToken = await harness.service.calibrationURL(for: .oneToken)
        let laya = await harness.service.calibrationURL(for: .laya)
        let node = await harness.service.calibrationURL(for: .node)
        #expect(oneToken.lastPathComponent == "local-calibration.json")
        #expect(laya.lastPathComponent == "laya-calibration.json")
        #expect(node.lastPathComponent == "node-calibration.json")
        #expect(Set([oneToken, laya, node]).count == 3, "no two lanes share a file")
        // And the no-lane spelling is still the one-token lane's, so every existing caller
        // reads what it always read.
        #expect(JevSettings.calibrationURL(besideConfigAt: harness.configURL) == oneToken)
    }

    /// Floors are per lane **and** per kind, and one lane's run never reaches another's.
    @Test func oneLanesFloorsAreNotAnothersAndAreNotSharedBetweenKinds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("laneflorrs-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("jev.json")

        // A calibration measured against Laya's checkpoint, with a choice floor well apart
        // from its score floor: the two distributions are not comparable, and the file has
        // to keep them apart.
        var result = ControlAPI.JevCalibration.fixture(lane: "laya")
        result.modelID = "\(LayaCheckpoint.english.repository)@\(LayaCheckpoint.english.revision)"
        result.floors = .init(
            choiceConfidence: 0.42, scoreConfidence: 0.81, noulLow: 0.1, noulHigh: 0.9
        )
        let layaURL = JevSettings.calibrationURL(besideConfigAt: config, lane: .laya)
        try CalibrationQuestions.save(result, to: layaURL)

        let loaded = try #require(CalibrationQuestions.lastResult(at: layaURL))
        #expect(loaded.lane == "laya")
        #expect(loaded.floors.choiceConfidence == 0.42)
        #expect(loaded.floors.scoreConfidence == 0.81, "a score floor is not a choice floor")

        // The one-token lane has no file, so it gets the settings' defaults rather than
        // Laya's numbers.
        let defaults = ControlAPI.JevCalibration.Floors(
            confidence: JevSettings.defaultCascadeFloor,
            noulLow: JevSettings.defaultCascadeNoulLow,
            noulHigh: JevSettings.defaultCascadeNoulHigh
        )
        let oneTokenURL = JevSettings.calibrationURL(besideConfigAt: config, lane: .oneToken)
        #expect(CalibrationQuestions.lastResult(at: oneTokenURL) == nil)
        #expect(CalibrationQuestions.floors(
            for: nil, calibration: nil, settings: defaults
        ) == defaults)

        // And Laya's own floors apply only while that checkpoint is the one in use: a
        // different revision is a different model, and its confidence is its own.
        let matching = CalibrationQuestions.LoadedModel(id: result.modelID)
        #expect(CalibrationQuestions.floors(
            for: matching, calibration: loaded, settings: defaults
        ).choiceConfidence == 0.42)
        let moved = CalibrationQuestions.LoadedModel(
            id: "\(LayaCheckpoint.english.repository)@0000000"
        )
        #expect(CalibrationQuestions.floors(
            for: moved, calibration: loaded, settings: defaults
        ) == defaults, "floors measured on one revision are not applied to another")
    }

    /// `GET /jev/calibration?lane=laya` reads Laya's own run. The route asked the host for
    /// it and the Mac never answered — the protocol's default, meant for hosts with no
    /// lanes, stood in for it — so every lane but the one-token one was a 404.
    @MainActor @Test func eachLanesCalibrationCanBeReadBack() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure()
        let model = AppModel(settings: .init())

        var laya = ControlAPI.JevCalibration.fixture(lane: "laya")
        laya.modelID = "laya-run"
        try CalibrationQuestions.save(laya, to: await harness.service.calibrationURL(for: .laya))
        var node = ControlAPI.JevCalibration.fixture(lane: "node")
        node.modelID = "node-run"
        try CalibrationQuestions.save(node, to: await harness.service.calibrationURL(for: .node))

        let readLaya = await model.decisionCalibration(lane: "laya", using: harness.service)
        #expect(readLaya?.modelID == "laya-run")
        #expect(readLaya?.lane == "laya")
        let readNode = await model.decisionCalibration(lane: "node", using: harness.service)
        #expect(readNode?.modelID == "node-run")

        // No lane, or `local`, is the one-token lane, which has never been calibrated here.
        #expect(await model.decisionCalibration(lane: nil, using: harness.service) == nil)
        #expect(await model.decisionCalibration(lane: "local", using: harness.service) == nil)
        // Jev is the reference, not a lane with a calibration; an unknown word is nothing.
        #expect(await model.decisionCalibration(lane: "typesafe", using: harness.service) == nil)
        #expect(await model.decisionCalibration(lane: "quantum", using: harness.service) == nil)
    }

    /// A file written before there was more than one lane has no `lane` field, and is read
    /// as the lane it can only have been.
    @Test func aFileFromBeforeLanesReadsAsTheLaneItMeasured() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oldcal-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("local-calibration.json")

        var old = ControlAPI.JevCalibration.fixture(lane: nil)
        old.lane = nil
        try CalibrationQuestions.save(old, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("\"lane\""), "nothing is written that was not there before")

        let read = try #require(CalibrationQuestions.lastResult(at: url))
        #expect(read.lane == nil)
        #expect(read.floors.choiceConfidence == 0.6, "the floors still load")
    }
}

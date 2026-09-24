import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

// MARK: - Fixtures

/// Candidates that look like the real catalog's, written out rather than derived, so a
/// policy test still means something after someone edits `VideoCatalog`.
enum RoutingFixtures {

    static let wan = MediaCandidate(
        id: "wan22-ti2v-5b", name: "Wan 2.2 5B", goodAt: "The cinematic pick.",
        supportedSeconds: [3, 5], maxResolution: "720p", isUncensored: false,
        runsOn: MediaCandidate.pairedMachine, isReady: true,
        typicalRenderTime: "~10 min per 5 s clip"
    )
    static let ltx = MediaCandidate(
        id: "ltx2-distilled", name: "LTX-2 distilled", goodAt: "The iteration pick.",
        supportedSeconds: [3, 5], maxResolution: "1080p", isUncensored: false,
        runsOn: MediaCandidate.pairedMachine, isReady: true
    )
    static let ltxUncensored = MediaCandidate(
        id: "ltx23-uncensored", name: "LTX-2.3 Uncensored v1.4", goodAt: "The unfiltered pick.",
        supportedSeconds: [3, 5, 8, 10], maxResolution: "720p", isUncensored: true,
        runsOn: MediaCandidate.pairedMachine, isReady: true
    )
    /// The same lane with nothing to run it: an adult prompt has nowhere to go.
    static var uninstalledUncensored: MediaCandidate {
        var copy = ltxUncensored
        copy.isReady = false
        return copy
    }
    static let h3 = MediaCandidate(
        id: "hailuo-h3", name: "MiniMax Hailuo H3", goodAt: "The high-motion option.",
        supportedSeconds: [3, 5, 10, 15], maxResolution: "1080p", isUncensored: false,
        runsOn: MediaCandidate.pairedMachine, isReady: true,
        typicalRenderTime: "several minutes",
        supportsSamplingChoice: true, supportsStepCount: true
    )
    static let flux = MediaCandidate(
        id: "flux1-schnell", name: "FLUX.1 schnell", goodAt: "Distilled for speed.",
        maxResolution: "1024px native", runsOn: MediaCandidate.thisMac, isReady: true,
        supportsStepCount: true, defaultSteps: 4
    )
    /// An undistilled model, where a step count really is a quality dial.
    static let qwenImage = MediaCandidate(
        id: "qwen-image", name: "Qwen-Image", goodAt: "Text rendering.",
        maxResolution: "1328px native", runsOn: MediaCandidate.thisMac, isReady: true,
        supportsStepCount: true, defaultSteps: 20
    )

    static let video = [wan, ltx, ltxUncensored, h3]

    /// Answers as they come back from Jev, with every question present, so a test changes
    /// one number at a time rather than rebuilding the set.
    static func answers(
        model: String = "ltx2-distilled", confidence: Double = 0.9,
        probabilities: [String: Double]? = nil, adult: Double = 0.02,
        people: Double = 0.1, motion: Double = 0.8, text: Double = 0.02,
        photoreal: Double = 0.1, stylized: Double = 0.1, violence: Double = 0.02,
        realPerson: Double = 0.02, brand: Double = 0.02,
        clipLength: (Double, Double) = (1, 0.9),
        detail: (Double, Double) = (1, 0.9)
    ) -> MediaRoutingAnswers {
        MediaRoutingAnswers(
            modelChoice: model, modelConfidence: confidence,
            modelProbabilities: probabilities ?? [model: confidence],
            nouls: [
                "adult_content": adult, "depicts_people": people, "motion_heavy": motion,
                "needs_legible_text": text, "photorealistic": photoreal,
                "stylized_or_animated": stylized, "violent_or_gore": violence,
                "names_real_person": realPerson, "names_brand_or_character": brand,
            ],
            scores: [
                "clip_length": (clipLength.0, clipLength.1),
                "detail_level": (detail.0, detail.1),
            ]
        )
    }

    static func defaults(
        explicit: String? = nil, fallback: String? = "wan22-ti2v-5b", seconds: Int = 5,
        automaticUncensoredLane: Bool = true
    ) -> MediaRoutingDefaults {
        .init(
            explicitModelID: explicit, fallbackModelID: fallback, seconds: seconds,
            automaticUncensoredLane: automaticUncensoredLane
        )
    }

    static func routed(_ outcome: MediaRoutingOutcome) -> MediaRoutingDecision? {
        if case .route(let decision) = outcome { return decision }
        return nil
    }

    static func refusal(_ outcome: MediaRoutingOutcome) -> String? {
        if case .refuse(let message) = outcome { return message }
        return nil
    }
}

// MARK: - Traits

@Suite("Media routing traits")
struct MediaRoutingTraitTests {

    /// The real catalog, read the way the router reads it. If someone adds a video model
    /// this is the test that notices its traits came out wrong.
    @Test func videoTraitsComeFromTheCatalog() {
        let entry = VideoCatalog.ltx23Uncensored
        let candidate = MediaCandidate.video(
            entry, node: "box", capabilityParameters: ["h3_turbo"]
        )
        #expect(candidate.id == entry.id)
        #expect(candidate.name == entry.name)
        #expect(candidate.goodAt == entry.summary)
        #expect(candidate.supportedSeconds == [3, 5, 8, 10])
        #expect(candidate.maxResolution == "720p")
        #expect(candidate.isUncensored)
        #expect(candidate.isReady)
        // Never a machine name: the question tells the model to ignore availability, and a
        // node's name is the owner's, not something to hand to a third party.
        #expect(candidate.runsOn == MediaCandidate.pairedMachine)
        #expect(candidate.typicalRenderTime == entry.typicalDuration)
        #expect(candidate.supportsSamplingChoice)
        #expect(!candidate.supportsStepCount)
    }

    @Test func aModelWithNoNodeIsNotReadyButStillSaysWhereItWouldRun() {
        let candidate = MediaCandidate.video(VideoCatalog.wan22, node: nil)
        #expect(!candidate.isReady)
        #expect(candidate.runsOn == MediaCandidate.pairedMachine)
        #expect(!candidate.supportsSamplingChoice && !candidate.supportsStepCount)
    }

    /// Exactly one uncensored lane in the catalog today, and the derivation has to find it
    /// without a hard-coded id — because the next one will not share this one's id.
    @Test func exactlyTheUncensoredLaneIsFlagged() {
        let flagged = VideoCatalog.all.filter { MediaCandidate.isUncensoredVideo($0) }
        #expect(flagged.map(\.id) == ["ltx23-uncensored"])
    }

    @Test(arguments: [
        ("MP4, 720p 24 fps", "720p"),
        ("MP4, up to 1080p", "1080p"),
        ("MP4, 480p–1080p", "1080p"),
        ("MP4 with audio, up to 720p 24 fps", "720p"),
        ("GLB and OBJ", String?.none),
    ])
    func theLargestAdvertisedSizeIsRead(_ outputs: String, _ expected: String?) {
        #expect(MediaCandidate.largestResolution(in: outputs) == expected)
    }

    @Test func everyVideoEntryProducesUsableTraits() {
        for entry in VideoCatalog.all {
            let candidate = MediaCandidate.video(entry, node: "box")
            #expect(!candidate.name.isEmpty && !candidate.goodAt.isEmpty)
            #expect(!candidate.supportedSeconds.isEmpty)
            #expect(candidate.maxResolution != nil, "\(entry.id) advertises no size")
        }
    }

    @Test func imageTraitsComeFromTheDiffusionCatalog() {
        let entry = DiffusionCatalog.fluxSchnell
        let candidate = MediaCandidate.image(entry, installed: true, runsOn: "this Mac")
        #expect(candidate.id == entry.id)
        #expect(candidate.defaultSteps == entry.shape.defaultSteps)
        #expect(candidate.supportsStepCount && !candidate.supportsSamplingChoice)
        #expect(candidate.supportedSeconds.isEmpty)
        #expect(!candidate.isUncensored)
        #expect(!candidate.goodAt.contains("\n"), "a summary's line breaks reach the prompt")
        #expect(candidate.isReady)
    }

    /// Nearest-length arithmetic is the policy's, not the model's — this is the piece that
    /// has to be right for the duration veto to mean anything.
    @Test func nearestSecondsAndSupportAreBoundedByTolerance() {
        #expect(RoutingFixtures.ltxUncensored.nearestSeconds(to: 9) == 8)
        #expect(RoutingFixtures.h3.nearestSeconds(to: 9) == 10)
        #expect(RoutingFixtures.wan.nearestSeconds(to: 15) == 5)
        #expect(RoutingFixtures.wan.supports(seconds: 5))
        #expect(RoutingFixtures.wan.supports(seconds: 3))
        #expect(!RoutingFixtures.wan.supports(seconds: 9))
        #expect(!RoutingFixtures.wan.supports(seconds: 15))
        #expect(RoutingFixtures.h3.supports(seconds: 15))
        #expect(RoutingFixtures.flux.nearestSeconds(to: 5) == nil)
    }
}

// MARK: - Questions

@Suite("Media routing questions")
struct MediaRoutingQuestionTests {

    @Test func everyQuestionIsValidAndWithinTypeSafeLimits() throws {
        let asked = MediaRoutingQuestions.questions(over: RoutingFixtures.video)
        for (name, question) in asked { try question.validate(name: name) }
        try JevService.checkLimits(asked)
        // The whole set travels in one request, which is the point of asking them together.
        var request = ControlAPI.DecideRequest(state: .string("x"), questions: asked)
        request.model = JevService.pinnedModel
        try request.validate()
    }

    @Test func theFixedSetIsTheOneThePolicyReadsBack() {
        #expect(MediaRoutingQuestions.noulNames == [
            "adult_content", "depicts_people", "motion_heavy",
            "names_brand_or_character", "names_real_person", "needs_legible_text",
            "photorealistic", "stylized_or_animated", "violent_or_gore",
        ])
        #expect(MediaRoutingQuestions.scoreNames == ["clip_length", "detail_level"])
        // The `model` choice is the only question that depends on what is installed.
        #expect(MediaRoutingQuestions.questions["model"] == nil)
        #expect(MediaRoutingQuestions.questions(over: [])["model"] == nil)
        #expect(MediaRoutingQuestions.questions(over: RoutingFixtures.video)["model"] != nil)
    }

    /// The `clip_length` rubric is only useful if each of its levels lands on a length some
    /// lane actually renders. Anything else asks a question whose answer cannot be obeyed.
    @Test func everyClipLengthLevelLandsOnALengthSomeLaneServes() throws {
        let levels = try #require(
            MediaRoutingQuestions.questions["clip_length"]?.criteria?.arrayValue
        )
        #expect(levels.count == MediaRoutingPolicy.clipLengthSeconds.count)
        let served = Set(VideoCatalog.all.flatMap(\.supportedSeconds))
        #expect(served == [3, 5, 8, 10, 15])
        for target in MediaRoutingPolicy.clipLengthSeconds {
            let reachable = VideoCatalog.all.contains { entry in
                abs(entry.normalizedSeconds(target) - target)
                    <= MediaRoutingThresholds.secondsTolerance
            }
            #expect(reachable, "no lane can render about \(target) s")
        }
    }

    @Test func theChoiceOffersOneOptionPerCandidateAndSeparatesTheUncensoredOne() throws {
        let question = try #require(
            MediaRoutingQuestions.questions(over: RoutingFixtures.video)["model"]
        )
        let criteria = try #require(question.criteria?.objectValue)
        #expect(Set(criteria.keys) == Set(
            RoutingFixtures.video.map(\.id) + [MediaRoutingQuestions.noMatchOption]
        ))
        let uncensored = try #require(criteria["ltx23-uncensored"]?.objectValue)
        #expect(uncensored["use_when"]?.stringValue?.contains("nudity") == true)
        #expect(uncensored["avoid_when"]?.stringValue?.contains("does not ask") == true)
        let ordinary = try #require(criteria["wan22-ti2v-5b"]?.objectValue)
        #expect(ordinary["avoid_when"]?.stringValue?.contains("asks for nudity") == true)
    }

    @Test func theStateCarriesTheRequestAndEveryLanesFacts() throws {
        let state = MediaRoutingQuestions.state(
            prompt: "a fox running", kind: .video, candidates: RoutingFixtures.video
        )
        let object = try #require(state.objectValue)
        let request = try #require(object["request"]?.objectValue)
        #expect(request["prompt"]?.stringValue == "a fox running")
        #expect(request["wants"]?.stringValue == MediaKind.video.promptNoun)

        let candidates = try #require(object["candidates"]?.arrayValue)
        #expect(candidates.count == RoutingFixtures.video.count)
        let first = try #require(candidates.first?.objectValue)
        for field in ["id", "name", "good_at", "runs_on",
                      "allows_adult_content", "clip_lengths_seconds", "max_resolution"] {
            #expect(first[field] != nil, "the state omits \(field)")
        }
        // Readiness is code's business, and the question says to ignore it. Sending it
        // anyway invites the model to weigh it twice.
        let sent = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(!sent.contains("ready_now"))
        #expect(!sent.contains("box"), "a node name reached the state")
    }

    /// The state limit is shrinking and a video prompt may be twelve thousand characters,
    /// so the cut has to happen here rather than as a 422 from TypeSafe.
    @Test func aLongPromptIsCutBeforeItIsSent() throws {
        let long = String(repeating: "a shot of a fox. ", count: 2_000)
        let state = MediaRoutingQuestions.state(
            prompt: long, kind: .video, candidates: RoutingFixtures.video
        )
        let sent = try #require(state.objectValue?["request"]?.objectValue?["prompt"]?.stringValue)
        #expect(sent.count == MediaRoutingQuestions.maximumPromptCharacters + 1)
        // Comfortably inside the 64 KB the service will send, candidates and all.
        #expect(try JevService.stateBytes(state) < 64 * 1024)
    }

    @Test(arguments: [
        (String?.none, true), ("", true), ("  ", true), ("auto", true), ("AUTO", true),
        ("wan22-ti2v-5b", false), ("automatic", false),
    ])
    func autoIsRecognisedExactly(_ id: String?, _ expected: Bool) {
        #expect(MediaRoutingQuestions.isAuto(id) == expected)
    }

    /// A question this app asked and Jev did not answer is a fault, named, not a zero.
    @Test func aMissingOrMistypedAnswerFailsByName() {
        let missing = ControlAPI.DecideResponse(
            model: "jev-1.13.0", usage: .init(inputTokens: 1, outputTokens: 1),
            answers: ["adult_content": .noul(0.9)]
        )
        #expect(throws: ControlAPI.SystemOneAnswerError.missing("depicts_people", "noul")) {
            _ = try MediaRoutingAnswers(missing, expectingModel: false)
        }

        var answers: [String: ControlAPI.SystemOneAnswer] = Dictionary(
            uniqueKeysWithValues: MediaRoutingQuestions.noulNames.map { ($0, .noul(0.1)) }
        )
        for name in MediaRoutingQuestions.scoreNames {
            answers[name] = .score(score: 1, confidence: 0.9, legend: [:], probabilities: [:])
        }
        // The kind changing under a feature is the failure the typed accessors exist for.
        answers["motion_heavy"] = .score(
            score: 1, confidence: 0.9, legend: [:], probabilities: [:]
        )
        let mistyped = ControlAPI.DecideResponse(
            model: "jev-1.13.0", usage: .init(inputTokens: 1, outputTokens: 1), answers: answers
        )
        #expect(throws: ControlAPI.SystemOneAnswerError.wrongKind(
            "motion_heavy", expected: "noul", found: "score"
        )) {
            _ = try MediaRoutingAnswers(mistyped, expectingModel: false)
        }
    }

    /// The gate for a noul is certainty at both ends, never a confidence band: a confident
    /// "no, nothing adult here" is 0.02, which a confidence gate would read as no answer.
    @Test func theAdultGateReadsBothEndsOfTheNoul() {
        #expect(MediaRoutingThresholds.adultLane(0.95) == .adult)
        #expect(MediaRoutingThresholds.adultLane(0.6) == .adult)
        #expect(MediaRoutingThresholds.adultLane(0.02) == .ordinary)
        #expect(MediaRoutingThresholds.adultLane(0.25) == .ordinary)
        #expect(MediaRoutingThresholds.adultLane(0.5) == .unclear)
        #expect(MediaRoutingThresholds.adultLane(0.26) == .unclear)
        #expect(MediaRoutingThresholds.adultLane(0.59) == .unclear)
        // The same numbers the shared gate would give.
        for probability in stride(from: 0.0, through: 1.0, by: 0.01) {
            let shared = JevThresholds.noulBand(
                probability, yes: MediaRoutingThresholds.adultContentYes,
                no: MediaRoutingThresholds.adultContentNo
            )
            #expect((MediaRoutingThresholds.adultLane(probability) == .unclear)
                    == (shared == .escalate))
        }
    }

    @Test func aFlatScoreIsNotUsed() {
        let sure = RoutingFixtures.answers(clipLength: (2.4, 0.8))
        #expect(sure.level("clip_length", of: 4) == 2)
        let unsure = RoutingFixtures.answers(clipLength: (2.4, 0.1))
        #expect(unsure.level("clip_length", of: 4) == nil)
        // Rounded to a level rather than read as a number between two of them.
        #expect(RoutingFixtures.answers(clipLength: (1.6, 0.8)).level("clip_length", of: 4) == 2)
        #expect(RoutingFixtures.answers(clipLength: (9, 0.8)).level("clip_length", of: 4) == 3)
        #expect(RoutingFixtures.answers(clipLength: (-3, 0.8)).level("clip_length", of: 4) == 0)
    }
}

// MARK: - Policy

@Suite("Media routing policy")
struct MediaRoutingPolicyTests {

    @Test func aNamedModelIsUsedWhateverJevPicked() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(model: "hailuo-h3", confidence: 0.99),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults(explicit: "wan22-ti2v-5b")
        )
        let decision = try #require(RoutingFixtures.routed(outcome))
        #expect(decision.modelID == "wan22-ti2v-5b")
        #expect(decision.reason.hasPrefix("You chose Wan 2.2 5B"))
        #expect(!decision.isUnsure)
    }

    /// Even the uncensored lane, and even for an ordinary prompt: naming it is an
    /// instruction, and the gate exists to stop the app guessing, not to stop the owner.
    @Test func aNamedUncensoredLaneIsNotVetoed() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(adult: 0.01),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults(explicit: "ltx23-uncensored")
        )
        #expect(RoutingFixtures.routed(outcome)?.modelID == "ltx23-uncensored")
    }

    @Test func anAdultPromptGoesToTheUncensoredLaneEvenWhenJevPickedAnother() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(model: "wan22-ti2v-5b", confidence: 0.95, adult: 0.88),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        let decision = try #require(RoutingFixtures.routed(outcome))
        #expect(decision.modelID == "ltx23-uncensored")
        #expect(decision.reason.contains("adult content"))
    }

    @Test func anOrdinaryPromptNeverReachesTheUncensoredLane() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "ltx23-uncensored", confidence: 0.97, adult: 0.05
            ),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        let decision = try #require(RoutingFixtures.routed(outcome))
        #expect(decision.modelID != "ltx23-uncensored")
        #expect(!decision.reason.contains("adult content"))
    }

    @Test func anAdultPromptWithNoUncensoredLaneIsRefusedRatherThanRerouted() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(adult: 0.9),
            candidates: [RoutingFixtures.wan, RoutingFixtures.h3], kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        let message = try #require(RoutingFixtures.refusal(outcome),
                                   "an adult prompt with nowhere to go must refuse, not route")
        #expect(message.contains("no uncensored lane is installed and ready"))
    }

    /// An uncensored lane nothing can run is not a destination. Routing to it queues an
    /// adult prompt against a dead model and tells nobody, which is worse than refusing.
    @Test func anUncensoredLaneNothingCanRunIsNotADestination() throws {
        let candidates = [
            RoutingFixtures.wan, RoutingFixtures.h3, RoutingFixtures.uninstalledUncensored,
        ]
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "ltx23-uncensored", confidence: 0.99, adult: 0.92
            ),
            candidates: candidates, kind: .video, defaults: RoutingFixtures.defaults()
        )
        let message = try #require(RoutingFixtures.refusal(outcome))
        #expect(message.contains("no uncensored lane is installed and ready"))
        // The same prompt with the lane installed routes to it.
        let ready = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "ltx23-uncensored", confidence: 0.99, adult: 0.92
            ),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        #expect(RoutingFixtures.routed(ready)?.modelID == "ltx23-uncensored")
    }

    /// B2. No lane, no setting and no named model buys a way past this one.
    @Test func sexualContentOfANamedRealPersonIsNeverRouted() throws {
        for defaults in [
            RoutingFixtures.defaults(),
            RoutingFixtures.defaults(explicit: "ltx23-uncensored"),
            RoutingFixtures.defaults(automaticUncensoredLane: false),
        ] {
            let outcome = MediaRoutingPolicy.choose(
                answers: RoutingFixtures.answers(
                    model: "ltx23-uncensored", confidence: 0.99, adult: 0.93, realPerson: 0.8
                ),
                candidates: RoutingFixtures.video, kind: .video, defaults: defaults
            )
            let message = try #require(RoutingFixtures.refusal(outcome))
            #expect(message.contains("named real person"))
            #expect(message.contains("nothing was queued"))
        }
        // Either half alone is not the rule: a named person in an ordinary prompt routes,
        // and adult content without one routes.
        let ordinary = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(adult: 0.02, realPerson: 0.95),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        #expect(RoutingFixtures.routed(ordinary) != nil)
        let anonymous = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(adult: 0.95, realPerson: 0.04),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        #expect(RoutingFixtures.routed(anonymous)?.modelID == "ltx23-uncensored")
    }

    /// F10. "None of these" is an answer, not a reason to take the runner-up.
    @Test func noneOfTheseFallsBackToTheOwnersDefaultAndSaysSo() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: MediaRoutingQuestions.noMatchOption, confidence: 0.92,
                probabilities: [MediaRoutingQuestions.noMatchOption: 0.92, "hailuo-h3": 0.05]
            ),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults(fallback: "wan22-ti2v-5b")
        )
        let decision = try #require(RoutingFixtures.routed(outcome))
        #expect(decision.modelID == "wan22-ti2v-5b")
        #expect(decision.reason.contains("no installed model fits, kept your default"))
    }

    /// F5. A named length is exact or it is a refusal — never quietly rounded, which is how
    /// somebody asking for fifteen seconds pays for five.
    @Test func aNamedLengthNoLaneServesIsRefusedWithTheOnesThatExist() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(),
            candidates: [RoutingFixtures.wan, RoutingFixtures.ltx], kind: .video,
            defaults: .init(fallbackModelID: "wan22-ti2v-5b", explicitSeconds: 9, seconds: 5)
        )
        let message = try #require(RoutingFixtures.refusal(outcome))
        #expect(message.contains("9 second clip"))
        #expect(message.contains("3, 5 seconds"))
        // And a named model that cannot do it is refused by id, not silently re-lengthed.
        let named = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: .init(
                explicitModelID: "wan22-ti2v-5b", fallbackModelID: "wan22-ti2v-5b",
                explicitSeconds: 15, seconds: 5
            )
        )
        #expect(try #require(RoutingFixtures.refusal(named)).contains("wan22-ti2v-5b"))
    }

    /// F6. Never queue against a lane nothing can run when a ready one would do.
    @Test func aConfidentPickStillPrefersALaneSomethingCanRun() throws {
        var dead = RoutingFixtures.h3
        dead.isReady = false
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "hailuo-h3", confidence: 0.98,
                probabilities: ["hailuo-h3": 0.98, "ltx2-distilled": 0.01, "wan22-ti2v-5b": 0.01]
            ),
            candidates: [dead, RoutingFixtures.ltx, RoutingFixtures.wan], kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        #expect(RoutingFixtures.routed(outcome)?.modelID == "ltx2-distilled")
        // With nothing ready at all the queue still takes it — a durable queue waits for a
        // node, which is what it did before any of this existed.
        var alsoDead = RoutingFixtures.ltx
        alsoDead.isReady = false
        let nothingReady = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(model: "hailuo-h3", confidence: 0.98),
            candidates: [dead, alsoDead], kind: .video, defaults: RoutingFixtures.defaults()
        )
        #expect(RoutingFixtures.routed(nothingReady)?.modelID == "hailuo-h3")
    }

    /// The length the app already had, when the prompt did not say.

    /// F11. The message tells a headless caller what to do, and does not name the lane it
    /// would have used — that would be a one-line guide to stepping around the setting.
    @Test func withAutomaticRoutingOffAnAdultPromptIsRefusedNotQueued() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(adult: 0.9),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults(automaticUncensoredLane: false)
        )
        let message = try #require(RoutingFixtures.refusal(outcome),
                                   "with automatic routing off nothing may be queued")
        #expect(message.contains("switched off"))
        #expect(message.contains("allow it in Settings"))
        #expect(!message.contains("LTX-2.3 Uncensored"))
        #expect(!message.contains("ltx23-uncensored"))
    }

    /// The middle of the gate is not "probably fine". A noul near a half means as likely as
    /// not, and either lane may reject the job.
    @Test func anUnclearAdultAnswerAsksRatherThanGuessing() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(adult: 0.45),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        let message = try #require(RoutingFixtures.refusal(outcome),
                                   "an ambiguous adult answer must not pick a lane")
        #expect(message.contains("could not tell"))
        // Written for a caller with no dialog to show: it says what to change.
        #expect(message.contains("Say explicitly in the prompt whether this is adult content"))
        #expect(message.contains("name a model id"))
    }

    @Test func aLaneThatCannotRenderTheLengthIsNotACandidate() throws {
        // "A long take" — only H3 goes to fifteen seconds.
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "ltx2-distilled", confidence: 0.99, clipLength: (3, 0.9)
            ),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        let decision = try #require(RoutingFixtures.routed(outcome))
        #expect(decision.modelID == "hailuo-h3")
        #expect(decision.seconds == 15)
    }

    @Test func theLengthSnapsToWhatTheChosenLaneActuallyServes() throws {
        // "A scene, about 8 to 10 seconds" — the uncensored merge stops at 8, H3 at 10.
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "hailuo-h3", confidence: 0.99, clipLength: (2, 0.9)
            ),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        #expect(RoutingFixtures.routed(outcome)?.seconds == 10)

        let uncensored = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "ltx23-uncensored", confidence: 0.99, adult: 0.9,
                clipLength: (2, 0.9)
            ),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        #expect(RoutingFixtures.routed(uncensored)?.seconds == 8)
    }

    /// A length the caller named is an instruction too — the router may still pick the
    /// lane, but only from the lanes that can render it.
    @Test func aNamedLengthIsHonouredAndStillVetoesLanes() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "wan22-ti2v-5b", confidence: 0.99, clipLength: (0, 0.95)
            ),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: .init(fallbackModelID: "wan22-ti2v-5b", explicitSeconds: 15, seconds: 5)
        )
        let decision = try #require(RoutingFixtures.routed(outcome))
        // Jev said "a moment"; the caller said fifteen seconds, and only one lane does that.
        #expect(decision.seconds == 15)
        #expect(decision.modelID == "hailuo-h3")
    }

    /// The length the app already had, when the prompt did not say.
    @Test func aFlatLengthAnswerKeepsTheUsersOwnSetting() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "wan22-ti2v-5b", confidence: 0.95, clipLength: (3, 0.05)
            ),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults(seconds: 3)
        )
        let decision = try #require(RoutingFixtures.routed(outcome))
        #expect(decision.modelID == "wan22-ti2v-5b")
        #expect(decision.seconds == 3)
    }

    /// When nothing can do the asked-for length, a clip of the nearest length beats a
    /// refusal nobody can act on — but the line says the length moved.
    @Test func anImpossibleLengthClampsAndSaysSo() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "wan22-ti2v-5b", confidence: 0.99, clipLength: (3, 0.9)
            ),
            candidates: [RoutingFixtures.wan, RoutingFixtures.ltx], kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        let decision = try #require(RoutingFixtures.routed(outcome))
        #expect(decision.seconds == 5)
        #expect(decision.reason.contains("no lane renders 15 s"))
    }

    @Test func aLowConfidenceChoiceKeepsTheUsersDefaultAndSaysJevWasUnsure() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "hailuo-h3", confidence: 0.2,
                probabilities: ["hailuo-h3": 0.2, "ltx2-distilled": 0.19, "wan22-ti2v-5b": 0.18]
            ),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults(fallback: "wan22-ti2v-5b")
        )
        let decision = try #require(RoutingFixtures.routed(outcome))
        #expect(decision.modelID == "wan22-ti2v-5b")
        #expect(decision.isUnsure)
        #expect(decision.reason.contains("Jev unsure, kept your default"))
    }

    /// Only fairly sure: take the pick that can actually run, not the one that cannot.
    @Test func aModerateConfidenceChoicePrefersALaneThatCanRunNow() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "ltx23-uncensored", confidence: 0.4,
                probabilities: ["ltx23-uncensored": 0.4, "wan22-ti2v-5b": 0.3], adult: 0.9
            ),
            candidates: [RoutingFixtures.ltxUncensored, RoutingFixtures.wan], kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        // The only uncensored lane is not ready, and an adult prompt may not go elsewhere:
        // "prefer ready" is a preference, not a licence to break the gate.
        #expect(RoutingFixtures.routed(outcome)?.modelID == "ltx23-uncensored")

        let ordinary = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "hailuo-h3", confidence: 0.4,
                probabilities: ["hailuo-h3": 0.4, "ltx2-distilled": 0.35]
            ),
            candidates: [
                MediaCandidate(
                    id: "hailuo-h3", name: "H3", goodAt: "x", supportedSeconds: [5],
                    runsOn: "nowhere", isReady: false
                ),
                RoutingFixtures.ltx,
            ],
            kind: .video, defaults: RoutingFixtures.defaults()
        )
        #expect(RoutingFixtures.routed(ordinary)?.modelID == "ltx2-distilled")
    }

    @Test func detailLevelDrivesTheLanesOwnControlAndNothingElse() throws {
        func decide(_ level: Double, _ candidates: [MediaCandidate], _ model: String)
            -> MediaRoutingDecision? {
            RoutingFixtures.routed(MediaRoutingPolicy.choose(
                answers: RoutingFixtures.answers(
                    model: model, confidence: 0.99, clipLength: (1, 0.9), detail: (level, 0.9)
                ),
                candidates: candidates, kind: candidates[0].supportedSeconds.isEmpty ? .image : .video,
                defaults: RoutingFixtures.defaults()
            ))
        }
        let h3Only = [RoutingFixtures.h3]
        #expect(decide(0, h3Only, "hailuo-h3")?.h3Turbo == true)
        #expect(decide(0, h3Only, "hailuo-h3")?.h3Steps == nil)
        #expect(decide(1, h3Only, "hailuo-h3")?.h3Turbo == nil)
        #expect(decide(2, h3Only, "hailuo-h3")?.h3Turbo == false)
        #expect(decide(2, h3Only, "hailuo-h3")?.h3Steps == 20)

        // A lane with no per-clip control gets none invented for it: an unadvertised
        // parameter is a job the node refuses.
        let wanOnly = [RoutingFixtures.wan]
        for level in [0.0, 1, 2] {
            let decision = decide(level, wanOnly, "wan22-ti2v-5b")
            #expect(decision?.h3Turbo == nil && decision?.h3Steps == nil && decision?.steps == nil)
        }

        // F14. A distilled model's four steps are how it was trained, not a dial: halving
        // them is mush and doubling them is the same picture, slower. Left alone.
        let fluxOnly = [RoutingFixtures.flux]
        for level in [0.0, 1, 2] {
            #expect(decide(level, fluxOnly, "flux1-schnell")?.steps == 4)
        }
        // An undistilled model has a real range to move along.
        let qwenOnly = [RoutingFixtures.qwenImage]
        #expect(decide(0, qwenOnly, "qwen-image")?.steps == 10)
        #expect(decide(1, qwenOnly, "qwen-image")?.steps == 20)
        #expect(decide(2, qwenOnly, "qwen-image")?.steps == 40)
        // And the app's own 1...200 bound is never crossed.
        let heavy = MediaCandidate(
            id: "x", name: "X", goodAt: "x", runsOn: MediaCandidate.thisMac, isReady: true,
            supportsStepCount: true, defaultSteps: 150
        )
        #expect(decide(2, [heavy], "x")?.steps == 200)
    }

    /// The line the queue carries. It is a record of the decision, so it has to be built
    /// from the same numbers the decision was.
    @Test func theReasonNamesTheLaneTheLengthAndWhatDroveIt() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "ltx2-distilled", confidence: 0.95, people: 0.05, motion: 0.9,
                clipLength: (1, 0.9)
            ),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        let decision = try #require(RoutingFixtures.routed(outcome))
        #expect(decision.reason == "Auto → LTX-2 distilled (5 s): motion-heavy, no people")
    }

    /// F7. Every noul this feature pays for is read somewhere. The two that do not gate a
    /// lane earn their tokens in the line the owner reads.
    @Test func everyQuestionAskedShowsUpInADecision() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "wan22-ti2v-5b", confidence: 0.95, people: 0.9, motion: 0.4,
                violence: 0.85, brand: 0.9, detail: (2, 0.9)
            ),
            candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        let reason = try #require(RoutingFixtures.routed(outcome)).reason
        #expect(reason.contains("graphic violence"))
        #expect(reason.contains("named brand"))
        #expect(reason.contains("people"))
    }

    @Test func theReasonStillSaysSomethingWhenNothingStandsOut() throws {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(
                model: "flux1-schnell", confidence: 0.9, people: 0.4, motion: 0.4,
                detail: (1, 0.9)
            ),
            candidates: [RoutingFixtures.flux], kind: .image,
            defaults: RoutingFixtures.defaults(fallback: "flux1-schnell")
        )
        let decision = try #require(RoutingFixtures.routed(outcome))
        #expect(decision.reason == "Auto → FLUX.1 schnell: best fit for this prompt")
        #expect(decision.seconds == nil)
    }

    @Test func noCandidatesIsARefusalRatherThanACrash() {
        let outcome = MediaRoutingPolicy.choose(
            answers: RoutingFixtures.answers(), candidates: [], kind: .image,
            defaults: RoutingFixtures.defaults()
        )
        guard case .refuse = outcome else {
            Issue.record("an empty candidate list must refuse")
            return
        }
    }

    /// Nothing in the policy reaches for a clock, a file or a network, so the same answers
    /// give the same decision every time.
    @Test func theSameAnswersAlwaysGiveTheSameDecision() {
        let answers = RoutingFixtures.answers(
            model: "ltx2-distilled", confidence: 0.6,
            probabilities: ["ltx2-distilled": 0.34, "wan22-ti2v-5b": 0.33, "hailuo-h3": 0.33]
        )
        let first = MediaRoutingPolicy.choose(
            answers: answers, candidates: RoutingFixtures.video, kind: .video,
            defaults: RoutingFixtures.defaults()
        )
        for _ in 0..<20 {
            #expect(MediaRoutingPolicy.choose(
                answers: answers, candidates: RoutingFixtures.video, kind: .video,
                defaults: RoutingFixtures.defaults()
            ) == first)
        }
    }
}

// MARK: - The enqueue path

/// Points `SwarmConfig` at a path that does not exist, so a routed enqueue polls nothing.
/// Without it these tests would read whoever's swarm is configured on the machine running
/// them and go to the network for it.
struct NoSwarmConfig: SuiteTrait, TestTrait {
    func prepare(for test: Test) async throws {
        setenv(
            "SILICON_SWARM_CONFIG",
            FileManager.default.temporaryDirectory
                .appendingPathComponent("no-such-swarm-\(UUID()).json").path,
            1
        )
    }
}

extension Trait where Self == NoSwarmConfig {
    static var noSwarmConfig: Self { Self() }
}

@Suite("Media routing in the app", .serialized, .redirectedConversationStore, .noSwarmConfig)
@MainActor
struct MediaRoutingAppTests {

    /// Jev's side of a routed video request: one model choice, every noul, both scores.
    nonisolated static func answer(
        model: String = "ltx2-distilled", confidence: Double = 0.94, adult: Double = 0.02,
        clipLength: Double = 1
    ) -> String {
        var answers: [String] = [
            #"{"type":"choice","choice":"\#(model)","confidence":\#(confidence),"#
            + #""probabilities":{"\#(model)":\#(confidence)}}"#,
        ]
        var body = #""model":\#(answers[0])"#
        answers = []
        for name in MediaRoutingQuestions.noulNames {
            let value: Double
            switch name {
            case "adult_content": value = adult
            case "motion_heavy": value = 0.85
            case "depicts_people": value = 0.05
            default: value = 0.05
            }
            answers.append(#""\#(name)":{"type":"noul","noul":\#(value)}"#)
        }
        for (name, score) in [("clip_length", clipLength), ("detail_level", 1.0)] {
            answers.append(
                #""\#(name)":{"type":"score","score":\#(score),"confidence":0.85,"#
                + #""legend":{},"probabilities":{"\#(Int(score))":0.85}}"#
            )
        }
        body += "," + answers.joined(separator: ",")
        return #"{"model":"jev-1.13.0","usage":{"input_tokens":900,"output_tokens":40},"#
            + #""answers":{\#(body)}}"#
    }

    /// A `JevService` of this test's own, pointed at a loopback double and a private
    /// settings file — never the shared singleton and never the owner's `jev.json`.
    static func route(
        _ body: @escaping @Sendable () -> String
    ) async throws -> (harness: JevHarness, server: CapturingServer) {
        let server = try CapturingServer { _, _ in .init(body: body()) }
        let harness = JevHarness()
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.service.update { settings in
            settings.enabled = true
            settings.features[.mediaRouting] = true
            // Two identical batches in one test must each reach the server.
            settings.cacheMinutes = 0
        }
        return (harness, server)
    }

    /// The app's own candidate list, not a hand-written one: this is the test that notices
    /// `videoRoutingCandidates()` handing the policy something it cannot use.
    @Test func theAppOffersTheWholeCatalogWithReadinessFromTheSwarm() {
        let model = freshModel()
        let candidates = model.videoRoutingCandidates()
        #expect(candidates.map(\.id) == VideoCatalog.all.map(\.id))
        // No swarm in a test, so nothing is ready — and that is what makes an adult prompt
        // refuse rather than queue against a lane no machine offers.
        #expect(candidates.allSatisfy { !$0.isReady })
        #expect(candidates.allSatisfy { $0.runsOn == MediaCandidate.pairedMachine })
        #expect(candidates.contains { $0.isUncensored })
        #expect(!model.hasUncensoredVideoLane)
    }

    @Test func aRoutedBatchPicksTheLaneAndRecordsWhy() async throws {
        let (harness, server) = try await Self.route { Self.answer() }
        defer { server.stop(); harness.clean() }

        let model = freshModel()
        model.selectedVideoModel = VideoCatalog.wan22.id
        let view = try await MediaRouter.$override.withValue(harness.service) {
            try await model.enqueueVideos(ControlAPI.VideoQueueRequest(
                prompts: ["a fox sprinting through long grass"], title: "Routed",
                modelID: MediaRoutingQuestions.autoModelID
            ))
        }
        let item = try #require(view.items.first)
        #expect(item.modelID == "ltx2-distilled")
        #expect(item.seconds == 5)
        #expect(item.detail == "Auto → LTX-2 distilled (5 s): motion-heavy, no people")
        #expect(model.videoBatchQueue.items.first?.detail == item.detail)
        // One request, every question in it.
        #expect(server.requests.count == 1)
        let sent = try #require(server.requests.first)
        #expect(sent.path == "/v1/systemone")
        let asked = try #require(
            (try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])?["questions"]
                as? [String: Any]
        )
        #expect(Set(asked.keys) == Set(
            MediaRoutingQuestions.noulNames + MediaRoutingQuestions.scoreNames + ["model"]
        ))
        // The key never appears in what was sent, only in the header.
        #expect(!String(decoding: sent.body, as: UTF8.self).contains("sk-fixture"))
    }

    /// The whole promise of the feature switch: off, this path is byte for byte what it was
    /// — no request, no message, no change to what gets queued.
    @Test func withoutJevAnAutoBatchIsTodaysBehaviour() async throws {
        let server = try untouchedServer("media routing is switched off")
        let harness = JevHarness()
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        defer { server.stop(); harness.clean() }

        let model = freshModel()
        model.selectedVideoModel = VideoCatalog.wan22.id
        model.videoSeconds = 3
        let view = try await MediaRouter.$override.withValue(harness.service) {
            try await model.enqueueVideos(ControlAPI.VideoQueueRequest(
                prompts: ["a fox sprinting"], modelID: MediaRoutingQuestions.autoModelID
            ))
        }
        let item = try #require(view.items.first)
        #expect(item.modelID == VideoCatalog.wan22.id)
        #expect(item.seconds == 3)
        #expect(item.detail == nil)
        // Nothing was sent, nothing was spent, and nothing was said about it.
        #expect(server.requests.isEmpty)
        #expect(await harness.service.ledger().month().total.calls == 0)
        // The queue worker's own "waiting for a node" line is today's behaviour and still
        // appears; what must not appear is anything about routing.
        #expect(view.message == nil)
        #expect(model.videoQueueMessage?.contains("Jev") != true)
    }

    /// F12. The image half: "auto" resolves to a real entry, the steps come with it, and a
    /// step count the caller named outranks the router's.
    @Test func anAutoImageRequestIsRoutedAndKeepsWhatTheCallerNamed() async throws {
        let model = freshModel()
        // Whichever entries this machine has: the point is that the router's pick is used,
        // not that a particular model is installed on whoever runs the tests.
        let candidate = try #require(model.imageRoutingCandidates().first)
        let entry = try #require(DiffusionCatalog.entry(id: candidate.id))
        let (harness, server) = try await Self.route { Self.answer(model: candidate.id) }
        defer { server.stop(); harness.clean() }

        let routed = try await MediaRouter.$override.withValue(harness.service) {
            try await model.mediaRoutedImage(.init(prompt: "a fox", modelID: "auto"))
        }
        #expect(routed.request.modelID == candidate.id)
        #expect(routed.reason?.hasPrefix("Auto → \(entry.name)") == true)
        // Steps came from the router, because the caller named none.
        #expect(routed.request.steps == entry.shape.defaultSteps)

        let named = try await MediaRouter.$override.withValue(harness.service) {
            try await model.mediaRoutedImage(.init(prompt: "a fox", modelID: "auto", steps: 17))
        }
        #expect(named.request.steps == 17)
    }

    /// A swarm node's `auto` render is chosen among free lanes only. With nothing but Jev to
    /// route it, that means not routed at all — the same fall-back an omitted model has
    /// always had — and nothing is sent or spent. The owner's own `auto` a moment later is
    /// routed, so the door is shut for the peer rather than simply broken.
    @Test func aSwarmNodesAutoRenderNeverAsksThePaidRouter() async throws {
        let (harness, server) = try await Self.route { Self.answer() }
        defer { server.stop(); harness.clean() }
        let model = freshModel()
        let prompt = "a fox sprinting through long grass"

        let (clip, image) = try await MediaRouter.$override.withValue(harness.service) {
            try await PaidLanes.$allowed.withValue(false) {
                (
                    try await model.mediaRoutedVideo(
                        prompt: prompt, explicitModelID: "auto", seconds: nil
                    ),
                    try await model.mediaRoutedImage(.init(prompt: prompt, modelID: "auto"))
                )
            }
        }
        #expect(clip == nil)
        #expect(image.request.modelID == nil)
        #expect(image.reason == nil)
        #expect(server.requests.isEmpty)
        #expect(await harness.service.ledger().month().total.calls == 0)

        let owner = try await MediaRouter.$override.withValue(harness.service) {
            try await model.mediaRoutedVideo(prompt: prompt, explicitModelID: "auto", seconds: nil)
        }
        #expect(owner?.modelID == "ltx2-distilled")
        #expect(server.requests.count == 1)
    }

    /// B3. `localOnly` says this prompt must not leave the Mac. Routing it would send it to
    /// TypeSafe, which is exactly what the caller forbade.
    @Test func aLocalOnlyImageRequestNeverReachesJev() async throws {
        let server = try untouchedServer("the caller asked for local only")
        let harness = JevHarness()
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.service.update { settings in
            settings.enabled = true
            settings.features[.mediaRouting] = true
        }
        defer { server.stop(); harness.clean() }

        let model = freshModel()
        let routed = try await MediaRouter.$override.withValue(harness.service) {
            try await model.mediaRoutedImage(
                .init(prompt: "a fox", modelID: "auto", localOnly: true)
            )
        }
        // Normalised, so the request still works — and nothing was sent.
        #expect(routed.request.modelID == nil)
        #expect(routed.reason == nil)
        #expect(server.requests.isEmpty)
    }

    /// With the feature off, "auto" is still a word the tools advertise, so it has to mean
    /// what an omitted model has always meant rather than an unknown-model error.
    @Test func autoNormalisesToTodaysDefaultWhenRoutingIsOff() async throws {
        let server = try untouchedServer("media routing is switched off")
        let harness = JevHarness()
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        defer { server.stop(); harness.clean() }

        let model = freshModel()
        let routed = try await MediaRouter.$override.withValue(harness.service) {
            try await model.mediaRoutedImage(.init(prompt: "a fox", modelID: "auto"))
        }
        #expect(routed.request.modelID == nil)
        #expect(routed.reason == nil)
        // And it really resolves to something, rather than throwing unknownModel("auto").
        let plan = try await model.planImage(.init(prompt: "a fox", modelID: "auto"))
        #expect(plan.steps > 0)
        #expect(server.requests.isEmpty)
    }

    /// Plan then generate is one charge, not two: same prompt, same candidates, same
    /// questions, so the service's cache answers the second.
    @Test func planThenGenerateAsksOnce() async throws {
        let (harness, server) = try await Self.route {
            Self.answer(model: "flux1-schnell")
        }
        defer { server.stop(); harness.clean() }
        // The app's own default, not this test's: zero would make the point vacuous.
        try await harness.service.update { $0.cacheMinutes = 10 }

        let model = freshModel()
        try await MediaRouter.$override.withValue(harness.service) {
            _ = try await model.mediaRoutedImage(.init(prompt: "a fox", modelID: "auto"))
            _ = try await model.mediaRoutedImage(.init(prompt: "a fox", modelID: "auto"))
        }
        #expect(server.requests.count == 1)
        #expect(await harness.service.ledger().month().total.calls == 1)
    }

    /// The image candidates are the ones this Mac could actually start on.
    @Test func imageCandidatesAreTheInstalledOnesOrTheCatalog() {
        let model = freshModel()
        let candidates = model.imageRoutingCandidates()
        #expect(!candidates.isEmpty)
        #expect(candidates.allSatisfy { !$0.isUncensored })
        #expect(candidates.allSatisfy { $0.supportedSeconds.isEmpty })
        let known = Set(DiffusionCatalog.all.map(\.id))
        #expect(candidates.allSatisfy { known.contains($0.id) })
        #expect(candidates.allSatisfy {
            $0.runsOn == MediaCandidate.thisMac || $0.runsOn == MediaCandidate.pairedMachine
        })
    }

    /// F9. The toggle is a stored preference and outlives the thing that makes it work.
    /// Turning Jev off must put the composer back to exactly what it did before — the model,
    /// the length and the sampling controls all of them.
    @Test func theComposerToggleOnlyCountsWhileRoutingCanHappen() async throws {
        let harness = JevHarness()
        await harness.configure(key: nil, baseURL: URL(string: "http://127.0.0.1:1")!)
        defer { harness.clean() }
        // The owner asked for it, but there is no key, so nothing can route.
        try await harness.service.update { settings in
            settings.enabled = true
            settings.features[.mediaRouting] = true
            settings.composerAutoRoute = true
        }

        let model = freshModel()
        model.selectedVideoModel = VideoCatalog.hailuoH3.id
        model.videoSeconds = 10
        model.videoSampling = .turbo
        let request = await MediaRouter.$override.withValue(harness.service) {
            await model.composerRequest(prompts: "a fox", seed: 7)
        }
        #expect(request.modelID == VideoCatalog.hailuoH3.id)
        #expect(request.seconds == 10)
        #expect(request.h3Turbo == true)

        // With a key it asks, and hands the lot to the router instead.
        let ready = JevHarness()
        await ready.configure(baseURL: URL(string: "http://127.0.0.1:1")!)
        defer { ready.clean() }
        try await ready.service.update { settings in
            settings.enabled = true
            settings.features[.mediaRouting] = true
            settings.composerAutoRoute = true
        }
        let routed = await MediaRouter.$override.withValue(ready.service) {
            await model.composerRequest(prompts: "a fox", seed: 7)
        }
        #expect(routed.modelID == MediaRoutingQuestions.autoModelID)
        #expect(routed.seconds == nil)
        #expect(routed.h3Turbo == nil)
    }

    /// F16. An MCP caller that passed `model_id: "auto"` has no queue to read, so the
    /// synchronous response is the only place it can learn what it got.
    @Test func theSynchronousVideoResponseCarriesTheRoutingLine() async throws {
        let model = freshModel()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-response-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let item = try model.videoBatchQueue.enqueueSingle(
            VideoRequest(
                entryID: VideoCatalog.ltx2.id, prompt: "a fox", seconds: 5,
                resolution: "720p", outputDirectory: directory
            ),
            detail: "Auto → LTX-2 distilled (5 s): motion-heavy, no people"
        )
        let file = directory.appendingPathComponent("clip.mp4")
        try Data("clip".utf8).write(to: file)
        try model.videoBatchQueue.complete(item.id, result: .init(
            file: file, modelName: "LTX-2 distilled", prompt: "a fox", elapsed: 12
        ))

        let response = try await model.waitForQueuedVideo(item.id, timeout: 5)
        #expect(response.detail == "Auto → LTX-2 distilled (5 s): motion-heavy, no people")
        #expect(response.model == VideoCatalog.ltx2.id)
    }

    /// The single-clip button with the toggle off is `generateVideo()` and nothing else.
    @Test func theClipButtonWithRoutingOffIsTodaysButton() async throws {
        let server = try untouchedServer("the composer toggle is off")
        let harness = JevHarness()
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.service.update { settings in
            settings.enabled = true
            settings.features[.mediaRouting] = true
            settings.composerAutoRoute = false
        }
        defer { server.stop(); harness.clean() }

        let model = freshModel()
        model.selectedVideoModel = VideoCatalog.wan22.id
        model.videoSeconds = 3
        model.videoPrompt = "a fox sprinting"
        await MediaRouter.$override.withValue(harness.service) {
            model.enqueueVideoClip()
            // The button hands off to a task; wait for the queue rather than for a clock.
            for _ in 0..<200 where model.videoBatchQueue.items.isEmpty {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let item = try #require(model.videoBatchQueue.items.first)
        #expect(item.request.entryID == VideoCatalog.wan22.id)
        #expect(item.request.seconds == 3)
        #expect(item.detail == nil)
        #expect(model.videoPrompt.isEmpty)
        #expect(server.requests.isEmpty)
    }

    @Test func anExplicitModelIsNeverRouted() async throws {
        let server = try untouchedServer("the caller named a model")
        let harness = JevHarness()
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.service.update { settings in
            settings.enabled = true
            settings.features[.mediaRouting] = true
        }
        defer { server.stop(); harness.clean() }

        let model = freshModel()
        let view = try await MediaRouter.$override.withValue(harness.service) {
            try await model.enqueueVideos(ControlAPI.VideoQueueRequest(
                prompts: ["a fox"], modelID: VideoCatalog.hailuoH3.id, seconds: 15
            ))
        }
        #expect(view.items.first?.modelID == VideoCatalog.hailuoH3.id)
        #expect(view.items.first?.seconds == 15)
        #expect(view.items.first?.detail == nil)
        #expect(server.requests.isEmpty)
    }

    @Test func aRoutedRequestIsBilledToMediaRouting() async throws {
        let (harness, server) = try await Self.route { Self.answer() }
        defer { server.stop(); harness.clean() }

        let model = freshModel()
        _ = try await MediaRouter.$override.withValue(harness.service) {
            try await model.enqueueVideos(
                ControlAPI.VideoQueueRequest(prompts: ["a fox"], modelID: "auto")
            )
        }

        let month = await harness.service.ledger().month()
        #expect(month.total.calls == 1)
        #expect(month.features["mediaRouting"]?.calls == 1)
        #expect(month.features["mediaRouting"]?.inputTokens == 900)
        #expect(month.features["decideTool"] == nil)
        #expect(month.models == ["jev-1.13.0": 1])
    }

    /// The feature is wired up, so Settings must offer it rather than caption it "coming".
    @Test func theFeatureIsBuilt() {
        #expect(JevFeature.mediaRouting.isBuilt)
        // Still off until the owner turns it on.
        #expect(!JevSettings().isOn(.mediaRouting))
    }

    /// The default is a question asked every time, not a value frozen the first time a
    /// settings window was drawn: a Mac that installs a lane next week gets the sensible
    /// answer without anyone having opened Settings.
    @Test func theUncensoredDefaultTracksWhatIsInstalledUntilTheOwnerSays() {
        var settings = JevSettings()
        #expect(settings.automaticUncensoredLane == nil)
        #expect(settings.automaticUncensoredLane(uncensoredLaneInstalled: true))
        #expect(!settings.automaticUncensoredLane(uncensoredLaneInstalled: false))

        settings.automaticUncensoredLane = false
        #expect(!settings.automaticUncensoredLane(uncensoredLaneInstalled: true))
        settings.automaticUncensoredLane = true
        #expect(settings.automaticUncensoredLane(uncensoredLaneInstalled: false))
    }

    /// Both toggles are in the governed file, so `GET /jev` shows them and `POST /jev` can
    /// set them — and a file written before they existed still loads.
    @Test func bothMediaTogglesSurviveTheSettingsFile() throws {
        var settings = JevSettings()
        settings.automaticUncensoredLane = false
        settings.composerAutoRoute = true
        let round = try JSONDecoder().decode(
            JevSettings.self, from: JSONEncoder().encode(settings)
        )
        #expect(round == settings)

        // "Follow the lane" is absent from the file rather than written as a value.
        let following = try JSONEncoder().encode(JevSettings())
        let object = try #require(
            try JSONSerialization.jsonObject(with: following) as? [String: Any]
        )
        #expect(object["automaticUncensoredLane"] == nil)
        #expect(object["composerAutoRoute"] as? Bool == false)

        let older = Data(#"{"enabled":true,"model":"jev-1.13.0"}"#.utf8)
        let loaded = try JSONDecoder().decode(JevSettings.self, from: older)
        #expect(loaded.automaticUncensoredLane == nil && !loaded.composerAutoRoute)
    }

    /// F15. The seam is a scope, not a switch. Outside one, the app asks the shared service;
    /// inside two concurrent ones, neither sees the other's.
    @Test func theServiceSeamIsScopedAndDoesNotLeak() async {
        #expect(MediaRouter.override == nil)
        #expect(MediaRouter.service === JevService.shared)

        let first = JevService()
        let second = JevService()
        async let a: Bool = MediaRouter.$override.withValue(first) {
            try? await Task.sleep(for: .milliseconds(20))
            return MediaRouter.service === first
        }
        async let b: Bool = MediaRouter.$override.withValue(second) {
            return MediaRouter.service === second
        }
        #expect(await a)
        #expect(await b)
        #expect(MediaRouter.service === JevService.shared)
    }

    /// `warning` is where an image render already reports what the caller should know, so
    /// the routing line joins it rather than inventing a second field.
    @Test func aRoutingLineJoinsAnyWarningWithoutLosingEither() {
        #expect(AppModel.merged(nil, nil) == nil)
        #expect(AppModel.merged("tight on memory", nil) == "tight on memory")
        #expect(AppModel.merged(nil, "Auto → FLUX") == "Auto → FLUX")
        #expect(AppModel.merged("tight", "Auto → FLUX") == "Auto → FLUX · tight")
    }

    /// A model with its own queue and output folders. Enqueueing a clip writes its batch's
    /// manifest into the video folder, and the default one is the owner's own
    /// `~/Movies/Silicon Optimizer`.
    private func freshModel() -> AppModel {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-\(UUID())")
        var settings = Settings()
        settings.videoOutputDirectory = folder.appendingPathComponent("Videos").path
        settings.imageOutputDirectory = folder.appendingPathComponent("Images").path
        settings.meshOutputDirectory = folder.appendingPathComponent("Meshes").path
        // And its own 3D engine folder: with none named, the check searches the home folder
        // and every local disk.
        settings.trellisBaseDirectory = folder.appendingPathComponent("engines").path
        return AppModel(
            videoQueue: VideoBatchQueue(storeURL: folder.appendingPathComponent("queue.json")),
            settings: settings
        )
    }
}

// MARK: - Live

/// Against the real TypeSafe API with a real key, only when both are asked for. Never part
/// of an ordinary run: it costs money. The key is read from the environment at the moment it
/// is used and never printed — not the value, not its length, not a prefix.
@Suite("Media routing, live")
struct MediaRoutingLiveTests {

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SILICON_JEV_LIVE"] == "1"))
    func routesThreePromptsTheWayAPersonWould() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.service.configure(
            keyProvider: { ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] },
            keyIsSet: { ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] != nil },
            configURL: harness.configURL
        )
        try await harness.service.update { settings in
            settings.enabled = true
            settings.features[.mediaRouting] = true
            settings.cacheMinutes = 0
        }
        guard await harness.service.isAvailable(.mediaRouting) else {
            Issue.record("SILICON_JEV_LIVE=1 but TYPESAFE_API_KEY is not set.")
            return
        }
        let candidates = RoutingFixtures.video

        // 1. Fast, short, no people: the iteration lane, a few seconds.
        let quick = try await MediaRoutingQuestions.ask(
            prompt: "quick test render: a paper aeroplane looping once over an empty desk",
            kind: .video, candidates: candidates, using: harness.service
        )
        let quickAnswers = try MediaRoutingAnswers(quick, expectingModel: true)
        #expect(quickAnswers.noul("depicts_people") < 0.5)
        #expect(MediaRoutingThresholds.adultLane(quickAnswers.noul("adult_content")) == .ordinary)
        #expect(quickAnswers.level("detail_level", of: 3) == 0)
        let quickDecision = RoutingFixtures.routed(MediaRoutingPolicy.choose(
            answers: quickAnswers, candidates: candidates, kind: .video,
            defaults: RoutingFixtures.defaults()
        ))
        #expect(try #require(quickDecision).modelID != "ltx23-uncensored")
        print("LIVE quick → \(try #require(quickDecision).reason)")

        // 2. A long, busy scene: the only lane that renders fifteen seconds.
        let long = try await MediaRoutingQuestions.ask(
            prompt: "a fifteen second continuous take: a motorcycle chase through a night "
                + "market, the camera following from behind, sparks and crowds, then the "
                + "rider skids to a halt and looks back",
            kind: .video, candidates: candidates, using: harness.service
        )
        let longAnswers = try MediaRoutingAnswers(long, expectingModel: true)
        #expect(longAnswers.noul("motion_heavy") > 0.5)
        #expect(longAnswers.level("clip_length", of: 4) ?? 0 >= 2)
        let longDecision = try #require(RoutingFixtures.routed(MediaRoutingPolicy.choose(
            answers: longAnswers, candidates: candidates, kind: .video,
            defaults: RoutingFixtures.defaults()
        )))
        #expect((longDecision.seconds ?? 0) >= 8)
        print("LIVE long → \(longDecision.reason)")

        // 3. Explicitly adult: the uncensored lane, and nowhere else.
        let adult = try await MediaRoutingQuestions.ask(
            prompt: "an explicit nude scene: two lovers undressing completely in a bedroom, "
                + "full frontal nudity, sexually explicit",
            kind: .video, candidates: candidates, using: harness.service
        )
        let adultAnswers = try MediaRoutingAnswers(adult, expectingModel: true)
        #expect(MediaRoutingThresholds.adultLane(adultAnswers.noul("adult_content")) == .adult)
        let adultDecision = try #require(RoutingFixtures.routed(MediaRoutingPolicy.choose(
            answers: adultAnswers, candidates: candidates, kind: .video,
            defaults: RoutingFixtures.defaults()
        )))
        #expect(adultDecision.modelID == "ltx23-uncensored")
        print("LIVE adult → \(adultDecision.reason)")

        // It really cost something, and the ledger really has it under this feature.
        #expect(await harness.service.ledger().month().features["mediaRouting"]?.calls == 3)
    }
}

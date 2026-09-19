import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconCore
@testable import SiliconHardware
@testable import SiliconPlanner
@testable import SiliconRuntime
@testable import SiliconUI

// MARK: - Fixtures

/// Answers in the shape Jev sends them, built by name so a test says what it is varying and
/// inherits a sane value for everything else.
///
/// Everything defaults to a confident *no* on the nouls and a moderate difficulty, which is
/// "an ordinary job with no special requirement": the state a test that is about one veto
/// should start from.
struct RecommendationAnswers {
    var vision = 0.02
    var code = 0.02
    var toolCalling = 0.02
    var multilingual = 0.02
    var longContext = 0.02
    var uncensored = 0.01
    var fastResponses = 0.02
    var deepReasoning = 0.02
    var difficulty = 1.0
    var difficultyConfidence = 0.9
    /// Option id → probability. The top one becomes `choice`; `confidence` defaults to it.
    var best: [String: Double]
    var confidence: Double?

    func response() -> ControlAPI.DecideResponse {
        let winner = best.max { left, right in
            left.value == right.value ? left.key > right.key : left.value < right.value
        }
        var answers: [String: ControlAPI.SystemOneAnswer] = [
            "needs_vision": .noul(vision),
            "needs_code": .noul(code),
            "needs_tool_calling": .noul(toolCalling),
            "needs_multilingual": .noul(multilingual),
            "needs_long_context": .noul(longContext),
            "needs_uncensored": .noul(uncensored),
            "needs_fast_responses": .noul(fastResponses),
            "needs_deep_reasoning": .noul(deepReasoning),
            "task_difficulty": .score(
                score: difficulty, confidence: difficultyConfidence,
                legend: [:], probabilities: [:]
            ),
        ]
        if !best.isEmpty {
            answers["best_for_task"] = .choice(
                choice: winner?.key ?? "",
                confidence: confidence ?? winner?.value ?? 0,
                probabilities: best
            )
        }
        return ControlAPI.DecideResponse(
            model: JevService.pinnedModel,
            usage: .init(inputTokens: 1_200, outputTokens: 40),
            answers: answers, provider: "typesafe", latencyMS: 180
        )
    }
}

/// A shortlist that does not depend on the catalog, so a policy test says exactly which
/// trait it is exercising instead of hoping an entry still has it.
func candidate(
    _ id: String, traits: [RecommendationTrait] = [], context: Int = 131_072,
    ceiling: Int? = nil, speed: Double = 30, rating: Int = 4, installed: Bool = false
) -> RecommendationCandidate {
    RecommendationCandidate(
        id: id, name: id.capitalized, family: id.capitalized, parameters: "8B",
        capabilities: RecommendationTrait.allCases.filter(traits.contains),
        // `context` is what this Mac would load; `ceiling` is the catalogue's, which
        // defaults to the same thing because most of the time it is.
        contextLength: context, maxContext: ceiling ?? context,
        quantization: "Q4_K_M", tokensPerSecond: speed,
        rating: rating, isInstalled: installed, isFeatured: false
    )
}

/// A Mac that runs most of the catalogue, so the shortlist is full and the state-size
/// ceiling is measured at the worst case rather than a comfortable one.
let hugeMac = SystemProfile(
    chipName: "Apple M3 Ultra", generation: .m3, variant: .ultra, modelIdentifier: "Mac16,9",
    totalMemory: .gib(512), performanceCores: 24, efficiencyCores: 8, gpuCores: 80,
    neuralEngineCores: 32, diskTotal: .gib(4096), diskFree: .gib(2000),
    memoryBandwidthGBps: 800, ssdReadMBps: 5000
)

let bigMac = SystemProfile(
    chipName: "Apple M3 Max", generation: .m3, variant: .max, modelIdentifier: "Mac15,11",
    totalMemory: .gib(64), performanceCores: 12, efficiencyCores: 4, gpuCores: 40,
    neuralEngineCores: 16, diskTotal: .gib(1024), diskFree: .gib(900),
    memoryBandwidthGBps: 300, ssdReadMBps: 5000
)

func evenFit(_ candidates: [RecommendationCandidate]) -> [String: Double] {
    Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, 1.0) })
}

/// A canned reply in the wire shape, so the ledger test exercises the real client rather
/// than a hand-written `DecideResponse` that never met a JSON decoder.
func cannedRecommendation(for ids: [String]) -> String {
    var best: [String: Double] = [:]
    for (index, id) in ids.enumerated() {
        best[id] = index == 0 ? 0.8 : 0.2 / Double(max(1, ids.count - 1))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = (try? encoder.encode(RecommendationAnswers(best: best).response())) ?? Data()
    return String(decoding: encoded, as: UTF8.self)
}

// MARK: - Traits

@Suite("Jev recommendation traits")
struct RecommendationTraitTests {

    @Test func traitsComeFromTheCatalogEntryAndNotFromItsProse() throws {
        let coder = try #require(ModelCatalog.entry(id: "qwen3-coder-30b-a3b"))
        let traits = RecommendationCandidate.traits(of: coder)
        #expect(traits.contains(.coding))
        #expect(traits.contains(.toolCalling))
        #expect(traits.contains(.multilingual))
        // Its summary talks about reasoning "like a large model"; the capability set does
        // not claim it, and the capability set is what this reads.
        #expect(!traits.contains(.reasoning))
        #expect(!traits.contains(.vision))
        #expect(!traits.contains(.embedding))

        let vision = try #require(ModelCatalog.entry(id: "bonsai-2-27b"))
        #expect(RecommendationCandidate.traits(of: vision).contains(.vision))

        let embed = try #require(ModelCatalog.entry(id: "nomic-embed-text-v1.5"))
        #expect(RecommendationCandidate.traits(of: embed) == [.embedding])
    }

    @Test func everyCatalogEntryYieldsTraitsInOneCanonicalOrder() {
        for entry in ModelCatalog.all {
            let traits = RecommendationCandidate.traits(of: entry)
            #expect(Set(traits).count == traits.count, "\(entry.id) repeats a trait")
            #expect(
                traits == RecommendationTrait.allCases.filter(traits.contains),
                "\(entry.id) is not in declaration order"
            )
        }
    }

    /// The one trait the catalog has no flag for. Both signals are checked, so a rename
    /// cannot silently drop it and a future adapter that is not an ablation cannot silently
    /// add it.
    @Test func uncensoredIsDeclaredByTheCatalogueAndBackedUpByTheAdapter() throws {
        let orca = try #require(ModelCatalog.entry(id: "orcabonsai-27b-uncensored"))
        #expect(orca.isUncensored, "the catalogue has to say so itself")
        #expect(RecommendationCandidate.traits(of: orca).contains(.uncensored))

        // Same weights, same files, no ablation: the base entry must not inherit it.
        let base = try #require(ModelCatalog.entry(id: "bonsai-2-27b"))
        #expect(!base.isUncensored)
        #expect(!RecommendationCandidate.isUncensored(base))

        // Turned around from "how many are flagged": every entry that *looks* like an
        // ablation has to be declared one. This fails when somebody adds a refusal-ablated
        // model and forgets the flag, which is the failure worth catching — being offered a
        // model that refuses things when you asked for one that does not is a bad surprise.
        for entry in ModelCatalog.all {
            let carriesAnAblation = entry.variants.contains { variant in
                guard let summary = variant.lora?.summary else { return false }
                return summary.range(of: "refusal", options: .caseInsensitive) != nil
                    || summary.range(of: "ablat", options: .caseInsensitive) != nil
            }
            let namedSo = entry.name.range(of: "uncensored", options: .caseInsensitive) != nil
                || entry.name.range(of: "abliterat", options: .caseInsensitive) != nil
            if carriesAnAblation || namedSo {
                #expect(entry.isUncensored, "declare isUncensored on \(entry.id)")
            }
        }

        // The safety net still catches an entry whose flag was forgotten, so a miss is a
        // failing test rather than a wrong recommendation.
        var undeclared = orca
        undeclared.isUncensored = false
        #expect(RecommendationCandidate.isUncensored(undeclared))

        // And the flag alone is enough, with no adapter at all.
        var declared = base
        declared.isUncensored = true
        #expect(RecommendationCandidate.isUncensored(declared))

        // The name is no longer a source of truth: renaming an entry does not make it one.
        var renamed = base
        renamed.name = "Bonsai 2 27B Uncensored"
        #expect(!RecommendationCandidate.isUncensored(renamed))
    }

    @Test func theFamilyIsTheNameWithoutItsSizeAndPacking() throws {
        let expected = [
            "qwen3-coder-30b-a3b": "Qwen3-Coder",
            "qwen3.8-27b": "Qwen3.8",
            "qwen3.8-27b-mlx": "Qwen3.8",
            "bonsai-2-27b": "Bonsai 2",
            "orcabonsai-27b-uncensored": "OrcaBonsai Uncensored",
        ]
        for (id, family) in expected {
            let entry = try #require(ModelCatalog.entry(id: id))
            #expect(RecommendationCandidate.family(of: entry) == family, "\(id)")
        }
        // Nothing is ever emptied out by the stripping.
        for entry in ModelCatalog.all {
            #expect(!RecommendationCandidate.family(of: entry).isEmpty, "\(entry.id)")
        }
    }

    @Test func sizeTokensAreRecognisedAndOrdinaryWordsAreNot() {
        for token in ["30B", "3.8B", "A3B", "120B", "1.7B", "27b", "700M"] {
            #expect(RecommendationCandidate.isSizeToken(token), "\(token)")
        }
        for token in ["Air", "Bonsai", "B", "AB", "Small", "VL", "4.5", "Qwen3.8"] {
            #expect(!RecommendationCandidate.isSizeToken(token), "\(token)")
        }
    }

    @Test func aCandidateCarriesTheMacsOwnPlanForTheEntry() throws {
        let entry = try #require(ModelCatalog.entry(id: "qwen3-coder-30b-a3b"))
        let configurator = AutoConfigurator(profile: bigMac)
        let fit = try #require(configurator.best(for: entry))
        let subject = RecommendationCandidate(
            entry: entry, recommendation: fit, isInstalled: true
        )
        #expect(subject.id == entry.id)
        #expect(subject.name == entry.name)
        #expect(subject.maxContext == entry.maxContext)
        // What this Mac will load, from its own plan — not the catalogue ceiling.
        #expect(subject.contextLength == fit.configuration.contextLength)
        #expect(subject.contextLength <= subject.maxContext)
        #expect(subject.rating == entry.rating)
        #expect(subject.isInstalled)
        #expect(subject.quantization == fit.quantization.rawValue)
        #expect(subject.tokensPerSecond == fit.speed.generationTokensPerSecond)
        // Active parameters are the number people are surprised by, so they are carried.
        #expect(subject.parameters.contains("30B") && subject.parameters.contains("active"))
    }
}

// MARK: - Questions

@Suite("Jev recommendation questions")
struct RecommendationQuestionTests {

    @Test func everyQuestionPassesTheServicesOwnValidationAndLimits() throws {
        let shortlist = (0..<RecommendationQuestions.maximumCandidates).map {
            candidate("model-\($0)", traits: [.coding, .vision])
        }
        let questions = RecommendationQuestions.questions(over: shortlist)
        #expect(questions.count == RecommendationQuestions.questions.count + 1)
        let request = ControlAPI.DecideRequest(
            state: RecommendationQuestions.state(task: "anything", candidates: shortlist),
            questions: questions
        )
        try request.validate()
        try JevService.checkLimits(questions)

        // The kinds the policy reads them back as.
        #expect(questions["best_for_task"]?.type == "choice")
        #expect(questions["task_difficulty"]?.type == "score")
        for id in ["needs_vision", "needs_code", "needs_tool_calling", "needs_multilingual",
                   "needs_long_context", "needs_uncensored", "needs_fast_responses",
                   "needs_deep_reasoning"] {
            #expect(questions[id]?.type == "noul", "\(id)")
            // Both sides written out: the jaggedness note's first failure mode is a
            // scoping word read at face value, and `false` is where the boundary case goes.
            let criteria = try #require(questions[id]?.criteria?.objectValue, "\(id)")
            #expect(criteria["true"]?.stringValue?.isEmpty == false, "\(id)")
            #expect(criteria["false"]?.stringValue?.isEmpty == false, "\(id)")
        }
        // A score takes 2–10 levels; this one is the three the policy's floor is written
        // against, lowest first.
        #expect(questions["task_difficulty"]?.criteria?.arrayValue?.count == 3)
    }

    @Test func theChoiceNamesEveryCandidateAndSaysWhatEachOneCannotDo() throws {
        let shortlist = [
            candidate("seer", traits: [.vision, .coding]),
            candidate("scribe", traits: [.coding]),
            candidate("agent", traits: [.toolCalling]),
        ]
        let choice = try #require(
            RecommendationQuestions.questions(over: shortlist)["best_for_task"]
        )
        let criteria = try #require(choice.criteria?.objectValue)
        #expect(Set(criteria.keys) == ["seer", "scribe", "agent"])

        // Contrastive: what this one lacks and a rival has, computed rather than authored.
        let scribe = try #require(criteria["scribe"]?.objectValue)
        let cannot = try #require(scribe["cannot"]?.arrayValue).compactMap(\.stringValue)
        #expect(cannot.contains(RecommendationTrait.vision.phrase))
        #expect(cannot.contains(RecommendationTrait.toolCalling.phrase))
        #expect(!cannot.contains(RecommendationTrait.coding.phrase))

        // The one candidate with everything the others have says nothing about what it
        // cannot do, rather than an empty list to read past.
        let everything = [candidate("only", traits: [.coding])]
        let onlyChoice = try #require(
            RecommendationQuestions.questions(over: everything)["best_for_task"]
        )
        let lone = try #require(onlyChoice.criteria?.objectValue?["only"]?.objectValue)
        #expect(lone["cannot"] == nil)

        // No candidates, no Choice: an empty option map is a 422, and there is nothing to
        // choose between anyway.
        #expect(RecommendationQuestions.questions(over: [])["best_for_task"] == nil)
    }

    /// `jev-1.13` is unreliable on numeric magnitude and reliable on named buckets, so no
    /// raw token count or context length reaches the model.
    @Test func numbersReachTheModelAsNamesNotAsMagnitudes() {
        #expect(RecommendationQuestions.contextLabel(8_192).hasPrefix("short"))
        #expect(RecommendationQuestions.contextLabel(32_768).hasPrefix("standard"))
        #expect(RecommendationQuestions.contextLabel(131_072).hasPrefix("long"))
        #expect(RecommendationQuestions.contextLabel(262_144).hasPrefix("very long"))
        #expect(RecommendationQuestions.speedLabel(6).hasPrefix("slow"))
        #expect(RecommendationQuestions.speedLabel(22).hasPrefix("workable"))
        #expect(RecommendationQuestions.speedLabel(45).hasPrefix("fast"))
        #expect(RecommendationQuestions.speedLabel(90).hasPrefix("very fast"))
        // The exact context number is nowhere in the option's description.
        let described = RecommendationQuestions.describe(
            candidate("m", traits: [.coding], context: 262_144), against: []
        )
        #expect(!described.promptText.contains("262144"))
    }

    /// The plain top sixteen is a list ordered by one axis. A Mac with a deep catalogue
    /// fills all sixteen with general text models, and then a job that needs to look at a
    /// photograph is asked about a shortlist with nothing on it that can — the model cannot
    /// choose an option that was not offered.
    @Test func theShortlistKeepsASlotForEachThingAJobCanRequire() {
        // Twenty plain text models in fit order, then the only ones that can do each thing,
        // all of them worse fits than everything above.
        var pool = (0..<20).map { candidate("plain-\($0)", traits: [.coding], context: 8_192) }
        pool.append(candidate("seer", traits: [.coding, .vision], context: 8_192, speed: 5))
        pool.append(candidate("agent", traits: [.toolCalling], context: 8_192, speed: 5))
        pool.append(candidate("blunt", traits: [.uncensored], context: 8_192, speed: 5))
        pool.append(candidate("elephant", context: RecommendationQuestions.longContextTokens,
                              speed: 5))
        pool.append(candidate("rocket", context: 8_192, speed: 400))

        let shortlist = RecommendationQuestions.shortlist(from: pool)
        let ids = shortlist.map(\.id)
        #expect(ids.count == RecommendationQuestions.maximumCandidates)
        for reserved in ["seer", "agent", "blunt", "elephant", "rocket"] {
            #expect(ids.contains(reserved), "\(reserved) lost its reserved slot")
        }
        // The best fit is never given up: it is what this route answers with Jev off.
        #expect(ids.first == "plain-0")
        // Displacement comes off the bottom, so the strongest fits survive.
        #expect(ids.contains("plain-1") && ids.contains("plain-10"))
        #expect(!ids.contains("plain-15"))
        // Still in fit order, because that is the order the fallback uses.
        #expect(ids == pool.map(\.id).filter(Set(ids).contains))
    }

    @Test func aShortlistThatAlreadyFitsIsLeftAlone() {
        let small = (0..<5).map { candidate("m\($0)", traits: [.vision, .toolCalling]) }
        #expect(RecommendationQuestions.shortlist(from: small).map(\.id) == small.map(\.id))
        // Exactly at the limit, too.
        let exact = (0..<RecommendationQuestions.maximumCandidates).map { candidate("m\($0)") }
        #expect(RecommendationQuestions.shortlist(from: exact).count == exact.count)
        #expect(RecommendationQuestions.shortlist(from: exact, limit: 0).isEmpty)
        // A trait nothing has reserves nothing, and the list is still full.
        let blind = (0..<20).map { candidate("m\($0)", traits: [.coding]) }
        #expect(RecommendationQuestions.shortlist(from: blind).count
            == RecommendationQuestions.maximumCandidates)
    }

    /// The state the service actually measures, at the worst shape this feature can build:
    /// the longest real catalogue names, the full shortlist, and a task at its own ceiling.
    @Test func aFullShortlistStaysWellInsideTheSizeLimit() throws {
        let configurator = AutoConfigurator(profile: hugeMac)
        let ranked = configurator.rank()
        let shortlist = RecommendationQuestions.shortlist(from: ranked.map {
            RecommendationCandidate(entry: $0.entry, recommendation: $0, isInstalled: true)
        })
        #expect(shortlist.count > 8, "a 512 GB Mac should run most of the catalogue")

        let task = String(repeating: "réviser des pull requests en Rust. ", count: 400)
        let trimmed = try #require(RecommendationQuestions.trimmedTask(task))
        #expect(trimmed.truncated)
        let state = RecommendationQuestions.state(task: trimmed.text, candidates: shortlist)
        let bytes = try JevService.stateBytes(state)

        // Measured, not assumed. The ceiling is generous enough not to fail on a catalogue
        // entry gaining a longer name, and far enough below the service's own 64 KB that a
        // regression here is a real change in what this feature sends.
        #expect(bytes < 12 * 1024, "state measured \(bytes) bytes")
        #expect(bytes <= JevSettings().maxStateBytes)

        // And the questions are the bigger half, so they are measured too: `jev-1.13`
        // allows 64k tokens for the state plus all of the questions.
        let whole = try JevService.stateBytes(.object([
            "state": state,
            "questions": .object(RecommendationQuestions.questions(over: shortlist).mapValues {
                .object([
                    "type": .string($0.type),
                    "instructions": $0.instructions ?? .null,
                    "criteria": $0.criteria ?? .null,
                ])
            }),
        ]))
        #expect(whole < 32 * 1024, "state plus questions measured \(whole) bytes")
    }

    @Test func aTaskIsTrimmedCutOnACharacterBoundaryOrRefusedEntirely() throws {
        #expect(RecommendationQuestions.trimmedTask(nil) == nil)
        #expect(RecommendationQuestions.trimmedTask("") == nil)
        #expect(RecommendationQuestions.trimmedTask("  \n\t ") == nil)
        let short = try #require(RecommendationQuestions.trimmedTask("  writing Go  "))
        #expect(short.text == "writing Go")
        #expect(!short.truncated, "nothing was cut, so nothing should be reported")

        // Multi-byte scalars: the cut lands between characters, so what is sent is still
        // text. A byte-wise truncation here would be a decoding failure on the wire.
        let long = String(repeating: "日本語の要約。", count: 2_000)
        let cut = try #require(RecommendationQuestions.trimmedTask(long))
        #expect(cut.truncated, "the caller has to be able to say so")
        #expect(cut.text.utf8.count <= RecommendationQuestions.maximumTaskBytes)
        #expect(cut.text.utf8.count > RecommendationQuestions.maximumTaskBytes - 8)
        #expect(long.hasPrefix(cut.text))
        #expect(String(decoding: Array(cut.text.utf8), as: UTF8.self) == cut.text)

        // Exactly at the limit is not a truncation.
        let exact = String(repeating: "a", count: RecommendationQuestions.maximumTaskBytes)
        #expect(RecommendationQuestions.trimmedTask(exact)?.truncated == false)
    }
}

// MARK: - Policy

@Suite("Jev recommendation policy")
struct RecommendationPolicyTests {

    private let shortlist = [
        candidate("plain", traits: [.coding], context: 32_768, speed: 80),
        candidate("seer", traits: [.coding, .vision], context: 32_768, speed: 20),
        candidate("agent", traits: [.coding, .toolCalling], context: 32_768, speed: 20),
        candidate("blunt", traits: [.coding, .uncensored], context: 32_768, speed: 20),
        candidate("elephant", traits: [.coding], context: 262_144, speed: 10),
    ]

    private func rank(
        _ answers: RecommendationAnswers,
        candidates: [RecommendationCandidate]? = nil,
        fit: [String: Double]? = nil
    ) throws -> RecommendationPolicy.Outcome {
        let pool = candidates ?? shortlist
        return try RecommendationPolicy.rank(
            answers: answers.response(), candidates: pool, fitScores: fit ?? evenFit(pool)
        )
    }

    /// Each veto on its own: the job needs one thing, and only the candidates that have it
    /// survive. Written one requirement per case rather than in a loop, because the thing
    /// being checked is that each noul is wired to the right trait — a loop over a table
    /// would pass just as happily if two of them were swapped.
    @Test func aConfidentVisionRequirementRemovesEverythingThatCannotSee() throws {
        var answers = RecommendationAnswers(best: ["plain": 0.9, "seer": 0.05])
        answers.vision = 0.95
        let outcome = try rank(answers)
        #expect(outcome.ranked.map(\.id) == ["seer"])
        #expect(outcome.ranked.first?.reason.contains("needs vision") == true)
    }

    @Test func aConfidentToolCallingRequirementRemovesEverythingThatCannotCallTools() throws {
        var answers = RecommendationAnswers(best: ["plain": 0.9, "agent": 0.05])
        answers.toolCalling = 0.92
        #expect(try rank(answers).ranked.map(\.id) == ["agent"])
    }

    @Test func aConfidentAdultRequirementRemovesEverythingThatWouldRefuse() throws {
        var answers = RecommendationAnswers(best: ["plain": 0.9, "blunt": 0.05])
        answers.uncensored = 0.88
        let outcome = try rank(answers)
        #expect(outcome.ranked.map(\.id) == ["blunt"])
        #expect(outcome.ranked.first?.reason.contains("uncensored answers") == true)
    }

    @Test func aConfidentLongContextRequirementRemovesEveryShortWindow() throws {
        var answers = RecommendationAnswers(best: ["plain": 0.9, "elephant": 0.05])
        answers.longContext = 0.9
        #expect(try rank(answers).ranked.map(\.id) == ["elephant"])
        // Exactly at the floor is long enough; one token under is not.
        let edge = [
            candidate("at", context: RecommendationQuestions.longContextTokens),
            candidate("under", context: RecommendationQuestions.longContextTokens - 1),
        ]
        var wants = RecommendationAnswers(best: ["under": 0.9, "at": 0.05])
        wants.longContext = 0.9
        #expect(try rank(wants, candidates: edge).ranked.map(\.id) == ["at"])
    }

    /// The veto is about what this Mac will load, not what the model was trained to. An
    /// entry with a 262K ceiling that this machine plans down to 16K cannot hold a
    /// repository, and offering it for one would be a promise the machine cannot keep.
    @Test func theContextVetoReadsThePlanNotTheCatalogueCeiling() throws {
        let pool = [
            // Trained long, planned short here: it must lose.
            candidate("cramped", context: 16_384, ceiling: 262_144),
            // Trained to exactly the floor and loaded there: it must win.
            candidate("roomy", context: RecommendationQuestions.longContextTokens,
                      ceiling: RecommendationQuestions.longContextTokens),
        ]
        var answers = RecommendationAnswers(best: ["cramped": 0.9, "roomy": 0.05])
        answers.longContext = 0.9
        let outcome = try rank(answers, candidates: pool)
        #expect(outcome.ranked.map(\.id) == ["roomy"])

        // And the note about nothing being long enough reads the plan too.
        let allCramped = [candidate("cramped", context: 16_384, ceiling: 262_144)]
        var nothing = RecommendationAnswers(best: ["cramped": 1.0])
        nothing.longContext = 0.9
        let fallback = try rank(nothing, candidates: allCramped)
        #expect(fallback.followedJev == false)
        #expect(fallback.note?.contains("one request") == true)
    }

    /// The ceiling is mentioned to the model, not judged on: a shorter plan is what the
    /// option is described by, with the headroom as a footnote.
    @Test func theCriteriaDescribeThePlanAndMentionTheCeiling() throws {
        let cramped = candidate("cramped", context: 16_384, ceiling: 262_144)
        let described = RecommendationQuestions.describe(cramped, against: [cramped])
        let fields = try #require(described.objectValue)
        #expect(fields["context"]?.stringValue?.hasPrefix("short") == true)
        #expect(fields["context_ceiling"] != nil)

        // Loaded at its ceiling: nothing to footnote.
        let full = candidate("full", context: 262_144, ceiling: 262_144)
        let there = try #require(
            RecommendationQuestions.describe(full, against: [full]).objectValue
        )
        #expect(there["context"]?.stringValue?.hasPrefix("very long") == true)
        #expect(there["context_ceiling"] == nil)
    }

    /// The gate is a noul's, not a Choice's. A number in the middle is the model saying it
    /// cannot tell, and half a requirement must not delete four models.
    @Test func anUnsureRequirementVetoesNothing() throws {
        for probability in [0.35, 0.5, 0.65, RecommendationQuestions.requirement.yes - 0.01] {
            var answers = RecommendationAnswers(best: ["plain": 0.9, "seer": 0.05])
            answers.vision = probability
            let outcome = try rank(answers)
            #expect(outcome.ranked.first?.id == "plain", "at \(probability)")
            #expect(outcome.ranked.count == RecommendationPolicy.places)
        }
        // A confident *no* is not a requirement either — both ends of a noul are certain,
        // and only the yes end asks for anything.
        var certainlyNot = RecommendationAnswers(best: ["plain": 0.9, "seer": 0.05])
        certainlyNot.vision = 0.01
        #expect(try rank(certainlyNot).ranked.first?.id == "plain")
    }

    @Test func requirementsCombineRatherThanCompete() throws {
        let pool = [
            candidate("both", traits: [.vision, .toolCalling]),
            candidate("eyes", traits: [.vision]),
            candidate("hands", traits: [.toolCalling]),
        ]
        var answers = RecommendationAnswers(best: ["eyes": 0.8, "hands": 0.15, "both": 0.05])
        answers.vision = 0.9
        answers.toolCalling = 0.9
        let outcome = try rank(answers, candidates: pool)
        #expect(outcome.ranked.map(\.id) == ["both"])
        #expect(outcome.ranked.first?.reason.contains("needs vision and tool calling") == true)
    }

    /// Nothing can do the job. The route still answers, and says why the answer is not what
    /// was asked for — a 404 on a Mac that can run something is a worse lie.
    @Test func anImpossibleRequirementFallsBackAndSaysSo() throws {
        var answers = RecommendationAnswers(best: ["plain": 0.9, "seer": 0.05])
        answers.vision = 0.95
        let blind = shortlist.filter { !$0.has(.vision) }
        let outcome = try rank(answers, candidates: blind)
        #expect(outcome.ranked.count == RecommendationPolicy.places)
        #expect(outcome.followedJev == false)
        #expect(outcome.note?.contains("images") == true)
        #expect(outcome.notes.count == 1)
    }

    // MARK: Weights

    @Test func jevsPickOutweighsHardwareFitButFitStillMoves() throws {
        let pool = [candidate("liked", speed: 20), candidate("fits", speed: 20)]
        let answers = RecommendationAnswers(best: ["liked": 0.75, "fits": 0.25], confidence: 0.75)

        // Fit equal: Jev decides.
        #expect(try rank(answers, candidates: pool, fit: evenFit(pool)).ranked.map(\.id)
            == ["liked", "fits"])

        // The margin in the Choice is 0.5, worth 0.275 of composite. A fit gap larger than
        // that overturns it; a smaller one does not. Both directions, so the weights are
        // pinned rather than merely ordered.
        let small = try rank(answers, candidates: pool, fit: ["liked": 1.0, "fits": 0.2])
        #expect(small.ranked.map(\.id) == ["liked", "fits"])
        let large = try rank(answers, candidates: pool, fit: ["liked": 0.0, "fits": 1.0])
        #expect(large.ranked.map(\.id) == ["fits", "liked"])
        #expect(RecommendationPolicy.jevWeight > RecommendationPolicy.fitWeight)
        #expect(RecommendationPolicy.fitWeight > RecommendationPolicy.speedWeight)
    }

    @Test func speedCountsOnlyWhenSomeoneIsWaiting() throws {
        let pool = [candidate("quick", speed: 120), candidate("slow", speed: 9)]
        let tied = ["quick": 0.5, "slow": 0.5]

        var patient = RecommendationAnswers(best: tied, confidence: 0.6)
        patient.fastResponses = 0.02
        let unhurried = try rank(patient, candidates: pool, fit: ["quick": 0.6, "slow": 0.8])
        #expect(unhurried.ranked.map(\.id) == ["slow", "quick"])

        var waiting = patient
        waiting.fastResponses = 0.9
        let hurried = try rank(waiting, candidates: pool, fit: ["quick": 0.6, "slow": 0.8])
        #expect(hurried.ranked.map(\.id) == ["quick", "slow"])
        #expect(hurried.ranked.first?.reason.hasPrefix("quick general work") == true)
    }

    /// The one thing `task_difficulty` decides: a person who asked for a proof will wait for
    /// it, so a demanding job does not trade capability for tokens a second.
    @Test func aDemandingJobStopsPayingForSpeed() throws {
        let pool = [candidate("quick", speed: 120), candidate("slow", speed: 9)]
        var answers = RecommendationAnswers(best: ["quick": 0.5, "slow": 0.5], confidence: 0.6)
        answers.fastResponses = 0.9
        answers.difficulty = RecommendationQuestions.demandingFloor

        let demanding = try rank(answers, candidates: pool, fit: ["quick": 0.6, "slow": 0.8])
        #expect(demanding.ranked.map(\.id) == ["slow", "quick"])

        answers.difficulty = RecommendationQuestions.demandingFloor - 0.01
        let ordinary = try rank(answers, candidates: pool, fit: ["quick": 0.6, "slow": 0.8])
        #expect(ordinary.ranked.map(\.id) == ["quick", "slow"])
    }

    /// A flat difficulty distribution places nothing, and its expectation is the middle of
    /// the scale whatever the job was. Read as ordinary rather than as a number.
    @Test func anUnreadableDifficultyScoreIsNotActedOn() throws {
        let pool = [candidate("quick", speed: 120), candidate("slow", speed: 9)]
        var answers = RecommendationAnswers(best: ["quick": 0.5, "slow": 0.5], confidence: 0.6)
        answers.fastResponses = 0.9
        answers.difficulty = 2.0

        // Confident that it is demanding: speed stops counting, and the better fit wins.
        answers.difficultyConfidence = RecommendationQuestions.scoreConfidenceFloor
        #expect(try rank(answers, candidates: pool, fit: ["quick": 0.6, "slow": 0.8])
            .ranked.map(\.id) == ["slow", "quick"])

        // The same score, too spread to mean it: treated as ordinary work, so the job's own
        // "someone is waiting" is what decides.
        answers.difficultyConfidence = RecommendationQuestions.scoreConfidenceFloor - 0.01
        #expect(try rank(answers, candidates: pool, fit: ["quick": 0.6, "slow": 0.8])
            .ranked.map(\.id) == ["quick", "slow"])
    }

    @Test func theSpeedTermStopsClimbingAtTheCeiling() throws {
        let ceiling = RecommendationPolicy.speedCeiling
        let pool = [candidate("fast", speed: ceiling), candidate("absurd", speed: ceiling * 40)]
        var answers = RecommendationAnswers(best: ["fast": 0.5, "absurd": 0.5], confidence: 0.6)
        answers.fastResponses = 0.9
        // Identical composites, so the tie-break decides: a model four hundred tokens a
        // second faster must not be able to buy its way past a better one.
        let outcome = try rank(answers, candidates: pool, fit: ["fast": 0.9, "absurd": 0.4])
        #expect(outcome.ranked.map(\.id) == ["fast", "absurd"])
    }

    // MARK: Confidence

    @Test func aFlatChoiceFallsBackToHardwareFitOrderWithANote() throws {
        let pool = [candidate("a"), candidate("b"), candidate("c")]
        let answers = RecommendationAnswers(
            best: ["a": 0.9, "b": 0.05, "c": 0.05],
            confidence: RecommendationQuestions.choiceThresholds.confirm - 0.01
        )
        let outcome = try rank(answers, candidates: pool, fit: ["a": 0.1, "b": 0.5, "c": 0.9])
        #expect(outcome.followedJev == false)
        #expect(outcome.ranked.map(\.id) == ["c", "b", "a"])
        #expect(outcome.note?.contains("could not separate") == true)
        // The reasons still come from the nouls; only the ordering was handed back.
        #expect(outcome.ranked.allSatisfy { $0.reason.contains("fits at Q4_K_M") })
    }

    @Test func aCloseChoiceIsFollowedButFlagged() throws {
        let pool = [candidate("a"), candidate("b")]
        let answers = RecommendationAnswers(
            best: ["a": 0.9, "b": 0.1],
            confidence: RecommendationQuestions.choiceThresholds.confirm
        )
        let outcome = try rank(answers, candidates: pool, fit: ["a": 0.2, "b": 1.0])
        #expect(outcome.followedJev)
        #expect(outcome.note?.contains("not clear-cut") == true)

        var confident = answers
        confident.confidence = RecommendationQuestions.choiceThresholds.act
        #expect(try rank(confident, candidates: pool, fit: ["a": 0.2, "b": 1.0]).note == nil)
    }

    /// The composite overruling Jev is the point of the fit and speed terms — and it is
    /// also the thing an owner will ask about, so it is said out loud.
    ///
    /// Sixteen options, the realistic shape: a winner at 0.25 and the rest spread. That is
    /// a confidence well above the escalate floor and nowhere near a certainty, which is
    /// exactly when the weights decide the order.
    @Test func demotingJevsOwnPickIsSaidOutLoud() throws {
        var probabilities = ["liked": 0.25]
        for index in 0..<15 { probabilities["filler-\(index)"] = 0.05 }
        let pool = [candidate("liked", speed: 20)]
            + (0..<15).map { candidate("filler-\($0)", speed: 20) }
        var fit = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, 0.2) })
        fit["liked"] = 0.0
        fit["filler-0"] = 1.0

        let answers = RecommendationAnswers(best: probabilities, confidence: 0.42)
        let outcome = try rank(answers, candidates: pool, fit: fit)
        #expect(outcome.followedJev, "the Choice was readable; only the weights moved it")
        #expect(outcome.ranked.first?.id == "filler-0")
        #expect(outcome.notes.contains { $0.contains("Jev preferred Liked") })
        #expect(outcome.notes.contains { $0.contains("runs less well") })

        // When the weights agree with Jev there is nothing to explain.
        fit["liked"] = 1.0
        fit["filler-0"] = 0.2
        let agreed = try rank(answers, candidates: pool, fit: fit)
        #expect(agreed.ranked.first?.id == "liked")
        #expect(!agreed.notes.contains { $0.contains("preferred") })
    }

    /// A veto taking Jev's pick off the list reads differently from the weights demoting
    /// it, and saying which one happened is the whole value of the note.
    @Test func aVetoedPickIsExplainedAsAVetoNotAsADemotion() throws {
        let pool = [
            candidate("blind", traits: [.coding]),
            candidate("seer", traits: [.coding, .vision]),
        ]
        var answers = RecommendationAnswers(best: ["blind": 0.8, "seer": 0.2], confidence: 0.8)
        answers.vision = 0.95
        let outcome = try rank(answers, candidates: pool)
        #expect(outcome.ranked.map(\.id) == ["seer"])
        #expect(outcome.notes.contains { $0.contains("Jev preferred Blind") })
        #expect(outcome.notes.contains { $0.contains("no vision") })
        #expect(!outcome.notes.contains { $0.contains("runs less well") })
    }

    /// A veto still applies when the Choice was too flat to order anything: a noul is its
    /// own absolute judgment with its own gate, and the two do not share a threshold.
    @Test func vetoesSurviveALowConfidenceChoice() throws {
        var answers = RecommendationAnswers(
            best: ["plain": 0.3, "seer": 0.25, "agent": 0.25, "blunt": 0.2], confidence: 0.1
        )
        answers.vision = 0.95
        let outcome = try rank(answers)
        #expect(outcome.followedJev == false)
        #expect(outcome.ranked.map(\.id) == ["seer"])
    }

    // MARK: Shape

    @Test func theAnswerIsAtMostThreeStableAndExplained() throws {
        let pool = (0..<8).map { candidate("m\($0)", traits: [.coding]) }
        let answers = RecommendationAnswers(
            best: Dictionary(uniqueKeysWithValues: pool.map { ($0.id, 0.125) }), confidence: 0.6
        )
        let first = try rank(answers, candidates: pool, fit: evenFit(pool))
        #expect(first.ranked.count == RecommendationPolicy.places)
        // Everything tied: the order still has to be the same every time, because a
        // recommendation that reshuffles on a reload is an alarming thing to watch.
        for _ in 0..<12 {
            #expect(try rank(answers, candidates: pool, fit: evenFit(pool)).ranked == first.ranked)
        }
        #expect(first.ranked.allSatisfy { !$0.reason.isEmpty })

        // Fewer candidates than places is not an error.
        let one = [candidate("only")]
        #expect(try rank(RecommendationAnswers(best: ["only": 1]), candidates: one)
            .ranked.count == 1)
        // And none at all is an empty answer rather than a crash.
        let empty = try RecommendationPolicy.rank(
            answers: RecommendationAnswers(best: [:]).response(),
            candidates: [], fitScores: [:]
        )
        #expect(empty.ranked.isEmpty)
    }

    @Test func theReasonSaysWhatTheJobNeedsAndWhatTheModelCosts() throws {
        var answers = RecommendationAnswers(best: ["seer": 1.0])
        answers.vision = 0.95
        answers.code = 0.9
        let only = [candidate("seer", traits: [.coding, .vision], speed: 27.6, installed: true)]
        let reason = try #require(rank(answers, candidates: only).ranked.first?.reason)
        // One canonical order — `RecommendationTrait`'s own — so the line is the same
        // sentence whichever question came back first.
        #expect(reason == "needs code and vision; fits at Q4_K_M at ~28 tok/s; already installed")
    }

    @Test func aMissingAnswerIsAnErrorByNameRatherThanADefaultRanking() {
        var incomplete = RecommendationAnswers(best: ["plain": 1.0]).response()
        incomplete.answers.removeValue(forKey: "needs_uncensored")
        #expect(throws: ControlAPI.SystemOneAnswerError.self) {
            try RecommendationPolicy.rank(
                answers: incomplete, candidates: shortlist, fitScores: evenFit(shortlist)
            )
        }
        // And a question that came back as the wrong kind is caught too, rather than read
        // as a zero.
        var swapped = RecommendationAnswers(best: ["plain": 1.0]).response()
        swapped.answers["needs_vision"] = .score(
            score: 1, confidence: 1, legend: [:], probabilities: [:]
        )
        #expect(throws: ControlAPI.SystemOneAnswerError.self) {
            try RecommendationPolicy.rank(
                answers: swapped, candidates: shortlist, fitScores: evenFit(shortlist)
            )
        }
    }

    @Test func fitIsNormalisedAgainstTheBestCandidateNotAnAbsoluteScale() {
        #expect(RecommendationPolicy.normalizedFit(["a": 40, "b": 10]) == ["a": 1.0, "b": 0.25])
        // A raw score of zero or below has no meaning to divide by, and a machine where
        // nothing scores must not produce a NaN that sorts unpredictably.
        #expect(RecommendationPolicy.normalizedFit(["a": 0, "b": 0]) == ["a": 0, "b": 0])
        #expect(RecommendationPolicy.normalizedFit([:]).isEmpty)
        let clamped = RecommendationPolicy.normalizedFit(["a": 10, "b": -5])
        #expect(clamped["b"] == 0)
        #expect(clamped.values.allSatisfy { (0...1).contains($0) })
    }
}

// MARK: - The service, the ledger and the hook

@Suite("Jev recommendation wiring", .redirectedConversationStore)
struct RecommendationWiringTests {

    @Test func theLedgerRecordsTheCallAgainstTheRecommendationFeature() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        let shortlist = [candidate("a", traits: [.coding]), candidate("b")]
        let server = try CapturingServer { _ in cannedRecommendation(for: ["a", "b"]) }
        defer { server.stop() }

        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.service.update { settings in
            settings.enabled = true
            settings.features[.recommendation] = true
        }
        #expect(await harness.service.isAvailable(.recommendation))

        let response = try await RecommendationQuestions.ask(
            task: "reviewing Rust pull requests", candidates: shortlist,
            using: harness.service
        )
        let outcome = try RecommendationPolicy.rank(
            answers: response, candidates: shortlist, fitScores: evenFit(shortlist)
        )
        #expect(outcome.ranked.first?.id == "a")

        let month = await harness.service.ledger().month()
        #expect(month.features["recommendation"]?.calls == 1)
        #expect(month.features["recommendation"]?.inputTokens == 1_200)
        #expect(month.total.calls == 1)
        #expect(month.features["decideTool"] == nil)
        // The version that answered is recorded, so a threshold tuned on 1.13 is noticed
        // drifting onto 1.14.
        #expect(month.models[JevService.pinnedModel] == 1)

        // The model pin travels with the request, and the key does not reach the body.
        let sent = try #require(server.requests.first)
        let body = String(decoding: sent.body, as: UTF8.self)
        #expect(body.contains(JevService.pinnedModel))
        #expect(body.contains("best_for_task"))
        #expect(!body.contains("sk-fixture"))
    }

    @Test func theFeatureSwitchRefusesBeforeAnySocketIsOpened() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        let server = try untouchedServer("the recommendation switch is off")
        defer { server.stop() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        // Jev itself on, this feature off: a stored key is not consent to spend it.
        try await harness.service.update { settings in settings.enabled = true }

        #expect(await !harness.service.isAvailable(.recommendation))
        await #expect(throws: JevError.disabled(.recommendation)) {
            _ = try await RecommendationQuestions.ask(
                task: "anything", candidates: [candidate("a")], using: harness.service
            )
        }
        #expect(server.requests.isEmpty)
    }

    @Test func theFeatureIsBuiltAndShipsOffWithAnHonestSummary() {
        #expect(JevFeature.recommendation.isBuilt)
        // Every feature that lands flips the same line; a merge that kept only one side
        // would be caught here rather than by a route that quietly stopped asking.
        #expect(JevFeature.decideTool.isBuilt, "another feature's flip was lost")
        #expect(JevFeature.routing.isBuilt, "another feature's flip was lost")
        #expect(!JevSettings().isOn(.recommendation), "it must still ship off")
        let summary = JevFeature.recommendation.summary
        #expect(summary.contains("job"))
        #expect(!summary.isEmpty)
    }

    /// Without a task this route is what it always was, and it costs nothing: no Keychain
    /// read, no request, no `reason` on the answer that only the Jev path can set.
    @MainActor
    @Test func noTaskMeansTodaysAnswerAndNoRequest() async throws {
        let app = AppModel(settings: .init())
        let expected = app.autoConfigurator().rank(
            catalog: ModelCatalog.all.filter { $0.category != .embedding },
            otherAppsInUse: app.memoryUsedByOtherApps
        ).first

        for task in [nil, "", "   \n\t "] as [String?] {
            let pick = await app.recommend(category: nil, task: task)
            #expect(pick?.id == expected?.entry.id)
            #expect(pick?.reason == nil, "the Jev path always sets a reason")
            #expect(pick?.alternatives == nil)
        }
        // A category still filters, with or without a task.
        let coding = await app.recommend(category: ModelCategory.coding.rawValue, task: nil)
        #expect(coding == nil || coding?.category == ModelCategory.coding.rawValue)
        #expect(await app.recommend(category: "Nonsense", task: nil) != nil)
    }
}

// MARK: - The route and the tool

@Suite("Jev recommendation route and tool")
struct RecommendationRouteTests {

    private func withServer(
        _ body: (RecommendingHost, ControlAPI.Handshake, Int) async throws -> Void
    ) async throws {
        let host = RecommendingHost()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recommend-route-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let handshakeURL = directory.appendingPathComponent("control.json")
        let server = ControlServer(
            host: host, handshakeURL: handshakeURL,
            buddy: BuddyRegistry(url: directory.appendingPathComponent("buddy.json")),
            discoverTailnetAddress: { nil }
        )
        try await server.start()
        defer { Task { await server.stop() } }

        var handshake: ControlAPI.Handshake?
        for _ in 0..<200 where handshake == nil {
            handshake = try? JSONDecoder().decode(
                ControlAPI.Handshake.self, from: try Data(contentsOf: handshakeURL)
            )
            if handshake == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let control = try #require(handshake)
        try await body(host, control, control.port)
        await server.stop()
    }

    private func call(
        _ method: String, _ path: String, port: Int, token: String, body: Data? = nil
    ) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    @Test func aTaskGoesInAPostBodyAndComesBackWithTheRunnersUp() async throws {
        try await withServer { host, control, port in
            // The characters that break a naive query string, and would have been mangled
            // or split by the old `?task=` form.
            let task = "reading scanned invoices in Français & Deutsch + tables"
            let (status, body) = try await call(
                "POST", "/recommend", port: port, token: control.token,
                body: try JSONEncoder().encode(
                    ControlAPI.RecommendRequest(category: "Vision", task: task)
                )
            )
            #expect(status == 200)
            #expect(await host.lastTask == task, "the task reached the host intact")
            #expect(await host.lastCategory == "Vision")

            let decoded = try JSONDecoder().decode(ControlAPI.CatalogModel.self, from: body)
            #expect(decoded.reason == "needs vision; fits at Q4_K_M at ~28 tok/s")
            #expect(decoded.note == "Jev preferred Second; it is ranked lower because it "
                + "runs less well on this Mac.")
            #expect(decoded.followedJev == true)
            #expect(decoded.alternatives?.map(\.id) == ["second", "third"])
            #expect(decoded.alternatives?.allSatisfy { $0.reason != nil } == true)
            // The runners-up do not nest further: three deep is a list, not a tree.
            #expect(decoded.alternatives?.allSatisfy { $0.alternatives == nil } == true)
        }
    }

    /// A job description is the owner's prose about their own work, and a URL is the part
    /// of a request that survives in shell histories and proxy logs. Refused with somewhere
    /// to go, rather than ignored — which would look exactly like the feature being off.
    @Test func aTaskInTheQueryStringIsRefusedAndPointedAtThePost() async throws {
        try await withServer { host, control, port in
            let (status, body) = try await call(
                "GET", "/recommend?task=reading+invoices", port: port, token: control.token
            )
            #expect(status == 400)
            let refusal = try JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: body)
            #expect(refusal.error == ControlServer.taskBelongsInAPost)
            #expect(refusal.error.contains("POST /recommend"))
            // Nothing was asked of the host, so nothing could have been spent.
            #expect(await host.calls == 0)
        }
    }

    @Test func aPlainGetIsUnchangedAndCarriesNeitherNewField() async throws {
        try await withServer { host, control, port in
            await host.setTaskAware(false)
            let (status, body) = try await call(
                "GET", "/recommend?category=Vision", port: port, token: control.token
            )
            #expect(status == 200)
            #expect(await host.lastTask == nil)
            // Absent from the JSON rather than null, so an older client sees the shape it
            // was generated against.
            let text = String(decoding: body, as: UTF8.self)
            #expect(!text.contains("reason"))
            #expect(!text.contains("alternatives"))
            #expect(!text.contains("followedJev"))
            #expect(!text.contains("\"note\""))
        }
    }

    /// The paid half of this route is not a paired phone's to spend.
    ///
    /// `GET /recommend` reads and advises and costs nothing, so a chat-only device keeps
    /// it. `POST /recommend` asks Jev once per distinct description, and there is no budget
    /// cap by default — so it takes full control, refused by the server's one scope gate
    /// with the same sentence every other closed route uses.
    @Test func rankingAgainstAJobIsClosedToChatOnlyDevices() throws {
        let chat = ControlServer.Caller.device(id: "phone", scope: .chat)
        let full = ControlServer.Caller.device(id: "tablet", scope: .full)

        #expect(chat.mayReach(method: "GET", path: "/recommend"))
        #expect(!chat.mayReach(method: "POST", path: "/recommend"))
        #expect(full.mayReach(method: "POST", path: "/recommend"))

        // Through the gate itself, not just the set it reads, so the refusal a phone
        // actually receives is the one under test.
        let posted = HTTPRequest(
            method: "POST", path: "/recommend", query: [:], headers: [:],
            body: Data(#"{"task":"anything"}"#.utf8)
        )
        let refusal = try #require(ControlServer.scopeRefusal(for: posted, as: chat))
        #expect(refusal.status == 403)
        #expect(String(decoding: refusal.body, as: UTF8.self)
            .contains(ControlServer.chatOnlyRefusal))

        let read = HTTPRequest(
            method: "GET", path: "/recommend", query: [:], headers: [:], body: Data()
        )
        #expect(ControlServer.scopeRefusal(for: read, as: chat) == nil)
        #expect(ControlServer.scopeRefusal(for: posted, as: full) == nil)
    }
}

extension ControlAPI.CatalogModel {
    static func recommendationFixture(
        id: String, reason: String?, note: String? = nil, followedJev: Bool? = nil,
        alternatives: [ControlAPI.CatalogModel]? = nil
    ) -> Self {
        .init(
            id: id, name: id.capitalized, author: "Fixture", license: "Apache-2.0",
            summary: "A model.", category: "Vision", parameters: "8B",
            activeParameters: nil, isMoE: false, capabilities: ["Vision"], rating: 4,
            maxContext: 131_072, quantizations: ["Q4_K_M"],
            recommendation: .init(
                quantization: "Q4_K_M", contextLength: 32_768, expertSlots: nil,
                estimatedGenerationTokensPerSecond: 28, estimatedPromptTokensPerSecond: 600,
                downloadBytes: 5_000_000_000,
                plan: .init(
                    verdict: "fits", residentBytes: 6_000_000_000,
                    budgetBytes: 29_200_000_000, weightsBytes: 5_000_000_000,
                    expertsBytes: 0, kvCacheBytes: 900_000_000, computeBytes: 100_000_000,
                    streamedFromDiskBytes: 0, suggestions: [], notes: []
                ),
                rationale: "Fits comfortably."
            ),
            reason: reason, note: note, followedJev: followedJev,
            alternatives: alternatives
        )
    }
}

/// A `ControlHost` that answers `/recommend` and records what it was asked. Everything else
/// traps: this suite is about one route.
actor RecommendingHost: ControlHost {
    private(set) var lastCategory: String?
    private(set) var lastTask: String?
    private(set) var calls = 0
    private var taskAware = true

    func setTaskAware(_ value: Bool) {
        taskAware = value
        lastTask = nil
    }

    func recommend(category: String?, task: String?) async -> ControlAPI.CatalogModel? {
        calls += 1
        lastCategory = category
        lastTask = task
        guard taskAware, task != nil else {
            return .recommendationFixture(id: "winner", reason: nil)
        }
        return .recommendationFixture(
            id: "winner", reason: "needs vision; fits at Q4_K_M at ~28 tok/s",
            note: "Jev preferred Second; it is ranked lower because it runs less well on "
                + "this Mac.",
            followedJev: true,
            alternatives: [
                .recommendationFixture(id: "second", reason: "needs vision; fits at Q6_K at ~12 tok/s"),
                .recommendationFixture(id: "third", reason: "needs vision; fits at Q8_0 at ~9 tok/s"),
            ]
        )
    }

    func swarm() async -> ControlAPI.SwarmView { .init(peers: [], polledSecondsAgo: nil) }
    func profile() async -> ControlAPI.Profile { fatalError("unused") }
    func metrics() async -> ControlAPI.Metrics { fatalError("unused") }
    func status() async -> ControlAPI.Status {
        .init(state: "idle", loadedModelID: nil, loadedModelName: nil, contextLength: nil,
              expertStreaming: false, lastGenerationTokensPerSecond: nil)
    }
    func catalog(category: String?, onlyRunnable: Bool) async -> [ControlAPI.CatalogModel] { [] }
    func installed() async -> [ControlAPI.InstalledModel] { [] }
    func unload() async {}
    func imageModels() async -> [ControlAPI.ImageModel] { [] }
    func meshModels() async -> [ControlAPI.MeshModel] { [] }
    func videoModels() async -> [ControlAPI.VideoModel] { [] }
    func conversationList() async -> [ControlAPI.ConversationSummary] { [] }
    func createConversation(title: String?) async -> ControlAPI.ConversationSummary {
        .init(id: "1", title: title ?? "New", updatedAt: ControlAPI.timestamp(Date()),
              messageCount: 0)
    }
    func jevStatus() async -> ControlAPI.JevStatus { .fixture() }
    func recentGuardrailScreenings() async -> ControlAPI.GuardrailScreenings {
        .init(available: false, questions: [], screenings: [])
    }
    func updateJev(_ update: ControlAPI.JevUpdate) async throws -> ControlAPI.JevStatus {
        .fixture()
    }
    func nodeAdvertisement() async -> ControlAPI.NodeAdvertisement {
        .init(
            name: "Fixture", platform: "macos-apple-silicon",
            profile: .init(chip: "Apple M3 Max", memoryGB: 38.7, bandwidthGBps: 300,
                           gpuCores: 40),
            capabilities: [],
            metrics: .init(queueDepth: 0, headroomGB: 8.9, gpuUtilPct: 0, memoryUsedPct: 0)
        )
    }
    func beginEventUpdates(postingTo hub: BuddyEventHub) async {}

    func plan(_ request: ControlAPI.PlanRequest) async throws -> ControlAPI.Plan {
        throw RecommendingHostError.unused
    }
    func install(_ request: ControlAPI.LoadRequest) async throws -> String {
        throw RecommendingHostError.unused
    }
    func load(_ request: ControlAPI.LoadRequest) async throws -> ControlAPI.Status {
        throw RecommendingHostError.unused
    }
    func chat(_ request: ControlAPI.ChatRequest) async throws -> ControlAPI.ChatResponse {
        throw RecommendingHostError.unused
    }
    func decide(_ request: ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse {
        throw RecommendingHostError.unused
    }
    func benchmark() async throws -> ControlAPI.BenchmarkResult {
        throw RecommendingHostError.unused
    }
    func planImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImagePlan {
        throw RecommendingHostError.unused
    }
    func generateImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImageResponse {
        throw RecommendingHostError.unused
    }
    func planMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshPlan {
        throw RecommendingHostError.unused
    }
    func generateMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshResponse {
        throw RecommendingHostError.unused
    }
    func generateVideo(
        _ request: ControlAPI.VideoGenerateRequest
    ) async throws -> ControlAPI.VideoResponse {
        throw RecommendingHostError.unused
    }
    func chatStream(
        _ request: ControlAPI.ChatRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        throw RecommendingHostError.unused
    }
    func conversation(id: String) async throws -> ControlAPI.ConversationDetail {
        throw RecommendingHostError.unused
    }
    func replyInConversation(
        id: String, to message: ControlAPI.NewMessageRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        throw RecommendingHostError.unused
    }
}

enum RecommendingHostError: Error { case unused }

// MARK: - Live

/// Against the real TypeSafe API, with a real key, when both are explicitly asked for.
///
/// Costs money, so it is never part of an ordinary run. The key is read from the environment
/// at the moment it is used and is never printed — not the value, not its length, not a
/// prefix — and nothing here echoes the request body.
@Suite("Jev recommendation, live")
struct RecommendationLiveTests {

    private func shortlist() -> [RecommendationCandidate] {
        [
            candidate("qwen3-coder-30b-a3b", traits: [.coding, .toolCalling, .multilingual],
                      context: 262_144, speed: 70, rating: 5),
            candidate("qwen2.5-vl-7b", traits: [.vision, .multilingual],
                      context: 128_000, speed: 60, rating: 4),
            candidate("qwen3-4b", traits: [.coding, .reasoning, .multilingual],
                      context: 262_144, speed: 110, rating: 4),
            candidate("llama3.3-70b", traits: [.reasoning, .toolCalling, .multilingual],
                      context: 131_072, speed: 9, rating: 5),
            candidate("orcabonsai-27b-uncensored",
                      traits: [.coding, .vision, .reasoning, .toolCalling, .multilingual,
                               .uncensored],
                      context: 262_144, speed: 25, rating: 4),
        ]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SILICON_JEV_LIVE"] == "1"))
    func judgesTwoRealTaskDescriptions() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.service.configure(
            keyProvider: { ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] },
            keyIsSet: { ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] != nil },
            configURL: harness.configURL
        )
        try await harness.service.update { settings in
            settings.enabled = true
            settings.features[.recommendation] = true
        }
        guard await harness.service.isAvailable(.recommendation) else {
            Issue.record("SILICON_JEV_LIVE=1 but TYPESAFE_API_KEY is not set.")
            return
        }

        let candidates = shortlist()
        let fit = RecommendationPolicy.normalizedFit(
            Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, Double($0.rating)) })
        )

        // One that plainly needs to look at pictures.
        let vision = try await RecommendationQuestions.ask(
            task: """
                I photograph handwritten field notes on my phone and want the model to read \
                each photo and turn it into a tidy markdown summary.
                """,
            candidates: candidates, using: harness.service
        )
        #expect(vision.model.hasPrefix("jev-"))
        #expect(try vision.noul("needs_vision") > 0.5)
        #expect(try vision.noul("needs_code") < 0.5)
        let seeing = try RecommendationPolicy.rank(
            answers: vision, candidates: candidates, fitScores: fit
        )
        #expect(seeing.ranked.allSatisfy { id in
            candidates.first { $0.id == id.id }?.has(.vision) == true
        }, "a vision job was ranked onto a text-only model")

        // One that plainly does not, and wants tools and speed instead.
        let agent = try await RecommendationQuestions.ask(
            task: """
                An editor assistant that runs shell commands and edits files through function \
                calls while I type. Everything is English source code and I am waiting for \
                each reply.
                """,
            candidates: candidates, using: harness.service
        )
        #expect(try agent.noul("needs_vision") < 0.5)
        #expect(try agent.noul("needs_tool_calling") > 0.5)
        #expect(try agent.noul("needs_code") > 0.5)
        #expect(try agent.noul("needs_multilingual") < 0.5)
        let tooling = try RecommendationPolicy.rank(
            answers: agent, candidates: candidates, fitScores: fit
        )
        #expect(tooling.ranked.allSatisfy { id in
            candidates.first { $0.id == id.id }?.has(.toolCalling) == true
        }, "a tool-calling job was ranked onto a model that cannot call tools")
        #expect(!tooling.ranked.isEmpty)

        // Two calls, two ledger entries, both against this feature.
        let month = await harness.service.ledger().month()
        #expect(month.features["recommendation"]?.calls == 2)
    }
}

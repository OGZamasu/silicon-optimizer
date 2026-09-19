import Foundation
import Network
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconCore
@testable import SiliconRuntime
@testable import SiliconUI

// MARK: - Fixtures

/// A gateway model entry, as `gatewayModels()` would have built it.
func routingModel(
    id: String, name: String, serving: Bool = false, context: Int? = nil,
    quantization: String? = nil, tokensPerSecond: Double? = nil
) -> GatewayAPI.Model {
    GatewayAPI.Model(
        id: id, displayName: name, where_: "wherever", contextWindow: context,
        serving: serving, quantization: quantization, tokensPerSecond: tokensPerSecond
    )
}

func routingShape(totalBillions: Double, activeBillions: Double? = nil) -> ModelShape {
    ModelShape(
        totalParameters: Int64(totalBillions * 1e9), blockCount: 48, embeddingLength: 2048,
        feedForwardLength: 6144, headCount: 32, headCountKV: 4, trainingContextLength: 262_144,
        moe: activeBillions.map {
            MoEShape(
                expertCount: 128, expertsUsedPerToken: 8, expertFeedForwardLength: 768,
                moeLayerCount: 48, activeParameters: Int64($0 * 1e9), hasSharedExpert: false
            )
        }
    )
}

func routingInstall(
    id: String, name: String, capabilities: ModelCapabilities = [],
    projector: Bool = false, shape: ModelShape? = nil,
    quantization: Quantization = .q4_K_M, catalogID: String? = nil
) -> InstalledModel {
    InstalledModel(
        id: id, name: name, catalogID: catalogID, quantization: quantization, format: .gguf,
        primaryFile: URL(fileURLWithPath: "/tmp/\(id).gguf"),
        allFiles: [URL(fileURLWithPath: "/tmp/\(id).gguf")],
        projectorFile: projector ? URL(fileURLWithPath: "/tmp/\(id).mmproj") : nil,
        sizeOnDisk: .zero, installedAt: Date(), shape: shape, capabilities: capabilities
    )
}

/// A candidate with everything spelled out, so a policy test says exactly what it is testing.
func candidate(
    _ label: String, id: String? = nil, placement: RoutingCandidate.Placement = .thisMac,
    vision: Bool = false, code: Bool = false, reasoning: Bool = false,
    uncensored: Bool = false, context: Int? = 32_768, billions: Double? = 8,
    tokensPerSecond: Double? = 30, price: Double? = 0, ready: Bool = false
) -> RoutingCandidate {
    RoutingCandidate(
        id: id ?? "local/\(label)", label: label, name: label, placement: placement,
        parameterBillions: billions, quantization: "Q4_K_M", contextWindow: context,
        vision: vision, codeTuned: code, reasoning: reasoning, uncensored: uncensored,
        tokensPerSecond: tokensPerSecond, usdPerMillionTokens: price, readyNow: ready
    )
}

// MARK: - Traits

@Suite("Routing candidates")
struct RoutingCandidateTests {

    @Test func aLocalModelIsDescribedByItsFileNotItsName() {
        let install = routingInstall(
            id: "qwen3-coder-30b@Q4_K_M", name: "Qwen3 Coder 30B",
            capabilities: [.coding, .toolCalling],
            shape: routingShape(totalBillions: 30, activeBillions: 3.3),
            catalogID: "qwen3-coder-30b"
        )
        let entry = RoutingCandidate.local(
            routingModel(
                id: "local/qwen3-coder-30b@Q4_K_M", name: "Qwen3 Coder 30B — Q4_K_M",
                serving: true, context: 16_384, tokensPerSecond: 41.2
            ),
            installed: install, catalog: nil, label: "qwen3-coder-30b"
        )
        #expect(entry.codeTuned)
        #expect(entry.parameterBillions == 30)
        #expect(entry.activeParameterBillions == 3.3)
        #expect(entry.workingBillions == 3.3)
        #expect(entry.contextWindow == 16_384)
        #expect(entry.quantization == "Q4_K_M")
        #expect(entry.tokensPerSecond == 41.2)
        #expect(entry.readyNow)
        // Your own hardware bills nobody per token, and a router that pretended otherwise
        // would send everything to whichever cloud model looked cheapest.
        #expect(entry.usdPerMillionTokens == 0)
        #expect(entry.isFree)
        #expect(!entry.vision)
    }

    @Test func aVisionModelWithoutItsProjectorCannotSee() {
        let shape = routingShape(totalBillions: 8)
        let blind = RoutingCandidate.local(
            routingModel(id: "local/a", name: "Qwen2.5-VL 7B"),
            installed: routingInstall(
                id: "a", name: "Qwen2.5-VL 7B", capabilities: [.vision], shape: shape
            ),
            catalog: nil, label: "a"
        )
        let seeing = RoutingCandidate.local(
            routingModel(id: "local/b", name: "Qwen2.5-VL 7B"),
            installed: routingInstall(
                id: "b", name: "Qwen2.5-VL 7B", capabilities: [.vision], projector: true,
                shape: shape
            ),
            catalog: nil, label: "b"
        )
        #expect(!blind.vision)
        #expect(seeing.vision)
    }

    @Test func theCatalogFillsInWhatTheFileCannotSay() {
        guard let entry = ModelCatalog.all.first(where: { $0.capabilities.contains(.reasoning) })
        else { Issue.record("the catalog should have a reasoning model"); return }
        let install = routingInstall(
            id: "\(entry.id)@Q4_K_M", name: entry.name, capabilities: [], catalogID: entry.id
        )
        let candidate = RoutingCandidate.local(
            routingModel(id: "local/\(install.id)", name: entry.name),
            installed: install, catalog: entry, label: "x"
        )
        #expect(candidate.reasoning)
        #expect(candidate.parameterBillions ?? 0 > 0)
    }

    @Test func aNodeModelIsReadOutOfItsName() {
        let entry = RoutingCandidate.node(
            routingModel(
                id: "node/studio/Qwen3-Coder-30B-A3B", name: "Qwen3-Coder-30B-A3B — Studio",
                serving: true, context: 131_072
            ),
            peer: "Studio", label: "qwen3-coder-30b-a3b"
        )
        #expect(entry.codeTuned)
        #expect(entry.parameterBillions == 30)
        #expect(entry.activeParameterBillions == 3)
        #expect(entry.placement == .node("Studio"))
        #expect(entry.isFree)
        #expect(entry.name == "Qwen3-Coder-30B-A3B")
    }

    @Test func aRemoteModelCostsWhatTheProviderPublished() {
        let priced = RoutingCandidate.cloud(
            routingModel(id: "cloud/open-router/minimax/minimax-m3", name: "MiniMax M3"),
            cloud: CloudModel(
                id: "minimax/minimax-m3", displayName: "MiniMax M3", provider: .openRouter,
                contextWindow: 204_800, pricePerMillionInputUSD: 0.4
            ),
            provider: "OpenRouter", label: "minimax-m3"
        )
        #expect(priced.usdPerMillionTokens == 0.4)
        #expect(!priced.isFree)
        #expect(priced.contextWindow == 204_800)
        #expect(priced.readyNow, "a remote model has nothing to load")

        let free = RoutingCandidate.cloud(
            routingModel(id: "cloud/token-harbor/glm-4.7:free", name: "GLM 4.7 (free)"),
            cloud: CloudModel(
                id: "glm-4.7:free", displayName: "GLM 4.7 (free)", provider: .tokenHarbor
            ),
            provider: "Token Harbor", label: "glm-free"
        )
        #expect(free.usdPerMillionTokens == 0)
        #expect(free.isFree)

        let unknown = RoutingCandidate.cloud(
            routingModel(id: "cloud/gmi/some-model", name: "Some Model"),
            cloud: CloudModel(id: "some-model", displayName: "Some Model", provider: .gmi),
            provider: "GMI Cloud", label: "some-model"
        )
        #expect(unknown.usdPerMillionTokens == nil, "unknown is not the same as free")
        #expect(!unknown.isFree)
    }

    @Test func aListingsPriceIsReadWhenItHasOne() {
        let body = Data(#"""
        {"data": [
          {"id": "minimax/minimax-m3", "name": "MiniMax M3", "context_length": 204800,
           "pricing": {"prompt": "0.0000004", "completion": "0.0000016"}},
          {"id": "free/thing", "pricing": {"prompt": "0"}},
          {"id": "quiet/thing"}
        ]}
        """#.utf8)
        let models = AppModel.parseCloudModels(body, provider: .openRouter)
        #expect(models.count == 3)
        // Per token on the wire, per million in the app: 0.0000004 × 1e6.
        #expect(abs((models[0].pricePerMillionInputUSD ?? 0) - 0.4) < 1e-9)
        #expect(models[1].pricePerMillionInputUSD == 0)
        #expect(models[2].pricePerMillionInputUSD == nil)
    }

    @Test func aNameGivesAwayWhatItCan() {
        let coder = RoutingCandidate.NameTraits("Qwen3-Coder-30B-A3B")
        #expect(coder.codeTuned)
        #expect(coder.totalBillions == 30)
        #expect(coder.activeBillions == 3)

        let seer = RoutingCandidate.NameTraits("Qwen2.5-VL-7B-Instruct")
        #expect(seer.vision)
        #expect(seer.totalBillions == 7)

        let thinker = RoutingCandidate.NameTraits("QwQ-32B")
        #expect(thinker.reasoning)
        #expect(thinker.totalBillions == 32)

        let blunt = RoutingCandidate.NameTraits("OrcaBonsai 27B Uncensored")
        #expect(blunt.uncensored)
        #expect(blunt.totalBillions == 27)

        // A version number is not a parameter count, and a model called Codex is not a
        // coding model because of the letters it shares with one.
        let versioned = RoutingCandidate.NameTraits("minimax-m2.7")
        #expect(versioned.totalBillions == nil)
        #expect(!versioned.codeTuned)
    }

    @Test func labelsAreUniqueAndReadable() {
        let labels = RoutingCandidate.labels(for: [
            "Qwen3 Coder 30B — Q4_K_M", "Qwen3 Coder 30B — Q4_K_M", "", "MiniMax M3",
        ])
        #expect(labels[0] == "qwen3-coder-30b-q4-k-m")
        #expect(labels[1] == "qwen3-coder-30b-q4-k-m-2")
        #expect(labels[2] == "model")
        #expect(Set(labels).count == labels.count)
        #expect(labels.allSatisfy { $0.count <= 48 && !$0.hasPrefix("-") && !$0.hasSuffix("-") })
    }
}

// MARK: - The request

@Suite("Routing request")
struct RoutingRequestTests {

    @Test func itReadsBothDialects() {
        let chat = RoutingRequest.read(body: Data(#"""
        {"model": "silicon/auto", "messages": [
          {"role": "system", "content": "You are a coding agent with tools."},
          {"role": "user", "content": "hello"},
          {"role": "assistant", "content": "hi"},
          {"role": "user", "content": "what is a monad"}
        ]}
        """#.utf8))
        #expect(chat.message == "what is a monad")
        #expect(chat.turns == 3)
        #expect(chat.systemMentionsCodeOrTools)
        #expect(!chat.imagesAttached)
        #expect(chat.messageWords == 4)

        let responses = RoutingRequest.read(body: Data(#"""
        {"model": "silicon/auto", "instructions": "Be nice.",
         "input": [{"type": "message", "role": "user",
                    "content": [{"type": "input_text", "text": "draw me a conclusion"}]}]}
        """#.utf8))
        #expect(responses.message == "draw me a conclusion")
        #expect(!responses.systemMentionsCodeOrTools)
    }

    @Test func itSeesAttachedImagesAndOfferedTools() {
        let request = RoutingRequest.read(body: Data(#"""
        {"messages": [{"role": "user", "content": [
            {"type": "text", "text": "what is this"},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64,AAAA"}}]}],
         "tools": [{"type": "function", "function": {"name": "read_file"}}]}
        """#.utf8))
        #expect(request.imagesAttached)
        #expect(request.systemMentionsCodeOrTools)
    }

    @Test func aLongMessageKeepsItsHeadAndItsTail() {
        let ask = "SO WHAT DOES IT DO"
        let long = String(repeating: "filler ", count: 4_000) + ask
        let request = RoutingRequest.read(
            body: Data("{\"messages\":[{\"role\":\"user\",\"content\":\"\(long)\"}]}".utf8)
        )
        #expect(request.message.count <= RoutingRequest.maximumMessageCharacters + 8)
        #expect(request.message.hasSuffix(ask), "the question is usually at the end")
        #expect(request.message.hasPrefix("filler"))
        // Counted in code: jev-1.13 does not count, and the length is not a judgment.
        #expect(request.messageWords == 4_005, "4000 fillers plus the five-word question")
    }

    @Test func theCacheKeyIsTheConversationAndTheMessage() {
        func key(_ body: String) -> String { RoutingRequest.read(body: Data(body.utf8)).cacheKey }
        let same = key(#"{"messages":[{"role":"user","content":"same"}]}"#)
        #expect(same == key(#"{"messages":[{"role":"user","content":"same"}]}"#))
        #expect(same != key(#"{"messages":[{"role":"user","content":"other"}]}"#))
        // A different conversation shape is a different decision even with the same message.
        #expect(same != key(
            #"{"messages":[{"role":"user","content":"a"},{"role":"assistant","content":"b"},"#
            + #"{"role":"user","content":"same"}]}"#
        ))
        #expect(!same.contains("same"), "a cache key must not carry the message")
    }
}

// MARK: - The questions

@Suite("Routing questions")
struct RoutingQuestionTests {

    static let candidates = (0..<40).map { index in
        candidate(
            "model-\(index)", placement: index % 3 == 0 ? .node("Studio") : .thisMac,
            ready: index % 2 == 0
        )
    }

    @Test func everyQuestionIsWellFormedAndInsideTheLimits() throws {
        let questions = RoutingQuestions.questions(
            for: RoutingQuestions.shortlist(Self.candidates)
        )
        let request = ControlAPI.DecideRequest(
            state: RoutingQuestions.state(
                request: RoutingRequest.read(body: Data(#"{"messages":[]}"#.utf8)),
                candidates: RoutingQuestions.shortlist(Self.candidates)
            ),
            questions: questions
        )
        try request.validate()
        try JevService.checkLimits(questions)
        _ = request

        #expect(questions.count == 8)
        for name in [
            "needs_vision", "needs_long_context", "is_code_task", "is_quick_lookup",
            "needs_frontier_reasoning", "is_creative_writing",
        ] {
            #expect(questions[name]?.type == "noul", "\(name) should be a noul")
            // A noul's criteria describe both outcomes, and they must not contradict the
            // instruction — jev-1.13 gets confused when true means no.
            let criteria = questions[name]?.criteria?.objectValue
            #expect(criteria?["true"] != nil && criteria?["false"] != nil)
        }
        #expect(questions["complexity"]?.type == "score")
        #expect(questions["complexity"]?.criteria?.arrayValue?.count == 3)
        #expect(questions["best_model"]?.type == "choice")
        // The wire allows 255 options. This stops well before that on purpose.
        let options = try #require(questions["best_model"]?.criteria?.objectValue)
        #expect(options.count == RoutingQuestions.maximumCandidates)
        for (_, description) in options {
            let fields = try #require(description.objectValue)
            #expect(fields["what"]?.stringValue?.isEmpty == false)
            #expect(fields["good_for"]?.stringValue?.isEmpty == false)
            #expect(fields["not_for"]?.stringValue?.isEmpty == false)
        }
    }

    @Test func thereIsNoChoiceWhenThereIsNothingToChooseBetween() {
        #expect(RoutingQuestions.questions(for: [])["best_model"] == nil)
        #expect(RoutingQuestions.questions(for: []).count == 7)
    }

    @Test func theShortlistPrefersWhatIsWarmAndIsStable() {
        let shortlist = RoutingQuestions.shortlist(Self.candidates)
        #expect(shortlist.count == RoutingQuestions.maximumCandidates)
        #expect(shortlist.allSatisfy { $0.readyNow }, "warm models come first")
        #expect(shortlist.map(\.label) == RoutingQuestions.shortlist(Self.candidates).map(\.label))
    }

    @Test func theStateStaysWellInsideTheLimit() throws {
        let realistic = (0..<RoutingQuestions.maximumCandidates).map { index in
            RoutingCandidate(
                id: "local/qwen3-coder-30b-a3b-instruct@Q4_K_M-\(index)",
                label: "qwen3-coder-30b-a3b-instruct-q4-k-m-\(index)",
                name: "Qwen3 Coder 30B A3B Instruct — Q4_K_M",
                placement: .node("The Studio Machine Downstairs"),
                parameterBillions: 30, activeParameterBillions: 3.3, quantization: "Q4_K_M",
                contextWindow: 262_144, vision: true, codeTuned: true, reasoning: true,
                uncensored: true, tokensPerSecond: 41.25, usdPerMillionTokens: 0.42,
                readyNow: true
            )
        }
        let message = String(repeating: "word ", count: 2_000)
        let request = RoutingRequest.read(
            body: Data("{\"messages\":[{\"role\":\"user\",\"content\":\"\(message)\"}]}".utf8)
        )
        let state = RoutingQuestions.state(request: request, candidates: realistic)
        let stateBytes = try JevService.stateBytes(state)
        let questionBytes = try JSONEncoder().encode(
            RoutingQuestions.questions(for: realistic)
        ).count

        // The state limit is what the service enforces; the pair is what the model reads.
        #expect(stateBytes < 32 * 1024, "state was \(stateBytes) bytes")
        #expect(stateBytes + questionBytes < 64 * 1024, "\(stateBytes) + \(questionBytes) bytes")
    }

    @Test func nothingSentCarriesAModelIDOrAFilePath() throws {
        // An imported model's gateway id is `local/external:<path>`. A routing question has
        // no use for a path, and the app promises it does not send one.
        let imported = RoutingCandidate(
            id: "local/external:/Users/someone/Private/secret-project.gguf",
            label: "secret-project", name: "secret-project", placement: .thisMac,
            contextWindow: 8_192, readyNow: true
        )
        let request = RoutingRequest.read(body: Data(#"{"messages":[]}"#.utf8))
        let encoder = JSONEncoder()
        let state = String(
            decoding: try encoder.encode(
                RoutingQuestions.state(request: request, candidates: [imported])
            ), as: UTF8.self
        )
        let questions = String(
            decoding: try encoder.encode(RoutingQuestions.questions(for: [imported])),
            as: UTF8.self
        )
        for text in [state, questions] {
            #expect(!text.contains("/Users/"))
            #expect(!text.contains("external:"))
            #expect(!text.contains("local/"))
        }
    }
}

// MARK: - The policy

/// Every rule gets a case that only passes while the rule is there. Removing the vision veto,
/// the context veto, the confidence floor, the warm preference or the frontier preference each
/// fails exactly one of these.
@Suite("Routing policy")
struct RoutingPolicyTests {

    let coder = candidate("coder", code: true, billions: 30, ready: true)
    let seer = candidate("seer", vision: true, billions: 7)
    let small = candidate("small", context: 8_192, billions: 3, tokensPerSecond: 90, ready: true)
    let big = candidate(
        "big", id: "node/studio/big", placement: .node("Studio"), reasoning: true,
        context: 131_072, billions: 120, tokensPerSecond: 60
    )

    var all: [RoutingCandidate] { [coder, seer, small, big] }

    @Test func itTakesJevsPickWhenItIsConfident() {
        let decision = RoutingPolicy.choose(
            answers: RoutingAnswers(bestModel: "seer", bestModelConfidence: 0.9),
            candidates: all, defaultModel: coder.id
        )
        #expect(decision.modelID == seer.id)
        #expect(decision.reason.contains("Jev picked it"))
    }

    @Test func visionVetoesEverythingThatCannotSee() {
        // Jev picked the coder and was sure about it; the message needs eyes.
        let decision = RoutingPolicy.choose(
            answers: RoutingAnswers(
                needsVision: 0.85, bestModel: "coder", bestModelConfidence: 0.95
            ),
            candidates: all, defaultModel: coder.id
        )
        #expect(decision.modelID == seer.id)
        #expect(decision.reason.contains("vision required"))
    }

    @Test func aWantForVisionThatNothingCanMeetDoesNotFailTheRequest() {
        let decision = RoutingPolicy.choose(
            answers: RoutingAnswers(needsVision: 0.95),
            candidates: [coder, small], defaultModel: coder.id
        )
        #expect(decision.modelID == coder.id)
        #expect(decision.reason.contains("nothing here has it"))
    }

    @Test func aLongContextVetoesASmallWindow() {
        let decision = RoutingPolicy.choose(
            answers: RoutingAnswers(
                needsLongContext: 0.8, bestModel: "small", bestModelConfidence: 0.95
            ),
            candidates: [small, big], defaultModel: small.id
        )
        #expect(decision.modelID == big.id)
        #expect(decision.reason.contains("long context required"))
    }

    @Test func anUnknownWindowIsNotAKnownShortfall() {
        let unknown = candidate("unknown", context: nil, ready: true)
        let decision = RoutingPolicy.choose(
            answers: RoutingAnswers(
                needsLongContext: 0.8, bestModel: "unknown", bestModelConfidence: 0.9
            ),
            candidates: [small, unknown], defaultModel: small.id
        )
        #expect(decision.modelID == unknown.id)
    }

    @Test func aFlatChoiceFallsBackToTheDefault() {
        let sure = RoutingPolicy.choose(
            answers: RoutingAnswers(bestModel: "big", bestModelConfidence: 0.61),
            candidates: all, defaultModel: coder.id
        )
        #expect(sure.modelID == big.id)

        // 0.30 is under the confirm threshold: several options are equally plausible, and
        // the owner's own default is the better guess than a coin toss between them.
        let flat = RoutingPolicy.choose(
            answers: RoutingAnswers(bestModel: "big", bestModelConfidence: 0.30),
            candidates: all, defaultModel: coder.id
        )
        #expect(flat.modelID == coder.id)
        #expect(flat.reason.contains("below"))

        let silent = RoutingPolicy.choose(
            answers: RoutingAnswers(), candidates: all, defaultModel: coder.id
        )
        #expect(silent.modelID == coder.id)
        #expect(silent.reason.contains("no model choice"))
    }

    @Test func aTrivialLookupGoesToSomethingAlreadyWarm() {
        // Jev picked the big node model, confidently. It is not loaded, and the question is
        // "what year was X" — waiting two minutes for a load would be absurd.
        let decision = RoutingPolicy.choose(
            answers: RoutingAnswers(
                isQuickLookup: 0.9, complexity: 0.1, complexityConfidence: 0.9,
                bestModel: "big", bestModelConfidence: 0.95
            ),
            candidates: all, defaultModel: coder.id
        )
        #expect([coder.id, small.id].contains(decision.modelID))
        #expect(decision.reason.contains("already warm"))

        // The same question when the pick is already warm changes nothing.
        let warm = RoutingPolicy.choose(
            answers: RoutingAnswers(
                isQuickLookup: 0.9, complexity: 0.1, complexityConfidence: 0.9,
                bestModel: "small", bestModelConfidence: 0.95
            ),
            candidates: all, defaultModel: coder.id
        )
        #expect(warm.modelID == small.id)
    }

    @Test func hardWorkGoesToAnotherMachine() {
        let decision = RoutingPolicy.choose(
            answers: RoutingAnswers(
                complexity: 1.8, complexityConfidence: 0.8,
                bestModel: "coder", bestModelConfidence: 0.9
            ),
            candidates: all, defaultModel: coder.id
        )
        #expect(decision.modelID == big.id)
        #expect(decision.reason.contains("hard multi-step work"))

        // Frontier reasoning alone is enough, without a hard complexity read.
        let frontier = RoutingPolicy.choose(
            answers: RoutingAnswers(
                needsFrontierReasoning: 0.8, bestModel: "coder", bestModelConfidence: 0.9
            ),
            candidates: all, defaultModel: coder.id
        )
        #expect(frontier.modelID == big.id)
    }

    @Test func spendingSomeoneElsesMoneyNeedsAConfidentRead() {
        // Hard, but Jev is not sure it is hard. Sending this to a node or a paid provider on
        // a shrug is exactly the mistake the confidence floor exists to stop.
        let decision = RoutingPolicy.choose(
            answers: RoutingAnswers(
                complexity: 1.9, complexityConfidence: 0.2,
                bestModel: "coder", bestModelConfidence: 0.9
            ),
            candidates: all, defaultModel: coder.id
        )
        #expect(decision.modelID == coder.id)
    }

    @Test func aCodeTaskPrefersAModelTunedForCode() {
        let decision = RoutingPolicy.choose(
            answers: RoutingAnswers(
                isCodeTask: 0.9, complexity: 1.0, complexityConfidence: 0.8,
                bestModel: "seer", bestModelConfidence: 0.9
            ),
            candidates: all, defaultModel: seer.id
        )
        #expect(decision.modelID == coder.id)
        #expect(decision.reason.contains("tuned for code"))

        // …but a story about a programmer is not a code task, and a coding fine-tune is the
        // wrong instrument for one.
        let story = RoutingPolicy.choose(
            answers: RoutingAnswers(
                isCodeTask: 0.7, isCreativeWriting: 0.9, complexity: 1.0,
                complexityConfidence: 0.8, bestModel: "seer", bestModelConfidence: 0.9
            ),
            candidates: all, defaultModel: seer.id
        )
        #expect(story.modelID == seer.id)
    }

    @Test func whatCodeCanSeeOverridesWhatJevJudged() {
        let withImage = RoutingRequest(
            message: "what is this", turns: 1, imagesAttached: true,
            systemMentionsCodeOrTools: false, messageWords: 3
        )
        // Jev said no, but there is a picture attached: code counted it, so code wins.
        let answers = RoutingAnswers(needsVision: 0.01).observing(withImage)
        #expect(answers.needsVision == 1)
        #expect(RoutingPolicy.choose(
            answers: answers, candidates: all, defaultModel: coder.id
        ).modelID == seer.id)

        let long = RoutingRequest(
            message: "…", turns: 1, imagesAttached: false,
            systemMentionsCodeOrTools: false,
            messageWords: RoutingQuestions.Cutoff.longMessageWords
        )
        #expect(RoutingAnswers().observing(long).needsLongContext == 1)
    }

    @Test func withNothingToChooseBetweenItUsesTheDefault() {
        let decision = RoutingPolicy.choose(
            answers: RoutingAnswers(bestModel: "gone", bestModelConfidence: 1),
            candidates: [], defaultModel: "local/whatever"
        )
        #expect(decision.modelID == "local/whatever")
    }

    @Test func aDefaultThatCannotTakeTheRequestIsNotUsedEither() {
        // The owner's default is the small-window model and the request needs the room.
        let decision = RoutingPolicy.choose(
            answers: RoutingAnswers(needsLongContext: 0.9),
            candidates: [small, big], defaultModel: small.id
        )
        #expect(decision.modelID == big.id)
        #expect(decision.reason.contains("cannot take this one"))
    }
}

// MARK: - The listing

@Suite("Auto in the model list")
struct RoutingListingTests {

    let models = [routingModel(id: "local/a", name: "A", serving: true)]

    @Test func autoIsListedOnlyWhenRoutingCanAnswer() {
        #expect(AppModel.listingAuto(models, routingAvailable: false).map(\.id) == ["local/a"])

        let listed = AppModel.listingAuto(models, routingAvailable: true)
        #expect(listed.map(\.id) == [GatewayAPI.autoModelID, "local/a"])
        #expect(listed[0].displayName == "Auto — Jev picks")
        #expect(listed[0].serving)
        #expect(listed[0].contextWindow == nil, "Auto cannot promise a window")

        // Nothing to choose between is an id that would fail if a harness called it.
        #expect(AppModel.listingAuto([], routingAvailable: true).isEmpty)
    }

    @Test func autoIsNotAModelAnythingCanServe() {
        #expect(GatewayAPI.parseModelID(GatewayAPI.autoModelID) == nil)
        #expect(GatewayAPI.isAutoModelID("silicon/auto"))
        #expect(!GatewayAPI.isAutoModelID("local/silicon/auto"))
    }
}

// MARK: - Deciding against a fake TypeSafe

/// The answers a fake Jev gives back, in TypeSafe's own wire shape.
func routingAnswerBody(
    bestModel: String, confidence: Double = 0.9, complexity: Double = 1,
    complexityConfidence: Double = 0.9, quickLookup: Double = 0.1, vision: Double = 0.02,
    longContext: Double = 0.02, codeTask: Double = 0.1, frontier: Double = 0.1,
    creative: Double = 0.05
) -> String {
    """
    {"model":"jev-1.13.0","usage":{"input_tokens":1200,"output_tokens":8},
     "answers":{
       "best_model":{"type":"choice","choice":"\(bestModel)","confidence":\(confidence),
                     "probabilities":{"\(bestModel)":\(confidence)}},
       "complexity":{"type":"score","score":\(complexity),
                     "confidence":\(complexityConfidence),"legend":{},
                     "probabilities":{"0":0.1,"1":0.8,"2":0.1}},
       "needs_vision":{"type":"noul","noul":\(vision)},
       "needs_long_context":{"type":"noul","noul":\(longContext)},
       "is_code_task":{"type":"noul","noul":\(codeTask)},
       "is_quick_lookup":{"type":"noul","noul":\(quickLookup)},
       "needs_frontier_reasoning":{"type":"noul","noul":\(frontier)},
       "is_creative_writing":{"type":"noul","noul":\(creative)}
     }}
    """
}

@Suite("Routing a request")
struct ModelRouterTests {

    static let candidates = [
        candidate("warm", billions: 8, ready: true),
        candidate("coder", code: true, billions: 30),
    ]

    static let request = RoutingRequest(
        message: "refactor this function", turns: 1, imagesAttached: false,
        systemMentionsCodeOrTools: true, messageWords: 3
    )

    /// A harness with routing switched on rather than the decide tool.
    private func routingHarness(_ server: CapturingServer) async throws -> JevHarness {
        let harness = JevHarness()
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.service.update {
            $0.enabled = true
            $0.features[.routing] = true
        }
        return harness
    }

    @Test func itSendsTheRequestToTheModelJevChose() async throws {
        let server = try CapturingServer { _ in routingAnswerBody(bestModel: "coder") }
        defer { server.stop() }
        let harness = try await routingHarness(server)
        defer { harness.clean() }

        let decision = await ModelRouter.route(
            request: Self.request, candidates: Self.candidates,
            defaultModel: "local/warm", using: harness.service
        )
        #expect(decision.modelID == "local/coder")
        #expect(decision.reason.contains("Jev picked it"))
        #expect(server.requests.count == 1)

        // The ledger knows which feature spent the money.
        let month = await harness.service.ledger().month()
        #expect(month.features["routing"]?.calls == 1)
        #expect(month.features["routing"]?.inputTokens == 1_200)
        #expect(month.features[JevFeature.decideTool.rawValue] == nil)
        #expect(month.models["jev-1.13.0"] == 1)
    }

    @Test func itUsesTheDefaultWhenJevFails() async throws {
        let server = try CapturingServer(status: 500) { _ in #"{"error":{"message":"boom"}}"# }
        defer { server.stop() }
        let harness = try await routingHarness(server)
        defer { harness.clean() }

        let decision = await ModelRouter.route(
            request: Self.request, candidates: Self.candidates,
            defaultModel: "local/warm", using: harness.service
        )
        #expect(decision.modelID == "local/warm")
        #expect(decision.reason.contains("routing did not answer"))
        #expect(decision.reason.contains("warm"))
    }

    @Test func itUsesTheDefaultWhenRoutingIsSwitchedOff() async throws {
        let server = try untouchedServer("routing is switched off")
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.service.update { $0.enabled = true }

        let decision = await ModelRouter.route(
            request: Self.request, candidates: Self.candidates,
            defaultModel: "local/warm", using: harness.service
        )
        #expect(decision.modelID == "local/warm")
        #expect(decision.reason.contains("not answering routing"))
        #expect(server.requests.isEmpty, "nothing should reach TypeSafe")
    }

    @Test func aRetryOfTheSameMessageIsNotPaidForTwice() async throws {
        let server = try CapturingServer { _ in routingAnswerBody(bestModel: "coder") }
        defer { server.stop() }
        let harness = try await routingHarness(server)
        defer { harness.clean() }

        for _ in 0..<3 {
            let decision = await ModelRouter.route(
                request: Self.request, candidates: Self.candidates,
                defaultModel: "local/warm", using: harness.service
            )
            #expect(decision.modelID == "local/coder")
        }
        #expect(server.requests.count == 1, "the cache should have answered the retries")
        #expect(await harness.service.ledger().calls == 1)

        // A different message is a different decision.
        var other = Self.request
        other.message = "write me a poem instead"
        _ = await ModelRouter.route(
            request: other, candidates: Self.candidates,
            defaultModel: "local/warm", using: harness.service
        )
        #expect(server.requests.count == 2)
    }

    @Test func whatIsSentIsTheMessageAndTheCandidatesAndNothingElse() async throws {
        let server = try CapturingServer { _ in routingAnswerBody(bestModel: "warm") }
        defer { server.stop() }
        let harness = try await routingHarness(server)
        defer { harness.clean() }

        _ = await ModelRouter.route(
            request: Self.request, candidates: Self.candidates,
            defaultModel: "local/warm", using: harness.service
        )
        let sent = try #require(server.requests.first)
        let body = try #require(
            try JSONSerialization.jsonObject(with: sent.body) as? [String: Any]
        )
        let state = try #require(body["state"] as? [String: Any])
        #expect(state["message"] as? String == "refactor this function")
        #expect(Set(state.keys) == ["message", "conversation", "candidates"])
        #expect((body["questions"] as? [String: Any])?.count == 8)
        // The key travels in a header and nowhere else, and never in what is logged.
        #expect(sent.headers["x-api-key"] != nil || sent.headers["authorization"] != nil)
    }
}

// MARK: - The gateway wire

/// A gateway host that owns one model, answers routing with a canned decision, and records
/// what it was asked to make ready.
final class RoutingFakeHost: GatewayHost, @unchecked Sendable {

    /// What the gateway asked to be made ready, in order.
    actor Log {
        private(set) var models: [String] = []
        func add(_ model: String) { models.append(model) }
    }

    let backend: URL
    let decision: GatewayRoutingDecision?
    let log = Log()

    init(backend: URL, decision: GatewayRoutingDecision?) {
        self.backend = backend
        self.decision = decision
    }

    func gatewayModels() async -> [GatewayAPI.Model] {
        AppModel.listingAuto(
            [routingModel(id: "local/chosen", name: "Chosen", serving: true)],
            routingAvailable: decision != nil
        )
    }

    func gatewayEnsureReady(
        modelID: String, onStage: @escaping @Sendable (String) -> Void
    ) async throws -> GatewayReadyBackend {
        await log.add(modelID)
        guard !GatewayAPI.isAutoModelID(modelID) else {
            throw GatewayHostError.autoHasNothingToPick
        }
        return GatewayReadyBackend(baseURL: backend, backendModel: "engine-spelling")
    }

    func gatewayRoute(modelID: String, body: Data) async -> GatewayRoutingDecision? {
        GatewayAPI.isAutoModelID(modelID) ? decision : nil
    }

    func gatewayMediaRoots() async -> [String] { [] }
    func gatewayReveal(path: String) async {}
    func gatewayOpenMeshViewer() async {}
}

@Suite("Auto through the gateway")
struct RoutingGatewayTests {

    /// Starts a gateway in front of a canned backend and returns both, plus the token.
    private func gateway(
        decision: GatewayRoutingDecision?
    ) async throws -> (server: GatewayServer, host: RoutingFakeHost, backend: CapturingServer, port: Int) {
        let backend = try CapturingServer { _ in
            #"{"id":"c1","object":"chat.completion","model":"engine-spelling","#
            + #""choices":[{"index":0,"message":{"role":"assistant","content":"hello"},"#
            + #""finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1}}"#
        }
        let host = RoutingFakeHost(
            backend: URL(string: "http://127.0.0.1:\(backend.port)/")!, decision: decision
        )
        let server = GatewayServer(host: host, ledger: nil, token: "gateway-secret")
        try await server.start(preferredPort: 0)
        var port = await server.port
        var waited = 0
        while port == 0, waited < 100 {
            try await Task.sleep(for: .milliseconds(20))
            port = await server.port
            waited += 1
        }
        return (server, host, backend, port)
    }

    private func post(
        _ body: String, to port: Int, path: String = "/v1/chat/completions"
    ) async throws -> (HTTPURLResponse, [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer gateway-secret", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (response as! HTTPURLResponse, json)
    }

    @Test func autoProxiesToTheChosenModelAndSaysWhichItWas() async throws {
        let (server, host, backend, port) = try await gateway(
            decision: GatewayRoutingDecision(
                modelID: "local/chosen", reason: "Chosen — Jev picked it (confidence 0.91)"
            )
        )
        defer { backend.stop(); Task { await server.stop() } }
        #expect(port > 0)

        let (response, json) = try await post(
            #"{"model":"silicon/auto","messages":[{"role":"user","content":"hi"}]}"#, to: port
        )
        #expect(response.statusCode == 200)
        // Routed to the real model, and made ready as that model — not as the virtual id.
        #expect(await host.log.models == ["local/chosen"])
        // The backend was asked under its own spelling, exactly as an ordinary request.
        let sent = try #require(backend.requests.first)
        #expect(sent.path == "/chat/completions")
        let sentBody = (try? JSONSerialization.jsonObject(with: sent.body)) as? [String: Any]
        #expect(sentBody?["model"] as? String == "engine-spelling")
        // The client asked Auto and is told what answered, in the one field the shape has
        // and in a header.
        #expect(json["model"] as? String == "local/chosen")
        #expect(response.value(forHTTPHeaderField: "x-silicon-routed-to") == "local/chosen")
        #expect(json["choices"] != nil)
    }

    @Test func anOrdinaryModelIsNotRoutedAndNotLabelled() async throws {
        let (server, host, backend, port) = try await gateway(
            decision: GatewayRoutingDecision(modelID: "local/chosen", reason: "never asked")
        )
        defer { backend.stop(); Task { await server.stop() } }

        let (response, json) = try await post(
            #"{"model":"local/named","messages":[{"role":"user","content":"hi"}]}"#, to: port
        )
        #expect(response.statusCode == 200)
        #expect(await host.log.models == ["local/named"])
        #expect(response.value(forHTTPHeaderField: "x-silicon-routed-to") == nil)
        // Untouched: the backend's own answer, with the backend's own model name.
        #expect(json["model"] as? String == "engine-spelling")
    }

    @Test func autoWithoutARouterFailsWithSomethingReadable() async throws {
        let (server, _, backend, port) = try await gateway(decision: nil)
        defer { backend.stop(); Task { await server.stop() } }

        let (response, json) = try await post(
            #"{"model":"silicon/auto","messages":[{"role":"user","content":"hi"}]}"#, to: port
        )
        #expect(response.statusCode == 502)
        #expect((json["error"] as? String)?.contains("Auto had nothing to choose between") == true)
        #expect(backend.requests.isEmpty)
    }

    @Test func aStreamedAutoRequestCarriesTheHeaderAndTheComment() async throws {
        let frames = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
            + "data: [DONE]\n\n"
        let backend = try CapturingServer { _ in frames }
        defer { backend.stop() }
        let host = RoutingFakeHost(
            backend: URL(string: "http://127.0.0.1:\(backend.port)/")!,
            decision: GatewayRoutingDecision(modelID: "local/chosen", reason: "Chosen — warm")
        )
        let server = GatewayServer(host: host, ledger: nil, token: "gateway-secret")
        try await server.start(preferredPort: 0)
        var port = await server.port
        var waited = 0
        while port == 0, waited < 100 {
            try await Task.sleep(for: .milliseconds(20))
            port = await server.port
            waited += 1
        }
        defer { Task { await server.stop() } }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer gateway-secret", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(
            #"{"model":"silicon/auto","stream":true,"messages":[{"role":"user","content":"hi"}]}"#
                .utf8
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let head = response as! HTTPURLResponse
        #expect(head.value(forHTTPHeaderField: "x-silicon-routed-to") == "local/chosen")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(": silicon-routed-to: Chosen — warm"))
        #expect(text.contains("data: [DONE]"))
    }
}

// MARK: - Live

/// The real thing: real questions, a real key, real money — only when both are asked for.
/// The key is read from the environment where it is used and is never printed.
@Suite("Routing, live")
struct RoutingLiveTests {

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SILICON_JEV_LIVE"] == "1"))
    func jevRoutesARealQuestion() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.service.configure(
            keyProvider: { ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] },
            keyIsSet: { ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] != nil },
            configURL: harness.configURL
        )
        try await harness.service.update { $0.enabled = true; $0.features[.routing] = true }
        guard await harness.service.isAvailable(.routing) else {
            Issue.record("SILICON_JEV_LIVE=1 but TYPESAFE_API_KEY is not set.")
            return
        }

        let candidates = [
            candidate(
                "tiny-chat-3b", context: 8_192, billions: 3, tokensPerSecond: 95, ready: true
            ),
            candidate("big-coder-30b", code: true, context: 131_072, billions: 30),
            candidate("vision-7b", vision: true, billions: 7),
        ]

        // A plain code question: the coder should win, and nothing should veto it.
        let code = RoutingRequest(
            message: "This Swift function deadlocks when two callers hit it at once. "
                + "Rewrite it so the second caller waits instead.",
            turns: 1, imagesAttached: false, systemMentionsCodeOrTools: true, messageWords: 24
        )
        let response = try await RoutingQuestions.ask(
            request: code, candidates: candidates, using: harness.service
        )
        #expect(response.model.hasPrefix("jev-"))
        let answers = RoutingAnswers.read(from: response).observing(code)
        #expect(answers.isCodeTask > 0.5)
        #expect(answers.needsVision < 0.5)
        #expect(answers.isCreativeWriting < 0.5)
        let decision = RoutingPolicy.choose(
            answers: answers, candidates: candidates, defaultModel: "local/tiny-chat-3b"
        )
        #expect(decision.modelID == "local/big-coder-30b")

        // A one-line lookup: whatever Jev picks, the policy should not make anyone wait.
        let lookup = RoutingRequest(
            message: "What is the capital of Portugal?", turns: 1, imagesAttached: false,
            systemMentionsCodeOrTools: false, messageWords: 6
        )
        let quick = RoutingAnswers.read(from: try await RoutingQuestions.ask(
            request: lookup, candidates: candidates, using: harness.service
        )).observing(lookup)
        #expect(quick.isQuickLookup > 0.5)
        #expect(quick.complexity ?? 2 < 1)
        #expect(RoutingPolicy.choose(
            answers: quick, candidates: candidates, defaultModel: "local/big-coder-30b"
        ).modelID == "local/tiny-chat-3b")

        #expect(await harness.service.ledger().month().features["routing"]?.calls == 2)
    }
}

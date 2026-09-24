import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconCore
@testable import SiliconHardware
@testable import SiliconMCP
@testable import SiliconPlanner
@testable import SiliconRuntime
@testable import SiliconUI

// MARK: - The budget, as laya-mlx spends it

/// laya-mlx 0.1.0's `build_prefix`, which these mirror: each option is a mask token and at
/// most 48 tokens of "label: description", the whole question is held to 192 by cutting its
/// own text first and then every option alike, and the state gets what is left of 512.
@Suite("What a Laya checkpoint can read")
struct LayaBudgetTests {

    private func noul(_ instructions: String, true yes: String? = nil) -> ControlAPI.SystemOneQuestion {
        .init(
            type: "noul", instructions: .string(instructions),
            criteria: yes.map { .object(["true": .string($0)]) }
        )
    }

    private func words(_ count: Int) -> String {
        Array(repeating: "word", count: count).joined(separator: " ")
    }

    /// The state reads as Python writes it — the library serialises it with `json.dumps`,
    /// keys in the sorted order the sidecar sends them.
    @Test func aStateReadsAsPythonWritesIt() {
        let state = JSONContent.object([
            "b": .array([.bool(true), .null, .number(2), .number(2.5)]),
            "a": .string("line \"one\"\nline two"),
        ])
        #expect(LayaBudget.text(of: state)
                == #"{"a": "line \"one\"\nline two", "b": [true, null, 2, 2.5]}"#)
        #expect(LayaBudget.text(of: .string("as it is")) == "as it is")
    }

    @Test func aShortQuestionIsNotCut() {
        #expect(LayaBudget.prefix(noul("Is this true?")).cut == false)
    }

    /// An option past 48 tokens loses its end, and so does a question whose own text does not
    /// fit what its options leave of 192.
    @Test func aLongOptionOrALongQuestionIsCut() {
        #expect(LayaBudget.prefix(noul("Is this true?", true: words(60))).cut)
        #expect(LayaBudget.prefix(noul(words(200))).cut)
    }

    /// Many options share 176 tokens between them, which cuts even bare labels once there
    /// are enough of them.
    @Test func manyOptionsAreCutEvenAsBareLabels() {
        let labels = (1...40).map { "option-number-\($0)" }
        let choice = ControlAPI.SystemOneQuestion(
            type: "choice", instructions: .string("Which one?"),
            criteria: .object(Dictionary(uniqueKeysWithValues: labels.map { ($0, .null) }))
        )
        #expect(LayaBudget.prefix(choice).cut)
        // Such a choice cannot be asked at all, and its form says so by leaving it out.
        #expect(LayaBudget.compact(["pick": choice])["pick"] == nil)
    }

    /// A choice written for Jev — long descriptions per option, instructions as an object —
    /// comes back with every label, what each option is for, and a question in words, all
    /// inside the budget.
    @Test func aLongChoiceIsReshapedToFitWithEveryLabel() throws {
        let labels = ["alpha-7b", "beta-coder-14b", "gamma-vision-12b", "delta-32b"]
        let choice = ControlAPI.SystemOneQuestion(
            type: "choice",
            instructions: .object([
                "question": .string("Which one of these models should answer the message?"),
                "pick": .string(words(40)),
            ]),
            criteria: .object(Dictionary(uniqueKeysWithValues: labels.map {
                ($0, JSONContent.object([
                    "what": .string("\($0) is for " + words(50)),
                    "not_for": .string(words(30)),
                ]))
            }))
        )
        #expect(LayaBudget.prefix(choice).cut)

        let compacted = try #require(LayaBudget.compact(["pick": choice])["pick"])
        #expect(LayaBudget.prefix(compacted).cut == false)
        let options = try #require(compacted.criteria?.objectValue)
        #expect(options.keys.sorted() == labels.sorted())
        #expect(options["alpha-7b"]?.stringValue?.hasPrefix("alpha-7b is for") == true)
        #expect(compacted.instructions?.stringValue?.hasPrefix(
            "Which one of these models should answer the message?"
        ) == true)
    }

    /// Free text is cut to its head and tail until the state fits; what the questions judge
    /// is never touched.
    @Test func aStateIsShortenedAroundItsSubject() {
        let questions = ["q": noul("Is this true?")]
        let subject = JSONContent.object(["arguments": .string(words(100))])
        let state = JSONContent.object([
            "tool_call": subject,
            "context": .string("start " + words(600) + " end"),
        ])
        #expect(!LayaBudget.fits(state: state, questions: questions))

        let fitted = LayaBudget.shortened(state, toFit: questions, protecting: ["tool_call"])
        #expect(LayaBudget.fits(state: fitted, questions: questions))
        #expect(fitted.objectValue?["tool_call"] == subject)
        let context = fitted.objectValue?["context"]?.stringValue ?? ""
        #expect(context.hasPrefix("start") && context.hasSuffix("end") && context.contains(" … "))
    }

    /// And a subject that does not fit is sent as it is — for the sidecar to refuse — rather
    /// than cut.
    @Test func aSubjectTooLongToFitIsLeftWhole() {
        let questions = ["q": noul("Is this true?")]
        let state = JSONContent.object(["reply": .string(words(700))])
        let fitted = LayaBudget.shortened(state, toFit: questions, protecting: ["reply"])
        #expect(fitted == state)
        #expect(!LayaBudget.fits(state: fitted, questions: questions))
    }
}

// MARK: - Every ability's form

/// The states the app actually sends, built with its own builders from typical inputs, in
/// the form a Laya lane gets — checked against the English checkpoint's 512 tokens with the
/// stand-in count. Before these forms only two of the eight abilities fitted; routing and
/// tool selection, the two asked most often, ran to three and four times the room.
@Suite("Each ability's Laya form")
@MainActor
struct LayaFormTests {

    private func expectFits(
        _ feature: JevFeature, _ state: JSONContent, _ questions: LayaForms.Questions,
        _ what: String, sourceLocation: SourceLocation = #_sourceLocation
    ) -> (state: JSONContent, questions: LayaForms.Questions) {
        let form = LayaForms.form(feature, state: state, questions: questions)
        let room = LayaBudget.room(for: form.questions)
        let used = LayaBudget.tokens(LayaBudget.text(of: form.state))
        #expect(
            LayaBudget.fits(state: form.state, questions: form.questions),
            "\(feature.rawValue) \(what): \(used) tokens of state for \(room) of room",
            sourceLocation: sourceLocation
        )
        return form
    }

    // MARK: Routing

    private func routingCandidates(locals: Int, nodes: Int, clouds: Int) -> [RoutingCandidate] {
        let localIDs = [
            "qwen3-coder-30b-a3b", "qwen3-8b", "gemma-3-12b-it", "qwen2.5-vl-7b", "gpt-oss-20b",
            "qwen3.8-27b", "mistral-small-3.2-24b", "orcabonsai-27b-uncensored", "phi-4",
        ]
        var entries: [(GatewayAPI.Model, Int)] = []
        var sources: [(InstalledModel, ModelEntry)?] = []
        for id in localIDs.prefix(locals) {
            let entry = ModelCatalog.entry(id: id)!
            let install = routingInstall(
                id: "\(id)@Q4_K_M", name: entry.name, capabilities: entry.capabilities,
                projector: entry.capabilities.contains(.vision), shape: entry.shape,
                quantization: .q4_K_M, catalogID: id
            )
            entries.append((routingModel(
                id: GatewayAPI.modelID(local: install.id),
                name: "\(install.name) — \(install.quantization.rawValue)",
                serving: entries.isEmpty, context: min(entry.shape.trainingContextLength, 16_384),
                quantization: install.quantization.rawValue, tokensPerSecond: 40
            ), 0))
            sources.append((install, entry))
        }
        let nodeModels = [
            ("Studio", "Qwen3-Coder-30B-A3B"), ("Studio", "qwen3.8-27b"),
            ("GPU Box", "gpt-oss-120b"), ("GPU Box", "GLM-4.5-Air"),
        ]
        for (peer, name) in nodeModels.prefix(nodes) {
            entries.append((routingModel(
                id: GatewayAPI.modelID(peerSlug: GatewayAPI.peerSlug(peer), model: name),
                name: "\(name) — \(peer)", serving: true, context: 131_072
            ), 1))
            sources.append(nil)
        }
        let cloudModels = [
            CloudModel(
                id: "minimax/minimax-m3", displayName: "MiniMax M3", provider: .openRouter,
                contextWindow: 204_800, pricePerMillionInputUSD: 0.4
            ),
            CloudModel(
                id: "glm-4.7:free", displayName: "GLM 4.7 (free)", provider: .tokenHarbor,
                contextWindow: 131_072
            ),
        ]
        var chosenClouds: [CloudModel] = []
        for cloud in cloudModels.prefix(clouds) {
            entries.append((routingModel(
                id: cloud.gatewayID, name: cloud.displayName, serving: true,
                context: cloud.contextWindow
            ), 2))
            sources.append(nil)
            chosenClouds.append(cloud)
        }
        let labels = RoutingCandidate.labels(for: entries.map { $0.0.displayName })
        var cloudIndex = 0
        let all: [RoutingCandidate] = entries.enumerated().map { index, pair in
            switch pair.1 {
            case 0:
                let (installed, entry) = sources[index]!
                return .local(pair.0, installed: installed, catalog: entry, label: labels[index])
            case 1:
                let peer = pair.0.displayName.components(separatedBy: " — ").last ?? "Studio"
                return .node(pair.0, peer: peer, label: labels[index])
            default:
                defer { cloudIndex += 1 }
                let cloud = chosenClouds[cloudIndex]
                return .cloud(pair.0, cloud: cloud, provider: cloud.provider.displayName, label: labels[index])
            }
        }
        return RoutingQuestions.shortlist(all, keeping: all.first?.id)
    }

    private let harnessTurn = """
        In Sources/SiliconUI/Jev/RoutingQuestions.swift the shortlist puts every local model \
        ahead of the swarm, so with more than sixteen installed models the node models never \
        reach the question. Change shortlist(_:keeping:) so at least two node models survive \
        the cap when any are reachable, keep the pinned fallback behaviour exactly as it is, \
        and add a test in JevRoutingTests that fails without the change.
        """

    @Test func routingFitsWithEightOrFifteenCandidates() throws {
        let request = RoutingRequest(
            message: harnessTurn, turns: 3, imagesAttached: false,
            systemMentionsCodeOrTools: true, messageWords: 70
        )
        for candidates in [
            routingCandidates(locals: 5, nodes: 2, clouds: 1),
            routingCandidates(locals: 9, nodes: 4, clouds: 2),
        ] {
            let form = expectFits(
                .routing,
                RoutingQuestions.state(request: request, candidates: candidates),
                RoutingQuestions.questions(for: candidates),
                "\(candidates.count) candidates"
            )
            // The seven judgments the policy runs on are all still asked.
            for name in RoutingQuestions.questions.keys {
                #expect(form.questions[name] != nil, "\(name) was dropped")
            }
            #expect(form.state.objectValue?["message"] != nil)
        }
    }

    // MARK: Media routing

    @Test func mediaRoutingFitsAndKeepsThePromptWhole() {
        let videoLanes = [
            MediaCandidate.video(VideoCatalog.wan22, node: "Studio"),
            MediaCandidate.video(VideoCatalog.ltx2, node: "Studio"),
            MediaCandidate.video(VideoCatalog.ltx23Uncensored, node: nil),
            MediaCandidate.video(
                VideoCatalog.hailuoH3, node: "GPU Box",
                capabilityParameters: ["h3_turbo", "h3_steps"]
            ),
        ]
        let prompt = """
            A lone lighthouse keeper climbs the spiral staircase of a stone lighthouse during a \
            winter storm. Handheld camera following from behind, warm lantern light against cold \
            blue windows, rain streaking across the glass. At the top he pauses and looks out at \
            a small fishing boat fighting the swell. Photorealistic, 35mm film grain.
            """
        let form = expectFits(
            .mediaRouting,
            MediaRoutingQuestions.state(prompt: prompt, kind: .video, candidates: videoLanes),
            MediaRoutingQuestions.questions(over: videoLanes),
            "video"
        )
        // What the safety gates read goes whole, or not at all.
        #expect(form.state.objectValue?["request"]?.objectValue?["prompt"] == .string(prompt))
        #expect(form.questions["adult_content"] != nil && form.questions["names_real_person"] != nil)

        let images = DiffusionCatalog.all.prefix(5).map {
            MediaCandidate.image($0, installed: true, runsOn: MediaCandidate.thisMac)
        }
        _ = expectFits(
            .mediaRouting,
            MediaRoutingQuestions.state(
                prompt: "Poster for a jazz night: one trumpet silhouetted against a warm "
                    + "orange spotlight, bold title text reading 'Blue Hour Sessions'.",
                kind: .image, candidates: Array(images)
            ),
            MediaRoutingQuestions.questions(over: Array(images)),
            "image"
        )
    }

    // MARK: Tool selection

    @Test func toolSelectionFitsInAllThreeCalls() throws {
        let roster = SkillCandidate.roster(Tools.all.map {
            SkillCandidate.make(name: $0.name, kind: .tool, description: $0.description)
        })
        let turn = SkillSelectionTurn(
            turn: "render three 8-second versions of the fox shot from yesterday, one per video "
                + "model, and put them in the queue so I can compare them tonight",
            lastToolResult: "Rendered fox-snow-01.mp4 with Wan 2.2 5B: 5 s, 1280x704, 3 min 12 s."
        )
        _ = expectFits(
            .skillSelection,
            SkillSelectionQuestions.state(turn, roster: roster),
            SkillSelectionQuestions.wideQuestions(for: roster),
            "the first call, over \(roster.count) tools"
        )
        let shortlist = ["generate_video", "queue_videos", "list_video_models"].compactMap { name in
            roster.first { $0.name == name }
        }
        try #require(shortlist.count == 3)
        _ = expectFits(
            .skillSelection,
            SkillSelectionQuestions.state(turn, roster: shortlist, detailed: true),
            SkillSelectionQuestions.shortlistQuestions(for: shortlist),
            "the second call"
        )

        var messages: [[String: Any]] = [
            ["role": "system", "content": "You are a coding agent."],
            ["role": "user", "content": harnessTurn],
        ]
        for index in 0..<5 {
            messages.append([
                "role": "assistant", "content": "",
                "tool_calls": [["id": "call_\(index)", "type": "function",
                                "function": ["name": "shell", "arguments": "{}"]]],
            ])
            messages.append([
                "role": "tool", "tool_call_id": "call_\(index)",
                "content": "$ swift build\nBuilding for debugging...\n"
                    + String(repeating: "[\(index)/14] Compiling SiliconUI RoutingQuestions.swift\n", count: 40),
            ])
        }
        messages.append(["role": "user", "content": "Now make the failing test pass."])
        let body = try JSONSerialization.data(withJSONObject: ["model": "silicon/auto", "messages": messages])
        let plan = try #require(ContextPruning.plan(body: body, contextWindow: 4_096, aboveFraction: 0.25))
        let latest = try #require(ContextPruning.latestUserTurn(inBody: body))
        _ = expectFits(
            .skillSelection,
            ContextPruning.state(latestTurn: latest, candidates: plan.candidates),
            ContextPruning.questions(for: plan.candidates),
            "pruning \(plan.candidates.count) results"
        )
    }

    // MARK: Recommendation

    @Test func recommendationFits() {
        let mac = SystemProfile(
            chipName: "Apple M3 Max", generation: .m3, variant: .max, modelIdentifier: "Mac15,11",
            totalMemory: .gib(36), performanceCores: 10, efficiencyCores: 4, gpuCores: 30,
            neuralEngineCores: 16, diskTotal: .gib(1024), diskFree: .gib(500),
            memoryBandwidthGBps: 300, ssdReadMBps: 5000
        )
        let candidates = RecommendationQuestions.shortlist(from: AutoConfigurator(profile: mac).rank().map {
            RecommendationCandidate(entry: $0.entry, recommendation: $0, isInstalled: false)
        })
        let task = """
            A Japanese-language support bot for a small online shop. It answers customer emails \
            about orders, shipping and returns, reads screenshots customers attach, and calls our \
            order-lookup and refund tools rather than guessing.
            """
        _ = expectFits(
            .recommendation,
            RecommendationQuestions.state(task: task, candidates: candidates),
            RecommendationQuestions.questions(over: candidates),
            "\(candidates.count) models"
        )
    }

    // MARK: Guardrails

    @Test func guardrailsFitAndKeepTheToolCallWhole() {
        let testOutput = """
            $ swift test --filter ImageCacheTests
            Building for debugging...
            ✘ Test twoViewsLoadingTheSameURLShareOneRequest() recorded an issue at \
            ImageCacheTests.swift:41:9: Expectation failed: (requests.count → 2) == 1
            ✘ Suite "Image cache" failed after 0.214 seconds with 1 issue.
            """ + String(repeating: "\n(output continues)", count: 30)
        let edit = """
            {"path":"Sources/ImageCache/ImageCache.swift","oldText":"        inFlight[url] = task\
            \\n        let data = try await task.value","newText":"        inFlight[url] = task\
            \\n        defer { inFlight[url] = nil }\\n        let data = try await task.value"}
            """
        for (tool, arguments) in [
            ("bash", "{\"command\":\"swift test --filter ImageCacheTests 2>&1 | tail -40 && git push origin fix/image-cache\"}"),
            ("edit", edit),
        ] {
            let state = GuardrailState.make(
                request: "the image cache deadlocks when two views load the same URL — fix it and run its tests",
                tool: tool, arguments: arguments, workingDirectory: "/tmp/image-cache",
                recentTranscript: [testOutput, testOutput]
            )
            let form = expectFits(.guardrails, state, GuardrailQuestions.questions, tool)
            #expect(form.state.objectValue?["tool_call"] == state.objectValue?["tool_call"])
        }
    }

    // MARK: Verification

    @Test func verificationFitsATypicalReplyAndRefusesToCutALongOne() {
        let reply = """
            Use a LaunchAgent with a StartCalendarInterval: save a plist in \
            ~/Library/LaunchAgents with Label, ProgramArguments pointing at your script, and \
            StartCalendarInterval set to Hour 7, Minute 0. Load it with `launchctl bootstrap \
            gui/$(id -u)` and the plist's path. Make the script executable and use absolute \
            paths in it, because launchd does not read your shell profile. If the Mac is asleep \
            at seven, the job runs when it wakes.
            """
        _ = expectFits(
            .verification,
            VerificationQuestions.state(
                message: "How do I make a launchd job that runs my script every morning at 7?",
                systemPrompt: "You are a helpful assistant running locally on the user's Mac.",
                reply: reply, context: nil
            ).content,
            VerificationQuestions.questions,
            "a one-paragraph reply"
        )

        // A reply several times the room is not cut to fit: cut, it would read as cut off
        // and as not answering, and a flagged reply is re-run. It goes whole, to be refused.
        let long = String(repeating: reply + "\n\n", count: 4)
        let state = VerificationQuestions.state(
            message: "How do I make a launchd job?", systemPrompt: nil, reply: long, context: nil
        ).content
        let form = LayaForms.form(.verification, state: state, questions: VerificationQuestions.questions)
        #expect(form.state.objectValue?["reply"] == state.objectValue?["reply"])
        #expect(!LayaBudget.fits(state: form.state, questions: form.questions))
    }

    // MARK: Calibration and the decide tool

    @Test func everyCalibrationCaseFitsAsItIsWritten() {
        for item in CalibrationQuestions.builtIn {
            let form = expectFits(.calibration, item.state, item.questions, item.id)
            #expect(form.state == item.state)
        }
    }

    /// The decide tool's state and questions are the caller's own, and go as asked.
    @Test func theDecideToolSendsTheCallersRequestAsAsked() {
        let state = JSONContent.string("A customer was charged twice.")
        let form = expectFits(.decideTool, state, jevQuestions, "fixture")
        #expect(form.state == state && form.questions == jevQuestions)
    }
}

// MARK: - Only the Laya lanes

/// Jev and the loaded model read the whole request; only the two lanes that run a Laya
/// checkpoint get the form.
@Suite("The router's Laya form")
struct LayaFormRoutingTests {

    actor Capturing: DecisionLane {
        nonisolated let laneID: DecisionLaneID
        private(set) var asked: [ControlAPI.DecideRequest] = []
        init(_ laneID: DecisionLaneID) { self.laneID = laneID }
        nonisolated func isReady() async -> Bool { true }
        nonisolated func decide(_ request: ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse {
            await record(request)
            return ControlAPI.DecideResponse(
                model: laneID.wireName, usage: .init(inputTokens: 1, outputTokens: 0),
                answers: request.questions.keys.reduce(into: [:]) { $0[$1] = .noul(0.9) },
                provider: laneID.wireName
            )
        }
        private func record(_ request: ControlAPI.DecideRequest) { asked.append(request) }
    }

    @Test func theFormReachesLayaAndNotTheLoadedModel() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(key: nil)
        let router = DecisionRouter(service: harness.service)
        let laya = Capturing(.laya), oneToken = Capturing(.oneToken)
        await router.register(laya)
        await router.register(oneToken)
        await router.useLayaForm { _, _, questions in
            (.string("the form"), questions)
        }
        let questions = ControlAPI.DecideRequest.fixture().questions

        _ = try await router.ask(lane: .laya, feature: .routing, state: .string("whole"), questions: questions)
        _ = try await router.ask(lane: .oneToken, feature: .routing, state: .string("whole"), questions: questions)

        #expect(await laya.asked.map(\.state) == [.string("the form")])
        #expect(await oneToken.asked.map(\.state) == [.string("whole")])
    }

    /// A form with nothing left to ask is a refusal of this request, and the next lane
    /// answers — the Laya lane stays ready for the next one.
    @Test func aFormWithNothingLeftToAskFallsThrough() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(key: nil)
        let router = DecisionRouter(service: harness.service)
        let laya = Capturing(.laya), oneToken = Capturing(.oneToken)
        await router.register(laya)
        await router.register(oneToken)
        await router.useLayaForm { _, state, _ in (state, [:]) }
        let questions = ControlAPI.DecideRequest.fixture().questions

        let answer = try await router.decide(.routing, state: .string("s"), questions: questions)
        #expect(answer.provider == DecisionLaneID.oneToken.wireName)
        #expect(await laya.asked.isEmpty)
        #expect(await router.availability(for: .calibration).laya)
    }
}

import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

// MARK: - Hosts for the route tests

enum DecisionsHostError: Error { case unused }

/// A host that answers the decision routes and records what reached it.
///
/// Everything else is the same conservative boilerplate the other route fixtures use: this
/// suite is about the wire and the scope rules, not about a Mac.
actor DecisionsTestHost: ControlHost {
    private(set) var laneUpdates = 0
    private(set) var installs = 0
    private(set) var tests: [String] = []
    private(set) var calibratedLanes: [String?] = []
    private var calibrations: [String: ControlAPI.JevCalibration] = [:]

    func setCalibration(_ result: ControlAPI.JevCalibration, for lane: String) {
        calibrations[lane] = result
    }

    func decisionsStatus() async -> ControlAPI.DecisionsStatus {
        .init(
            lanes: DecisionLaneID.allCases.map { lane in
                .init(
                    id: lane.wireName, displayName: lane.displayName,
                    available: false, installed: false, detail: "fixture",
                    leavesTheMac: lane.leavesTheMac, costsMoney: lane.costsMoney,
                    jev: lane == .jev ? .init(
                        enabled: false, keySet: false, model: JevService.pinnedModel,
                        monthlyBudgetUSD: nil, budgetRemainingUSD: nil,
                        spentThisMonthUSD: 0
                    ) : nil,
                    laya: lane == .laya ? .init(
                        enabled: true, checkpoint: LayaCheckpoint.default.rawValue,
                        checkpoints: LayaCheckpoint.allCases.map {
                            .init(
                                id: $0.rawValue, displayName: $0.displayName,
                                repository: $0.repository, revision: $0.revision,
                                downloadBytes: $0.downloadBytes, baseModel: $0.baseModel,
                                parameterMillions: $0.parameterMillions,
                                contextTokens: $0.contextTokens, installed: false,
                                publishedShortQuestionMS: $0.publishedShortQuestionMS,
                                publishedPeakMemoryBytes: $0.publishedPeakMemoryBytes,
                                summary: $0.summary
                            )
                        },
                        package: LayaPackage.requirement,
                        packageSHA256: LayaPackage.wheelSHA256,
                        licence: LayaCheckpoint.licence,
                        weightsAttribution: LayaCheckpoint.weightsAttribution,
                        portAttribution: LayaCheckpoint.portAttribution,
                        sourceURL: LayaPackage.repository,
                        upstreamURL: LayaPackage.upstreamRepository,
                        bytesOnDisk: 0
                    ) : nil,
                    node: lane == .node ? .init(enabled: false) : nil
                )
            },
            abilities: JevFeature.allCases.map {
                .init(
                    id: $0.rawValue, displayName: $0.displayName, summary: $0.summary,
                    enabled: false, built: $0.isBuilt, laneOverride: "automatic",
                    lane: nil, calls: 0, inputTokens: 0, estimatedUSD: 0
                )
            },
            recent: .init(available: false, questions: [], screenings: []),
            month: JevLedger.monthKey(), totalCalls: 0, totalEstimatedUSD: 0
        )
    }

    func updateDecisionLanes(
        _ update: ControlAPI.DecisionLanesUpdate
    ) async throws -> ControlAPI.DecisionsStatus {
        if let checkpoint = update.layaCheckpoint,
           LayaCheckpoint(rawValue: checkpoint) == nil {
            throw ControlHostError.badRequest(
                ControlAPI.DecisionLaneVocabulary.unknownCheckpoint(checkpoint)
            )
        }
        for (_, choice) in update.overrides ?? [:]
        where DecisionLaneOverride(rawValue: choice) == nil {
            throw ControlHostError.badRequest(
                ControlAPI.DecisionLaneVocabulary.unknownOverride(choice)
            )
        }
        laneUpdates += 1
        return await decisionsStatus()
    }

    func installDecisionLane(
        _ request: ControlAPI.DecisionInstallRequest
    ) async throws -> ControlAPI.DecisionInstallAccepted {
        installs += 1
        return .init(
            started: true, checkpoint: request.checkpoint ?? "english",
            estimatedBytes: LayaCheckpoint.default.downloadBytes, detail: "fixture"
        )
    }

    func runDecisionTest(
        _ request: ControlAPI.DecisionTestRequest
    ) async throws -> ControlAPI.DecisionTestResult {
        guard DecisionLaneID.named(request.lane) != nil else {
            throw ControlHostError.badRequest(
                ControlAPI.DecisionLaneVocabulary.unknownLane(request.lane)
            )
        }
        tests.append(request.lane)
        return .init(
            lane: request.lane, model: "fixture",
            answers: request.questions.mapValues { _ in .noul(0.9) },
            latencyMS: 20, perQuestionMS: 20,
            usage: .init(inputTokens: 1, outputTokens: 0), estimatedUSD: 0
        )
    }

    func calibrateDecisionLane(_ lane: String?) async throws -> ControlAPI.JevCalibration {
        calibratedLanes.append(lane)
        return .fixture(lane: lane ?? "local")
    }

    func decisionCalibration(lane: String?) async -> ControlAPI.JevCalibration? {
        calibrations[lane ?? "local"]
    }

    func jevStatus() async -> ControlAPI.JevStatus { .fixture() }
    func jevCalibration() async -> ControlAPI.JevCalibration? { calibrations["local"] }
    func calibrateJev() async throws -> ControlAPI.JevCalibration { .fixture(lane: "local") }
    func recommend(category: String?, task: String?) async -> ControlAPI.CatalogModel? { nil }

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
        throw DecisionsHostError.unused
    }
    func install(_ request: ControlAPI.LoadRequest) async throws -> String {
        throw DecisionsHostError.unused
    }
    func load(_ request: ControlAPI.LoadRequest) async throws -> ControlAPI.Status {
        throw DecisionsHostError.unused
    }
    func chat(_ request: ControlAPI.ChatRequest) async throws -> ControlAPI.ChatResponse {
        throw DecisionsHostError.unused
    }
    func decide(_ request: ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse {
        throw DecisionsHostError.unused
    }
    func benchmark() async throws -> ControlAPI.BenchmarkResult {
        throw DecisionsHostError.unused
    }
    func planImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImagePlan {
        throw DecisionsHostError.unused
    }
    func generateImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImageResponse {
        throw DecisionsHostError.unused
    }
    func planMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshPlan {
        throw DecisionsHostError.unused
    }
    func generateMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshResponse {
        throw DecisionsHostError.unused
    }
    func generateVideo(
        _ request: ControlAPI.VideoGenerateRequest
    ) async throws -> ControlAPI.VideoResponse {
        throw DecisionsHostError.unused
    }
    func chatStream(
        _ request: ControlAPI.ChatRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        throw DecisionsHostError.unused
    }
    func conversation(id: String) async throws -> ControlAPI.ConversationDetail {
        throw DecisionsHostError.unused
    }
    func replyInConversation(
        id: String, to message: ControlAPI.NewMessageRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        throw DecisionsHostError.unused
    }
}

/// A host that is not the Mac app: it takes every default in the protocol extension, which
/// is what the MCP bridge's doubles and the other fixtures get.
actor BareDecisionHost: ControlHost {
    func jevStatus() async -> ControlAPI.JevStatus { .fixture() }
    func jevCalibration() async -> ControlAPI.JevCalibration? { nil }
    func calibrateJev() async throws -> ControlAPI.JevCalibration { .fixture(lane: nil) }
    func recommend(category: String?, task: String?) async -> ControlAPI.CatalogModel? { nil }

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
        throw DecisionsHostError.unused
    }
    func install(_ request: ControlAPI.LoadRequest) async throws -> String {
        throw DecisionsHostError.unused
    }
    func load(_ request: ControlAPI.LoadRequest) async throws -> ControlAPI.Status {
        throw DecisionsHostError.unused
    }
    func chat(_ request: ControlAPI.ChatRequest) async throws -> ControlAPI.ChatResponse {
        throw DecisionsHostError.unused
    }
    func decide(_ request: ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse {
        throw DecisionsHostError.unused
    }
    func benchmark() async throws -> ControlAPI.BenchmarkResult {
        throw DecisionsHostError.unused
    }
    func planImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImagePlan {
        throw DecisionsHostError.unused
    }
    func generateImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImageResponse {
        throw DecisionsHostError.unused
    }
    func planMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshPlan {
        throw DecisionsHostError.unused
    }
    func generateMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshResponse {
        throw DecisionsHostError.unused
    }
    func generateVideo(
        _ request: ControlAPI.VideoGenerateRequest
    ) async throws -> ControlAPI.VideoResponse {
        throw DecisionsHostError.unused
    }
    func chatStream(
        _ request: ControlAPI.ChatRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        throw DecisionsHostError.unused
    }
    func conversation(id: String) async throws -> ControlAPI.ConversationDetail {
        throw DecisionsHostError.unused
    }
    func replyInConversation(
        id: String, to message: ControlAPI.NewMessageRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        throw DecisionsHostError.unused
    }
}

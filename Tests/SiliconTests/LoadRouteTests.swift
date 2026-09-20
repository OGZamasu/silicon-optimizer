import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime

/// `POST /load` and `GET /status` as a phone meets them.
///
/// Two things are being pinned. A load belongs to the Mac once it has been asked for, not to
/// the socket that asked — so a request that goes away must not take the load with it. And
/// two loads at once must produce a sentence rather than a silently abandoned first load.
///
/// Nothing here loads a model: the host is a double that holds a load until a test releases
/// it, over a loopback listener with its own private handshake file.
@Suite("Load route")
struct LoadRouteTests {

    // MARK: - A load outlives its request

    /// The deliverable, at the layer that decides it: cancel the wait, and the load carries
    /// on regardless. Before this, a load ran *inside* the request's task — so a phone that
    /// locked its screen could end a load the Mac had been told to do, and the failure that
    /// followed was indistinguishable from a model that could not load.
    @Test func cancellingTheRequestDoesNotCancelTheLoad() async throws {
        let host = LoadTestHost()
        let dispatcher = LoadDispatcher()

        let waiting = Task {
            try await dispatcher.load(
                ControlAPI.LoadRequest(modelID: "qwen3-coder-30b"),
                on: host, patience: .seconds(10)
            )
        }
        try await waitUntil { await host.accepted == 1 }

        waiting.cancel()
        let answer = try await waiting.value
        guard case .stillLoading = answer else {
            Issue.record("a cancelled wait should leave the load running")
            return
        }

        // The load is still going, and nothing has been told to give up on it.
        #expect(await host.completed == 0)
        #expect(await host.cancellations == 0)
        #expect(await dispatcher.isLoading)

        await host.release()
        try await waitUntil { await host.completed == 1 }
        #expect(await host.cancellations == 0)
        try await waitUntil { await dispatcher.isLoading == false }
    }

    /// And when it finishes in time, nothing about the answer changed.
    @Test func aLoadThatFinishesInTimeAnswersExactlyAsItAlwaysDid() async throws {
        let host = LoadTestHost()
        let dispatcher = LoadDispatcher()
        await host.release()

        let answer = try await dispatcher.load(
            ControlAPI.LoadRequest(modelID: "qwen3-coder-30b"), on: host, patience: .seconds(5)
        )
        guard case .finished(let status) = answer else {
            Issue.record("expected the load's own status")
            return
        }
        #expect(status.loadedModelID == "qwen3-coder-30b")
        #expect(status.state == "Ready")
    }

    /// A load that fails still fails the request that asked for it, with the runtime's own
    /// sentence — one sentence, not a log.
    @Test func aFailedLoadStillFailsTheRequest() async throws {
        let sentence = "llama-server stopped on its own after 8 seconds (exit 1)."
        let host = LoadTestHost(failing: sentence)
        let dispatcher = LoadDispatcher()
        await host.release()

        do {
            _ = try await dispatcher.load(
                ControlAPI.LoadRequest(modelID: "bonsai-2-27b"), on: host, patience: .seconds(5)
            )
            Issue.record("a failed load must not answer as a success")
        } catch {
            #expect(error.localizedDescription == sentence)
        }
        // And the machine is free for the next attempt, rather than stuck behind a load
        // that is over.
        #expect(await dispatcher.isLoading == false)
    }

    // MARK: - Over the wire

    /// A load slower than the request's patience answers with the live status — the same
    /// shape, the same `state` line `GET /status` would give — and keeps loading.
    @Test func aSlowLoadAnswersWithTheStatusAndKeepsGoing() async throws {
        try await withServer(patience: .milliseconds(200)) { fixture in
            let (code, body) = try await fixture.call(
                "POST", "/load", body: #"{"modelID":"qwen3-coder-30b"}"#
            )
            #expect(code == 200)
            let status = try JSONDecoder().decode(ControlAPI.Status.self, from: body)
            #expect(status.state == LoadTestHost.loadingLine)
            #expect(status.loadedModelID == nil)
            // Nothing failed, so nothing is claimed to have failed.
            #expect(status.failure == nil)
            #expect(await fixture.host.accepted == 1)
            #expect(await fixture.host.cancellations == 0)

            // And the load the Mac was told to do finishes, request or no request.
            await fixture.host.release()
            try await waitUntil { await fixture.host.completed == 1 }
            let (_, after) = try await fixture.call("GET", "/status")
            #expect(try JSONDecoder().decode(ControlAPI.Status.self, from: after)
                    .loadedModelID == "qwen3-coder-30b")
        }
    }

    /// The overlapping-load decision, in one test: the second caller is refused, in words,
    /// and the first load is untouched.
    @Test func aSecondLoadIsRefusedRatherThanKillingTheFirst() async throws {
        try await withServer(patience: .seconds(10)) { fixture in
            let first = Task {
                try await fixture.call("POST", "/load", body: #"{"modelID":"bonsai-2-27b"}"#)
            }
            try await waitUntil { await fixture.host.accepted == 1 }

            let (code, body) = try await fixture.call(
                "POST", "/load", body: #"{"modelID":"qwen3-coder-30b"}"#
            )
            #expect(code == 409)
            let refusal = try JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: body)
            #expect(refusal.error == ControlAPI.LoadAlreadyRunning(
                modelID: "bonsai-2-27b", secondsAgo: 0
            ).localizedDescription)
            #expect(refusal.error.contains("Nothing was changed"))

            // The first load never heard about any of it.
            #expect(await fixture.host.accepted == 1)
            #expect(await fixture.host.cancellations == 0)

            await fixture.host.release()
            #expect(try await first.value.0 == 200)
            #expect(await fixture.host.completed == 1)

            // And once it is over, the machine is free again: the load that was refused
            // succeeds by simply being asked for a second time.
            #expect(try await fixture.call(
                "POST", "/load", body: #"{"modelID":"qwen3-coder-30b"}"#
            ).0 == 200)
            #expect(await fixture.host.completed == 2)
        }
    }

    // MARK: - The failure a client reads

    /// The new fields, on the wire, exactly as the contract documents them.
    @Test func statusCarriesTheFailureAsDocumented() async throws {
        let failure = LoadFailure(
            reason: .killed,
            summary: "llama-server was killed (signal 9) after 8 seconds, which usually "
                + "means the system reclaimed its memory.",
            detail: "load_tensors: loading model tensors\nloaded multimodal model",
            runtime: .llamaCpp, signal: 9,
            at: try #require(ControlAPI.date(fromTimestamp: "2026-09-19T11:04:38Z"))
        )

        try await withServer(patience: .seconds(1), lastFailure: failure) { fixture in
            let (code, body) = try await fixture.call("GET", "/status")
            #expect(code == 200)

            let json = try #require(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            // The human line is the sentence, and only the sentence.
            #expect(json["state"] as? String == failure.summary)
            let wire = try #require(json["failure"] as? [String: Any])
            #expect(wire["reason"] as? String == "killed")
            #expect(wire["signal"] as? Int == 9)
            #expect(wire["exitStatus"] == nil)
            #expect(wire["runtime"] as? String == "llama.cpp")
            #expect(wire["wasReplaced"] as? Bool == false)
            #expect(wire["at"] as? String == "2026-09-19T11:04:38Z")
            #expect((wire["detail"] as? String)?.contains("loaded multimodal model") == true)
            // The sentence is not duplicated into the detail block.
            #expect(wire["summary"] == nil)

            // And a client that only ever read `state` still reads exactly what it did.
            let status = try JSONDecoder().decode(ControlAPI.Status.self, from: body)
            #expect(status.state == failure.summary)
            #expect(status.failure?.reason == "killed")
        }
    }

    /// Absent, not null, when there is nothing to report — so a client written before this
    /// existed sees the same bytes it always saw.
    @Test func aHealthyStatusCarriesNoFailureKeyAtAll() throws {
        let status = ControlAPI.Status(
            state: "Ready", loadedModelID: "qwen3-coder-30b",
            loadedModelName: "Qwen3-Coder 30B A3B", contextLength: 16_384,
            expertStreaming: false, lastGenerationTokensPerSecond: 89.4
        )
        let text = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        #expect(!text.contains("failure"))
        #expect(try JSONDecoder().decode(ControlAPI.Status.self, from: Data(text.utf8))
                .failure == nil)
    }

    // MARK: - Fixture

    private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw LoadTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct Fixture: Sendable {
        let host: LoadTestHost
        let port: Int
        let token: String
        let session: URLSession

        func call(
            _ method: String, _ path: String, body: String? = nil
        ) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.httpBody = body.map { Data($0.utf8) }
            if body != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            return (try #require((response as? HTTPURLResponse)?.statusCode), data)
        }
    }

    private func withServer(
        patience: Duration, lastFailure: LoadFailure? = nil,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("load-route-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let handshakeURL = directory.appendingPathComponent("control.json")
        let host = LoadTestHost(lastFailure: lastFailure)
        let server = ControlServer(
            host: host, handshakeURL: handshakeURL,
            buddy: BuddyRegistry(url: directory.appendingPathComponent("buddy.json")),
            events: BuddyEventHub(),
            loadPatience: patience,
            discoverTailnetAddress: { nil }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            try await server.start()
            try await waitUntil { FileManager.default.fileExists(atPath: handshakeURL.path) }
            let handshake = try JSONDecoder().decode(
                ControlAPI.Handshake.self, from: try Data(contentsOf: handshakeURL)
            )
            try await body(Fixture(
                host: host, port: handshake.port, token: handshake.token, session: session
            ))
        } catch {
            await host.release()
            await server.stop()
            throw error
        }
        await host.release()
        await server.stop()
    }
}

enum LoadTestError: Error, LocalizedError {
    case timeout
    case loadFailed(String)
    case unexpectedRoute

    var errorDescription: String? {
        switch self {
        case .timeout: "The fixture timed out."
        case .loadFailed(let sentence): sentence
        case .unexpectedRoute: "Unexpected test route."
        }
    }
}

/// A control host whose `load` takes as long as the test wants it to, and which counts every
/// load it was told to give up on.
private actor LoadTestHost: ControlHost {

    static let loadingLine = "Loading weights… 42%"

    private(set) var accepted = 0
    private(set) var completed = 0
    private(set) var cancellations = 0
    private var loaded: String?
    private var released = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    /// When set, the load fails with this sentence instead of succeeding.
    private let failing: String?
    /// A load that already failed, reported the way the app reports one: the sentence as
    /// the state line, the facts beside it.
    private let lastFailure: LoadFailure?

    init(failing: String? = nil, lastFailure: LoadFailure? = nil) {
        self.failing = failing
        self.lastFailure = lastFailure
    }

    func release() {
        released = true
        let waiting = waiters
        waiters = [:]
        for waiter in waiting.values { waiter.resume() }
    }

    func load(_ request: ControlAPI.LoadRequest) async throws -> ControlAPI.Status {
        accepted += 1
        if !released {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled {
                        cancellations += 1
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.abandon(id) }
            }
        }
        if let failing {
            completed += 1
            throw LoadTestError.loadFailed(failing)
        }
        loaded = request.modelID
        completed += 1
        return await status()
    }

    private func abandon(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        cancellations += 1
        waiter.resume(throwing: CancellationError())
    }

    func status() async -> ControlAPI.Status {
        ControlAPI.Status(
            state: stateLine, loadedModelID: loaded, loadedModelName: loaded,
            contextLength: loaded == nil ? nil : 16_384,
            expertStreaming: false, lastGenerationTokensPerSecond: nil,
            // As the app does it: the sentence is the state line, and the same failure's
            // facts are beside it.
            failure: lastFailure?.wire
        )
    }

    private var stateLine: String {
        if let lastFailure { return lastFailure.summary }
        if loaded != nil { return "Ready" }
        return accepted > completed ? Self.loadingLine : "Not loaded"
    }

    func unload() async { loaded = nil }

    // The rest of the protocol. This fixture is about one route; everything else exists so
    // the server has a host at all.
    func swarm() async -> ControlAPI.SwarmView { .init(peers: [], polledSecondsAgo: nil) }
    func profile() async -> ControlAPI.Profile { fatalError("Unexpected test route") }
    func metrics() async -> ControlAPI.Metrics { fatalError("Unexpected test route") }
    func catalog(category: String?, onlyRunnable: Bool) async -> [ControlAPI.CatalogModel] { [] }
    func installed() async -> [ControlAPI.InstalledModel] { [] }
    func recommend(category: String?, task: String?) async -> ControlAPI.CatalogModel? { nil }
    func plan(_ request: ControlAPI.PlanRequest) async throws -> ControlAPI.Plan {
        throw LoadTestError.unexpectedRoute
    }
    func install(_ request: ControlAPI.LoadRequest) async throws -> String {
        throw LoadTestError.unexpectedRoute
    }
    func chat(_ request: ControlAPI.ChatRequest) async throws -> ControlAPI.ChatResponse {
        throw LoadTestError.unexpectedRoute
    }
    func decide(_ request: ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse {
        throw LoadTestError.unexpectedRoute
    }
    func jevStatus() async -> ControlAPI.JevStatus { .fixture() }
    func updateJev(_ update: ControlAPI.JevUpdate) async throws -> ControlAPI.JevStatus {
        throw LoadTestError.unexpectedRoute
    }
    func recentGuardrailScreenings() async -> ControlAPI.GuardrailScreenings {
        .init(available: false, questions: [], screenings: [])
    }
    func jevCalibration() async -> ControlAPI.JevCalibration? { nil }
    func calibrateJev() async throws -> ControlAPI.JevCalibration {
        throw LoadTestError.unexpectedRoute
    }
    func benchmark() async throws -> ControlAPI.BenchmarkResult {
        throw LoadTestError.unexpectedRoute
    }
    func imageModels() async -> [ControlAPI.ImageModel] { [] }
    func planImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImagePlan {
        throw LoadTestError.unexpectedRoute
    }
    func generateImage(
        _ request: ControlAPI.ImageRequest
    ) async throws -> ControlAPI.ImageResponse {
        throw LoadTestError.unexpectedRoute
    }
    func meshModels() async -> [ControlAPI.MeshModel] { [] }
    func planMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshPlan {
        throw LoadTestError.unexpectedRoute
    }
    func generateMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshResponse {
        throw LoadTestError.unexpectedRoute
    }
    func videoModels() async -> [ControlAPI.VideoModel] { [] }
    func videoQueue() async -> ControlAPI.VideoQueueView {
        .init(paused: false, activeID: nil, message: nil, items: [])
    }
    func enqueueVideos(
        _ request: ControlAPI.VideoQueueRequest
    ) async throws -> ControlAPI.VideoQueueView {
        await videoQueue()
    }
    func controlVideoQueue(
        _ request: ControlAPI.VideoQueueControl
    ) async throws -> ControlAPI.VideoQueueView {
        await videoQueue()
    }
    func generateVideo(
        _ request: ControlAPI.VideoGenerateRequest
    ) async throws -> ControlAPI.VideoResponse {
        throw LoadTestError.unexpectedRoute
    }
    func nodeAdvertisement() async -> ControlAPI.NodeAdvertisement {
        fatalError("Unexpected test route")
    }
    func chatStream(
        _ request: ControlAPI.ChatRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        throw LoadTestError.unexpectedRoute
    }
    func conversationList() async -> [ControlAPI.ConversationSummary] { [] }
    func createConversation(title: String?) async -> ControlAPI.ConversationSummary {
        .init(id: UUID().uuidString, title: title ?? "Untitled",
              updatedAt: ControlAPI.timestamp(Date()), messageCount: 0)
    }
    func conversation(id: String) async throws -> ControlAPI.ConversationDetail {
        throw LoadTestError.unexpectedRoute
    }
    func replyInConversation(
        id: String, to message: ControlAPI.NewMessageRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        throw LoadTestError.unexpectedRoute
    }
    func beginEventUpdates(postingTo hub: BuddyEventHub) async {}
}

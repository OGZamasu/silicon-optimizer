import Foundation
import Testing
@testable import SiliconControl

@Suite("Video control connection capacity")
struct VideoControlCapacityTests {
    @Test func disconnectedClientsReleaseAllEightSlotsWithoutDiscardingAcceptedWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("video-disconnect-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let handshakeURL = directory.appendingPathComponent("control.json")
        let host = WaitingVideoHost()
        let server = ControlServer.inTemporaryFolder(directory, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            try await server.start()
            try await waitUntil { FileManager.default.fileExists(atPath: handshakeURL.path) }
            let handshake = try JSONDecoder().decode(ControlAPI.Handshake.self, from: Data(contentsOf: handshakeURL))
            let client = TestControlClient(session: session, port: handshake.port, token: handshake.token)
            for wave in 1...2 {
                let calls = (0..<ControlServer.maximumSynchronousVideos).map { _ in
                    Task { try await client.status("/video/generate", body: #"{"prompt":"durable fixture"}"#) }
                }
                try await waitUntil { await host.accepted == wave * ControlServer.maximumSynchronousVideos }
                for call in calls { call.cancel() }
                for call in calls { _ = try? await call.value }
                try await waitUntil { await host.cancelledWaits == wave * ControlServer.maximumSynchronousVideos }
                #expect(try await client.status("/video/queue") == 200)
                #expect(try await client.status("/status") == 200)
            }
            let final = Task { try await client.status("/video/generate", body: #"{"prompt":"still usable"}"#) }
            try await waitUntil { await host.accepted == 2 * ControlServer.maximumSynchronousVideos + 1 }
            await host.releaseAll(failing: false)
            #expect(try await final.value == 200)
            // Cancellation relinquishes the wait, not the durable acceptance.
            #expect(await host.accepted == 17)
            #expect(await host.cancelledWaits == 16)
            await server.stop()
        } catch {
            session.invalidateAndCancel()
            await host.releaseAll(failing: true)
            await server.stop()
            throw error
        }
    }

    @Test func videoWaitsLeaveRoomForQueueControlsAndReleaseTheirSlots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("video-control-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let handshakeURL = directory.appendingPathComponent("control.json")
        let host = WaitingVideoHost()
        let server = ControlServer.inTemporaryFolder(directory, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 100
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var pending: [Task<Int, any Error>] = []
        do {
            try await server.start(swarmToken: "swarm-capacity-test-token")
            try await waitUntil { FileManager.default.fileExists(atPath: handshakeURL.path) }
            let handshake = try JSONDecoder().decode(ControlAPI.Handshake.self, from: Data(contentsOf: handshakeURL))
            let client = TestControlClient(session: session, port: handshake.port, token: handshake.token)
            let maximum = ControlServer.maximumSynchronousVideos

            for wave in 0..<3 {
                pending = (0..<maximum).map { _ in
                    Task { try await client.status("/video/generate", body: #"{"prompt":"fixture"}"#) }
                }
                try await waitUntil { await host.accepted == (wave + 1) * maximum }
                // Reproduce the original 64-request load, but overflow must not enqueue.
                let overflow = try await withThrowingTaskGroup(of: Int.self) { group in
                    for _ in 0..<56 {
                        group.addTask { try await client.status("/video/generate", body: #"{"prompt":"overflow"}"#) }
                    }
                    var codes: [Int] = []
                    for try await code in group { codes.append(code) }
                    return codes
                }
                #expect(overflow.count == 56 && overflow.allSatisfy { $0 == 429 })
                #expect(await host.accepted == (wave + 1) * maximum)
                if wave == 0 {
                    // The shared peer bearer cannot use the owner-only async queue.
                    // Its saturation response must not recommend those denied routes.
                    var peerRequest = URLRequest(url: URL(
                        string: "http://127.0.0.1:\(handshake.port)/video/generate"
                    )!)
                    peerRequest.httpMethod = "POST"
                    peerRequest.httpBody = Data(#"{"prompt":"peer overflow"}"#.utf8)
                    peerRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    peerRequest.setValue(
                        "Bearer swarm-capacity-test-token", forHTTPHeaderField: "Authorization"
                    )
                    let (body, response) = try await session.data(for: peerRequest)
                    #expect((response as? HTTPURLResponse)?.statusCode == 429)
                    let message = try JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: body).error
                    #expect(!message.contains("/video/queue"))
                    #expect(message.contains("Retry this direct request later"))
                }
                #expect(try await client.status("/health", authenticated: false) == 200)
                #expect(try await client.status("/status") == 200)
                #expect(try await client.status("/video/queue") == 200)
                #expect(try await client.status("/video/queue/control", body: #"{"action":"pause"}"#) == 200)
                #expect(try await client.status("/video/queue", body: #"{"prompts":["later"]}"#) == 200)
                #expect(try await client.status("/video/generate", body: #"{"prompt":"unauthorized"}"#,
                                               authenticated: false) == 401)
                #expect(await host.paused)

                // Success and host errors must both release capacity for the next wave.
                await host.releaseAll(failing: wave == 1)
                for task in pending { #expect(try await task.value == (wave == 1 ? 400 : 200)) }
                pending = []
                // Decoding fails after acquiring a slot; repeated failures must not leak it.
                for _ in 0..<(maximum + 1) {
                    #expect(try await client.status("/video/generate", body: "{") == 400)
                }
            }
            await server.stop()
            #expect(!FileManager.default.fileExists(atPath: handshakeURL.path))
        } catch {
            await host.releaseAll(failing: true)
            for task in pending { task.cancel() }
            await server.stop()
            throw error
        }
    }

    private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw TestControlError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private extension ControlServer {
    /// A server that keeps every file it writes or reads in `directory`, has a device
    /// registry of its own, and never looks for this Mac's tailnet. Left to its defaults it
    /// would read the owner's paired devices — and, if they allow a tailnet, bind this Mac's
    /// real tailscale address — and a queue poll would sweep the owner's real uploads folder
    /// and rewrite their media table.
    static func inTemporaryFolder(_ directory: URL, host: any ControlHost) -> ControlServer {
        ControlServer(
            host: host, handshakeURL: directory.appendingPathComponent("control.json"),
            buddy: BuddyRegistry(url: directory.appendingPathComponent("buddy.json")),
            events: BuddyEventHub(), media: MediaRegistry(url: nil),
            uploadsRoot: directory.appendingPathComponent("uploads"),
            postersRoot: directory.appendingPathComponent("posters"),
            discoverTailnetAddress: { nil }
        )
    }
}

private struct TestControlClient: Sendable {
    let session: URLSession
    let port: Int
    let token: String

    func status(_ path: String, body: String? = nil, authenticated: Bool = true) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body.map { Data($0.utf8) }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (_, response) = try await session.data(for: request)
        return try #require((response as? HTTPURLResponse)?.statusCode)
    }
}

private enum TestControlError: Error { case timeout, renderFailed, unexpectedRoute }

/// No renderer or user app is involved. The test listener has its own private
/// handshake and holds accepted video calls until explicitly released.
private actor WaitingVideoHost: ControlHost {
    var accepted = 0
    var cancelledWaits = 0
    var paused = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func generateVideo(_ request: ControlAPI.VideoGenerateRequest) async throws -> ControlAPI.VideoResponse {
        accepted += 1
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    cancelledWaits += 1
                    continuation.resume(throwing: CancellationError())
                } else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
        return .init(file: "/tmp/fixture.mp4", node: "fixture", model: "hailuo-h3", elapsedSeconds: 1)
    }
    private func abandon(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        cancelledWaits += 1
        waiter.resume(throwing: CancellationError())
    }
    func releaseAll(failing: Bool) {
        let released = waiters
        waiters = [:]
        for waiter in released.values {
            if failing { waiter.resume(throwing: TestControlError.renderFailed) }
            else { waiter.resume() }
        }
    }
    func status() async -> ControlAPI.Status {
        .init(state: "idle", loadedModelID: nil, loadedModelName: nil, contextLength: nil,
              expertStreaming: false, lastGenerationTokensPerSecond: nil)
    }
    func videoQueue() async -> ControlAPI.VideoQueueView {
        .init(paused: paused, activeID: nil, message: nil, items: [])
    }
    func controlVideoQueue(_ request: ControlAPI.VideoQueueControl) async throws -> ControlAPI.VideoQueueView {
        paused = request.action == "pause"
        return await videoQueue()
    }
    func enqueueVideos(_ request: ControlAPI.VideoQueueRequest) async throws -> ControlAPI.VideoQueueView {
        await videoQueue()
    }

    func swarm() async -> ControlAPI.SwarmView { fatalError("Unexpected test route") }
    func profile() async -> ControlAPI.Profile { fatalError("Unexpected test route") }
    func metrics() async -> ControlAPI.Metrics { fatalError("Unexpected test route") }
    func catalog(category: String?, onlyRunnable: Bool) async -> [ControlAPI.CatalogModel] { [] }
    func installed() async -> [ControlAPI.InstalledModel] { [] }
    func recommend(category: String?, task: String?) async -> ControlAPI.CatalogModel? { nil }
    func plan(_ request: ControlAPI.PlanRequest) async throws -> ControlAPI.Plan { throw TestControlError.unexpectedRoute }
    func install(_ request: ControlAPI.LoadRequest) async throws -> String { throw TestControlError.unexpectedRoute }
    func load(_ request: ControlAPI.LoadRequest) async throws -> ControlAPI.Status { throw TestControlError.unexpectedRoute }
    func unload() async {}
    func chat(_ request: ControlAPI.ChatRequest) async throws -> ControlAPI.ChatResponse { throw TestControlError.unexpectedRoute }
    func decide(_ request: ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse { throw TestControlError.unexpectedRoute }
    func jevStatus() async -> ControlAPI.JevStatus { .fixture() }
    func recentGuardrailScreenings() async -> ControlAPI.GuardrailScreenings {
        .init(available: false, questions: [], screenings: [])
    }
    func updateJev(_ update: ControlAPI.JevUpdate) async throws -> ControlAPI.JevStatus { throw TestControlError.unexpectedRoute }
    func jevCalibration() async -> ControlAPI.JevCalibration? { nil }
    func calibrateJev() async throws -> ControlAPI.JevCalibration { throw TestControlError.unexpectedRoute }
    func benchmark() async throws -> ControlAPI.BenchmarkResult { throw TestControlError.unexpectedRoute }
    func imageModels() async -> [ControlAPI.ImageModel] { [] }
    func planImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImagePlan { throw TestControlError.unexpectedRoute }
    func generateImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImageResponse { throw TestControlError.unexpectedRoute }
    func meshModels() async -> [ControlAPI.MeshModel] { [] }
    func planMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshPlan { throw TestControlError.unexpectedRoute }
    func generateMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshResponse { throw TestControlError.unexpectedRoute }
    func videoModels() async -> [ControlAPI.VideoModel] { [] }
    func nodeAdvertisement() async -> ControlAPI.NodeAdvertisement { fatalError("Unexpected test route") }

    // Silicon Buddy. This fixture is about video slots, so the streaming and conversation
    // routes only need to exist — `BuddyControlTests` has the double that exercises them.
    func chatStream(
        _ request: ControlAPI.ChatRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        throw TestControlError.unexpectedRoute
    }
    func conversationList() async -> [ControlAPI.ConversationSummary] { [] }
    func createConversation(title: String?) async -> ControlAPI.ConversationSummary {
        .init(id: UUID().uuidString, title: title ?? "Untitled",
              updatedAt: ControlAPI.timestamp(Date()), messageCount: 0)
    }
    func conversation(id: String) async throws -> ControlAPI.ConversationDetail {
        throw BuddyHostError.noSuchConversation(id)
    }
    func replyInConversation(
        id: String, to message: ControlAPI.NewMessageRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        throw TestControlError.unexpectedRoute
    }
    func beginEventUpdates(postingTo hub: BuddyEventHub) async {}
}

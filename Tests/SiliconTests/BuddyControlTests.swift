import Foundation
import Network
import Testing
@testable import SiliconControl

/// The control server as a phone meets it: pairing, a device token, the second listener, and
/// the two streaming routes.
///
/// Everything here runs over loopback with a private handshake file, so no user app, no
/// tailnet and no real model is involved.
@Suite("Silicon Buddy control routes")
struct BuddyControlTests {

    // MARK: - Pairing over the wire

    @Test func pairingMintsATokenThatWorksEverywhereAndOnlyTheMacCanRevokeIt() async throws {
        try await withServer { _, client, registry, _ in
            let invitation = await registry.invite(host: "127.0.0.1", port: client.port)

            // The one unauthenticated POST on this server.
            let (status, body) = try await client.call(
                "POST", "/buddy/pair", token: nil,
                body: #"{"code":"\#(invitation.code)","deviceName":"iPad mini","platform":"ipados"}"#
            )
            #expect(status == 200)
            let paired = try JSONDecoder().decode(ControlAPI.BuddyPairResponse.self, from: body)
            #expect(paired.port == client.port)

            // A device token is a bearer like any other, on every working route.
            #expect(try await client.status("GET", "/status", token: paired.token) == 200)
            #expect(try await client.status("GET", "/installed", token: paired.token) == 200)
            #expect(try await client.status("GET", "/status", token: "guessed") == 401)

            // Except the two that administer other devices.
            #expect(try await client.status("GET", "/buddy/devices", token: paired.token) == 403)
            #expect(try await client.status(
                "DELETE", "/buddy/devices/\(paired.deviceID)", token: paired.token
            ) == 403)

            let (listStatus, listBody) = try await client.call(
                "GET", "/buddy/devices", token: client.token
            )
            #expect(listStatus == 200)
            let listed = try JSONDecoder().decode(
                [ControlAPI.BuddyDeviceSummary].self, from: listBody
            )
            #expect(listed.map(\.name) == ["iPad mini"])
            #expect(listed.first?.lastSeen != nil)
            // The digest never leaves the file it is written in.
            #expect(!String(decoding: listBody, as: UTF8.self).contains("tokenHash"))

            #expect(try await client.status(
                "DELETE", "/buddy/devices/\(paired.deviceID)", token: client.token
            ) == 200)
            #expect(try await client.status(
                "DELETE", "/buddy/devices/\(paired.deviceID)", token: client.token
            ) == 404)
            // Revoked means revoked, on the next request rather than the next launch.
            #expect(try await client.status("GET", "/status", token: paired.token) == 401)
        }
    }

    @Test func aWrongCodeIsRefusedAndThenThrottled() async throws {
        try await withServer { _, client, registry, _ in
            await registry.invite(host: "127.0.0.1", port: client.port)
            let attempt = #"{"code":"000000","deviceName":"Phone","platform":"android"}"#

            for _ in 0..<BuddyRegistry.attemptsPerMinute {
                let refused = try await client.status(
                    "POST", "/buddy/pair", token: nil, body: attempt
                )
                #expect(refused == 403)
            }
            let throttled = try await client.status(
                "POST", "/buddy/pair", token: nil, body: attempt
            )
            #expect(throttled == 429)
        }
    }

    @Test func pairingWithNoCodeOpenIsRefusedRatherThanAccepted() async throws {
        try await withServer { _, client, _, _ in
            let refused = try await client.status(
                "POST", "/buddy/pair", token: nil,
                body: #"{"code":"123456","deviceName":"Phone","platform":"android"}"#
            )
            #expect(refused == 403)
        }
    }

    // MARK: - The second listener

    @Test func onlyTailnetAndLoopbackAddressesMayBeBound() {
        for allowed in ["100.64.0.1", "100.100.100.100", "100.127.255.255", "127.0.0.1"] {
            #expect(ControlServer.isBindableTailnetAddress(allowed))
        }
        // The wildcard above all: binding it is exactly how a private API becomes public.
        for refused in [
            "0.0.0.0", "::", "::1", "", " ", "192.168.1.10", "10.0.0.5", "100.128.0.1",
            "100.63.255.255", "99.64.0.1", "127.0.0.1.1", "localhost", "100.64.0.1:8788",
        ] {
            #expect(!ControlServer.isBindableTailnetAddress(refused), "\(refused) must be refused")
        }
    }

    @Test func theSecondListenerServesTheSameRoutesAndClosesOnDemand() async throws {
        try await withServer { server, client, registry, _ in
            #expect(await server.tailnetListenerAddress == nil)
            await #expect(throws: ControlServer.TailnetBindError.self) {
                try await server.setTailnetAccess(address: "0.0.0.0")
            }
            #expect(await server.tailnetListenerAddress == nil)

            let second = try await openSecondListener(on: server)
            let phone = TestClient(port: second, token: client.token, session: client.session)

            // Same routes, same auth, a different way in.
            #expect(try await phone.status("GET", "/health", token: nil) == 200)
            #expect(try await phone.status("GET", "/status", token: client.token) == 200)
            #expect(try await phone.status("GET", "/status", token: nil) == 401)

            let invitation = await registry.invite(host: "127.0.0.1", port: second)
            let (status, body) = try await phone.call(
                "POST", "/buddy/pair", token: nil,
                body: #"{"code":"\#(invitation.code)","deviceName":"Phone","platform":"android"}"#
            )
            #expect(status == 200)
            let paired = try JSONDecoder().decode(ControlAPI.BuddyPairResponse.self, from: body)
            #expect(try await phone.status("GET", "/status", token: paired.token) == 200)

            // Turning the toggle off takes the listener down; loopback is untouched.
            try await server.setTailnetAccess(address: nil)
            #expect(await server.tailnetListenerAddress == nil)
            await #expect(throws: (any Error).self) {
                _ = try await phone.status("GET", "/health", token: nil)
            }
            #expect(try await client.status("GET", "/status", token: client.token) == 200)
        }
    }

    // MARK: - Streaming chat

    @Test func chatStreamSendsTokensThenMetrics() async throws {
        try await withServer(tokens: ["Hel", "lo", " there"]) { _, client, _, _ in
            let events = try await client.events(
                "POST", "/chat/stream",
                body: #"{"messages":[{"role":"user","content":"hi","images":[]}]}"#
            ) { $0.contains { $0.name == "finished" } }

            #expect(events.filter { $0.name == "token" }.map(\.data) == [
                #"{"text":"Hel"}"#, #"{"text":"lo"}"#, #"{"text":" there"}"#,
            ])
            let finished = try #require(events.first { $0.name == "finished" })
            let metrics = try JSONDecoder().decode(
                ControlAPI.ChatMetrics.self, from: Data(finished.data.utf8)
            )
            #expect(metrics.generatedTokens == 3 && metrics.promptTokens == 7)
        }
    }

    @Test func aHostFailureBecomesAnErrorEventRatherThanASilentHangUp() async throws {
        try await withServer(failing: true) { _, client, _, _ in
            let events = try await client.events(
                "POST", "/chat/stream",
                body: #"{"messages":[{"role":"user","content":"hi","images":[]}]}"#
            ) { $0.contains { $0.name == "error" } }
            let failure = try #require(events.first { $0.name == "error" })
            #expect(failure.data.contains("No model is loaded."))
        }
    }

    @Test func aClientWalkingAwayCancelsTheGenerationAndFreesTheSlot() async throws {
        try await withServer(tokens: (0..<200).map { "t\($0)" }, pace: .milliseconds(20)) {
            _, client, _, host in
            let reading = Task {
                _ = try await client.events(
                    "POST", "/chat/stream",
                    body: #"{"messages":[{"role":"user","content":"hi","images":[]}]}"#
                ) { $0.count >= 2 }
                // Never reached: this stream has 200 tokens to go.
                try await Task.sleep(for: .seconds(30))
            }
            try await waitUntil { await host.startedStreams == 1 }
            try await waitUntil { await host.emitted >= 2 }
            reading.cancel()
            _ = try? await reading.value

            // The upstream generation stops, rather than talking to a dead socket.
            try await waitUntil { await host.cancelledStreams == 1 }
            // And the slot it held comes back.
            #expect(try await client.status("GET", "/status", token: client.token) == 200)
        }
    }

    @Test func onlySoManyStreamsAtOnce() async throws {
        try await withServer(tokens: [], pace: .milliseconds(1)) { _, client, _, _ in
            var held: [StreamHandle] = []
            defer { held.forEach { $0.cancel() } }
            for _ in 0..<ControlServer.maximumEventStreams {
                held.append(try await client.openEventStream())
            }
            // Every slot is taken, so the next phone is told to close one rather than
            // being quietly starved of a socket the MCP bridge also needs.
            #expect(try await client.status("GET", "/events", token: client.token) == 429)

            held.removeLast().cancel()
            try await waitUntil { (try? await client.status("GET", "/health", token: nil)) == 200 }
            var reopened = 0
            for _ in 0..<20 where reopened == 0 {
                if let handle = try? await client.openEventStream() {
                    held.append(handle)
                    reopened = 1
                } else {
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            #expect(reopened == 1)
        }
    }

    // MARK: - The /events stream

    @Test func theEventStreamOpensWithAHeartbeatAndForwardsWhatTheAppPosts() async throws {
        let hub = BuddyEventHub()
        try await withServer(hub: hub) { _, client, _, _ in
            let posting = Task {
                // Posted repeatedly: the subscription is established inside the server, so
                // there is no moment this side can wait for other than the first frame.
                while !Task.isCancelled {
                    await hub.post(.download(.init(
                        id: "qwen3-coder", name: "Qwen3-Coder", fraction: 0.5,
                        bytesReceived: 512, bytesExpected: 1024, bytesPerSecond: 128
                    )))
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            defer { posting.cancel() }

            let events = try await client.events("GET", "/events", body: nil) {
                $0.contains { $0.name == "download" }
            }
            #expect(events.first?.name == "heartbeat")
            let beat = try JSONDecoder().decode(
                ControlAPI.HeartbeatEvent.self, from: Data(events[0].data.utf8)
            )
            #expect(ControlAPI.date(fromTimestamp: beat.at) != nil)

            let download = try #require(events.first { $0.name == "download" })
            let decoded = try JSONDecoder().decode(
                ControlAPI.DownloadEvent.self, from: Data(download.data.utf8)
            )
            #expect(decoded.id == "qwen3-coder" && decoded.fraction == 0.5)
        }
    }

    @Test func theEventStreamNeedsATokenLikeEverythingElse() async throws {
        try await withServer { _, client, _, _ in
            let refused = try await client.status("GET", "/events", token: nil)
            #expect(refused == 401)
        }
    }

    // MARK: - Conversations

    @Test func conversationsAreListedCreatedReadAndRepliedTo() async throws {
        try await withServer(tokens: ["Yes", "."]) { _, client, _, _ in
            let (createStatus, created) = try await client.call(
                "POST", "/conversations", token: client.token, body: #"{"title":"Trip plan"}"#
            )
            #expect(createStatus == 200)
            let summary = try JSONDecoder().decode(
                ControlAPI.ConversationSummary.self, from: created
            )
            #expect(summary.title == "Trip plan" && summary.messageCount == 0)

            let (_, listed) = try await client.call("GET", "/conversations", token: client.token)
            let list = try JSONDecoder().decode(
                [ControlAPI.ConversationSummary].self, from: listed
            )
            #expect(list.map(\.id) == [summary.id])

            let events = try await client.events(
                "POST", "/conversations/\(summary.id)/messages",
                body: #"{"content":"Are we going?","images":[]}"#
            ) { $0.contains { $0.name == "finished" } }
            #expect(events.filter { $0.name == "token" }.count == 2)

            let (detailStatus, detail) = try await client.call(
                "GET", "/conversations/\(summary.id)", token: client.token
            )
            #expect(detailStatus == 200)
            let conversation = try JSONDecoder().decode(
                ControlAPI.ConversationDetail.self, from: detail
            )
            #expect(conversation.messages.map(\.role) == ["user", "assistant"])
            #expect(conversation.messages.last?.content == "Yes.")
            // Images are never sent back, however they arrived.
            #expect(!String(decoding: detail, as: UTF8.self).contains("images"))

            #expect(try await client.status(
                "GET", "/conversations/\(UUID().uuidString)", token: client.token
            ) == 404)
            #expect(try await client.status("GET", "/conversations", token: nil) == 401)
        }
    }

    // MARK: - Fixture

    private func waitUntil(
        _ seconds: Double = 5, _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Binds the second listener on loopback at a port nobody is using. Ports are picked
    /// rather than requested because the real one is the control server's own, and both
    /// listeners sharing it would make it impossible to tell which one answered.
    private func openSecondListener(on server: ControlServer) async throws -> Int {
        for _ in 0..<12 {
            let candidate = Int.random(in: 49_152...65_500)
            try await server.setTailnetAccess(address: "127.0.0.1", port: candidate)
            for _ in 0..<50 {
                if await server.tailnetError != nil { break }
                if await server.tailnetListenerAddress != nil,
                   await reachable(port: candidate) { return candidate }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await server.setTailnetAccess(address: nil)
        }
        throw BuddyTestError.timeout
    }

    private func reachable(port: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func withServer(
        tokens: [String] = ["ok"], pace: Duration = .milliseconds(1), failing: Bool = false,
        hub: BuddyEventHub = BuddyEventHub(),
        _ body: (ControlServer, TestClient, BuddyRegistry, BuddyTestHost) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-control-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let handshakeURL = directory.appendingPathComponent("control.json")
        let registry = BuddyRegistry(url: directory.appendingPathComponent("buddy.json"))
        let host = BuddyTestHost(tokens: tokens, pace: pace, failing: failing)
        let server = ControlServer(
            host: host, handshakeURL: handshakeURL, buddy: registry, events: hub
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 64
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        try await server.start()
        defer { Task { await server.stop() } }
        try await waitUntil { FileManager.default.fileExists(atPath: handshakeURL.path) }
        let handshake = try JSONDecoder().decode(
            ControlAPI.Handshake.self, from: try Data(contentsOf: handshakeURL)
        )
        try await body(
            server,
            TestClient(port: handshake.port, token: handshake.token, session: session),
            registry, host
        )
        await server.stop()
    }
}

enum BuddyTestError: Error, LocalizedError {
    case timeout, noModelLoaded, unexpectedRoute

    var errorDescription: String? {
        switch self {
        case .timeout: "The fixture timed out."
        case .noModelLoaded: "No model is loaded."
        case .unexpectedRoute: "Unexpected test route."
        }
    }
}

// MARK: - A client that can read a stream

struct TestClient: Sendable {
    let port: Int
    let token: String
    let session: URLSession

    func request(_ method: String, _ path: String, token: String?, body: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func call(
        _ method: String, _ path: String, token: String?, body: String? = nil
    ) async throws -> (Int, Data) {
        let (data, response) = try await session.data(
            for: request(method, path, token: token, body: body)
        )
        return (try #require((response as? HTTPURLResponse)?.statusCode), data)
    }

    func status(
        _ method: String, _ path: String, token: String?, body: String? = nil
    ) async throws -> Int {
        try await call(method, path, token: token, body: body).0
    }

    struct Frame: Sendable, Equatable {
        var name: String
        var data: String
    }

    /// Reads SSE frames until `stop` has seen enough.
    func events(
        _ method: String, _ path: String, body: String?,
        until stop: @Sendable ([Frame]) -> Bool
    ) async throws -> [Frame] {
        let (bytes, response) = try await session.bytes(
            for: request(method, path, token: token, body: body)
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        var frames: [Frame] = []
        var name = ""
        for try await line in bytes.lines {
            if line.hasPrefix("event: ") {
                name = String(line.dropFirst("event: ".count))
            } else if line.hasPrefix("data: ") {
                frames.append(Frame(name: name, data: String(line.dropFirst("data: ".count))))
                if stop(frames) { break }
            }
        }
        return frames
    }

    /// Opens an `/events` stream and holds it, returning once the server has actually
    /// accepted it — which is what the first heartbeat proves.
    func openEventStream() async throws -> StreamHandle {
        let ready = Ready()
        let task = Task {
            let (bytes, response) = try await session.bytes(
                for: request("GET", "/events", token: token, body: nil)
            )
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw BuddyTestError.unexpectedRoute
            }
            for try await line in bytes.lines where line.hasPrefix("data: ") {
                await ready.signal()
            }
        }
        do {
            try await ready.wait()
        } catch {
            task.cancel()
            throw error
        }
        return StreamHandle(task: task)
    }
}

struct StreamHandle {
    let task: Task<Void, any Error>
    func cancel() { task.cancel() }
}

/// One-shot readiness, because a held-open stream has no return value to wait on.
actor Ready {
    private var signalled = false

    func signal() { signalled = true }

    func wait() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !signalled {
            guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

// MARK: - The host double

/// A `ControlHost` with a scripted model and an in-memory conversation store. It counts the
/// streams it starts and the ones that were cancelled out from under it, which is how the
/// disconnect test proves the generation actually stopped.
actor BuddyTestHost: ControlHost {

    private let tokens: [String]
    private let pace: Duration
    private let failing: Bool
    private(set) var startedStreams = 0
    private(set) var cancelledStreams = 0
    private(set) var emitted = 0
    private(set) var eventUpdatesRequested = 0
    private var stored: [ControlAPI.ConversationDetail] = []

    init(tokens: [String], pace: Duration, failing: Bool) {
        self.tokens = tokens
        self.pace = pace
        self.failing = failing
    }

    private func noteCancelled() { cancelledStreams += 1 }
    private func noteEmitted() { emitted += 1 }

    private func scripted(
        appendingTo conversation: String? = nil
    ) throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        guard !failing else { throw BuddyTestError.noModelLoaded }
        startedStreams += 1
        let tokens = self.tokens
        let pace = self.pace
        return AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    for token in tokens {
                        try await Task.sleep(for: pace)
                        await self.noteEmitted()
                        if let conversation {
                            await self.append(token, to: conversation)
                        }
                        continuation.yield(.token(token))
                    }
                    continuation.yield(.finished(.init(
                        promptTokens: 7, generatedTokens: tokens.count,
                        tokensPerSecond: 12.5, timeToFirstToken: 0.25
                    )))
                    continuation.finish()
                } catch {
                    await self.noteCancelled()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func append(_ token: String, to id: String) {
        guard let index = stored.firstIndex(where: { $0.id == id }),
              let last = stored[index].messages.indices.last
        else { return }
        stored[index].messages[last].content += token
    }

    func chatStream(
        _ request: ControlAPI.ChatRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        try scripted()
    }

    func conversationList() async -> [ControlAPI.ConversationSummary] {
        stored.map {
            .init(id: $0.id, title: $0.title, updatedAt: $0.updatedAt,
                  messageCount: $0.messages.count)
        }
    }

    func createConversation(title: String?) async -> ControlAPI.ConversationSummary {
        let conversation = ControlAPI.ConversationDetail(
            id: UUID().uuidString, title: title ?? "New Conversation",
            updatedAt: ControlAPI.timestamp(Date()), messages: []
        )
        stored.append(conversation)
        return .init(id: conversation.id, title: conversation.title,
                     updatedAt: conversation.updatedAt, messageCount: 0)
    }

    func conversation(id: String) async throws -> ControlAPI.ConversationDetail {
        guard let found = stored.first(where: { $0.id == id }) else {
            throw BuddyHostError.noSuchConversation(id)
        }
        return found
    }

    func replyInConversation(
        id: String, to message: ControlAPI.NewMessageRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        guard let index = stored.firstIndex(where: { $0.id == id }) else {
            throw BuddyHostError.noSuchConversation(id)
        }
        let now = ControlAPI.timestamp(Date())
        stored[index].messages.append(
            .init(role: "user", content: message.content, createdAt: now)
        )
        stored[index].messages.append(.init(role: "assistant", content: "", createdAt: now))
        return try scripted(appendingTo: id)
    }

    func beginEventUpdates() async { eventUpdatesRequested += 1 }

    func status() async -> ControlAPI.Status {
        .init(state: "idle", loadedModelID: nil, loadedModelName: nil, contextLength: nil,
              expertStreaming: false, lastGenerationTokensPerSecond: nil)
    }
    func installed() async -> [ControlAPI.InstalledModel] { [] }
    func catalog(category: String?, onlyRunnable: Bool) async -> [ControlAPI.CatalogModel] { [] }
    func recommend(category: String?) async -> ControlAPI.CatalogModel? { nil }
    func unload() async {}
    func videoModels() async -> [ControlAPI.VideoModel] { [] }
    func imageModels() async -> [ControlAPI.ImageModel] { [] }
    func meshModels() async -> [ControlAPI.MeshModel] { [] }
    func videoQueue() async -> ControlAPI.VideoQueueView {
        .init(paused: false, activeID: nil, message: nil, items: [])
    }
    func swarm() async -> ControlAPI.SwarmView { .init(peers: [], polledSecondsAgo: nil) }
    func profile() async -> ControlAPI.Profile { fatalError("Unexpected test route") }
    func metrics() async -> ControlAPI.Metrics { fatalError("Unexpected test route") }
    func nodeAdvertisement() async -> ControlAPI.NodeAdvertisement {
        fatalError("Unexpected test route")
    }
    func plan(_ request: ControlAPI.PlanRequest) async throws -> ControlAPI.Plan {
        throw BuddyTestError.unexpectedRoute
    }
    func install(_ request: ControlAPI.LoadRequest) async throws -> String {
        throw BuddyTestError.unexpectedRoute
    }
    func load(_ request: ControlAPI.LoadRequest) async throws -> ControlAPI.Status {
        throw BuddyTestError.unexpectedRoute
    }
    func chat(_ request: ControlAPI.ChatRequest) async throws -> ControlAPI.ChatResponse {
        throw BuddyTestError.unexpectedRoute
    }
    func decide(_ request: ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse {
        throw BuddyTestError.unexpectedRoute
    }
    func benchmark() async throws -> ControlAPI.BenchmarkResult {
        throw BuddyTestError.unexpectedRoute
    }
    func planImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImagePlan {
        throw BuddyTestError.unexpectedRoute
    }
    func generateImage(
        _ request: ControlAPI.ImageRequest
    ) async throws -> ControlAPI.ImageResponse {
        throw BuddyTestError.unexpectedRoute
    }
    func planMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshPlan {
        throw BuddyTestError.unexpectedRoute
    }
    func generateMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshResponse {
        throw BuddyTestError.unexpectedRoute
    }
    func generateVideo(
        _ request: ControlAPI.VideoGenerateRequest
    ) async throws -> ControlAPI.VideoResponse {
        throw BuddyTestError.unexpectedRoute
    }
    func enqueueVideos(
        _ request: ControlAPI.VideoQueueRequest
    ) async throws -> ControlAPI.VideoQueueView {
        throw BuddyTestError.unexpectedRoute
    }
    func controlVideoQueue(
        _ request: ControlAPI.VideoQueueControl
    ) async throws -> ControlAPI.VideoQueueView {
        throw BuddyTestError.unexpectedRoute
    }
}

import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconUI

/// The control server restarts whenever swarm settings change. Fired off in a burst, the
/// restarts have to land in order: exactly one server listening afterwards, its handshake
/// on disk, and no listener left bound that the app no longer holds.
@Suite("Control server restarts")
@MainActor
struct ControlServerRestartTests {

    @Test("three restarts in quick succession leave one server and one handshake")
    func burstOfRestartsLeavesOneServer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("control-restart-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let handshakeURL = directory.appendingPathComponent("control.json")
        let registry = BuddyRegistry(url: directory.appendingPathComponent("buddy.json"))

        // Every server the model builds, so the replaced ones can be checked as well as the
        // one it holds. Scratch files throughout: the user's handshake and paired devices are
        // never involved, and no tailnet is ever bound.
        var built: [ControlServer] = []
        let model = AppModel(settings: .init())
        model.makeControlServer = { host in
            let server = ControlServer(
                host: host, handshakeURL: handshakeURL, buddy: registry,
                events: BuddyEventHub(), media: MediaRegistry(url: nil),
                uploadsRoot: directory.appendingPathComponent("uploads"),
                postersRoot: directory.appendingPathComponent("posters"),
                discoverTailnetAddress: { nil }
            )
            built.append(server)
            return server
        }
        defer { Task { await model.controlServer?.stop() } }

        model.applySwarmSettings()
        model.applySwarmSettings()
        model.applySwarmSettings()
        await model.waitForControlServerRestarts()
        // Each call builds a server. A listener that a restart left behind needs a moment to
        // come up before it can be looked for, so the settle after the handshake is deliberate.
        try await eventually { built.count == 3 }
        try await eventually { FileManager.default.fileExists(atPath: handshakeURL.path) }
        try await Task.sleep(for: .milliseconds(300))

        // The app holds the last server, and the last server is the only one listening.
        let live = try #require(model.controlServer)
        #expect(live === built.last)
        for server in built.dropLast() {
            let port = await server.listeningPort
            guard port != 0 else { continue }
            #expect(
                await !BuddyControlTests.reachable(port: port),
                "a replaced server is still listening on \(port)"
            )
        }

        // One handshake, naming the live server: not overwritten by a start that came late,
        // not deleted by a stop that did.
        let handshake = try JSONDecoder().decode(
            ControlAPI.Handshake.self, from: Data(contentsOf: handshakeURL)
        )
        #expect(await live.listeningPort == handshake.port)
        #expect(handshake.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(await BuddyControlTests.reachable(port: handshake.port))
    }

    // MARK: - What a stopped server leaves running

    static let swarmSecret = "swarm-secret-for-the-restart-fixture"

    /// The app stops this server when the swarm is turned off or its secret changes, and
    /// builds another. A node's event stream opened on the old one must not go on being
    /// fed status frames and heartbeats by a server that no longer honours its secret.
    @Test func aSwarmEventStreamEndsWhenItsServerStops() async throws {
        let host = BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false)
        try await withServer(host: host, swarmToken: Self.swarmSecret) {
            (fixture: AgentFixture) async throws in
            let stream = try await fixture.local.openEventStream(token: Self.swarmSecret)
            #expect(await fixture.server.openEventStreams == 1)

            await fixture.server.stop()
            // A heartbeat is every fifteen seconds; ended means ended now, not at the next.
            #expect(await Self.ends(stream, within: .seconds(3)), "the node is still being fed")
            try await eventuallyAsync { await fixture.server.openEventStreams == 0 }
        }
    }

    /// And a node's chat stream: its generation stops rather than finishing into a server
    /// that has gone.
    @Test func aSwarmChatStreamEndsWhenItsServerStops() async throws {
        let host = BuddyTestHost(
            tokens: (0..<400).map { "t\($0)" }, pace: .milliseconds(25), failing: false
        )
        try await withServer(host: host, swarmToken: Self.swarmSecret) {
            (fixture: AgentFixture) async throws in
            let tokens = FrameCount()
            let chat = Task {
                _ = try await fixture.local.events(
                    "POST", "/chat/stream", token: Self.swarmSecret,
                    body: #"{"messages":[{"role":"user","content":"hi","images":[]}]}"#
                ) { frames in
                    tokens.set(frames.count)
                    return frames.contains { $0.name == "finished" }
                }
            }
            try await eventuallyAsync { tokens.value > 0 }

            await fixture.server.stop()
            let ended = await Self.ends(StreamHandle(task: chat), within: .seconds(3))
            #expect(ended, "the node is still being streamed tokens")
            try await eventuallyAsync { await host.cancelledStreams == 1 }
        }
    }

    /// Whether the stream has finished within `limit`. A stream still open by then is
    /// cancelled from this side, so the test does not wait on it either way.
    static func ends(_ stream: StreamHandle, within limit: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await stream.task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            stream.cancel()
            group.cancelAll()
            return first
        }
    }

    private func eventuallyAsync(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// How many frames a stream has read, from inside the reader's `@Sendable` stop check.
private final class FrameCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func set(_ value: Int) { lock.withLock { count = value } }
}

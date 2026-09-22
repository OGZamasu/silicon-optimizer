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
                events: BuddyEventHub(), discoverTailnetAddress: { nil }
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

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

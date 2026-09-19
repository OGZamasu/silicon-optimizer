import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconUI

/// The swarm's poll is where a failed bind gets another try, and a Mac with no peers yet is
/// the one that most needs it — it is the one still being set up, with tailscale possibly
/// still coming up. The retry therefore runs before the "no peers, nothing to poll" exit,
/// not after it.
///
/// Serialized because `SwarmExposure.shared` is a process-wide singleton, like the event
/// pump: `AppModel` is `@Observable` and an extension cannot add stored properties to it.
@Suite("Swarm exposure retry", .serialized, .redirectedConversationStore, .redirectedSwarmConfig)
@MainActor
struct SwarmExposureRetryTests {

    @Test(
        .enabled(
            if: SwarmConfig.load()?.peers.isEmpty ?? true,
            "This run reads a swarm config that has peers, so the no-peers path is not taken"
        )
    )
    func theExposureRetryRunsWithNoPeersConfigured() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exposure-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = AppModel(settings: .init())
        let port = try await BuddyControlTests.freeLoopbackPort()
        let server = ControlServer(
            host: model,
            handshakeURL: directory.appendingPathComponent("control.json"),
            buddy: BuddyRegistry(url: directory.appendingPathComponent("buddy.json")),
            events: BuddyEventHub(),
            discoverTailnetAddress: { "127.0.0.1" }
        )
        defer { Task { await server.stop() } }
        try await server.start(
            exposeToTailnet: true, swarmToken: "a-shared-swarm-secret", tailnetPort: port
        )
        try await TailnetExposureTests.waitUntil { await server.tailnetEndpoint != nil }
        model.controlServer = server

        // Deliberately stale — what the window would still be showing after a bind that
        // failed at launch, or after one that has since moved.
        SwarmExposure.shared.apply(.init(
            requested: true, listening: true, address: "100.64.9.9", port: 8788
        ))

        await model.refreshSwarm()

        #expect(SwarmExposure.shared.address == "127.0.0.1")
        #expect(SwarmExposure.shared.port == port)
        #expect(SwarmExposure.shared.isReachableByPeers)
        await server.stop()
    }
}

/// Points `SwarmConfig` at a registry this test bundle owns, so a run's verdict does not
/// depend on whatever swarm.json the developer happens to have. Left alone when the
/// live-node proofs are opted in, because those are about the real one.
enum SwarmTestConfig {
    static let redirected: Bool = {
        guard ProcessInfo.processInfo.environment["SILICON_LIVE_TESTS"] != "1" else {
            return false
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-tests-swarm-\(UUID()).json")
        let config = SwarmConfig(swarmToken: "a-shared-swarm-secret", peers: [])
        guard let data = try? JSONEncoder().encode(config) else { return false }
        try? data.write(to: url, options: .atomic)
        setenv("SILICON_SWARM_CONFIG", url.path, 1)
        return true
    }()

    static func redirect() { _ = redirected }
}

struct RedirectedSwarmConfig: SuiteTrait, TestTrait {
    func prepare(for test: Test) async throws { SwarmTestConfig.redirect() }
}

extension Trait where Self == RedirectedSwarmConfig {
    static var redirectedSwarmConfig: Self { Self() }
}

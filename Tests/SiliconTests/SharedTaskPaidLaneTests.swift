import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

/// The `/events` pumps are started by whichever subscriber arrives first, from inside that
/// subscriber's request — and a `Task` keeps its creator's task-locals for life. A swarm node
/// opening `/events` first would otherwise leave both loops running with `PaidLanes.allowed`
/// false long after its request ended, so that any paid feature added to them later would be
/// silently shut for the owner too. Each is started with the lanes open instead.
@Suite(
    "Shared tasks and the paid lanes", .serialized, .redirectedConversationStore,
    .hermeticAgentSeams
)
@MainActor
struct SharedTaskPaidLaneTests {

    @Test func aSwarmSubscriberStartingTheEventPumpDoesNotShutThePaidLanesForIt() async throws {
        let model = Self.model()
        let hub = BuddyEventHub()
        let pump = BuddyEventPump()
        defer { pump.stop() }
        let peer = await hub.subscribe(as: .peer)

        PaidLanes.$allowed.withValue(false) {
            pump.start(watching: model, hub: hub, interval: .milliseconds(10))
        }
        #expect(try await Self.eventually { pump.paidLanesOpenInLoop != nil })
        #expect(pump.paidLanesOpenInLoop == true)
        await hub.cancel(peer.id)
    }

    /// The agent pump runs only for an audience that may see agent frames, so a phone is
    /// subscribed — but the start still comes from inside a swarm node's request, which is
    /// what `beginEventUpdates` does when the peer's `/events` arrives while a phone watches.
    @Test func aSwarmRequestStartingTheAgentPumpDoesNotShutThePaidLanesForIt() async throws {
        let model = Self.model()
        let hub = BuddyEventHub()
        let pump = AgentEventPump()
        defer { pump.stop() }
        let phone = await hub.subscribe(as: .device(id: "phone", scope: .full))
        let peer = await hub.subscribe(as: .peer)

        PaidLanes.$allowed.withValue(false) {
            pump.start(watching: model, hub: hub, interval: .milliseconds(10))
        }
        #expect(try await Self.eventually { pump.paidLanesOpenInLoop != nil })
        #expect(pump.paidLanesOpenInLoop == true)
        await hub.cancel(peer.id)
        await hub.cancel(phone.id)
    }

    /// What every such start goes through.
    @Test func workTheAppStartsFromInsideASwarmRequestSeesTheLanesOpen() async {
        let seen = await PaidLanes.$allowed.withValue(false) {
            PaidLanes.forTheApp { Task { PaidLanes.allowed } }
        }.value
        #expect(seen)
        // And a task started the ordinary way from the same place keeps the request's mark,
        // which is the whole reason the helper exists.
        let inherited = await PaidLanes.$allowed.withValue(false) {
            Task { PaidLanes.allowed }
        }.value
        #expect(!inherited)
    }

    // MARK: - Helpers

    private static func model() -> AppModel {
        let model = AppModel(
            videoQueue: VideoBatchQueue(
                storeURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("paid-lane-queue-\(UUID()).json")
            ),
            settings: .init()
        )
        BuddyAgentSessions.shared.forget(model)
        return model
    }

    private static func eventually(
        within limit: Duration = .seconds(5), _ condition: () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

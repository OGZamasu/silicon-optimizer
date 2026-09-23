import Foundation
import Testing
@testable import SiliconRuntime
@testable import SiliconUI

@Suite("Decision lanes across actor boundaries", .redirectedConversationStore)
@MainActor
struct DecisionLanesConcurrencyTests {
    /// A gateway model-list request asks these same readiness callbacks from the
    /// router's executor. The app must hop back to its main-actor state, even when
    /// there are no models or peers to offer. Assuming main-actor isolation here
    /// used to terminate the process before it could return an empty availability.
    @Test func bootstrappedReadinessCanBeAskedFromADetachedTask() async {
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(key: nil)
        let runtime = LayaRuntime()
        let router = DecisionRouter(service: harness.service)
        let model = AppModel(
            videoQueue: VideoBatchQueue(storeURL: harness.directory.appendingPathComponent("queue.json")),
            settings: .init()
        )
        await DecisionLanesBootstrap.configure(model, runtime: runtime, router: router)

        #expect(await router.registered() == [.laya, .node, .oneToken])
        let (installation, available, canAnswer) = await Task.detached {
            let available = await router.availability(for: .routing)
            let canAnswer = await router.canAnswer(.routing)
            let installation = await runtime.installation()
            return (installation, available, canAnswer)
        }.value

        #expect(installation.missing == .libraryNotConfigured)
        #expect(!available.jev)
        #expect(!available.laya)
        #expect(!available.node)
        #expect(!available.oneToken)
        #expect(!canAnswer)
    }

    /// Hopping to the UI actor must still read the current library. Capturing a
    /// startup snapshot would avoid the crash but leave the runtime looking at an
    /// old drive after the owner changes Settings.
    @Test func bootstrappedRuntimeReadsLibraryChangesAcrossActors() async {
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(key: nil)
        let runtime = LayaRuntime()
        let router = DecisionRouter(service: harness.service)
        let first = harness.directory.appendingPathComponent("first-library")
        let second = harness.directory.appendingPathComponent("second-library")
        var settings = Settings()
        settings.modelLibraryDirectory = first.path
        let model = AppModel(
            videoQueue: VideoBatchQueue(storeURL: harness.directory.appendingPathComponent("queue.json")),
            settings: settings
        )
        await DecisionLanesBootstrap.configure(model, runtime: runtime, router: router)

        let before = await Task.detached { await runtime.installation() }.value
        #expect(before.missing == .libraryUnreachable(first.path))

        model.settings.modelLibraryDirectory = second.path
        let after = await Task.detached { await runtime.installation() }.value
        #expect(after.missing == .libraryUnreachable(second.path))

        model.settings.modelLibraryDirectory = ""
        let cleared = await Task.detached { await runtime.installation() }.value
        #expect(cleared.missing == .libraryNotConfigured)
    }
}

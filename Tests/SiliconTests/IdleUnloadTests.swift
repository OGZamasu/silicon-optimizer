import Foundation
import Testing
@testable import SiliconHardware
@testable import SiliconUI

/// The bug these exist for: a chat driven through the MCP bridge sets no `generationTask`, so
/// for the whole of a long answer the app believed nothing was running. The idle timer then
/// unloaded the model, and nothing held macOS awake, out from under a request in flight.
@Suite("Work in flight")
@MainActor
struct WorkInFlightTests {

    @Test func aFreshModelHasNothingRunning() {
        #expect(AppModel().hasWorkInFlight == false)
    }

    @Test func aDetachedGenerationCountsAsWorkInFlight() async {
        let model = AppModel()
        await model.whileGenerating {
            #expect(model.hasWorkInFlight)
        }
        #expect(model.hasWorkInFlight == false)
    }

    /// A failed generation must not leave the app permanently "busy": that would disable the
    /// idle unload and pin the machine awake for the rest of the session.
    @Test func aThrownErrorStillClearsTheFlag() async {
        struct Failure: Error {}
        let model = AppModel()
        await #expect(throws: Failure.self) {
            try await model.whileGenerating { throw Failure() }
        }
        #expect(model.hasWorkInFlight == false)
    }

    /// Concurrent requests share one server, and the last one to finish is what releases it.
    @Test func overlappingGenerationsReleaseOnlyOnTheLast() async {
        let model = AppModel()
        await model.whileGenerating {
            await model.whileGenerating {
                #expect(model.hasWorkInFlight)
            }
            #expect(model.hasWorkInFlight)
        }
        #expect(model.hasWorkInFlight == false)
    }
}

@Suite("Sleep assertion")
struct PowerAssertionTests {

    @Test func anAssertionIsHeldUntilReleased() {
        let assertion = PowerAssertion(reason: "unit test")
        #expect(assertion.isHeld)
        assertion.release()
        #expect(assertion.isHeld == false)
    }

    /// Releasing twice must not release someone else's assertion ID.
    @Test func releasingTwiceIsHarmless() {
        let assertion = PowerAssertion(reason: "unit test")
        assertion.release()
        assertion.release()
        #expect(assertion.isHeld == false)
    }
}

import Foundation
import Testing
@testable import SiliconRuntime
@testable import SiliconUI

/// Pi's runtime reports its state from a task the app cancels on Stop and on an engine switch.
/// A start cancelled while it probes npm finds no npm it can use and says so — "npm older than
/// 11.19" — and that report lands after Stop has already set the engine idle. It must not stick:
/// a state belongs to the start that reported it, and a stopped or replaced start has no say.
@Suite("Pi engine state")
@MainActor
struct PiStateTests {

    @Test func aStartStoppedWhileProbingCannotLeaveAFailureBehind() {
        let model = AppModel(settings: .init())
        let cancelledStart = model.piLifecycleGeneration
        model.stopPi()
        #expect(model.piState == .idle)

        model.applyPiRuntimeState(
            .failed(message: "Pi needs Node.js 22.19 or newer with npm 11.19 or newer."),
            generation: cancelledStart
        )
        #expect(model.piState == .idle, "a stopped start's failure replaced idle")
        model.applyPiRuntimeState(.starting(stage: "Verifying Pi…"), generation: cancelledStart)
        #expect(model.piState == .idle)
    }

    @Test func theCurrentStartsStateStillApplies() {
        let model = AppModel(settings: .init())
        model.stopPi()
        let current = model.piLifecycleGeneration
        model.applyPiRuntimeState(.failed(message: "Pi exited (1)."), generation: current)
        #expect(model.piState == .failed("Pi exited (1)."))
    }
}

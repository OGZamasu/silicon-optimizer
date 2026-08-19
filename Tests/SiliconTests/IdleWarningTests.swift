import Foundation
import Testing
@testable import SiliconUI

/// A model that vanishes without warning is the complaint this answers: someone comes back to
/// a Mac that has quietly released 20 GB of weights and finds their chat unable to answer.
@Suite("Idle unload warning")
@MainActor
struct IdleWarningTests {

    @Test func warnsFiveMinutesAheadOnAnOrdinaryWindow() {
        #expect(AppModel.warningLead(forIdleMinutes: 30) == 5 * 60)
        #expect(AppModel.warningLead(forIdleMinutes: 10) == 5 * 60)
    }

    /// A short window must not produce a warning that arrives at the same moment as the
    /// unload, or one that is on screen for the entire idle period.
    @Test func aShortWindowWarnsAtItsHalfway() {
        #expect(AppModel.warningLead(forIdleMinutes: 5) == 150)
        #expect(AppModel.warningLead(forIdleMinutes: 6) == 180)
        // The floor the settings stepper allows.
        #expect(AppModel.warningLead(forIdleMinutes: 5) < Double(5) * 60)
    }

    /// Nothing loaded, nothing to warn about — the countdown must not appear on a fresh app.
    @Test func noCountdownWithoutALoadedModel() {
        let model = AppModel()
        #expect(model.secondsUntilIdleUnload == nil)
        #expect(model.modelFacingIdleUnload == nil)
    }

    /// The button resets the clock rather than switching the setting off: rescuing one model
    /// is not a decision that models should never be released.
    @Test func keepingItLoadedLeavesTheSettingAlone() {
        let model = AppModel()
        model.settings.unloadWhenIdle = true
        model.keepModelLoaded()
        #expect(model.settings.unloadWhenIdle)
        #expect(model.secondsUntilIdleUnload == nil)
    }

    /// Reaching the notification centre from a process that is not a bundled app raises an
    /// Objective-C exception and takes the process with it — which is what this test run is,
    /// and what `swift run` is. Every call has to check first.
    @Test func notificationsAreSkippedOutsideAnAppBundle() {
        #expect(IdleUnloadNotice.isAvailable == false)
        // The proof that the guard holds: none of these may crash here.
        IdleUnloadNotice.post(modelName: "Test", minutes: 5)
        IdleUnloadNotice.postUnloaded(modelName: "Test")
        IdleUnloadNotice.withdrawWarning()
    }
}

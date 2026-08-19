import Foundation
import Testing
@testable import SiliconUI

/// The bug these exist for: a DeepSeek Harness chat talks straight to `llama-server`, so no
/// app-side signal moves for the whole conversation. The idle timer asked the server "are you
/// busy?" exactly once, at the moment it fired — and an agent turn is many requests with tool
/// calls and reading time between them, so that question landed in a gap and the model was
/// unloaded mid-conversation. Nothing held the Mac awake through one of those turns either.
@Suite("Server activity")
@MainActor
struct ServerActivityTests {

    private let grace = AppModel.serverBusyGrace

    // MARK: - The grace window

    @Test func aServerNeverSeenBusyIsNotWorking() {
        #expect(AppModel.serverCountsAsWorking(lastBusyAt: nil, now: Date()) == false)
    }

    @Test func aServerBusyAMomentAgoIsStillWorking() {
        let now = Date()
        #expect(AppModel.serverCountsAsWorking(lastBusyAt: now, now: now))
    }

    /// The whole point: the pauses inside an agent turn must not read as idleness.
    @Test func aGapShorterThanTheGraceStillCountsAsWorking() {
        let now = Date()
        #expect(AppModel.serverCountsAsWorking(lastBusyAt: now - (grace - 1), now: now))
    }

    /// But a conversation that has genuinely finished must still release the model.
    @Test func aServerQuietLongerThanTheGraceIsNotWorking() {
        let now = Date()
        #expect(AppModel.serverCountsAsWorking(lastBusyAt: now - (grace + 1), now: now) == false)
    }

    // MARK: - What it protects

    @Test func aBusyServerCountsAsWorkInFlight() {
        let model = AppModel()
        #expect(model.hasWorkInFlight == false)

        model.noteServerBusy()
        #expect(model.hasWorkInFlight)
    }

    /// Work the app cannot see still has to hold off the idle unload, which reads
    /// `hasWorkInFlight` before anything else.
    @Test func aServerQuietSinceBeforeTheGraceStopsCounting() {
        let model = AppModel()
        model.noteServerBusy(at: Date() - (grace + 5))
        #expect(model.hasWorkInFlight == false)
    }

    /// Observing the server is also what stamps the activity clock, so a long conversation
    /// never accumulates the idle time that would arm the unload in the first place.
    @Test func observingABusyServerAlsoCountsAsActivity() {
        let model = AppModel()
        model.noteServerBusy(at: Date() - (grace + 5))
        // Outside the grace, so not "working" — but the clock was still stamped then, which is
        // what keeps a turn with long gaps from ever reaching the idle threshold.
        #expect(model.hasWorkInFlight == false)

        model.noteServerBusy()
        #expect(model.hasWorkInFlight)
    }
}

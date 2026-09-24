import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime

/// A Keychain read that waits for somebody to answer a consent dialog, the way the first
/// read after every rebuild of the app does.
///
/// The wait has a ceiling so a regression fails the test instead of hanging the suite: if
/// the dialog is still up when the ceiling passes, the read gives up on its own and says so
/// in `timedOut`.
final class ConsentDialog: @unchecked Sendable {
    private let lock = NSLock()
    private let shown = DispatchSemaphore(value: 0)
    private let answered = DispatchSemaphore(value: 0)
    private var readsSoFar = 0
    private var returnedSoFar = 0
    private var gaveUp = false
    private let key: String?
    private let ceiling: TimeInterval

    init(answering key: String? = "sk-fixture", ceiling: TimeInterval = 3) {
        self.key = key
        self.ceiling = ceiling
    }

    var reads: Int { lock.lock(); defer { lock.unlock() }; return readsSoFar }
    var returned: Int { lock.lock(); defer { lock.unlock() }; return returnedSoFar }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return gaveUp }

    /// The key provider: blocks its thread until `answer()` or the ceiling.
    func read() -> String? {
        lock.lock(); readsSoFar += 1; lock.unlock()
        shown.signal()
        let result = answered.wait(timeout: .now() + ceiling)
        lock.lock()
        returnedSoFar += 1
        if result == .timedOut { gaveUp = true }
        lock.unlock()
        return key
    }

    func answer() { answered.signal() }

    /// Returns once a read is blocked on the dialog. Waited for off the cooperative pool.
    func waitUntilShown() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = self.shown.wait(timeout: .now() + 5)
                continuation.resume()
            }
        }
    }
}

@Suite("Jev's key read and the Keychain dialog")
struct JevKeyReadTests {

    private func dialogHarness(
        dialog: ConsentDialog, server: CapturingServer
    ) async throws -> JevHarness {
        let harness = JevHarness()
        await harness.service.configure(
            keyProvider: { dialog.read() },
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            keyIsSet: { true },
            configURL: harness.configURL
        )
        try await harness.enable()
        return harness
    }

    /// The finding: the secret was read on the actor, so while the dialog was up every
    /// other caller — the gateway's pruning, `/v1/models`, `/decide`, verification, the
    /// Settings screen — queued behind it. Now they are answered while it waits.
    @Test func aConsentDialogDoesNotHoldUpEveryoneElse() async throws {
        let server = try CapturingServer { _, _ in .init(body: jevAnswer) }
        defer { server.stop() }
        let dialog = ConsentDialog()
        let harness = try await dialogHarness(dialog: dialog, server: server)
        defer { harness.clean() }

        let asking = Task {
            try await harness.service.ask(
                .decideTool, state: .string("Charged twice."), questions: jevQuestions
            )
        }
        await dialog.waitUntilShown()

        // The dialog is up. Everything else this actor does is still answered.
        _ = await harness.service.settings()
        #expect(await harness.service.isAvailable(.decideTool))
        _ = await harness.service.ledger()
        #expect(dialog.returned == 0, "those were answered only once the dialog went away")

        dialog.answer()
        let response = try await asking.value
        #expect(try response.noul("refund") == 0.93)
        #expect(server.requests.count == 1)
        #expect(!dialog.timedOut)
    }

    /// A caller's deadline starts when it asks, not when the dialog is answered: a feature
    /// that will only wait a few seconds is not held for as long as the dialog stays up.
    @Test func theCallersDeadlineCoversTheKeyRead() async throws {
        let server = try CapturingServer { _, _ in .init(body: jevAnswer) }
        defer { server.stop() }
        let dialog = ConsentDialog()
        let harness = try await dialogHarness(dialog: dialog, server: server)
        defer { harness.clean() }

        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: JevError.timedOut(.decideTool, seconds: 0.3)) {
            try await harness.service.ask(
                .decideTool, state: .string("Charged twice."), questions: jevQuestions,
                deadline: 0.3
            )
        }
        #expect(clock.now - started < .seconds(2))
        #expect(dialog.returned == 0, "the caller was answered while the dialog was still up")

        // Abandoned, not cancelled: once the dialog is answered the request goes out and
        // lands, and an identical ask joins it rather than paying twice.
        dialog.answer()
        let late = try await harness.service.ask(
            .decideTool, state: .string("Charged twice."), questions: jevQuestions
        )
        #expect(try late.noul("refund") == 0.93)
        #expect(server.requests.count == 1)
    }

    /// Two decisions arriving while the dialog is up share the one read, rather than
    /// raising a second dialog as soon as the first is answered.
    @Test func asksMadeWhileTheDialogIsUpShareOneRead() async throws {
        let server = try CapturingServer { _, _ in .init(body: jevAnswer) }
        defer { server.stop() }
        let dialog = ConsentDialog()
        let harness = try await dialogHarness(dialog: dialog, server: server)
        defer { harness.clean() }

        let first = Task {
            try await harness.service.ask(
                .decideTool, state: .string("one"), questions: jevQuestions
            )
        }
        await dialog.waitUntilShown()
        let second = Task {
            try await harness.service.ask(
                .decideTool, state: .string("two"), questions: jevQuestions
            )
        }
        // Until the second ask is waiting on the read it will share.
        let deadline = ContinuousClock.now + .seconds(5)
        while await harness.service.joinedKeyReads == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        dialog.answer()
        _ = try await first.value
        _ = try await second.value

        #expect(dialog.reads == 1)
        #expect(server.requests.count == 2)
    }

    /// With the actor free during the dialog, the owner can change their mind during it —
    /// and a pin set while the dialog is up stops the request it was holding, rather than
    /// letting it go out the moment somebody clicks Allow.
    @Test func aPinSetWhileTheDialogIsUpStillStopsTheRequest() async throws {
        let server = try untouchedServer("a request pinned away from Jev during the dialog")
        defer { server.stop() }
        let dialog = ConsentDialog()
        let harness = try await dialogHarness(dialog: dialog, server: server)
        defer { harness.clean() }

        let asking = Task {
            try await harness.service.ask(
                .decideTool, state: .string("Charged twice."), questions: jevQuestions
            )
        }
        await dialog.waitUntilShown()
        try await harness.service.update { $0.laneOverrides[.decideTool] = .alwaysLocal }
        dialog.answer()

        await #expect(throws: JevError.pinnedAwayFromJev(.decideTool, .alwaysLocal)) {
            try await asking.value
        }
        #expect(server.requests.isEmpty)
    }

    /// Deny — or a build whose code identity the item will not accept — leaves the key
    /// listed and unreadable. That is remembered: the next decision falls back instead of
    /// raising the same dialog to be refused the same way, until the key changes.
    @Test func aRefusedReadIsNotRetriedUntilTheKeyChanges() async throws {
        let server = try untouchedServer("the Keychain refused the key")
        defer { server.stop() }
        let dialog = ConsentDialog(answering: nil)
        let harness = try await dialogHarness(dialog: dialog, server: server)
        defer { harness.clean() }

        dialog.answer()
        await #expect(throws: JevError.noKey) {
            try await harness.service.ask(
                .decideTool, state: .string("Charged twice."), questions: jevQuestions
            )
        }
        #expect(dialog.reads == 1)
        #expect(await harness.service.isAvailable(.decideTool) == false)

        await #expect(throws: JevError.noKey) {
            try await harness.service.ask(
                .decideTool, state: .string("Charged twice."), questions: jevQuestions
            )
        }
        #expect(dialog.reads == 1, "a refused read was asked for again")

        // A new key is a new question.
        await harness.service.keyDidChange()
        #expect(await harness.service.isAvailable(.decideTool))
        dialog.answer()
        _ = try? await harness.service.ask(
            .decideTool, state: .string("Charged twice."), questions: jevQuestions
        )
        #expect(dialog.reads == 2)
        #expect(server.requests.isEmpty)
    }
}

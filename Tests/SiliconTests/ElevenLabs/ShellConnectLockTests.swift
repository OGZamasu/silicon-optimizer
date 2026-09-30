import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Connect's lock outlives the Settings view (probe T2): the check, the region it captured and
/// the locked controls live in the pane state, so a Settings pane or tab switch cannot unlock
/// the picker or Remove, or start a second Connect. And the link seam allows one Connect at a
/// time (probe T1), so an overlapping one cannot leave "linked" with no key.
@Suite("ElevenLabs Connect lock")
@MainActor
struct ShellConnectLockTests {

    typealias Gate = ShellRunnerGenerationTests.Gate

    /// A key store whose every store and remove waits for the test, and applies when released
    /// — a Keychain write or delete sitting behind its consent dialog.
    final class OrderedStore: ElevenLabsKeyStore, @unchecked Sendable {
        private let lock = NSLock()
        private var _key: String?
        private var pending: [(label: String, apply: () -> Void, go: CheckedContinuation<Void, Never>)] = []

        init(key: String?) { _key = key }
        var key: String? { lock.withLock { _key } }
        var labels: [String] { lock.withLock { pending.map(\.label) } }
        func apiKey() async throws -> String? { key }

        func store(_ key: String) async throws {
            await withCheckedContinuation { continuation in
                lock.withLock { pending.append(("store:\(key)", { self._key = key }, continuation)) }
            }
        }

        func remove() async throws {
            await withCheckedContinuation { continuation in
                lock.withLock { pending.append(("remove", { self._key = nil }, continuation)) }
            }
        }

        /// Lets the first pending operation whose label starts with `prefix` land.
        @discardableResult
        func release(_ prefix: String) -> Bool {
            let go: CheckedContinuation<Void, Never>? = lock.withLock {
                guard let index = pending.firstIndex(where: { $0.label.hasPrefix(prefix) }) else { return nil }
                let entry = pending.remove(at: index)
                entry.apply()
                return entry.go
            }
            go?.resume()
            return go != nil
        }
    }

    @MainActor final class Outcome {
        var done = false
        var error: String?
    }

    /// T1: Connect K2 (its Keychain write stuck) → Remove → Connect K3. The second Connect is
    /// refused while the first is still going, and the end state is consistent: not linked,
    /// no key. Without the lock, K3 goes ahead, and whichever write lands last decides — the
    /// probe ended "linked" with nothing stored.
    @Test func aSecondConnectWhileOneIsStoringIsRefusedAndTheEndIsConsistent() async throws {
        let (model, transport, _) = ShellSettingsTests.model(linkedKey: nil, handler: ShellSettingsTests.accountAnswer)
        defer { ShellSettingsTests.clean(model, transport) }
        let store = OrderedStore(key: nil)
        model.elevenLabsLink.store = store

        let k2 = Task { try? await model.linkElevenLabs(key: "fixture-key-k2-0002") }
        try await ShellExplorerTests.waitUntil { store.labels.contains("store:fixture-key-k2-0002") }
        model.unlinkElevenLabs()
        try await ShellExplorerTests.waitUntil { store.labels.contains("remove") }
        store.release("remove")
        await model.elevenLabsLink.pendingRemoval?.value

        let outcome = Outcome()
        let k3 = Task {
            do { _ = try await model.linkElevenLabs(key: "fixture-key-k3-0003") } catch { outcome.error = "\(error)" }
            outcome.done = true
        }
        try await ShellExplorerTests.waitUntil { outcome.done || store.labels.contains("store:fixture-key-k3-0003") }

        if outcome.done {
            #expect(outcome.error?.contains(ElevenLabsLink.linkInProgressMessage) == true)
            store.release("store:fixture-key-k2")              // K2's stuck write lands…
            try await ShellExplorerTests.waitUntil { store.labels.contains("remove") }
            store.release("remove")                            // …and it takes it back out.
            _ = await k2.value
        } else {
            // No lock: replay the probe's order so the failure shows as the inconsistency.
            Issue.record("a second Connect ran while the first was still storing")
            store.release("store:fixture-key-k2")
            try await ShellExplorerTests.waitUntil { store.labels.contains("remove") }
            store.release("store:fixture-key-k3")
            await k3.value
            store.release("remove")
            _ = await k2.value
        }
        #expect(model.elevenLabsLinked == (store.key != nil),
                "linked=\(model.elevenLabsLinked) but the store holds \(store.key ?? "nothing")")
        #expect(!model.elevenLabsLinked)
    }

    /// T2: the Settings view is rebuilt mid-check (a pane or tab switch). It finds the same
    /// connection model, still checking: the picker refuses, a second Connect is refused, and
    /// the key ends linked on the region it was checked on.
    @Test func aRebuiltSettingsViewFindsTheCheckStillRunning() async throws {
        let gate = Gate()
        let (model, transport, store) = ShellSettingsTests.model(linkedKey: nil) { request in
            await gate.wait()
            return ShellSettingsTests.accountAnswer(request)
        }
        defer { ShellSettingsTests.clean(model, transport) }
        let connecting = Task { await model.elevenLabsPane.connection.connect(key: ShellSettingsTests.candidate, model: model) }
        try await ShellExplorerTests.waitUntil { transport.requests.count >= 1 }

        let rebuilt = model.elevenLabsPane.connection          // what the view finds after the switch
        #expect(rebuilt.verifying)
        rebuilt.requestRegion(.eu, model: model)
        #expect(rebuilt.regionNotice == ElevenLabsConnectionModel.verifyingMessage)
        #expect(model.elevenLabsRegion == .global)
        #expect(await rebuilt.connect(key: "fixture-key-second-0004", model: model) == false)
        #expect(rebuilt.failure == ElevenLabsConnectionModel.alreadyCheckingMessage)

        gate.open()
        #expect(await connecting.value)
        #expect(model.elevenLabsRegion == .global)
        #expect(store.key == ShellSettingsTests.candidate)
    }
}

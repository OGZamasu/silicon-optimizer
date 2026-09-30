import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Connect takes time: the key is checked with ElevenLabs before it is stored. Whatever the
/// owner does meanwhile must stand. A Remove pressed during the check is not undone when the
/// check comes back, and the key is checked, stored and described for the region Connect was
/// pressed on — the picker waits. Probe shapes from the shell critic (P1, P2a, P2b).
@Suite("ElevenLabs Connect while things change")
@MainActor
struct ShellConnectRaceTests {

    typealias Gate = ShellRunnerGenerationTests.Gate

    @Test func aRemovePressedWhileAReplacementIsCheckedStands() async throws {
        let gate = Gate()
        let (model, transport, store) = ShellSettingsTests.model(linkedKey: ShellSettingsTests.key) { request in
            await gate.wait()
            return ShellSettingsTests.accountAnswer(request)
        }
        defer { ShellSettingsTests.clean(model, transport) }
        let connection = ElevenLabsConnectionModel()
        let connecting = Task { await connection.connect(key: "fixture-key-replacement-0003", model: model) }
        try await ShellExplorerTests.waitUntil { transport.requests.count >= 1 }
        #expect(connection.verifying)

        connection.remove(model: model)
        #expect(!model.elevenLabsLinked)
        await model.elevenLabsLink.pendingRemoval?.value
        gate.open()
        #expect(await connecting.value == false)
        #expect(!model.elevenLabsLinked)
        #expect(store.key == nil)
        #expect(connection.failure == ElevenLabsConnectionModel.removedWhileCheckingMessage)
    }

    /// The seam itself: a Remove that lands while the checked key is being stored takes it
    /// back out.
    @Test func aRemoveDuringTheStoreTakesTheKeyBackOut() async throws {
        let (model, transport, _) = ShellSettingsTests.model(linkedKey: nil, handler: ShellSettingsTests.accountAnswer)
        defer { ShellSettingsTests.clean(model, transport) }
        let store = SlowStore()
        model.elevenLabsLink.store = store
        let linking = Task { try await model.linkElevenLabs(key: ShellSettingsTests.candidate) }
        try await ShellExplorerTests.waitUntil { store.storing }
        model.unlinkElevenLabs()
        store.finishStoring()
        await #expect(throws: ElevenLabsError.cancelled) { try await linking.value }
        await model.elevenLabsLink.pendingRemoval?.value
        #expect(store.key == nil)
        #expect(!model.elevenLabsLinked)
    }

    @Test func aRefusedKeyIsDescribedForTheRegionItWasCheckedOn() async throws {
        let gate = Gate()
        let (model, transport, _) = ShellSettingsTests.model(linkedKey: nil) { _ in
            await gate.wait()
            return .jsonText(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#, status: 401)
        }
        defer { ShellSettingsTests.clean(model, transport) }
        let connection = ElevenLabsConnectionModel()
        let connecting = Task { await connection.connect(key: ShellSettingsTests.candidate, model: model) }
        try await ShellExplorerTests.waitUntil { transport.requests.count >= 1 }

        connection.requestRegion(.eu, model: model)
        #expect(connection.regionNotice == ElevenLabsConnectionModel.verifyingMessage)
        #expect(model.elevenLabsRegion == .global)
        gate.open()
        _ = await connecting.value
        #expect(transport.requests.allSatisfy { $0.url.host == "api.elevenlabs.io" })
        let failure = try #require(connection.failure)
        #expect(failure.hasPrefix(ElevenLabsRegion.global.displayName))
        #expect(!failure.contains("\(ElevenLabsRegion.eu.displayName) did not accept"))
    }

    @Test func aGoodKeyIsLinkedForTheRegionItWasCheckedOn() async throws {
        let gate = Gate()
        let (model, transport, _) = ShellSettingsTests.model(linkedKey: nil) { request in
            await gate.wait()
            return ShellSettingsTests.accountAnswer(request)
        }
        defer { ShellSettingsTests.clean(model, transport) }
        let connection = ElevenLabsConnectionModel()
        connection.requestRegion(.eu, model: model)
        let connecting = Task { await connection.connect(key: ShellSettingsTests.candidate, model: model) }
        try await ShellExplorerTests.waitUntil { transport.requests.count >= 1 }
        connection.requestRegion(.global, model: model)
        #expect(connection.regionNotice == ElevenLabsConnectionModel.verifyingMessage)
        #expect(model.elevenLabsRegion == .eu, "the picker moved while the key was being checked on EU")
        gate.open()
        #expect(await connecting.value)
        #expect(model.elevenLabsRegion == .eu)
        #expect(transport.requests.allSatisfy { $0.url.host == ElevenLabsRegion.eu.host })
    }

    /// A key store whose write waits for the test, like a Keychain write behind its dialog.
    final class SlowStore: ElevenLabsKeyStore, @unchecked Sendable {
        private let lock = NSLock()
        private var _key: String?
        private var _storing = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var released = false

        var key: String? { lock.withLock { _key } }
        var storing: Bool { lock.withLock { _storing } }

        func apiKey() async throws -> String? { key }

        func store(_ key: String) async throws {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    _storing = true
                    if released { return true }
                    waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            lock.withLock { _key = key }
        }

        func remove() async throws {
            lock.withLock { _key = nil }
        }

        func finishStoring() {
            let continuation = lock.withLock {
                released = true
                defer { waiter = nil }
                return waiter
            }
            continuation?.resume()
        }
    }
}

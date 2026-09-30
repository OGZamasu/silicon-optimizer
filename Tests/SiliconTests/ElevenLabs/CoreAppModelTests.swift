import Foundation
import Security
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// The app's end: Connect verifies before it stores, Remove forgets, launch reads nothing,
/// outputs land in dated folders. Every model here is built with injected settings, so it
/// holds an in-memory key and a scratch output folder; the Keychain and the network are never
/// reachable, and the Keychain credential is exercised only through a fake `Access`.
@MainActor
@Suite("ElevenLabs in the app model")
struct CoreAppModelTests {

    nonisolated static let key = "sk_" + String(repeating: "appfixture", count: 3)
    nonisolated static let oldKey = "sk_" + "the_old_key_000000"
    nonisolated static let replacementKey = "sk_" + "replacement_000000"

    /// A model with a fake transport answering the two account calls (or `failure`), and a
    /// fake key store.
    static func model(
        settings: Settings = .init(), storedKey: String? = nil,
        answer: @escaping @Sendable (ElevenLabsRequest) async throws -> FakeElevenLabsTransport.Reply = CoreAppModelTests.accountAnswer
    ) -> (AppModel, FakeElevenLabsTransport, FakeCredentialSource) {
        let model = AppModel(settings: settings)
        let transport = FakeElevenLabsTransport(handler: answer)
        let store = FakeCredentialSource(key: storedKey)
        model.elevenLabsLink.transport = transport
        model.elevenLabsLink.store = store
        model.elevenLabsLink.limits = CoreClientTests.fastLimits
        return (model, transport, store)
    }

    nonisolated static func accountAnswer(_ request: ElevenLabsRequest) -> FakeElevenLabsTransport.Reply {
        switch request.url.path {
        case "/v1/user": .json(["user_id": "user-1", "subscription": ["tier": "creator"]])
        case "/v1/user/subscription":
            .json(["tier": "creator", "character_count": 10, "character_limit": 100_000, "status": "active"])
        default: .audio(Data([1, 2, 3]))
        }
    }

    static func cleanUp(_ model: AppModel, _ transport: FakeElevenLabsTransport) {
        TemporaryFileSink.removeScratch(model.elevenLabsOutputDirectory)
        transport.removeTemporaryFiles()
    }

    // MARK: - Connect

    @Test func connectVerifiesThenStoresTheKeyAndTheRegion() async throws {
        let (model, transport, store) = Self.model()
        defer { Self.cleanUp(model, transport) }
        let account = try await model.linkElevenLabs(key: "  \(Self.key)\n", region: .us)
        #expect(account.tier == "creator")
        #expect(account.remainingCharacters == 99_990)
        #expect(store.key == Self.key)
        #expect(model.elevenLabsLinked)
        #expect(model.elevenLabsRegion == .us)
        #expect(model.elevenLabsAccount == account)
        #expect(model.elevenLabsLastError == nil)
        let client = try #require(model.elevenLabsClient)
        #expect(client.region == .us)
        #expect(await client.concurrencyLimit == 5)
        #expect(transport.requests.map(\.url.host) == ["api.us.elevenlabs.io", "api.us.elevenlabs.io"])
        #expect(transport.requests.allSatisfy { $0.header("xi-api-key") == Self.key })
    }

    @Test func aRejectedKeyStoresNothingAndSaysWhy() async throws {
        let (model, transport, store) = Self.model { _ in
            .jsonText(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#, status: 401)
        }
        defer { Self.cleanUp(model, transport) }
        await #expect {
            try await model.linkElevenLabs(key: Self.key, region: .eu)
        } throws: { error in
            guard case ElevenLabsError.api(401, _, let message, _) = error else { return false }
            return message.contains("different region")
        }
        #expect(store.key == nil)
        #expect(store.writes == 0)
        #expect(!model.elevenLabsLinked)
        #expect(model.elevenLabsRegion == .global, "a failed Connect must not move the region")
        #expect(model.elevenLabsLastError?.contains("Invalid API key") == true)
        #expect(model.elevenLabsLastError?.contains(Self.key) == false)
    }

    @Test func aNetworkFailureLeavesTheLinkedKeyAlone() async throws {
        var settings = Settings()
        settings.elevenLabsLinked = true
        let (model, transport, store) = Self.model(settings: settings, storedKey: Self.oldKey) { _ in
            throw ElevenLabsError.network("offline")
        }
        defer { Self.cleanUp(model, transport) }
        await #expect(throws: ElevenLabsError.network("offline")) {
            try await model.linkElevenLabs(key: Self.key)
        }
        #expect(store.key == Self.oldKey)
        #expect(model.elevenLabsLinked)
        #expect(model.elevenLabsLastError == ElevenLabsError.network("offline").description)
    }

    @Test func anEmptyOrBrokenKeyIsRefusedWithoutAsking() async throws {
        let (model, transport, _) = Self.model()
        defer { Self.cleanUp(model, transport) }
        await #expect(throws: ElevenLabsError.invalidArguments(["The key is empty."])) {
            try await model.linkElevenLabs(key: "  \n")
        }
        await #expect(throws: ElevenLabsError.self) { try await model.linkElevenLabs(key: "sk_one two") }
        #expect(transport.requests.isEmpty)
    }

    @Test func aKeychainThatWillNotKeepTheKeyLeavesNothingLinked() async throws {
        let (model, transport, store) = Self.model()
        defer { Self.cleanUp(model, transport) }
        store.setFailure(.credentialUnavailable("locked"))
        await #expect(throws: ElevenLabsError.credentialUnavailable("locked")) {
            try await model.linkElevenLabs(key: Self.key)
        }
        #expect(!model.elevenLabsLinked)
        #expect(model.elevenLabsLastError?.hasPrefix("The key works, but the Keychain would not keep it") == true)
    }

    // MARK: - Remove

    @Test func removeForgetsEverythingAndDeletesTheKey() async throws {
        let (model, transport, store) = Self.model()
        defer { Self.cleanUp(model, transport) }
        try await model.linkElevenLabs(key: Self.key)
        model.unlinkElevenLabs()
        #expect(!model.elevenLabsLinked)
        #expect(model.elevenLabsClient == nil)
        #expect(model.elevenLabsAccount == nil)
        await model.elevenLabsLink.pendingRemoval?.value
        #expect(store.key == nil)

        // Connecting again waits for a removal still under way instead of racing it.
        model.unlinkElevenLabs()
        try await model.linkElevenLabs(key: Self.key)
        #expect(store.key == Self.key)
    }

    @Test func aRemovalTheKeychainRefusesIsReported() async throws {
        let (model, transport, store) = Self.model()
        defer { Self.cleanUp(model, transport) }
        try await model.linkElevenLabs(key: Self.key)
        store.setFailure(.credentialUnavailable("locked"))
        model.unlinkElevenLabs()
        await model.elevenLabsLink.pendingRemoval?.value
        #expect(!model.elevenLabsLinked)
        #expect(model.elevenLabsLastError?.hasPrefix("The key could not be removed from the Keychain") == true)
    }

    // MARK: - Launch

    @Test func launchReadsNoKeyAndVerifiesOnFirstUse() async throws {
        var settings = Settings()
        settings.elevenLabsLinked = true
        settings.elevenLabsRegion = .india
        let (model, transport, store) = Self.model(settings: settings, storedKey: Self.key)
        defer { Self.cleanUp(model, transport) }
        #expect(model.elevenLabsLinked)
        let client = try #require(model.elevenLabsClient)
        #expect(client.region == .india)
        #expect(model.elevenLabsAccount == nil)
        #expect(store.reads == 0, "building the client must not read the key")
        #expect(transport.requests.isEmpty)

        let account = try await model.refreshElevenLabsAccount()
        #expect(model.elevenLabsAccount == account)
        #expect(store.reads > 0)
        #expect(transport.requests.allSatisfy { $0.url.host == "api.in.residency.elevenlabs.io" })
    }

    @Test func changingTheRegionBuildsANewClientForIt() async throws {
        var settings = Settings()
        settings.elevenLabsLinked = true
        let (model, transport, _) = Self.model(settings: settings, storedKey: Self.key)
        defer { Self.cleanUp(model, transport) }
        #expect(model.elevenLabsClient?.region == .global)
        model.elevenLabsRegion = .singapore
        #expect(model.elevenLabsClient?.region == .singapore)
        #expect(model.settings.elevenLabsRegion == .singapore)
        model.elevenLabsAllowRiskyForAgents = true
        #expect(model.settings.elevenLabsAllowRiskyForAgents)
    }

    @Test func notLinkedMeansNoClientAndRefreshSaysSo() async {
        let (model, transport, _) = Self.model()
        defer { Self.cleanUp(model, transport) }
        #expect(model.elevenLabsClient == nil)
        await #expect(throws: ElevenLabsError.notLinked) { try await model.refreshElevenLabsAccount() }
    }

    // MARK: - Outputs

    @Test func outputsLandInADatedFolderAndAreListedAndRegistered() async throws {
        let (model, transport, _) = Self.model()
        defer { Self.cleanUp(model, transport) }
        try await model.linkElevenLabs(key: Self.key)
        let client = try #require(model.elevenLabsClient)
        let result = try await client.textToSpeech(voice_id: "v1", text: "hello")
        let file = try #require(result.files.first)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        #expect(file.deletingLastPathComponent().lastPathComponent == formatter.string(from: Date()))
        #expect(file.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                == model.elevenLabsOutputDirectory.standardizedFileURL.path)
        #expect(model.elevenLabsOutputDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path)
                || model.elevenLabsOutputDirectory.resolvingSymlinksInPath().path
                    .hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path))

        let output = try #require(model.elevenLabsRecentOutputs.first)
        #expect(output.url == file)
        #expect(output.operationID == "text_to_speech_full")
        #expect(output.mediaID != nil)
    }

    @Test func theDatedSinkNamesByDayAndNeverOverwrites() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-dated-\(UUID().uuidString)", isDirectory: true)
        defer { TemporaryFileSink.removeScratch(root) }
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let sink = ElevenLabsDatedFileSink(root: root, now: { day })
        let operation = try #require(ElevenLabsCatalog.operation("sound_generation"))
        let first = try sink.destination(for: operation, suggestedName: "rain.mp3", contentType: "audio/mpeg")
        try Data([1]).write(to: first)
        let second = try sink.destination(for: operation, suggestedName: "rain.mp3", contentType: "audio/mpeg")
        #expect(first.deletingLastPathComponent() == sink.folder(for: day))
        #expect(first.lastPathComponent == "rain.mp3")
        #expect(second.lastPathComponent == "rain 2.mp3")
    }

    // MARK: - Settings

    @Test func theThreeSettingsRoundTrip() throws {
        var settings = Settings()
        settings.elevenLabsLinked = true
        settings.elevenLabsRegion = .eu
        settings.elevenLabsAllowRiskyForAgents = true
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.elevenLabsLinked)
        #expect(decoded.elevenLabsRegion == .eu)
        #expect(decoded.elevenLabsAllowRiskyForAgents)
        let text = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!text.contains("sk_"), "the key is never in the settings document")
    }

    // MARK: - The Keychain credential, without the Keychain

    @Test func theKeychainIsAskedOffTheMainThreadOnceAndRemembered() async throws {
        let calls = Calls()
        let credential = ElevenLabsCredential(access: .init(
            read: { calls.note("read", main: Thread.isMainThread); return .found(Self.key) },
            write: { _ in calls.note("write", main: Thread.isMainThread); return errSecSuccess },
            delete: { calls.note("delete", main: Thread.isMainThread); return errSecSuccess }
        ))
        #expect(try await credential.apiKey() == Self.key)
        #expect(try await credential.apiKey() == Self.key)
        #expect(calls.names == ["read"])
        try await credential.store(Self.replacementKey)
        #expect(try await credential.apiKey() == Self.replacementKey)
        try await credential.remove()
        #expect(try await credential.apiKey() == nil)
        #expect(calls.names == ["read", "write", "delete"])
        #expect(!calls.anyOnMain)
        #expect(!calls.anyOnSwiftTask, "the Keychain must be asked on a GCD thread, not the cooperative pool")
    }

    @Test func aLockedKeychainIsReportedAndAskedAgainNextTime() async throws {
        let calls = Calls()
        let credential = ElevenLabsCredential(access: .init(
            read: { calls.note("read", main: false); return .unavailable(errSecInteractionNotAllowed) },
            write: { _ in errSecAuthFailed },
            delete: { errSecItemNotFound }
        ))
        await #expect(throws: ElevenLabsError.self) { try await credential.apiKey() }
        await #expect(throws: ElevenLabsError.self) { try await credential.apiKey() }
        #expect(calls.names == ["read", "read"])
        await #expect(throws: ElevenLabsError.self) { try await credential.store(Self.replacementKey) }
        try await credential.remove()   // already gone counts as removed
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _names: [String] = []
        private var _anyOnMain = false
        private var _anyOnSwiftTask = false
        /// `main` is true on the main thread. A Swift-concurrency thread — the cooperative pool —
        /// has a current task; a GCD thread has none. Only a GCD thread may sit behind the
        /// Keychain's consent dialog, so the second is the property that matters.
        func note(_ name: String, main: Bool) {
            let onSwiftTask = withUnsafeCurrentTask { $0 != nil }
            lock.withLock {
                _names.append(name)
                _anyOnMain = _anyOnMain || main
                _anyOnSwiftTask = _anyOnSwiftTask || onSwiftTask
            }
        }
        var names: [String] { lock.withLock { _names } }
        var anyOnMain: Bool { lock.withLock { _anyOnMain } }
        var anyOnSwiftTask: Bool { lock.withLock { _anyOnSwiftTask } }
    }
}

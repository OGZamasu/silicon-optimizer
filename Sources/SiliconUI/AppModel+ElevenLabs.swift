import Foundation
import Observation
import Security
import SiliconControl
import SiliconElevenLabs

/// The app's end of ElevenLabs: whether a key is linked, where it lives, and the client the
/// pane, the control routes and MCP all call through.
///
/// "Linked" is a boolean in Settings, kept in step by Connect and Remove, so drawing the
/// sidebar or Settings never asks the Keychain anything, and launch reads nothing: the key is
/// read the first time a request is about to be sent, off the main actor, and the account is
/// verified the first time something asks for it (`refreshElevenLabsAccount()`).
@MainActor
@Observable
final class ElevenLabsLink {
    /// Where the key lives: the Keychain in the app, memory under a test.
    @ObservationIgnored var store: any ElevenLabsKeyStore
    /// URLSession in the app; under a test, a transport that refuses everything unless the
    /// test hands in a fake.
    @ObservationIgnored var transport: any ElevenLabsTransport
    /// Whether changes are written to the settings document. Off under injected settings.
    @ObservationIgnored let persistsSettings: Bool
    /// Where outputs go instead of `<voice output folder>/ElevenLabs`. A scratch directory
    /// under injected settings, so no test writes into the owner's Music folder.
    @ObservationIgnored var outputRootOverride: URL?
    /// The table finished files are registered in: the app's shared one, or an in-memory one
    /// under a test (the shared one persists into Application Support).
    @ObservationIgnored var registry: MediaRegistry?
    /// Size, time and retry bounds for the clients built here. Tests shorten the waits.
    @ObservationIgnored var limits = ElevenLabsClient.Limits()
    /// The last verified account: plan, balance, reset date.
    var account: ElevenLabsAccount?
    /// The last failure to verify, refresh or remove, in words that can be shown.
    var lastError: String?
    /// Files written this session, newest first.
    var recentOutputs: [ElevenLabsOutput] = []
    @ObservationIgnored var client: ElevenLabsClient?
    /// The Keychain removal Remove started, for anything that must wait for it.
    @ObservationIgnored var pendingRemoval: Task<Void, Never>?
    /// Bumped by every Remove. A Connect still checking its key when one happens stores
    /// nothing — or takes back what it stored — so a Remove pressed during Connect stands.
    @ObservationIgnored var linkGeneration = 0

    init(
        store: any ElevenLabsKeyStore, transport: any ElevenLabsTransport, persistsSettings: Bool,
        outputRootOverride: URL? = nil, registry: MediaRegistry? = nil
    ) {
        self.store = store
        self.transport = transport
        self.persistsSettings = persistsSettings
        self.outputRootOverride = outputRootOverride
        self.registry = registry
    }

    /// The running app's: the Keychain, the network, the shared media table.
    static func live(registry: MediaRegistry) -> ElevenLabsLink {
        ElevenLabsLink(store: ElevenLabsCredential(), transport: URLSessionTransport(),
                       persistsSettings: true, registry: registry)
    }

    /// An app model built with injected settings (tests, previews): nothing real reachable,
    /// and retry waits short enough that a read refused by the inert transport fails at once.
    static func inert() -> ElevenLabsLink {
        let link = ElevenLabsLink(
            store: FakeCredentialSource(), transport: UnavailableElevenLabsTransport(),
            persistsSettings: false,
            outputRootOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("elevenlabs-app-\(UUID().uuidString)", isDirectory: true),
            registry: MediaRegistry(url: nil)
        )
        link.limits.firstBackoff = 0.01
        link.limits.longestRetryWait = 0.05
        return link
    }

    /// At most this many recent outputs are listed.
    static let recentLimit = 50
}

/// A file ElevenLabs produced this session.
public struct ElevenLabsOutput: Sendable, Hashable, Identifiable {
    public var url: URL
    public var contentType: String
    public var operationID: String
    /// The id `GET /media/{id}` serves it under, when its type is one the app serves.
    public var mediaID: String?
    public var createdAt: Date
    public var id: URL { url }
}

extension AppModel {

    // MARK: - State

    /// Whether a key is linked. Settings' boolean, never a Keychain query.
    public var elevenLabsLinked: Bool { settings.elevenLabsLinked }

    /// Which ElevenLabs host the key is sent to. Changing it drops the current client and the
    /// account read through it; the next call builds a client for the new host.
    public var elevenLabsRegion: ElevenLabsRegion {
        get { settings.elevenLabsRegion }
        set {
            guard newValue != settings.elevenLabsRegion else { return }
            settings.elevenLabsRegion = newValue
            elevenLabsLink.client = nil
            elevenLabsLink.account = nil
            saveElevenLabsSettings()
        }
    }

    /// The owner's switch: "Let agents run destructive and real-world ElevenLabs actions".
    /// Off by default; MCP and control refuse those operations while it is off.
    public var elevenLabsAllowRiskyForAgents: Bool {
        get { settings.elevenLabsAllowRiskyForAgents }
        set {
            guard newValue != settings.elevenLabsAllowRiskyForAgents else { return }
            settings.elevenLabsAllowRiskyForAgents = newValue
            saveElevenLabsSettings()
        }
    }

    /// The last verified account, or nil before the first verification this launch.
    public var elevenLabsAccount: ElevenLabsAccount? { elevenLabsLink.account }

    /// The last failure to connect, refresh or remove, for Settings and the pane to show.
    public var elevenLabsLastError: String? { elevenLabsLink.lastError }

    /// Files ElevenLabs wrote this session, newest first.
    public var elevenLabsRecentOutputs: [ElevenLabsOutput] { elevenLabsLink.recentOutputs }

    /// `<voice output folder>/ElevenLabs`: every output lands in a dated folder under it.
    public var elevenLabsOutputDirectory: URL {
        elevenLabsLink.outputRootOverride
            ?? settings.resolvedVoiceOutputDirectory.appendingPathComponent("ElevenLabs", isDirectory: true)
    }

    /// The client for the linked key and region, or nil when nothing is linked. Built on first
    /// use; building it reads nothing — the key is read when the first request goes out.
    public var elevenLabsClient: ElevenLabsClient? {
        guard settings.elevenLabsLinked else { return nil }
        if let client = elevenLabsLink.client, client.region == settings.elevenLabsRegion {
            return client
        }
        let client = makeElevenLabsClient(credentials: elevenLabsLink.store, region: settings.elevenLabsRegion)
        elevenLabsLink.client = client
        return client
    }

    // MARK: - Connect and remove

    /// Verifies `key` with the free `GET /v1/user` and `GET /v1/user/subscription` on
    /// `region` (the current one unless given), and only then stores it and the region.
    ///
    /// A key ElevenLabs rejects stores nothing and leaves any linked key as it was; so does a
    /// network failure, which says what went wrong instead. A residency region's keys work
    /// only there, so a 401 on one says the key may belong to another region.
    @discardableResult
    public func linkElevenLabs(key rawKey: String, region: ElevenLabsRegion? = nil) async throws -> ElevenLabsAccount {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ElevenLabsError.invalidArguments(["The key is empty."]) }
        guard !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ElevenLabsError.invalidArguments(["A key has no spaces or line breaks in it."])
        }
        let region = region ?? settings.elevenLabsRegion
        let generation = elevenLabsLink.linkGeneration
        // Wait for a Remove still under way, so it cannot delete the key stored below.
        await elevenLabsLink.pendingRemoval?.value

        let probe = makeElevenLabsClient(credentials: CandidateKey(key: key), region: region)
        let account: ElevenLabsAccount
        do {
            account = try await probe.account()
        } catch {
            let failure = Self.elevenLabsError(error, key: key)
            elevenLabsLink.lastError = failure.description
            throw failure
        }
        // Removed while the key was being checked: the Remove stands.
        guard elevenLabsLink.linkGeneration == generation else { throw ElevenLabsError.cancelled }
        do {
            try await elevenLabsLink.store.store(key)
        } catch {
            let failure = Self.elevenLabsError(error, key: key)
            elevenLabsLink.lastError = "The key works, but the Keychain would not keep it: \(failure.description)"
            throw failure
        }
        // Removed while it was being stored: take it back out, unless a later Connect has
        // linked a key of its own since.
        guard elevenLabsLink.linkGeneration == generation else {
            if !settings.elevenLabsLinked { try? await elevenLabsLink.store.remove() }
            throw ElevenLabsError.cancelled
        }
        settings.elevenLabsRegion = region
        settings.elevenLabsLinked = true
        saveElevenLabsSettings()
        let client = makeElevenLabsClient(credentials: elevenLabsLink.store, region: region)
        await client.setConcurrencyLimit(account.concurrencyLimit)
        elevenLabsLink.client = client
        elevenLabsLink.account = account
        elevenLabsLink.lastError = nil
        return account
    }

    /// Deletes the key and forgets the account; the pane disappears at once. The Keychain
    /// deletion runs off the main actor; a failure is left in `elevenLabsLastError`.
    public func unlinkElevenLabs() {
        elevenLabsLink.linkGeneration += 1
        settings.elevenLabsLinked = false
        saveElevenLabsSettings()
        elevenLabsLink.client = nil
        elevenLabsLink.account = nil
        elevenLabsLink.lastError = nil
        let store = elevenLabsLink.store
        let previous = elevenLabsLink.pendingRemoval
        elevenLabsLink.pendingRemoval = Task { [weak self] in
            await previous?.value
            do {
                try await store.remove()
            } catch {
                self?.elevenLabsLink.lastError =
                    "The key could not be removed from the Keychain: \(Self.elevenLabsError(error, key: nil).description)"
            }
        }
    }

    /// Reads the plan and balance again (free). What the pane's header calls when it appears,
    /// and the first verification of a key linked at an earlier launch.
    @discardableResult
    public func refreshElevenLabsAccount() async throws -> ElevenLabsAccount {
        guard let client = elevenLabsClient else { throw ElevenLabsError.notLinked }
        do {
            let account = try await client.account()
            // A Remove or a region change while this was in flight wins.
            if elevenLabsLink.client === client { elevenLabsLink.account = account }
            elevenLabsLink.lastError = nil
            return account
        } catch {
            let failure = Self.elevenLabsError(error, key: nil)
            if elevenLabsLink.client === client { elevenLabsLink.lastError = failure.description }
            throw failure
        }
    }

    // MARK: - Plumbing

    func makeElevenLabsClient(
        credentials: any ElevenLabsCredentialSource, region: ElevenLabsRegion
    ) -> ElevenLabsClient {
        ElevenLabsClient(credentials: credentials, region: region, transport: elevenLabsLink.transport,
                         sink: elevenLabsSink(), limits: elevenLabsLink.limits)
    }

    /// Writes under `elevenLabsOutputDirectory/<yyyy-MM-dd>/`, registers each file with the
    /// media table (inside that folder only) and lists it in the recent outputs.
    func elevenLabsSink() -> ElevenLabsDatedFileSink {
        let root = elevenLabsOutputDirectory
        let registry = elevenLabsLink.registry
        return ElevenLabsDatedFileSink(root: root, onWrite: { [weak self] file, contentType, operation in
            let mediaID = await registry?.register(path: file.path, within: [root.path])
            let output = ElevenLabsOutput(url: file, contentType: contentType, operationID: operation.id,
                                          mediaID: mediaID, createdAt: Date())
            await self?.noteElevenLabsOutput(output)
        })
    }

    func noteElevenLabsOutput(_ output: ElevenLabsOutput) {
        elevenLabsLink.recentOutputs.insert(output, at: 0)
        if elevenLabsLink.recentOutputs.count > ElevenLabsLink.recentLimit {
            elevenLabsLink.recentOutputs.removeLast(elevenLabsLink.recentOutputs.count - ElevenLabsLink.recentLimit)
        }
    }

    func saveElevenLabsSettings() {
        guard elevenLabsLink.persistsSettings else { return }
        settings.save()
    }

    nonisolated static func elevenLabsError(_ error: any Error, key: String?) -> ElevenLabsError {
        ElevenLabsError(wrapping: error, redactingKey: key)
    }
}

/// A key being verified: held in memory for the two account calls and never stored unless
/// they succeed.
private struct CandidateKey: ElevenLabsCredentialSource {
    let key: String
    func apiKey() async throws -> String? { key }
}

// MARK: - Keychain

/// The ElevenLabs API key, in the Keychain and nowhere else.
///
/// Read only when a request is about to be sent, on a GCD thread — never on the main actor or
/// any other actor, because a freshly built app's first read waits on the Keychain's consent
/// dialog, and everything queued behind a blocked actor would wait with it. Kept in memory
/// after the first answer so the dialog is asked once per launch at most. There is no
/// "is a key stored?" query: Settings' `elevenLabsLinked` answers that without the Keychain.
final class ElevenLabsCredential: ElevenLabsKeyStore, @unchecked Sendable {
    static let service = "dev.siliconoptimizer.credentials"
    static let account = "elevenlabs-api-key"

    /// The three Keychain calls, as values so a test can run this type without the Keychain.
    struct Access: Sendable {
        var read: @Sendable () -> KeychainReadResult
        /// Stores the key, replacing any; false when the Keychain refused.
        var write: @Sendable (String) -> OSStatus
        /// Deletes the item; success or "not found" both count as gone.
        var delete: @Sendable () -> OSStatus
    }

    private let access: Access
    private let lock = NSLock()
    /// nil: never asked. `.some(nil)`: asked, and there is none.
    private var cached: String??
    /// Bumped whenever `store` or `remove` finishes. A read that started before that is older
    /// than what they left in `cached`, and must neither overwrite it nor be handed out.
    private var generation = 0
    /// The Keychain read now in flight, shared by everyone who asks meanwhile. A freshly built
    /// app's first read waits on the consent dialog, and the pane asks for the account and the
    /// voices at the same moment — one dialog each would be one too many.
    private var inFlight: Task<String?, any Error>?

    private enum Step {
        case answer(String?)
        case join(Task<String?, any Error>)
    }

    init(access: Access = .keychain) { self.access = access }

    func apiKey() async throws -> String? {
        let step: Step = lock.withLock {
            if let cached { return .answer(cached) }
            if let running = inFlight { return .join(running) }
            let started = generation
            let access = access
            let task = Task<String?, any Error> {
                let answer = await Self.offActor { access.read() }
                return try self.finishRead(answer, startedAt: started)
            }
            inFlight = task
            return .join(task)
        }
        switch step {
        case .answer(let key): return key
        case .join(let task): return try await task.value
        }
    }

    private func finishRead(_ answer: KeychainReadResult, startedAt started: Int) throws -> String? {
        try lock.withLock {
            inFlight = nil
            // A `store` or `remove` finished while this read was out: what it left is the truth
            // now, and this read's answer is older.
            guard started == generation else { return cached ?? nil }
            switch answer {
            case .found(let key):
                cached = .some(key)
                return key
            case .absent:
                cached = .some(nil)
                return nil
            case .unavailable(let status):
                // Nothing is remembered: the next request asks again, and a locked Keychain or a
                // dismissed dialog costs one call, not the session.
                throw ElevenLabsError.credentialUnavailable(Self.describe(status))
            }
        }
    }

    func store(_ key: String) async throws {
        let access = access
        let status = await Self.offActor { access.write(key) }
        guard status == errSecSuccess else {
            throw ElevenLabsError.credentialUnavailable(Self.describe(status))
        }
        lock.withLock {
            generation += 1
            cached = .some(key)
        }
    }

    func remove() async throws {
        let access = access
        let status = await Self.offActor { access.delete() }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ElevenLabsError.credentialUnavailable(Self.describe(status))
        }
        lock.withLock {
            generation += 1
            cached = .some(nil)
        }
    }

    /// Runs a Keychain call on a GCD thread: it can sit behind the consent dialog for as long
    /// as the user leaves it, and Swift's cooperative pool is not sized to lose a thread.
    static func offActor<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "\(message) (\(status))"
    }
}

extension ElevenLabsCredential.Access {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ElevenLabsCredential.service,
            kSecAttrAccount as String: ElevenLabsCredential.account,
        ]
    }

    /// The real Keychain. Never used by a test: `AppModel` under injected settings holds a
    /// `FakeCredentialSource`, and `ElevenLabsCredential`'s own tests pass their own `Access`.
    static let keychain = ElevenLabsCredential.Access(
        read: {
            var request = query
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data,
                      let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !key.isEmpty
                else { return .absent }
                return .found(key)
            case errSecItemNotFound:
                return .absent
            default:
                return .unavailable(status)
            }
        },
        write: { key in
            let data = Data(key.utf8)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecItemNotFound else { return status }
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "Silicon Optimizer — ElevenLabs API key"
            return SecItemAdd(item as CFDictionary, nil)
        },
        delete: {
            SecItemDelete(query as CFDictionary)
        }
    )
}

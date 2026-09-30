import Foundation
import Observation
import Security
import SiliconElevenLabs

/// The app's end of ElevenLabs: whether a key is linked, where it lives, and the client the
/// pane, the control routes and MCP all call through.
///
/// "Linked" is a boolean in Settings, kept in step by Connect and Remove, so drawing the
/// sidebar or Settings never asks the Keychain anything. The key itself is read only when a
/// request is about to be sent, off the main actor.
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
    /// The last verified account: plan, balance, reset date.
    var account: ElevenLabsAccount?
    /// The last failure to verify or refresh, in words that can be shown.
    var lastError: String?
    @ObservationIgnored var client: ElevenLabsClient?

    init(store: any ElevenLabsKeyStore, transport: any ElevenLabsTransport, persistsSettings: Bool) {
        self.store = store
        self.transport = transport
        self.persistsSettings = persistsSettings
    }

    /// The running app's: the Keychain and the network.
    static func live() -> ElevenLabsLink {
        ElevenLabsLink(store: ElevenLabsCredential(), transport: URLSessionTransport(), persistsSettings: true)
    }

    /// An app model built with injected settings (tests, previews): nothing real reachable.
    static func inert() -> ElevenLabsLink {
        ElevenLabsLink(
            store: FakeCredentialSource(), transport: UnavailableElevenLabsTransport(),
            persistsSettings: false
        )
    }
}

extension AppModel {

    /// Whether a key is linked. Settings' boolean, never a Keychain query.
    public var elevenLabsLinked: Bool { settings.elevenLabsLinked }

    /// Which ElevenLabs host the key is sent to. Changing it drops the current client; the
    /// next call builds one for the new host.
    public var elevenLabsRegion: ElevenLabsRegion {
        get { settings.elevenLabsRegion }
        set {
            guard newValue != settings.elevenLabsRegion else { return }
            settings.elevenLabsRegion = newValue
            elevenLabsLink.client = nil
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

    /// The client for the linked key and region, or nil when nothing is linked.
    public var elevenLabsClient: ElevenLabsClient? {
        nil
    }

    /// Verifies `key` with the free `GET /v1/user` and stores it only if that works.
    public func linkElevenLabs(key: String) async throws -> ElevenLabsAccount {
        throw ElevenLabsError.network("not implemented yet")
    }

    /// Deletes the key and forgets the account; the pane disappears.
    public func unlinkElevenLabs() {}

    func saveElevenLabsSettings() {
        guard elevenLabsLink.persistsSettings else { return }
        settings.save()
    }
}

/// The ElevenLabs API key, in the Keychain and nowhere else.
///
/// Read only when a request is about to be sent, on a GCD thread — never on the main actor or
/// any other actor, because a freshly built app's first read waits on the Keychain's consent
/// dialog, and everything queued behind a blocked actor would wait with it. Kept in memory
/// after the first read so the dialog is asked once per launch at most.
final class ElevenLabsCredential: ElevenLabsKeyStore, @unchecked Sendable {
    static let service = "dev.siliconoptimizer.credentials"
    static let account = "elevenlabs-api-key"

    func apiKey() async throws -> String? {
        throw ElevenLabsError.credentialUnavailable("not implemented yet")
    }

    func store(_ key: String) async throws {
        throw ElevenLabsError.credentialUnavailable("not implemented yet")
    }

    func remove() async throws {
        throw ElevenLabsError.credentialUnavailable("not implemented yet")
    }
}

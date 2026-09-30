import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Settings → ElevenLabs: its own pane, a region change that never leaves a key pointed at a
/// workspace it does not belong to, and no failure text that carries the key. Every model
/// here has an in-memory key store and a transport that refuses everything.
@Suite("ElevenLabs settings")
@MainActor
struct ShellSettingsTests {

    @Test func elevenLabsHasItsOwnSettingsPaneWhateverTheAdvancedToggleSays() {
        #expect(SettingsView.Pane.elevenLabs.rawValue == "ElevenLabs")
        #expect(SettingsView.Pane.offered(showingAdvanced: false).contains(.elevenLabs))
        #expect(SettingsView.Pane.resolve(remembered: "ElevenLabs", showingAdvanced: false) == .elevenLabs)
    }

    @Test func withNoKeyTheRegionJustChanges() {
        let model = AppModel(settings: .init())
        let connection = ElevenLabsConnectionModel()
        connection.requestRegion(.eu, model: model)
        #expect(model.elevenLabsRegion == .eu)
        #expect(connection.pendingRegionChange == nil)
    }

    /// Global and US-only are one account: the key carries over once the owner says so, and
    /// the account is checked again on the new host.
    @Test func movingBetweenGlobalAndUSOnlyKeepsTheKeyAfterAsking() async {
        let (model, store) = Self.linkedModel()
        let connection = ElevenLabsConnectionModel()
        connection.requestRegion(.us, model: model)
        #expect(model.elevenLabsRegion == .global)
        #expect(connection.pendingRegionChange?.to == .us)
        #expect(connection.pendingRegionChange?.keyCarriesOver == true)

        await connection.switchRegionKeepingKey(model: model)
        #expect(model.elevenLabsRegion == .us)
        #expect(model.elevenLabsLinked)
        #expect(store.key == Self.key)
        #expect(store.writes == 0)
        #expect(connection.pendingRegionChange == nil)
    }

    /// Each residency region is its own workspace with its own key: the only way offered is to
    /// remove the key and enter that region's.
    @Test func aResidencyRegionNeedsItsOwnKey() async {
        for (from, to) in [(ElevenLabsRegion.global, ElevenLabsRegion.eu), (.us, .india), (.eu, .singapore), (.singapore, .global)] {
            let (model, store) = Self.linkedModel(region: from)
            let connection = ElevenLabsConnectionModel()
            connection.requestRegion(to, model: model)
            #expect(connection.pendingRegionChange?.keyCarriesOver == false, "\(from) → \(to)")
            // Keeping the key is not on offer.
            await connection.switchRegionKeepingKey(model: model)
            #expect(model.elevenLabsRegion == from)
            #expect(store.key == Self.key)
            connection.cancelRegionChange()
            #expect(connection.pendingRegionChange == nil)
            #expect(model.elevenLabsRegion == from)
        }
    }

    @Test func removingTheKeyToSwitchRegionRemovesItAndEndsOnTheNewRegion() async {
        let (model, store) = Self.linkedModel()
        let connection = ElevenLabsConnectionModel()
        connection.requestRegion(.eu, model: model)
        connection.removeKeyAndSwitchRegion(model: model)
        #expect(model.elevenLabsRegion == .eu)
        #expect(!model.elevenLabsLinked)
        #expect(connection.pendingRegionChange == nil)
        await model.elevenLabsLink.pendingRemoval?.value
        #expect(store.key == nil)
    }

    // MARK: - Connect

    /// A key ElevenLabs refuses is not stored, the pane stays hidden, and the words shown do
    /// not include it.
    @Test func aRejectedKeyStoresNothing() async {
        let (model, transport, store) = Self.model(linkedKey: nil) { _ in
            .jsonText(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#, status: 401)
        }
        defer { Self.clean(model, transport) }
        let connection = ElevenLabsConnectionModel()
        let key = Self.candidate
        #expect(await connection.connect(key: key, model: model) == false)
        #expect(store.writes == 0)
        #expect(store.key == nil)
        #expect(!model.elevenLabsLinked)
        #expect(connection.failure?.contains("did not accept this key") == true)
        #expect(!(connection.failure ?? "").contains(key))
        #expect(transport.requests.first?.url.host == "api.elevenlabs.io")
        #expect(transport.requests.first?.header("xi-api-key") == key)
    }

    /// No network while replacing a key: the one already linked stays linked and stored.
    @Test func aNetworkFailureKeepsTheKeyAlreadyLinked() async {
        let (model, transport, store) = Self.model(linkedKey: Self.key) { _ in
            throw ElevenLabsError.network("The Internet connection appears to be offline.")
        }
        defer { Self.clean(model, transport) }
        let connection = ElevenLabsConnectionModel()
        #expect(await connection.connect(key: Self.candidate, model: model) == false)
        #expect(store.key == Self.key)
        #expect(store.writes == 0)
        #expect(model.elevenLabsLinked)
        #expect(connection.failure?.contains("still connected") == true)
    }

    /// Connect verifies against the region chosen in the picker, stores the key only then,
    /// and starts the pane fresh for the account.
    @Test func aGoodKeyIsVerifiedOnTheChosenRegionThenStored() async {
        let (model, transport, store) = Self.model(linkedKey: nil, handler: Self.accountAnswer)
        defer { Self.clean(model, transport) }
        let connection = ElevenLabsConnectionModel()
        connection.requestRegion(.eu, model: model)
        model.elevenLabsPane.record(.json(["old": true], ElevenLabsMeta(status: 200)),
                                    operation: ShellInterfaceTests.operation(id: "old"))
        #expect(await connection.connect(key: "  \(Self.candidate)\n", model: model))
        #expect(store.key == Self.candidate)
        #expect(model.elevenLabsLinked)
        #expect(model.elevenLabsRegion == .eu)
        #expect(model.elevenLabsAccount?.tier == "creator")
        #expect(Set(transport.requests.compactMap(\.url.host)) == ["api.eu.residency.elevenlabs.io"])
        #expect(model.elevenLabsPane.recents.isEmpty)
        #expect(connection.connected)
        #expect(connection.failure == nil)
    }

    @Test func disconnectingWhileOnThePaneMovesToSettingsAndForgetsTheSession() async {
        let (model, store) = Self.linkedModel()
        model.selectedTab = .elevenLabs
        model.elevenLabsPane.record(.json(["x": 1], ElevenLabsMeta(status: 200)),
                                    operation: ShellInterfaceTests.operation(id: "x"))
        ElevenLabsConnectionModel().remove(model: model)
        #expect(model.selectedTab == .settings)
        #expect(!model.elevenLabsLinked)
        #expect(model.elevenLabsPane.recents.isEmpty)
        await model.elevenLabsLink.pendingRemoval?.value
        #expect(store.key == nil)
    }

    @Test func pickingTheSameRegionAsksNothing() {
        let (model, _) = Self.linkedModel()
        let connection = ElevenLabsConnectionModel()
        connection.requestRegion(.global, model: model)
        #expect(connection.pendingRegionChange == nil)
    }

    @Test func aBlankKeyIsNotSent() async {
        let (model, store) = Self.linkedModel()
        let connection = ElevenLabsConnectionModel()
        #expect(await connection.connect(key: "  \n", model: model) == false)
        #expect(connection.failure == nil)
        #expect(store.writes == 0)
    }

    /// Whatever ElevenLabs or the network says back, the words shown never include the key —
    /// not even a key that does not look like one.
    @Test func aFailedConnectNeverShowsTheKey() {
        let odd = "not-shaped-like-a-key-12345"
        let shaped = "sk_" + String(repeating: "7f", count: 16)
        for key in [odd, shaped] {
            let errors: [ElevenLabsError] = [
                .api(status: 401, code: "invalid_api_key", message: "Invalid API key: \(key)", requestID: "r1"),
                .network("could not send \(key)"),
                .credentialUnavailable("\(key) locked"),
            ]
            for error in errors {
                let text = ElevenLabsConnectionModel.describe(error, key: key, region: .eu)
                #expect(!text.contains(key), "\(error)")
            }
        }
        let rejected = ElevenLabsConnectionModel.describe(
            ElevenLabsError.api(status: 401, code: nil, message: "Invalid API key", requestID: nil), key: odd, region: .eu
        )
        #expect(rejected.contains("EU data residency did not accept this key"))
        #expect(rejected.contains("nothing was saved"))
    }

    static let key = "fixture-key-not-real-0001"
    static let candidate = "fixture-key-candidate-0002"

    /// An app model with a fake transport answering through `handler` and an in-memory key
    /// store; its output folder is the scratch one every test model gets.
    static func model(
        linkedKey: String?, handler: @escaping @Sendable (ElevenLabsRequest) async throws -> FakeElevenLabsTransport.Reply
    ) -> (AppModel, FakeElevenLabsTransport, FakeCredentialSource) {
        var settings = Settings()
        settings.elevenLabsLinked = linkedKey != nil
        let model = AppModel(settings: settings)
        let transport = FakeElevenLabsTransport(handler: handler)
        let store = FakeCredentialSource(key: linkedKey)
        model.elevenLabsLink.transport = transport
        model.elevenLabsLink.store = store
        return (model, transport, store)
    }

    nonisolated static func accountAnswer(_ request: ElevenLabsRequest) -> FakeElevenLabsTransport.Reply {
        switch request.url.path {
        case "/v1/user": .json(["user_id": "user-1", "subscription": ["tier": "creator"]])
        case "/v1/user/subscription":
            .json(["tier": "creator", "character_count": 10, "character_limit": 100_000, "status": "active"])
        default: .jsonText(#"{"detail":"unexpected"}"#, status: 404)
        }
    }

    static func clean(_ model: AppModel, _ transport: FakeElevenLabsTransport) {
        TemporaryFileSink.removeScratch(model.elevenLabsOutputDirectory)
        transport.removeTemporaryFiles()
    }

    static func linkedModel(region: ElevenLabsRegion = .global) -> (AppModel, FakeCredentialSource) {
        var settings = Settings()
        settings.elevenLabsLinked = true
        settings.elevenLabsRegion = region
        let model = AppModel(settings: settings)
        let store = FakeCredentialSource(key: key)
        model.elevenLabsLink.store = store
        return (model, store)
    }
}

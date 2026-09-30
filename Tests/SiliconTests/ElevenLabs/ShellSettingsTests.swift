import Foundation
import Testing
import SiliconElevenLabs
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

    @Test func removingTheKeyToSwitchRegionEndsOnTheNewRegion() {
        let (model, _) = Self.linkedModel()
        let connection = ElevenLabsConnectionModel()
        connection.requestRegion(.eu, model: model)
        connection.removeKeyAndSwitchRegion(model: model)
        #expect(model.elevenLabsRegion == .eu)
        #expect(connection.pendingRegionChange == nil)
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

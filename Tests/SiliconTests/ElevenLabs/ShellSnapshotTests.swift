import AppKit
import Foundation
import SwiftUI
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// The pane, Settings and the Explorer drawn with made-up data, light and dark, narrow and
/// wide. Run with `ELEVENLABS_SNAPSHOT_DIR=<scratch folder>` to get PNGs to look at; without
/// it they are drawn and checked for content, and nothing is written. Every model here has
/// a transport that refuses everything, so nothing drawn can reach ElevenLabs.
@Suite("ElevenLabs shell snapshots", .serialized)
@MainActor
struct ShellSnapshotTests {

    @Test func thePaneOnASection() throws {
        let model = Self.linkedModel()
        model.elevenLabsPane.open(.soundEffects)
        try Self.both(ElevenLabsPane().environment(model), name: "pane-section")
    }

    @Test func thePaneOnTheExplorerWithAFormFilledIn() throws {
        let model = Self.linkedModel()
        model.elevenLabsPane.openInExplorer("text_to_speech_full")
        let session = try #require(model.elevenLabsPane.explorer(context: .app(model)).session(for: "text_to_speech_full"))
        session.form.nodes.first { $0.field.name == "voice_id" }?.text = "JBFqnCBsd6RMkjVDRZzb"
        session.form.nodes.first { $0.field.name == "text" }?.text = "The first rule of the Explorer: every operation, one form each."
        try Self.both(ElevenLabsPane().environment(model), name: "pane-explorer", height: 900)
    }

    @Test func theExplorerListNarrowedToDestructiveOperations() throws {
        let model = Self.linkedModel()
        model.elevenLabsPane.open(.explorer)
        let explorer = model.elevenLabsPane.explorer(context: .app(model))
        explorer.toggle(.destructive)
        explorer.search = "voice"
        try Self.both(ElevenLabsPane().environment(model), name: "pane-explorer-list")
    }

    @Test func thePaneWithRecentResultsAndARefusedKey() throws {
        let model = Self.linkedModel()
        let pane = model.elevenLabsPane
        pane.record(.json(["models": [["model_id": "eleven_v3", "can_do_text_to_speech": true],
                                      ["model_id": "eleven_flash_v2_5", "can_do_text_to_speech": true]]],
                          ElevenLabsMeta(status: 200, requestID: "req-7f3a")),
                    operation: try #require(ElevenLabsCatalog.operation("get_models")))
        pane.record(.text("WEBVTT\n\n00:00.000 --> 00:02.000\nHello there.", ElevenLabsMeta(status: 200, characterCost: 42)),
                    operation: try #require(ElevenLabsCatalog.operation("get_models")), title: "Subtitles")
        pane.showRecents()
        pane.connectionProblem = .keyRejected("ElevenLabs answered 401 (invalid_api_key): Invalid API key")
        try Self.both(ElevenLabsPane().environment(model), name: "pane-recents-refused")
    }

    @Test func thePaneWhenNotConnected() throws {
        try Self.both(ElevenLabsPane().environment(AppModel(settings: .init())), name: "pane-unlinked", height: 420)
    }

    @Test func settingsLinkedAndNot() throws {
        let linked = Self.linkedModel()
        try Self.both(Self.settings(linked), name: "settings-linked", height: 760)
        try Self.both(Self.settings(AppModel(settings: .init())), name: "settings-unlinked", height: 420)
    }

    @Test func theSheets() throws {
        let delete = try #require(ElevenLabsCatalog.operation("delete_voice"))
        let request = ElevenLabsConfirmationRequest.make(
            for: delete, subject: "the voice “Narrator”",
            call: ElevenLabsCallDescription(operationID: delete.id, method: "DELETE",
                                            url: "https://api.elevenlabs.io/v1/voices/JBFqnCBsd6RMkjVDRZzb",
                                            headers: [:], body: nil)
        )
        let calls = try #require(ElevenLabsCatalog.operation("create_batch_call"))
        let realWorld = ElevenLabsConfirmationRequest.make(
            for: calls, subject: "12 phone calls with “Front desk”",
            consequence: "ElevenLabs will call 12 numbers now, with the agent “Front desk”. Each call is billed."
        )
        let sheets = VStack(alignment: .leading, spacing: 20) {
            ElevenLabsRiskConfirmation(request: request, onConfirm: {}, onCancel: {})
            ElevenLabsRiskConfirmation(request: realWorld, onConfirm: {}, onCancel: {})
            ElevenLabsRegionChangeSheet(
                change: .init(from: .global, to: .eu, keyCarriesOver: false),
                onSwitch: {}, onRemoveKey: {}, onCancel: {}
            )
        }
        .padding(20)
        let images = try ElevenLabsSnapshot.render(sheets, name: "sheets", width: .narrow, height: 820)
        #expect(images.allSatisfy(ElevenLabsSnapshot.hasContent))
    }

    @Test func resultsAndAShownOnceSecret() throws {
        let operation = try #require(ElevenLabsCatalog.operation("create_service_account_api_key"))
        let answer = ElevenLabsResult.json(
            ["xi-api-key": .string("fixture-" + String(repeating: "x", count: 24)), "key_id": "key-01"],
            ElevenLabsMeta(status: 200)
        )
        let view = ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ElevenLabsCredentialReveal(credential: .init(operation: operation, result: answer), onDismiss: {})
                ElevenLabsResultView(result: ElevenLabsRevealedCredential.masked(answer, for: operation), operation: operation)
                ElevenLabsResultView(result: .events([["type": "agent_response", "text": "Hi!"], ["type": "end"]],
                                                     ElevenLabsMeta(status: 200)))
            }
            .padding(20)
        }
        try Self.both(view, name: "results", height: 640)
    }

    // MARK: - Helpers

    static func both(_ view: some View, name: String, height: CGFloat = 720) throws {
        for width in ElevenLabsSnapshot.Width.allCases {
            let images = try ElevenLabsSnapshot.render(view, name: name, width: width, height: height)
            #expect(images.count == 2)
            #expect(images.allSatisfy(ElevenLabsSnapshot.hasContent), "\(name) \(width) drew nothing")
        }
    }

    static func settings(_ model: AppModel) -> some View {
        Form {
            ElevenLabsSettingsSection(draft: .constant(""))
        }
        .formStyle(.grouped)
        .environment(model)
    }

    /// Linked, with an account as the free check would have left it. The transport refuses
    /// everything, as for every test model.
    static func linkedModel() -> AppModel {
        var settings = Settings()
        settings.elevenLabsLinked = true
        let model = AppModel(settings: settings)
        model.elevenLabsLink.account = ElevenLabsAccount(
            userID: "user-1", firstName: "Sam", tier: "creator", status: "active",
            characterCount: 38_400, characterLimit: 100_000,
            nextResetAt: Date(timeIntervalSince1970: 1_791_331_200), concurrencyLimit: 5
        )
        return model
    }
}

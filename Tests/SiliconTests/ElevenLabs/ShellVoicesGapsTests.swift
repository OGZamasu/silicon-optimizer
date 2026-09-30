import AppKit
import Foundation
import SwiftUI
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// What the voices/studio builder asked the shared parts for: a voice picker that needs no app
/// model when given its voices, and cost notes that can say money or the caller's own words.
@Suite("ElevenLabs shared parts, second round")
@MainActor
struct ShellVoicesGapsTests {

    // MARK: - Shared parts the voices builder asked for

    @Test func aVoicePickerGivenItsVoicesNeedsNoAppModel() {
        let directory = ElevenLabsVoiceDirectory(client: { nil })
        directory.set([ElevenLabsVoice(id: "v1", name: "Narrator")])
        let host = NSHostingView(rootView: ElevenLabsVoicePicker(selection: .constant("v1"), directory: directory))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        host.layoutSubtreeIfNeeded()
        #expect(host.frame.width == 400)
    }

    @Test func aPaidOrderSaysMoneyAndACallerCanSayItsOwn() throws {
        let submit = try #require(ElevenLabsCatalog.operation("public_submit_order"))
        #expect(submit.billable)
        #expect(ElevenLabsCostNote.text(for: submit) == "Charges money to your workspace — not credits.")
        #expect(ElevenLabsCostNote.text(for: submit, message: "Charges $120.00 to your workspace.") == "Charges $120.00 to your workspace.")
        let models = try #require(ElevenLabsCatalog.operation("get_models"))
        #expect(ElevenLabsCostNote.text(for: models, message: "Free") == "Free")
        #expect(ElevenLabsSection.productions.subtitle.count > 30)
        #expect(ElevenLabsSection.flows.subtitle.count > 30)
    }
}

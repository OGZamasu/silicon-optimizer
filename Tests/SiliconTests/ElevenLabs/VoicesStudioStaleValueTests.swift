import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// The follow-ups critic's R1: two ways a stale value could still be saved onto an item.
///
/// (a) A details read asked before a change answered lands after the change's own fetch — on
///     another runner, so nothing abandons it — and its older values took the screen and the
///     form; the next Save then wrote them back.
/// (b) Save pressed before the open item's details arrived sent the list row's values for every
///     field the owner had not touched.
///
/// Every answer that must come late is held on a signal, never on a delay.
@Suite("ElevenLabs voices & studio — stale values", .timeLimit(.minutes(1)))
@MainActor
struct VoicesStudioStaleValueTests {
    typealias Signals = VoicesStudioFollowupTests.Signals

    func body(_ fixture: VoicesStudioFixture, _ operationID: String) -> String {
        fixture.sent(operationID).last.map { String(decoding: $0.body, as: UTF8.self) } ?? ""
    }

    @MainActor final class Done { var value = false }

    /// Runs `action`, declining any question it puts up, so a regression that asks fails the
    /// test instead of waiting for an answer for ever.
    func declining(_ actions: VoicesStudioActions, _ action: @escaping @MainActor () async -> Void) async throws {
        let done = Done()
        let task = Task { await action(); done.value = true }
        try await voicesStudioWait {
            if actions.presentedQuestion != nil { actions.answer(false) }
            return done.value
        }
        await task.value
    }

    // MARK: - (a) a read asked before a change, answering after it

    /// Productions: a slow read of order A, then A renamed; the older read answers last and is
    /// dropped — the name field keeps the new name.
    @Test func anOrderReadAskedBeforeARenameIsDroppedWhenItAnswersAfter() async throws {
        let signals = Signals()
        let order = Self.order
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "public_update_order":
                return .json(["order_id": "o-a"])
            case "public_get_order":
                if signals.note("get") == 1 {
                    await signals.wait(for: "saved")
                    return .json(order("Old name"))
                }
                return .json(order("New name"))
            case "public_get_available_languages":
                return .json(["languages": []])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        let open = try #require(ProductionsOrder(json: order("Old name")))
        model.load(orders: [open], selected: open)
        let reading = Task { await model.select("o-a") }
        try await voicesStudioWait { fixture.sent("public_get_order").count == 1 }
        model.rename = "New name"
        await model.saveName()
        signals.note("saved")
        await reading.value
        #expect(model.rename == "New name", "the older read put the old name back in the field")
        #expect(model.selected?.name == "New name")
    }

    nonisolated static func order(_ name: String) -> JSONValue {
        ["order_id": "o-a", "name": .string(name), "state": "open", "sandbox": false, "items": []]
    }

    /// Pronunciation: a slow read of dictionary A, then A renamed; the older read is dropped.
    @Test func aDictionaryReadAskedBeforeARenameIsDroppedWhenItAnswersAfter() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "patch_pronunciation_dictionary":
                return .json(["id": "d-a"])
            case "get_pronunciation_dictionary_metadata":
                if signals.note("get") == 1 {
                    await signals.wait(for: "saved")
                    return .json(VoicesStudioFollowupTests.dictionary("d-a", name: "Old name"))
                }
                return .json(VoicesStudioFollowupTests.dictionary("d-a", name: "New name"))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        let a = try #require(PronunciationDictionary(json: VoicesStudioFollowupTests.dictionary("d-a", name: "Old name")))
        model.load(dictionaries: [a], selected: a)
        let reading = Task { await model.select("d-a") }
        try await voicesStudioWait { fixture.sent("get_pronunciation_dictionary_metadata").count == 1 }
        model.rename = "New name"
        await model.saveName()
        signals.note("saved")
        await reading.value
        #expect(model.rename == "New name", "the older read put the old name back in the field")
        #expect(model.selected?.name == "New name")
    }

    // MARK: - (b) Save before the open item's details are in

    /// Dictionary A open (its name in the rename field); B chosen, its details slow: the rename
    /// field no longer holds A's name, so Rename cannot give B the name of A.
    @Test func choosingAnotherDictionaryDoesNotLeaveTheFirstOnesNameToSend() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "patch_pronunciation_dictionary":
                return .json(["id": "d-b"])
            case "get_pronunciation_dictionary_metadata":
                await signals.wait(for: "checked")
                return .json(VoicesStudioFollowupTests.dictionary("d-b", name: "Dict B"))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        let a = try #require(PronunciationDictionary(json: VoicesStudioFollowupTests.dictionary("d-a", name: "Dict A")))
        let b = try #require(PronunciationDictionary(json: VoicesStudioFollowupTests.dictionary("d-b", name: "Dict B")))
        model.load(dictionaries: [a, b], selected: a)
        #expect(model.rename == "Dict A")
        let choosing = Task { await model.select("d-b") }
        try await voicesStudioWait { fixture.sent("get_pronunciation_dictionary_metadata").count == 1 }
        #expect(model.rename == "Dict B", "B's rename field still holds A's name: “\(model.rename)”")
        await model.saveName()
        #expect(!body(fixture, "patch_pronunciation_dictionary").contains("Dict A"), "B was renamed to A's name")
        signals.note("checked")
        await choosing.value
    }

    // MARK: - Webhooks: no editor from an old row

}

import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Productions: media registered from a file or a link (with what the spec requires for a
/// link), items shaped for their kind of work, languages from the pairs ElevenLabs offers,
/// and a submit that states what it charges.
@Suite("ElevenLabs Productions section")
@MainActor
struct VoicesStudioProductionsTests {

    static func order(_ id: String, state: String = "open", total: Double? = 240, sandbox: Bool = false,
                      items: [JSONValue] = []) -> JSONValue {
        var order: [String: JSONValue] = ["order_id": .string(id), "name": "Launch video", "state": .string(state),
                                          "sandbox": .bool(sandbox), "created_at": "2026-09-22T10:00:00Z",
                                          "items": .array(items)]
        if let total { order["total_amount_usd"] = .number(total) }
        return .object(order)
    }

    static let dubItem: JSONValue = [
        "item_id": "proditem_1", "quote": ["amount_usd": 240],
        "item": ["kind": "dub", "media_id": "prodmedia_1", "source_language": "en",
                 "destination_languages": ["es-ES", "fr-FR"], "include_captions": true, "include_source_captions": false],
    ]

    @Test func eachKindOfItemTakesTheShapeTheSpecGivesIt() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let media = "prodmedia_" + String(repeating: "a", count: 26)
        var draft = ProductionsItemDraft(kind: "dub", mediaIDs: [media], sourceLanguage: "en", destinationLanguages: ["es-ES"])
        draft.includeCaptions = true
        let dub = ProductionsSectionModel.itemArguments(orderID: "o1", draft: draft)
        #expect(dub.1.isEmpty)
        #expect(dub.0["request"]?["item"]["media_id"] == .string(media))
        #expect(dub.0["request"]?["item"]["captions_sdh"] == false)
        #expect(fixture.client.validate("public_upsert_order_item", arguments: dub.0).isEmpty)

        draft.kind = "subtitles"
        draft.sdh = true
        let subtitles = ProductionsSectionModel.itemArguments(orderID: "o1", draft: draft)
        #expect(subtitles.0["request"]?["item"]["media_ids"] == [.string(media)])
        #expect(subtitles.0["request"]?["item"]["media_id"] == .null)
        #expect(fixture.client.validate("public_upsert_order_item", arguments: subtitles.0).isEmpty)

        draft.kind = "transcription"
        draft.itemID = "proditem_" + String(repeating: "b", count: 26)
        let transcription = ProductionsSectionModel.itemArguments(orderID: "o1", draft: draft)
        #expect(transcription.0["request"]?["item"]["destination_languages"] == .null)
        #expect(transcription.0["request"]?["item_id"] == .string(draft.itemID!))
        #expect(fixture.client.validate("public_upsert_order_item", arguments: transcription.0).isEmpty)

        let empty = ProductionsSectionModel.itemArguments(orderID: "o1", draft: ProductionsItemDraft(kind: "dub"))
        #expect(empty.1 == ["Register or name the media first.", "Choose the source language.",
                            "Choose at least one language to dub into."])
    }

    @Test func mediaFromALinkNeedsItsTypeAndName() async throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        model.load(orders: [], selected: try #require(ProductionsOrder(json: Self.order("o1"))))
        model.mediaURL = "https://example.com/episode.mp4"
        model.mediaLanguage = "en"
        let missing = try #require(model.registerArguments())
        #expect(missing.2 == ["A link needs its content type and a file name, as the spec requires."])
        model.mediaURLType = "video/mp4"
        model.mediaURLName = "episode.mp4"
        let complete = try #require(model.registerArguments())
        #expect(complete.2.isEmpty)
        #expect(fixture.client.validate("public_register_media", arguments: complete.0, files: complete.1).isEmpty)
    }

    @Test func registeredMediaIsLookedUpAndChosenForTheItem() async throws {
        let scratch = try VoicesStudioScratch()
        defer { scratch.remove() }
        let fixture = VoicesStudioFixture([
            "public_register_media": [.json(["media_id": "prodmedia_1"])],
            "public_get_media_info": [.json(["media_id": "prodmedia_1", "name": "episode.mp4", "content_type": "video/mp4",
                                              "language": "en", "signed_url": "https://files.example/episode.mp4?sig=x"])],
        ])
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        model.load(orders: [], selected: try #require(ProductionsOrder(json: Self.order("o1"))))
        model.mediaFile = [try scratch.file("episode.mp4")]
        model.mediaLanguage = "en"
        await model.registerMedia()
        #expect(fixture.multipart("public_register_media").contains(#"name="media"; filename="episode.mp4""#))
        #expect(model.orderMedia.map(\.name) == ["episode.mp4"])
        #expect(model.item.mediaIDs == ["prodmedia_1"])
    }

    @Test func pairedLanguagesOfferTheDestinationsOfTheChosenSource() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        model.load(orders: [], languages: ["kind": "pair", "language_pairs": [
            ["source_language": ["code": "en", "label": "English"],
             "destination_languages": [["code": "es-ES", "label": "Spanish (Spain)"], ["code": "fr-FR", "label": "French"]]],
            ["source_language": ["code": "de", "label": "German"],
             "destination_languages": [["code": "en", "label": "English"]]],
        ]])
        #expect(model.languages["dub"]?.map(\.code) == ["en", "de"])
        model.item.sourceLanguage = "de"
        #expect(model.destinationChoices().map(\.code) == ["en"])
        model.item.sourceLanguage = "en"
        #expect(model.destinationChoices().map(\.label) == ["Spanish (Spain)", "French"])
    }

    @Test func submittingIsARealWorldChargeThatStatesTheAmount() async throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        model.load(orders: [], selected: try #require(ProductionsOrder(json: Self.order("o1", items: [Self.dubItem]))))
        let runner = try #require(model.actions.runner("public_submit_order"))
        #expect(runner.operation.billable)
        let asked = try await voicesStudioConfirm(model.actions.runner("public_submit_order"), answer: false) {
            await model.submit()
        }
        #expect(asked?.risk == .realWorld)
        #expect(asked?.title.contains("“Launch video”") == true)
        #expect(asked?.consequence.contains("$240.00") == true)
        #expect(asked?.consequence.contains("1 item goes") == true)
        #expect(fixture.transport.recorded.isEmpty)

        model.load(orders: [], selected: try #require(ProductionsOrder(json: Self.order("o2", sandbox: true, items: [Self.dubItem]))))
        #expect(model.submitConsequence.hasPrefix("This is a sandbox order: nothing is charged."))
    }

    @Test func theOrderListSendsEachStatusAndPagesByOffset() async throws {
        let fixture = VoicesStudioFixture(["public_list_orders": [.json(["orders": [Self.order("o1")]])]])
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        model.statusFilter = ["open", "paid"]
        await model.refresh()
        let query = fixture.query("public_list_orders")
        #expect(query.filter { $0.0 == "status" }.map(\.1) == ["open", "paid"])
        #expect(query.contains { $0 == ("offset", "0") })
        #expect(model.orders.map(\.name) == ["Launch video"])
        #expect(!model.hasMore)
    }
}

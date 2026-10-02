import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Flows: every model the spec lists is offered with its own fields, a generation goes out
/// with its model's constant and the chosen voice, statuses and cursors page the list, and a
/// template run carries its inputs by port.
@Suite("ElevenLabs Flows section")
@MainActor
struct VoicesStudioFlowsTests {

    @Test func everyKindOffersEveryModelOfItsUnion() {
        for kind in FlowsKind.allCases {
            let variants = FlowsModelVariant.variants(of: kind.createID)
            let count = ElevenLabsCatalog.operation(kind.createID)?.body?.schema["oneOf"].arrayValue?.count
            #expect(!variants.isEmpty, "\(kind)")
            #expect(variants.count == count, "\(kind): a model without a model_id constant would be unreachable")
            #expect(Set(variants.map(\.modelID)).count == variants.count)
        }
        let image = FlowsModelVariant.variants(of: "create_image_generation")
        #expect(image.first?.name == "OpenAI GPT Image 1")
    }

    @Test func aSpeechGenerationCarriesItsModelTheTextAndTheChosenVoice() async throws {
        let fixture = VoicesStudioFixture([
            "create_text_to_speech_generation": [.json(["id": "gen1", "status": "pending"])],
        ])
        defer { fixture.clean() }
        let model = FlowsSectionModel(environment: fixture.environment)
        model.choose("eleven_multilingual_v2", for: .speech)
        let form = try #require(model.form(.speech))
        #expect(!form.fields.contains { $0.name == "voice" })
        form.nodes.first { $0.field.name == "text" }?.text = "Hello from Flows."
        #expect(model.createArguments(.speech)?.problems == ["Choose the voice to speak with."])
        model.speechVoiceID = "v1"
        let built = try #require(model.createArguments(.speech))
        #expect(built.problems.isEmpty)
        #expect(built.arguments["model_id"] == "eleven_multilingual_v2")
        #expect(fixture.client.validate("create_text_to_speech_generation", arguments: built.arguments).isEmpty)
        #expect(model.estimatedCharacters(.speech) == 17)

        await model.create(.speech)
        #expect(fixture.body("create_text_to_speech_generation") == [
            "model_id": "eleven_multilingual_v2", "text": "Hello from Flows.", "voice": "v1",
        ])
        #expect(model.generations[.speech]?.first?.id == "gen1")
    }

    @Test func anImageModelsFormHoldsOnlyItsOwnFields() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = FlowsSectionModel(environment: fixture.environment)
        model.choose("gemini-2.5-flash-image", for: .image)
        let form = try #require(model.form(.image))
        let names = Set(form.fields.map(\.name))
        #expect(names.contains("prompt"))
        #expect(!names.contains("background"), "GPT Image's background is not a Gemini field")
        form.nodes.first { $0.field.name == "prompt" }?.text = "A lighthouse at dusk"
        let built = try #require(model.createArguments(.image))
        #expect(built.problems.isEmpty)
        #expect(built.arguments["model_id"] == "gemini-2.5-flash-image")
        #expect(fixture.client.validate("create_image_generation", arguments: built.arguments).isEmpty)
    }

    @Test func everyVideoModelHasItsOwnConfigurationForm() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = FlowsSectionModel(environment: fixture.environment)
        let variants = model.variants(.video)
        #expect(!variants.isEmpty)

        for variant in variants {
            model.choose(variant.modelID, for: .video)
            let form = try #require(model.form(.video))
            let supported = Set(variant.schema["properties"].objectValue?.keys.map { $0 } ?? [])
                .subtracting(["model_id"])
            #expect(Set(form.fields.map(\.name)) == supported, "\(variant.modelID) must show its API-supported controls")
        }
    }

    @Test func theListFiltersByStatusPagesByCursorAndChecksOne() async throws {
        let fixture = VoicesStudioFixture([
            "list_video_generations": [
                .json(["generations": [["id": "g1", "status": "generating"]], "next_cursor": "c2", "has_more": true]),
                .json(["generations": [["id": "g2", "status": "failed", "failure_reason": "content_policy",
                                        "error_message": "Blocked by policy"]], "next_cursor": "", "has_more": false]),
            ],
            "get_video_generation": [.json(["id": "g1", "status": "completed", "content_url": "https://files.example/g1.mp4",
                                            "content_mime_type": "video/mp4"])],
        ])
        defer { fixture.clean() }
        let model = FlowsSectionModel(environment: fixture.environment)
        model.statusFilter[.video] = "generating"
        await model.refresh(.video)
        #expect(fixture.query("list_video_generations").contains { $0 == ("status", "generating") })
        #expect(model.cursors[.video] == "c2")
        await model.loadMore(.video)
        #expect(fixture.query("list_video_generations").contains { $0 == ("cursor", "c2") })
        #expect(model.generations[.video]?.map(\.id) == ["g1", "g2"])
        #expect(model.generations[.video]?.last?.failure == "Blocked by policy")
        #expect(model.cursors[.video] == nil)
        await model.check(model.generations[.video]![0], kind: .video)
        #expect(model.generations[.video]?.first?.contentURL?.host == "files.example")
    }

    @Test func aTemplateRunSendsTextPortsAsTextAndTheRestAsJSON() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = FlowsSectionModel(environment: fixture.environment)
        let template = try #require(FlowsTemplate(json: [
            "id": "t1", "name": "Product video", "has_more_versions": false,
            "versions": [["version_id": "ver2", "published_at_unix": 1_780_000_000, "is_latest": true,
                          "inputs": [["id": "script", "content_schema": ["type": "string"]],
                                     ["id": "settings", "content_schema": ["type": "object"]]],
                          "outputs": [["id": "video", "content_schema": ["type": "string"]]]]],
        ]))
        model.load(templates: [template], open: template)
        model.inputs = ["script": "Meet the new lamp.", "settings": "{not json"]
        #expect(model.runArguments()?.1 == ["The input “settings” is not valid JSON."])
        model.inputs["settings"] = #"{"length": 15}"#
        model.notifyWebhooks = true
        let (arguments, problems) = try #require(model.runArguments())
        #expect(problems.isEmpty)
        #expect(arguments["inputs"] == ["script": "Meet the new lamp.", "settings": ["length": 15]])
        #expect(arguments["version_id"] == "latest")
        #expect(arguments["webhook"] == ["type": "all"])
        #expect(fixture.client.validate("create_public_template_run", arguments: arguments).isEmpty)
    }
}

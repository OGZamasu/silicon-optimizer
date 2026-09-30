import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Audio Native: a player made from an article file with its voice, look and dictionaries,
/// the embed code kept, a project's settings read, and its content replaced from a file or
/// its page.
@Suite("ElevenLabs Audio Native section")
@MainActor
struct VoicesStudioAudioNativeTests {

    static let settings: JSONValue = [
        "enabled": true, "snapshot_id": "snap1",
        "settings": ["title": "Why roads are long", "image": "", "author": "A. Writer", "small": false,
                     "text_color": "#1A1A1A", "background_color": "#FFFFFF", "sessionization": 0,
                     "status": "ready", "audio_url": "https://files.example/article.mp3"],
    ]

    @Test func aPlayerIsMadeFromAnArticleAndKeepsItsEmbedCode() async throws {
        let scratch = try VoicesStudioScratch()
        defer { scratch.remove() }
        let fixture = VoicesStudioFixture([
            "create_audio_native_project": [.json(["project_id": "an1", "converting": true,
                                                   "html_snippet": "<div id=\"elevenlabs-audionative-widget\"></div>"])],
            "get_audio_native_project_settings_endpoint": [.json(Self.settings)],
        ])
        defer { fixture.clean() }
        let model = AudioNativeSectionModel(environment: fixture.environment)
        #expect(AudioNativeSectionModel.createArguments(model.draft).2 == [
            "Give the project a name.", "Choose the article: a .txt or .html file.",
        ])
        model.draft.name = "Roads"
        model.draft.file = [try scratch.file("article.html", bytes: 2_400)]
        model.draft.voiceID = "v1"
        model.draft.textColor = "#1A1A1A"
        model.draft.dictionaries = [StudioDictionaryLocator(id: "d1", versionID: "ver1")]
        let (arguments, files, problems) = AudioNativeSectionModel.createArguments(model.draft)
        #expect(problems.isEmpty)
        #expect(fixture.client.validate("create_audio_native_project", arguments: arguments, files: files).isEmpty)

        await model.create()
        let body = fixture.multipart("create_audio_native_project")
        #expect(body.contains(#"name="file"; filename="article.html""#))
        #expect(body.contains(#"name="voice_id""#))
        #expect(body.contains(#"{"pronunciation_dictionary_id":"d1","version_id":"ver1"}"#))
        #expect(model.snippet?.contains("audionative") == true)
        #expect(model.converting)
        #expect(model.projectID == "an1")
        #expect(model.settings?.title == "Why roads are long")
        #expect(model.settings?.audioURL?.host == "files.example")
    }

    @Test func creatingAPlayerSaysItUsesCredits() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = AudioNativeSectionModel(environment: fixture.environment)
        for id in ["create_audio_native_project", "audio_native_project_update_content_endpoint",
                   "audio_native_update_content_from_url"] {
            let runner = try #require(model.actions.runner(id))
            #expect(runner.operation.billable, "\(id)")
            #expect(runner.costNote != nil)
        }
    }

    @Test func contentIsReplacedFromAFileOrFromItsPage() async throws {
        let scratch = try VoicesStudioScratch()
        defer { scratch.remove() }
        let fixture = VoicesStudioFixture([
            "audio_native_project_update_content_endpoint": [.json(["project_id": "an1", "converting": true,
                                                                    "publishing": true, "html_snippet": "<div/>"])],
            "audio_native_update_content_from_url": [.json(["project_id": "an2", "converting": true,
                                                            "publishing": true, "html_snippet": "<div/>"])],
            "get_audio_native_project_settings_endpoint": [.json(Self.settings), .json(Self.settings)],
        ])
        defer { fixture.clean() }
        let model = AudioNativeSectionModel(environment: fixture.environment)
        model.load(snippet: nil, projectID: "an1", settings: nil)
        model.contentFile = [try scratch.file("v2.txt")]
        model.contentAutoPublish = false
        await model.updateContent()
        let upload = fixture.multipart("audio_native_project_update_content_endpoint")
        #expect(fixture.path("audio_native_project_update_content_endpoint") == "/v1/audio-native/an1/content")
        #expect(upload.contains(#"name="file"; filename="v2.txt""#))
        #expect(upload.contains("name=\"auto_publish\"\r\n\r\nfalse"))

        model.pageURL = "https://example.com/roads"
        model.pageTitle = "Roads, again"
        await model.updateFromPage()
        #expect(fixture.body("audio_native_update_content_from_url") == ["url": "https://example.com/roads", "title": "Roads, again"])
        #expect(model.projectID == "an2")
    }
}

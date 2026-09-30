import AppKit
import Foundation
import SwiftUI
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// The shell's shared parts, as the section builders code against them: the section list,
/// which operations each section is built on, the runner's confirmation flow, the form built
/// from a schema, credentials shown once, and curl without the key.
@Suite("ElevenLabs shell interface")
@MainActor
struct ShellInterfaceTests {

    // MARK: - Sections

    @Test func everySectionHasItsOwnTitleAndAnIconThatExists() {
        let sections = ElevenLabsSection.allCases
        #expect(Set(sections.map(\.title)).count == sections.count)
        #expect(Set(sections.map(\.systemImage)).count == sections.count)
        for section in sections {
            #expect(
                NSImage(systemSymbolName: section.systemImage, accessibilityDescription: nil) != nil,
                "\(section) names an SF Symbol this Mac does not have: \(section.systemImage)"
            )
            #expect(!section.subtitle.isEmpty)
        }
    }

    @Test func theListShowsEveryCategoryInOrderAndEverySectionOnce() {
        let listed = ElevenLabsSectionCategory.allCases.flatMap(\.sections)
        #expect(listed == ElevenLabsSection.allCases)
        #expect(ElevenLabsSectionCategory.allCases.map(\.rawValue)
                == ["Create", "Voices", "Studio", "Agents", "Workspace", "Explorer"])
        #expect(ElevenLabsSectionCategory.explorer.sections == [.explorer])
    }

    /// Prefixes end on a segment boundary and the longest one wins, so a nested family goes
    /// to its own section rather than its parent's.
    @Test func anOperationBelongsToTheSectionWithTheLongestMatchingPrefix() {
        let expected: [(String, ElevenLabsSection?)] = [
            ("/v1/workspace/webhooks/{webhook_id}", .webhooks),
            ("/v1/workspace/members", .workspace),
            ("/v1/workspace/analytics/requests", .usage),
            ("/v1/voices/add", .voices),
            ("/v1/voices/add/{public_user_id}/{voice_id}", .voiceLibrary),
            ("/v1/voices/pvc/{voice_id}/train", .voices),
            ("/v1/text-to-speech/{voice_id}/stream", .speech),
            ("/v1/convai/agents/{agent_id}", .agents),
            ("/v1/convai/agents/{agent_id}/simulate-conversation/stream", .agentTesting),
            ("/v1/convai/agent-testing/create", .agentTesting),
            ("/v1/convai/agent/{agent_id}/knowledge-base/size", .agentKnowledge),
            ("/v1/convai/agent/{agent_id}/llm-usage/calculate", .agentAnalytics),
            ("/v1/convai/whatsapp-accounts", .agentPhoneNumbers),
            ("/v1/convai/whatsapp/outbound-call", .agentPhoneNumbers),
            ("/v1/convai/conversation/token", .agentConversations),
            ("/v1/workspaces/api-keys/disable", .serviceAccounts),
            ("/v1/music/finetunes/{finetune_id}", .music),
            ("/v1/musicians", nil),
            ("/v1/assets", nil),
        ]
        for (path, section) in expected {
            #expect(ElevenLabsSection.section(forPath: path) == section, "\(path)")
        }
    }

    @Test func aSectionsOperationsAreTheOnesItClaimsAndTheExplorerHasAll() {
        let catalog = [
            Self.operation(id: "tts", path: "/v1/text-to-speech/{voice_id}"),
            Self.operation(id: "hooks", path: "/v1/workspace/webhooks"),
            Self.operation(id: "asset", path: "/v1/assets"),
        ]
        #expect(ElevenLabsSection.speech.operations(in: catalog).map(\.id) == ["tts"])
        #expect(ElevenLabsSection.workspace.operations(in: catalog).isEmpty)
        #expect(ElevenLabsSection.webhooks.operations(in: catalog).map(\.id) == ["hooks"])
        #expect(ElevenLabsSection.explorer.operations(in: catalog).count == 3)
    }

    @Test func aRememberedSectionThatNoLongerExistsFallsBackToSpeech() {
        #expect(ElevenLabsSection.resolve(remembered: "agentSecrets") == .agentSecrets)
        #expect(ElevenLabsSection.resolve(remembered: "") == .speech)
        #expect(ElevenLabsSection.resolve(remembered: "voiceClone") == .speech)
    }

    /// Every section's view can be put on screen inside the pane's environment — the
    /// placeholders now, the builders' screens later.
    @Test func everySectionDrawsWithoutTheNetwork() {
        let model = AppModel(settings: .init())
        for section in ElevenLabsSection.allCases {
            let host = NSHostingView(rootView: ElevenLabsSectionContent(section: section).environment(model))
            host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            host.layoutSubtreeIfNeeded()
            #expect(host.frame.width == 800, "\(section)")
        }
    }

    // MARK: - Runner

    @Test func aDestructiveOperationAsksFirstAndSendsNothingWhenDeclined() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let runner = ElevenLabsRunner(
            operation: Self.operation(id: "delete_voice", method: "DELETE", path: "/v1/voices/{voice_id}", risk: .destructive),
            context: fixture.context
        )
        let running = Task { await runner.perform(arguments: ["voice_id": "abc"], subject: "the voice “Rachel”") }
        try await Self.waitUntil { runner.phase == .awaitingConfirmation }
        #expect(runner.confirmation?.title == "Delete the voice “Rachel”?")
        #expect(runner.confirmation?.confirmLabel == "Delete")
        runner.decline()
        let result = await running.value
        #expect(result == nil)
        #expect(runner.phase == .idle)
        #expect(runner.confirmation == nil)
        #expect(fixture.transport.requests.isEmpty)
    }

    @Test func aConfirmedOperationRunsToAnEnd() async throws {
        let fixture = Fixture(replies: [.json(nil, status: 200)])
        defer { fixture.clean() }
        let runner = ElevenLabsRunner(
            operation: Self.operation(id: "delete_voice", method: "DELETE", path: "/v1/voices/{voice_id}", risk: .destructive),
            context: fixture.context
        )
        let running = Task { await runner.perform(arguments: ["voice_id": "abc"]) }
        try await Self.waitUntil { runner.phase == .awaitingConfirmation }
        runner.confirm()
        _ = await running.value
        #expect(runner.phase == .succeeded || runner.phase == .failed)
        #expect(runner.confirmation == nil)
    }

    @Test func aReadRunsWithoutAsking() async throws {
        let fixture = Fixture(replies: [.json(["ok": true])])
        defer { fixture.clean() }
        let runner = ElevenLabsRunner(operation: Self.operation(id: "get_things"), context: fixture.context)
        _ = await runner.perform(arguments: [:])
        #expect(runner.confirmation == nil)
        #expect(runner.phase == .succeeded || runner.phase == .failed)
    }

    @Test func withNothingLinkedTheRunnerSaysSoAndSendsNothing() async {
        let runner = ElevenLabsRunner(
            operation: Self.operation(id: "get_things"), context: .init(client: { nil })
        )
        let result = await runner.perform(arguments: [:])
        #expect(result == nil)
        #expect(runner.phase == .failed)
        #expect(runner.failure == .notLinked)
    }

    @Test func failuresAreSortedByWhatTheOwnerCanDo() {
        #expect(ElevenLabsRunnerFailure(ElevenLabsError.api(status: 401, code: "invalid_api_key", message: "Invalid key", requestID: nil))
                .isKeyRejected)
        #expect(ElevenLabsRunnerFailure(ElevenLabsError.api(status: 403, code: nil, message: "Plan", requestID: nil))
                == .forbidden(ElevenLabsError.api(status: 403, code: nil, message: "Plan", requestID: nil).description))
        #expect(ElevenLabsRunnerFailure(ElevenLabsError.network("offline")) == .offline(ElevenLabsError.network("offline").description))
        #expect(ElevenLabsRunnerFailure(ElevenLabsError.invalidArguments(["text is required."]))
                == .invalidArguments(["text is required."]))
        #expect(ElevenLabsRunnerFailure(ElevenLabsError.notLinked) == .notLinked)
    }

    @Test func noFailureMessageCarriesSomethingKeyShaped() {
        let key = "sk_" + String(repeating: "a1", count: 20)
        let failure = ElevenLabsRunnerFailure(ElevenLabsError.api(status: 400, code: nil, message: "bad \(key)", requestID: nil))
        #expect(!failure.message.contains(key))
        #expect(!ElevenLabsRunnerFailure(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: key])).message.contains(key))
    }

    // MARK: - Confirmation wording

    @Test func aRealWorldConfirmationSaysItReachesOutsideTheAccount() {
        let request = ElevenLabsConfirmationRequest.make(
            for: Self.operation(id: "call", method: "POST", path: "/v1/convai/twilio/outbound-call",
                                summary: "Handle an outbound call via Twilio", risk: .realWorld)
        )
        #expect(request.consequence.contains("outside your"))
        #expect(request.confirmLabel == "Call now")
        #expect(request.call == "POST /v1/convai/twilio/outbound-call")
        #expect(request.title == "Handle an outbound call via Twilio?")
    }

    @Test func aTitleReadsAsASentenceWithOrWithoutASubject() {
        let calls = Self.operation(id: "create_batch_call", method: "POST", path: "/v1/convai/batch-calling/submit",
                                   summary: "Submit A Batch Call Request.", risk: .realWorld)
        #expect(ElevenLabsConfirmationRequest.make(for: calls, subject: "12 phone calls with “Front desk”").title
                == "Place 12 phone calls with “Front desk”?")
        let cancel = Self.operation(id: "cancel_batch_call", method: "POST", path: "/v1/convai/batch-calling/{batch_id}/cancel",
                                    summary: "Cancel A Batch Call.", risk: .realWorld)
        #expect(ElevenLabsConfirmationRequest.make(for: cancel, subject: "the batch “Monday”").title
                == "Cancel a batch call: the batch “Monday”?")
        #expect(ElevenLabsConfirmationRequest.make(for: cancel).confirmLabel == "Run")
        let invite = Self.operation(id: "invite_user", method: "POST", path: "/v1/workspace/invites/add",
                                    summary: "Invite User", risk: .realWorld)
        #expect(ElevenLabsConfirmationRequest.make(for: invite, subject: "an invite to a teammate").title
                == "Send an invite to a teammate?")
        #expect(ElevenLabsConfirmationRequest.sentenceCase("Add MCP Server To Agent") == "Add MCP server to agent")
    }

    // MARK: - Credentials

    @Test func aCredentialIsTakenOutOfTheResultAndMaskedInIt() {
        let operation = Self.operation(
            id: "create_key", method: "POST", path: "/v1/service-accounts/{id}/api-keys",
            risk: .realWorld, returnsCredential: true
        )
        let answer = ElevenLabsResult.json(["xi-api-key": "sk_secretsecretsecret", "key_id": "k1"], ElevenLabsMeta(status: 200))
        let credential = ElevenLabsRevealedCredential(operation: operation, result: answer)
        #expect(credential.fields == [.init(path: "xi-api-key", value: "sk_secretsecretsecret")])
        guard case .json(let masked, _) = ElevenLabsRevealedCredential.masked(answer, for: operation) else {
            Issue.record("expected JSON")
            return
        }
        #expect(masked["xi-api-key"] == .string(ElevenLabsRedaction.placeholder))
        #expect(masked["key_id"] == "k1")
    }

    @Test func credentialResultsNeverReachTheRecentList() {
        let pane = ElevenLabsPaneState(defaults: nil, client: { nil })
        let meta = ElevenLabsMeta(status: 200)
        pane.record(.json(["token": "t"], meta), operation: Self.operation(id: "token", returnsCredential: true))
        #expect(pane.recents.isEmpty)
        pane.record(.json(["ok": true], meta), operation: Self.operation(id: "plain"))
        #expect(pane.recents.map(\.operationID) == ["plain"])
    }

    @Test func theRecentListIsBounded() {
        let pane = ElevenLabsPaneState(defaults: nil, client: { nil })
        for index in 0..<(ElevenLabsPaneState.recentLimit + 5) {
            pane.record(.json(.number(Double(index)), ElevenLabsMeta(status: 200)), operation: Self.operation(id: "op\(index)"))
        }
        #expect(pane.recents.count == ElevenLabsPaneState.recentLimit)
        #expect(pane.recents.first?.operationID == "op\(ElevenLabsPaneState.recentLimit + 4)")
    }

    @Test func aRejectedKeyOrNoNetworkIsThePanesBusiness() {
        let pane = ElevenLabsPaneState(defaults: nil, client: { nil })
        pane.noteFailure(ElevenLabsError.api(status: 401, code: nil, message: "Invalid API key", requestID: nil))
        #expect(pane.connectionProblem == .keyRejected("Invalid API key"))
        pane.noteSuccess()
        #expect(pane.connectionProblem == nil)
        pane.noteFailure(ElevenLabsError.network("The Internet connection appears to be offline."))
        #expect(pane.connectionProblem == .offline("The Internet connection appears to be offline."))
        pane.noteFailure(ElevenLabsError.api(status: 422, code: nil, message: "bad", requestID: nil))
        #expect(pane.connectionProblem == .offline("The Internet connection appears to be offline."))
    }

    // MARK: - Form

    @Test func aFormMarksRequiredFieldsAndBuildsTypedEditors() throws {
        let form = ElevenLabsFormModel(operation: Self.speechLike)
        let byName = Dictionary(uniqueKeysWithValues: form.fields.map { ($0.name, $0) })
        #expect(form.fields.map(\.location) == [.path, .query, .body, .body, .body, .body, .body])
        #expect(byName["voice_id"]?.required == true)
        #expect(byName["output_format"]?.required == false)
        #expect(byName["text"]?.required == true)
        #expect(byName["text"]?.kind == .text(multiline: true, format: nil))
        #expect(byName["output_format"]?.kind == .choice(["mp3_44100_128", "pcm_16000"]))
        guard case .object(let settings)? = byName["voice_settings"]?.kind else {
            Issue.record("voice_settings should be a nested object")
            return
        }
        #expect(settings.map(\.name) == ["stability", "style"])
        #expect(settings.first?.constraints.maximum == 1)
        guard case .list(let item)? = byName["pronunciation_dictionary_locators"]?.kind,
              case .object = item.kind else {
            Issue.record("the locators should be a list of objects")
            return
        }
        guard case .variants(let variants)? = byName["source"]?.kind else {
            Issue.record("source should be a union")
            return
        }
        #expect(variants.map(\.title) == ["url", "text"])
    }

    @Test func blankOptionalFieldsAreLeftOutAndMissingRequiredOnesAreNamed() {
        let form = ElevenLabsFormModel(operation: Self.speechLike)
        let problems = form.arguments().problems
        #expect(problems.contains("voice_id is required."))
        #expect(problems.contains("text is required."))
        #expect(!problems.contains { $0.hasPrefix("output_format") })

        form.nodes.first { $0.field.name == "voice_id" }?.text = "v1"
        form.nodes.first { $0.field.name == "text" }?.text = "Hello"
        let settings = form.nodes.first { $0.field.name == "voice_settings" }
        settings?.included = true
        settings?.children.first { $0.field.name == "stability" }?.text = "1.5"
        let built = form.arguments()
        #expect(built.problems == ["voice_settings.stability must be at most 1."])
        settings?.children.first { $0.field.name == "stability" }?.text = "0.5"
        let fixed = form.arguments()
        #expect(fixed.problems.isEmpty)
        #expect(fixed.arguments == ["voice_id": "v1", "text": "Hello", "voice_settings": ["stability": 0.5]])
    }

    @Test func theBodyCanBeEditedAsJSONAndBack() {
        let form = ElevenLabsFormModel(operation: Self.speechLike)
        form.nodes.first { $0.field.name == "text" }?.text = "Hi"
        form.editBodyAsJSON()
        #expect(form.editsBodyAsJSON)
        #expect(form.bodyJSON.contains("\"text\" : \"Hi\""))
        form.bodyJSON = #"{"text": "Changed", "model_id": "eleven_v3"}"#
        #expect(form.arguments().arguments["body"] == ["text": "Changed", "model_id": "eleven_v3"])
        form.bodyJSON = "{not json"
        #expect(!form.editBodyAsFields())
        #expect(form.editsBodyAsJSON)
        form.bodyJSON = #"{"text": "Back"}"#
        #expect(form.editBodyAsFields())
        #expect(form.nodes.first { $0.field.name == "text" }?.text == "Back")
    }

    @Test func uploadFieldsBecomeFilePickersAndFiles() {
        let operation = Self.operation(
            id: "add_voice", method: "POST", path: "/v1/voices/add",
            body: ElevenLabsBody(
                contentType: .multipart, required: true,
                schema: ["type": "object", "required": ["name", "files"], "properties": [
                    "name": ["type": "string"],
                    "files": ["type": "array", "items": ["type": "string", "format": "binary"]],
                ]],
                fileFields: ["files"]
            )
        )
        let form = ElevenLabsFormModel(operation: operation)
        let files = form.nodes.first { $0.field.name == "files" }
        #expect(files?.field.kind == .file(multiple: true))
        #expect(form.arguments().problems.contains("files needs a file."))
        files?.files = [URL(fileURLWithPath: "/tmp/a.mp3"), URL(fileURLWithPath: "/tmp/b.wav")]
        form.nodes.first { $0.field.name == "name" }?.text = "Me"
        let built = form.arguments()
        #expect(built.problems.isEmpty)
        #expect(built.files["files"]?.map(\.filename) == ["a.mp3", "b.wav"])
        #expect(built.files["files"]?.map(\.contentType) == ["audio/mpeg", "audio/wav"])
        #expect(built.arguments == ["name": "Me"])
    }

    // MARK: - Curl

    @Test func copyAsCurlNeverCarriesTheKey() {
        let call = ElevenLabsCallDescription(
            operationID: "tts", method: "POST",
            url: "https://api.elevenlabs.io/v1/text-to-speech/abc?output_format=mp3_44100_128",
            headers: ["xi-api-key": "‹redacted›", "content-type": "application/json"],
            body: ["text": "It's here"]
        )
        let command = ElevenLabsCurl.command(for: call)
        #expect(command.contains("xi-api-key: $ELEVENLABS_API_KEY"))
        #expect(!command.contains("redacted"))
        #expect(command.contains(#"'{"text":"It'\''s here"}'"#))
        let leaky = ElevenLabsCallDescription(
            operationID: "x", method: "GET", url: "https://api.elevenlabs.io/v1/x?k=sk_abcdefghijklmnop",
            headers: [:], body: nil
        )
        #expect(!ElevenLabsCurl.command(for: leaky).contains("sk_abcdefghijklmnop"))
    }

    // MARK: - Fixtures

    /// A client over the public fakes: nothing leaves the process, nothing touches the
    /// Keychain, files go to a scratch directory removed at the end.
    struct Fixture {
        let transport: FakeElevenLabsTransport
        let credentials = FakeCredentialSource(key: "fixture-not-a-real-key")
        let sink = TemporaryFileSink()
        let client: ElevenLabsClient

        init(replies: [FakeElevenLabsTransport.Reply] = []) {
            transport = FakeElevenLabsTransport(replies: replies)
            client = ElevenLabsClient(credentials: credentials, region: .global, transport: transport, sink: sink)
        }

        @MainActor var context: ElevenLabsRunner.Context {
            let client = client
            let sink = sink
            return .init(client: { client }, sink: { sink })
        }

        func clean() {
            transport.removeTemporaryFiles()
            sink.removeAll()
        }
    }

    static func operation(
        id: String, method: String = "GET", path: String = "/v1/things", summary: String = "Get things",
        risk: ElevenLabsRisk = .read, returnsCredential: Bool = false, body: ElevenLabsBody? = nil,
        parameters: [ElevenLabsParameter] = []
    ) -> ElevenLabsOperation {
        ElevenLabsOperation(
            id: id, method: method, path: path, group: "Fixture", summary: summary, details: "",
            deprecated: false, parameters: parameters, body: body, response: .json, risk: risk,
            billable: risk == .generate, returnsCredential: returnsCredential, supportsStreaming: false
        )
    }

    /// Shaped like text-to-speech, with a nested object, a list of objects and a union.
    static var speechLike: ElevenLabsOperation {
        operation(
            id: "speech_like", method: "POST", path: "/v1/text-to-speech/{voice_id}", risk: .generate,
            body: ElevenLabsBody(
                contentType: .json, required: true,
                schema: [
                    "type": "object", "required": ["text"],
                    "properties": [
                        "text": ["type": "string", "description": "The text to speak."],
                        "model_id": ["type": "string", "default": "eleven_multilingual_v2"],
                        "voice_settings": ["anyOf": [
                            ["type": "object", "properties": [
                                "stability": ["type": "number", "minimum": 0, "maximum": 1, "default": 0.5],
                                "style": ["type": "number", "minimum": 0, "maximum": 1],
                            ]],
                            ["type": "null"],
                        ]],
                        "pronunciation_dictionary_locators": ["type": "array", "items": [
                            "type": "object", "required": ["pronunciation_dictionary_id"],
                            "properties": ["pronunciation_dictionary_id": ["type": "string"], "version_id": ["type": "string"]],
                        ]],
                        "source": ["oneOf": [
                            ["type": "object", "properties": ["type": ["const": "url"], "url": ["type": "string"]]],
                            ["type": "object", "properties": ["type": ["const": "text"], "text": ["type": "string"]]],
                        ]],
                    ],
                ],
                fileFields: []
            ),
            parameters: [
                ElevenLabsParameter(name: "voice_id", location: .path, required: true, description: "", schema: ["type": "string"]),
                ElevenLabsParameter(
                    name: "output_format", location: .query, required: false, description: "",
                    schema: ["type": "string", "enum": ["mp3_44100_128", "pcm_16000"]], defaultValue: "mp3_44100_128"
                ),
            ]
        )
    }

    static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting")
    }
}

extension ElevenLabsRunnerFailure {
    var isKeyRejected: Bool {
        if case .keyRejected = self { return true }
        return false
    }
}

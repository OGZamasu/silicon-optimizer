import AppKit
import Foundation
import SwiftUI
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// The Explorer and the runner over the real catalog and client: every operation gets a form,
/// runs go through the fake transport only, risky ones ask first, secrets are shown once and
/// kept nowhere, and curl never carries the key.
@Suite("ElevenLabs explorer and runner")
@MainActor
struct ShellExplorerTests {

    // MARK: - Forms for everything

    /// The brief's bar: a form for every one of the operations, without a crash, with every
    /// required parameter and body property marked.
    @Test func everyOperationGetsAFormWithItsRequiredFieldsMarked() throws {
        let all = ElevenLabsCatalog.all
        #expect(all.count == 403)
        for operation in all {
            let form = ElevenLabsFormModel(operation: operation)
            let fields = Dictionary(form.fields.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for parameter in operation.parameters where parameter.required || parameter.location == .path {
                let id = "\(parameter.location.rawValue).\(parameter.name)"
                #expect(fields[id]?.required == true, "\(operation.id): \(id) is not marked required")
            }
            if let body = operation.body {
                let bodyFields = form.fields.filter { $0.location == .body }
                let whole = bodyFields.count == 1 && bodyFields[0].name == "body"
                if !whole {
                    let schema = ElevenLabsFormField.resolved(JSONSchema.unwrapNullable(body.schema))
                    for name in schema["required"].arrayValue?.compactMap(\.stringValue) ?? [] {
                        #expect(fields["body.\(name)"]?.required == true, "\(operation.id): body.\(name) is not marked required")
                    }
                }
                for file in body.fileFields {
                    guard let field = fields["body.\(file)"] else { continue }
                    guard case .file = field.kind else {
                        Issue.record("\(operation.id): \(file) is not a file picker")
                        continue
                    }
                }
            }
            // Blank, the form names every required value it cannot make up, and sends
            // nothing optional.
            let blank = form.arguments()
            for field in form.fields where field.required && field.defaultValue == nil {
                let needsInput: Bool = switch field.kind {
                case .text, .integer, .number, .json, .file: true
                case .choice(let values): values.count > 1
                default: false
                }
                if needsInput {
                    #expect(blank.problems.contains { $0.hasPrefix(field.name + " ") },
                            "\(operation.id): nothing says \(field.name) is missing")
                }
            }
            for name in blank.arguments.keys {
                #expect(form.fields.first { $0.name == name }?.required == true,
                        "\(operation.id): a blank form sent the optional \(name)")
            }
        }
    }

    /// And every one of those forms draws. Opt-in, like the snapshots (`ELEVENLABS_DRAW=1`):
    /// 403 layouts hold the main actor for about ten seconds, which starves other suites'
    /// timing tests in a full run on a loaded Mac. Yields between forms all the same.
    @Test(.enabled(if: ElevenLabsSnapshot.enabled))
    func everyOperationsFormDraws() async {
        for operation in ElevenLabsCatalog.all {
            await Task.yield()
            let form = ElevenLabsFormModel(operation: operation)
            let host = NSHostingView(rootView: ElevenLabsOperationForm(form: form).frame(width: 640))
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height > 0, "\(operation.id)")
        }
    }

    // MARK: - The list

    @Test func theExplorerListsEveryOperationByGroup() {
        let explorer = ElevenLabsExplorerModel(context: .init(client: { nil }))
        let grouped = explorer.grouped
        #expect(grouped.reduce(0) { $0 + $1.operations.count } == 403)
        #expect(grouped.map(\.group) == ElevenLabsCatalog.groups.map(\.name))
        #expect(!explorer.isFiltered)
    }

    @Test func theFiltersNarrowByRiskCostAndDeprecation() {
        let explorer = ElevenLabsExplorerModel(context: .init(client: { nil }))
        explorer.toggle(.destructive)
        #expect(!explorer.matching.isEmpty)
        #expect(explorer.matching.allSatisfy { $0.risk == .destructive })
        explorer.toggle(.realWorld)
        #expect(explorer.matching.allSatisfy { $0.risk == .destructive || $0.risk == .realWorld })
        explorer.clearFilters()

        explorer.billableOnly = true
        #expect(!explorer.matching.isEmpty && explorer.matching.allSatisfy { $0.billable })
        explorer.billableOnly = false

        explorer.deprecated = .only
        #expect(explorer.matching.count == ElevenLabsCatalog.all.filter(\.deprecated).count)
        explorer.deprecated = .hide
        #expect(!explorer.matching.contains { $0.deprecated })
        explorer.clearFilters()

        explorer.search = "text to speech stream"
        #expect(explorer.matching.contains { $0.id == "text_to_speech_stream" })
        #expect(explorer.isFiltered)
    }

    // MARK: - Running

    @Test func aReadRunsThroughTheFakeTransportWithTheKeyOnlyInItsHeader() async throws {
        let fixture = Fixture(replies: [.json(["models": [["model_id": "eleven_v3"]]])])
        defer { fixture.clean() }
        let explorer = ElevenLabsExplorerModel(context: fixture.context)
        let session = try #require(explorer.session(for: "get_models"))
        await session.runner.perform(arguments: [:])
        #expect(session.runner.phase == .succeeded)
        let request = try #require(fixture.transport.requests.first)
        #expect(request.url.absoluteString == "https://api.elevenlabs.io/v1/models")
        #expect(request.header("xi-api-key") == Fixture.key)
        #expect(fixture.transport.hostViolations.isEmpty)
        #expect(session.runner.apiCall?.headers["xi-api-key"] != Fixture.key)
        #expect(fixture.pane.recents.map(\.operationID) == ["get_models"])
    }

    @Test func argumentsFromTheFormReachTheRequest() async throws {
        let fixture = Fixture(replies: [.audio(Data([0xFF, 0xF3, 0x01]))])
        defer { fixture.clean() }
        let explorer = ElevenLabsExplorerModel(context: fixture.context)
        let session = try #require(explorer.session(for: "text_to_speech_full"))
        session.form.nodes.first { $0.field.name == "voice_id" }?.text = "voice123"
        session.form.nodes.first { $0.field.name == "text" }?.text = "Hello"
        let built = session.form.arguments()
        #expect(built.problems.isEmpty)
        await session.runner.perform(arguments: built.arguments, files: built.files)
        #expect(session.runner.phase == .succeeded)
        let recorded = try #require(fixture.transport.recorded.first)
        #expect(recorded.request.method == "POST")
        #expect(recorded.request.url.path == "/v1/text-to-speech/voice123")
        #expect(try JSONValue(data: recorded.body)["text"] == "Hello")
        #expect(session.runner.result?.files.count == 1)
    }

    @Test func missingArgumentsAreRefusedBeforeAnythingIsSent() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "text_to_speech_full", context: fixture.context))
        let result = await runner.perform(arguments: [:])
        #expect(result == nil)
        #expect(runner.phase == .failed)
        #expect(!runner.problems.isEmpty)
        if case .invalidArguments = runner.failure {} else { Issue.record("expected invalid arguments, got \(String(describing: runner.failure))") }
        #expect(fixture.transport.requests.isEmpty)
    }

    @Test func aDeletionIsSentOnlyAfterItIsConfirmed() async throws {
        let fixture = Fixture(replies: [.json(["status": "ok"])])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "delete_voice", context: fixture.context))
        #expect(runner.operation.requiresConfirmation)
        let running = Task { await runner.perform(arguments: ["voice_id": "v9"], subject: "the voice “Narrator”") }
        try await Self.waitUntil { runner.phase == .awaitingConfirmation }
        #expect(fixture.transport.requests.isEmpty)
        #expect(runner.confirmation?.title == "Delete the voice “Narrator”?")
        #expect(runner.confirmation?.call?.hasPrefix("DELETE https://api.elevenlabs.io/v1/voices/v9") == true)
        runner.confirm()
        _ = await running.value
        #expect(runner.phase == .succeeded)
        #expect(fixture.transport.requests.map(\.method) == ["DELETE"])
    }

    @Test func aDeclinedRealWorldCallSendsNothing() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let operation = try #require(ElevenLabsCatalog.all.first { $0.risk == .realWorld && $0.method == "POST" })
        let runner = ElevenLabsRunner(operation: operation, context: fixture.context)
        let running = Task { await runner.perform(arguments: Self.minimalArguments(for: operation)) }
        try await Self.waitUntil { runner.phase != .idle }
        if runner.phase == .awaitingConfirmation {
            runner.decline()
        }
        _ = await running.value
        #expect(fixture.transport.requests.isEmpty)
        #expect(runner.phase == .idle || runner.phase == .failed)
    }

    /// The answer is ten minutes away; the time limit fails the test if Cancel does not
    /// reach the request.
    @Test(.timeLimit(.minutes(1)))
    func cancellingStopsARunInFlight() async throws {
        let fixture = Fixture(replies: [.init(status: 200, headers: ["content-type": "application/json"],
                                              body: Data("{}".utf8), delay: .seconds(600))])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "get_models", context: fixture.context))
        let running = Task { await runner.perform(arguments: [:]) }
        try await Self.waitUntil { runner.phase == .running }
        runner.cancel()
        let result = await running.value
        #expect(result == nil)
        #expect(runner.phase == .cancelled)
        #expect(runner.failure == nil)
    }

    @Test func aRefusedKeyIsReportedToThePane() async throws {
        let fixture = Fixture(replies: [.jsonText(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#, status: 401)])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "get_models", context: fixture.context))
        await runner.perform(arguments: [:])
        #expect(runner.failure.map { if case .keyRejected = $0 { true } else { false } } == true)
        if case .keyRejected? = fixture.pane.connectionProblem {} else {
            Issue.record("the pane should know the key was refused")
        }
        #expect(!(runner.errorMessage ?? "").contains(Fixture.key))
    }

    // MARK: - Secrets

    @Test func aSignedURLIsShownOnceAndKeptNowhere() async throws {
        let signed = "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=a1&conversation_signature=sig123"
        let fixture = Fixture(replies: [.json(["signed_url": .string(signed)])])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "get_conversation_signed_link", context: fixture.context))
        #expect(runner.operation.returnsCredential)
        await runner.perform(arguments: ["agent_id": "a1"])
        #expect(runner.phase == .succeeded)
        #expect(runner.credential?.fields == [.init(path: "signed_url", value: signed)])
        guard case .json(let shown, _)? = runner.result else {
            Issue.record("expected a JSON result")
            return
        }
        #expect(shown["signed_url"] == .string(ElevenLabsRedaction.placeholder))
        #expect(fixture.pane.recents.isEmpty)
        runner.dismissCredential()
        #expect(runner.credential == nil)
        #expect(!(runner.apiCall.map { $0.url + $0.headers.values.joined() } ?? "").contains("sig123"))
    }

    // MARK: - Streaming

    @Test func aStreamPlayedAsItArrivesIsAlsoKept() async throws {
        let chunks = [Data([1, 2, 3]), Data([4, 5]), Data([6])]
        let fixture = Fixture(replies: [.audio(chunks.reduce(Data(), +), chunks: chunks)])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "text_to_speech_stream", context: fixture.context))
        #expect(runner.operation.supportsStreaming)
        runner.streamMode = .play
        let result = await runner.perform(arguments: ["voice_id": "v1", "text": "Hi"])
        #expect(runner.phase == .succeeded)
        #expect(fixture.transport.recorded.first?.streamed == true)
        guard case .file(let url, _, let bytes, _)? = result else {
            Issue.record("expected a file, got \(String(describing: result))")
            return
        }
        #expect(bytes == 6)
        #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4, 5, 6]))
        #expect(url.deletingLastPathComponent() == fixture.sink.directory)
        #expect(fixture.sink.written == [url])
    }

    /// The `…/stream/with-timestamps` answer is JSON chunks carrying base64 audio. The audio
    /// is saved as the format asked for — not as `.json` because the stream was JSON — and
    /// the timings stay in the result.
    @Test func aStreamWithTimingsIsSavedAsTheAudioItCarries() async throws {
        let first = Data([0x10, 0x20, 0x30]), second = Data([0x40, 0x50])
        func chunk(_ audio: Data, _ characters: [String]) -> Data {
            JSONValue.object([
                "audio_base64": .string(audio.base64EncodedString()),
                "alignment": .object([
                    "characters": .array(characters.map(JSONValue.string)),
                    "character_start_times_seconds": [0, 0.1],
                    "character_end_times_seconds": [0.1, 0.2],
                ]),
            ]).encoded() + Data("\n".utf8)
        }
        let body = [chunk(first, ["H", "i"]), chunk(second, ["!", " "])]
        for (format, ext, type) in [("pcm_24000", "pcm", "audio/pcm"), (nil, "mp3", "audio/mpeg")] {
            let fixture = Fixture(replies: [.init(
                status: 200, headers: ["content-type": "application/json"], body: body.reduce(Data(), +), chunks: body
            )])
            defer { fixture.clean() }
            let runner = try #require(ElevenLabsRunner(operationID: "text_to_speech_stream_with_timestamps", context: fixture.context))
            runner.streamMode = .play
            var arguments: [String: JSONValue] = ["voice_id": "v1", "text": "Hi!"]
            if let format { arguments["output_format"] = .string(format) }
            let result = try #require(await runner.perform(arguments: arguments))
            #expect(runner.phase == .succeeded)
            guard case .parts(let parts, _) = result else {
                Issue.record("expected audio and timings, got \(result)")
                continue
            }
            let files = parts.compactMap { part -> (URL, String)? in
                if case .file(let url, let contentType, _) = part { (url, contentType) } else { nil }
            }
            #expect(files.count == 1)
            #expect(files.first?.0.pathExtension == ext)
            #expect(files.first?.1 == type)
            #expect(try files.first.map { try Data(contentsOf: $0.0) } == first + second)
            let timings = parts.compactMap { part -> JSONValue? in if case .json(let value) = part { value } else { nil } }
            #expect(timings.flatMap { $0["alignment"]["characters"].arrayValue ?? [] }.compactMap(\.stringValue) == ["H", "i", "!", " "])
            #expect(fixture.sink.written.map(\.pathExtension) == [ext])
        }
    }

    @Test func aCollectedStreamGoesThroughCall() async throws {
        let fixture = Fixture(replies: [.audio(Data([9, 9]), chunks: [Data([9]), Data([9])])])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "text_to_speech_stream", context: fixture.context))
        runner.streamMode = .collect
        await runner.perform(arguments: ["voice_id": "v1", "text": "Hi"])
        #expect(runner.phase == .succeeded)
        #expect(runner.result?.files.count == 1)
    }

    // MARK: - curl

    @Test func copyAsCurlUsesAPlaceholderForTheKey() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let explorer = ElevenLabsExplorerModel(context: fixture.context)
        let session = try #require(explorer.session(for: "text_to_speech_full"))
        guard case .failure(let problem) = explorer.curl(for: session) else {
            Issue.record("a blank form has problems")
            return
        }
        #expect(problem.problems.contains("voice_id is required."))
        session.form.nodes.first { $0.field.name == "voice_id" }?.text = "voice123"
        session.form.nodes.first { $0.field.name == "text" }?.text = "Hello"
        guard case .success(let command) = explorer.curl(for: session) else {
            Issue.record("expected a command")
            return
        }
        #expect(command.contains("https://api.elevenlabs.io/v1/text-to-speech/voice123"))
        #expect(command.contains("$ELEVENLABS_API_KEY"))
        #expect(!command.contains(Fixture.key))
        #expect(fixture.transport.requests.isEmpty)
    }

    // MARK: - Fixtures

    struct Fixture {
        static let key = "fixture-key-explorer-0001"
        let transport: FakeElevenLabsTransport
        let credentials = FakeCredentialSource(key: Fixture.key)
        let sink = TemporaryFileSink()
        let client: ElevenLabsClient
        let pane: ElevenLabsPaneState

        @MainActor
        init(replies: [FakeElevenLabsTransport.Reply] = []) {
            self.init(transport: FakeElevenLabsTransport(replies: replies))
        }

        /// Answers through `handler`, for tests that decide when an answer arrives.
        @MainActor
        init(handler: @escaping @Sendable (ElevenLabsRequest) async throws -> FakeElevenLabsTransport.Reply) {
            self.init(transport: FakeElevenLabsTransport(handler: handler))
        }

        @MainActor
        init(transport: FakeElevenLabsTransport) {
            self.transport = transport
            let client = ElevenLabsClient(credentials: credentials, region: .global, transport: transport, sink: sink)
            self.client = client
            pane = ElevenLabsPaneState(defaults: nil, client: { client })
        }

        @MainActor var context: ElevenLabsRunner.Context {
            let client = client
            let sink = sink
            return .init(client: { client }, sink: { sink }, pane: pane)
        }

        func clean() {
            transport.removeTemporaryFiles()
            sink.removeAll()
        }
    }

    /// Placeholder values for an operation's required path parameters.
    static func minimalArguments(for operation: ElevenLabsOperation) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [:]
        for parameter in operation.parameters(in: .path) { arguments[parameter.name] = "x1" }
        return arguments
    }

    static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        // Fifteen seconds of wall clock, not a count of naps: a loaded run stretches every nap.
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting")
    }
}

/// The voices list every picker shares: fetched once, page by page, over the fake transport.
@Suite("ElevenLabs voice directory")
@MainActor
struct ShellVoiceDirectoryTests {

    @Test func theDirectoryFollowsPagesAndKeepsOnlyHTTPSPreviews() async throws {
        let transport = FakeElevenLabsTransport { request in
            let token = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "next_page_token" }?.value
            if token == nil {
                return .json(["voices": [
                    ["voice_id": "v1", "name": "Narrator", "category": "premade",
                     "labels": ["accent": "british", "age": "middle_aged"],
                     "preview_url": "https://storage.example.com/v1.mp3"],
                    ["voice_id": "v2", "name": "Plain", "preview_url": "http://storage.example.com/v2.mp3"],
                ], "has_more": true, "next_page_token": "page-2"])
            }
            return .json(["voices": [["voice_id": "v3", "name": "Mine", "category": "cloned"]], "has_more": false])
        }
        let sink = TemporaryFileSink()
        defer { transport.removeTemporaryFiles(); sink.removeAll() }
        let client = ElevenLabsClient(
            credentials: FakeCredentialSource(key: "fixture-key-voices-0001"), region: .global,
            transport: transport, sink: sink
        )
        let directory = ElevenLabsVoiceDirectory(client: { client })
        await directory.loadIfNeeded()
        #expect(directory.voices.map(\.id) == ["v1", "v2", "v3"])
        #expect(directory.voice(id: "v1")?.labelSummary == "british · middle aged")
        #expect(directory.voice(id: "v1")?.previewURL?.absoluteString == "https://storage.example.com/v1.mp3")
        #expect(directory.voice(id: "v2")?.previewURL == nil)
        #expect(directory.error == nil)
        let paths = transport.requests.map { $0.url.path }
        #expect(paths == ["/v2/voices", "/v2/voices"])
        #expect(transport.requests.allSatisfy { $0.url.query?.contains("page_size=100") == true })

        // Once is enough: a second picker does not fetch again.
        await directory.loadIfNeeded()
        #expect(transport.requests.count == 2)
    }

    @Test func withNothingLinkedTheDirectorySaysSo() async {
        let directory = ElevenLabsVoiceDirectory(client: { nil })
        await directory.refresh()
        #expect(directory.voices.isEmpty)
        #expect(directory.error == ElevenLabsError.notLinked.description)
    }
}

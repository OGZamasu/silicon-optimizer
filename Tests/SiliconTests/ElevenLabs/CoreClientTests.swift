import Foundation
import Testing
@testable import SiliconElevenLabs

/// The client over the in-memory transport: what goes on the wire, what comes back, and what
/// never happens (a bad request sent, a billable one sent twice, the key anywhere but its
/// header).
@Suite("ElevenLabs client")
struct CoreClientTests {

    static let key = "sk_" + String(repeating: "fixture", count: 5)

    /// A client wired to fakes; the sink and the transport clean up after the test.
    struct Rig {
        let transport: FakeElevenLabsTransport
        let credential: FakeCredentialSource
        let sink: TemporaryFileSink
        let client: ElevenLabsClient

        init(
            region: ElevenLabsRegion = .global, key: String? = CoreClientTests.key,
            limits: ElevenLabsClient.Limits = CoreClientTests.fastLimits,
            handler: @escaping @Sendable (ElevenLabsRequest) async throws -> FakeElevenLabsTransport.Reply
        ) {
            transport = FakeElevenLabsTransport(handler: handler)
            credential = FakeCredentialSource(key: key)
            sink = TemporaryFileSink()
            client = ElevenLabsClient(
                credentials: credential, region: region, transport: transport, sink: sink, limits: limits
            )
        }

        init(region: ElevenLabsRegion = .global, replies: [FakeElevenLabsTransport.Reply]) {
            let queue = Queue(replies)
            self.init(region: region) { _ in queue.next() }
        }

        func cleanUp() {
            sink.removeAll()
            transport.removeTemporaryFiles()
        }
    }

    static var fastLimits: ElevenLabsClient.Limits {
        var limits = ElevenLabsClient.Limits()
        limits.firstBackoff = 0.01
        limits.longestRetryWait = 0.05
        return limits
    }

    final class Queue: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [FakeElevenLabsTransport.Reply]
        init(_ replies: [FakeElevenLabsTransport.Reply]) { self.replies = replies }
        func next() -> FakeElevenLabsTransport.Reply {
            lock.withLock { replies.isEmpty ? .jsonText("{}", status: 599) : replies.removeFirst() }
        }
    }

    // MARK: - Requests

    @Test func aReadGoesToTheRegionHostWithTheKeyInItsHeaderOnly() async throws {
        let rig = Rig(region: .eu, replies: [.json(["voices": []])])
        defer { rig.cleanUp() }
        let result = try await rig.client.call("get_voices", arguments: ["show_legacy": true])
        guard case .json(let value, let meta) = result else { Issue.record("expected JSON"); return }
        #expect(value == ["voices": []])
        #expect(meta.status == 200)

        let request = try #require(rig.transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://api.eu.residency.elevenlabs.io/v1/voices?show_legacy=true")
        #expect(request.header("xi-api-key") == Self.key)
        #expect(!request.url.absoluteString.contains(Self.key))
        #expect(!"\(request)".contains(Self.key))
        #expect(!String(reflecting: request).contains(Self.key))
        #expect(request.body == .none)
        #expect(rig.transport.hostViolations.isEmpty)
    }

    @Test func pathArgumentsArePercentEncodedAsOneSegment() async throws {
        let rig = Rig(replies: [.json([:])])
        defer { rig.cleanUp() }
        _ = try await rig.client.call("get_voice_by_id", arguments: ["voice_id": "a b?#é"])
        let url = try #require(rig.transport.requests.first?.url)
        #expect(url.absoluteString == "https://api.elevenlabs.io/v1/voices/a%20b%3F%23%C3%A9")
    }

    @Test func queryArraysRepeatTheirNameAndScalarsAreSpelledAsTheAPIExpects() async throws {
        let rig = Rig(replies: [.json([:])])
        defer { rig.cleanUp() }
        _ = try await rig.client.call("get_user_voices_v2", arguments: [
            "voice_ids": ["v1", "v 2"], "page_size": 10, "search": "a&b=c",
        ])
        let url = try #require(rig.transport.requests.first?.url)
        let query = try #require(url.query(percentEncoded: true))
        #expect(query.contains("page_size=10"))
        #expect(query.contains("search=a%26b%3Dc"))
        #expect(query.contains("voice_ids=v1&voice_ids=v%202"))
    }

    @Test func aJSONBodyCarriesTheFieldsAndSpeechLandsInTheSink() async throws {
        let audio = Data((0..<4_000).map { UInt8($0 % 251) })
        let rig = Rig(replies: [.audio(audio, headers: ["character-cost": "12", "request-id": "req-1",
                                                         "set-cookie": "tracking=1"])])
        defer { rig.cleanUp() }
        let result = try await rig.client.call("text_to_speech_full", arguments: [
            "voice_id": "voice-1", "text": "Hello there", "model_id": "eleven_multilingual_v2",
            "output_format": "mp3_44100_128", "voice_settings": ["stability": 0.5],
        ])
        guard case .file(let url, let contentType, let bytes, let meta) = result else {
            Issue.record("expected a file, got \(result)"); return
        }
        #expect(url.deletingLastPathComponent() == rig.sink.directory)
        #expect(url.pathExtension == "mp3")
        #expect(try Data(contentsOf: url) == audio)
        #expect(contentType == "audio/mpeg")
        #expect(bytes == audio.count)
        #expect(meta.characterCost == 12)
        #expect(meta.requestID == "req-1")
        #expect(meta.headers["set-cookie"] == nil)
        #expect(rig.sink.written == [url])

        let recorded = try #require(rig.transport.recorded.first)
        #expect(recorded.request.url.path == "/v1/text-to-speech/voice-1")
        #expect(recorded.request.url.query == "output_format=mp3_44100_128")
        #expect(recorded.request.header("Content-Type") == "application/json")
        let body = try JSONValue(data: recorded.body)
        #expect(body == ["text": "Hello there", "model_id": "eleven_multilingual_v2",
                         "voice_settings": ["stability": 0.5]])
        #expect(!String(decoding: recorded.body, as: UTF8.self).contains(Self.key))
        if case .file(let limit) = recorded.request.responseHandling { #expect(limit > 0) }
        else { Issue.record("audio should be downloaded to a file") }
    }

    @Test func aWholeBodyCanBeGivenAsBody() async throws {
        let rig = Rig(replies: [.json(["composition_plan": [:]])])
        defer { rig.cleanUp() }
        _ = try await rig.client.call("compose_plan", arguments: ["body": ["prompt": "calm piano"]])
        #expect(try JSONValue(data: rig.transport.recorded[0].body) == ["prompt": "calm piano"])
    }

    @Test func everyProblemIsReportedAndNothingIsSent() async {
        let rig = Rig(replies: [])
        defer { rig.cleanUp() }
        await #expect {
            try await rig.client.call("text_to_speech_full", arguments: [
                "model_id": true, "voice": "typo", "output_format": "wav_bogus",
            ])
        } throws: { error in
            guard case ElevenLabsError.invalidArguments(let problems) = error else { return false }
            return problems.contains("missing required path parameter \"voice_id\"")
                && problems.contains("missing required field \"text\"")
                && problems.contains("\"model_id\" must be a string")
                && problems.contains("unknown argument \"voice\"")
                && problems.contains { $0.hasPrefix("\"output_format\" must be one of:") }
        }
        #expect(rig.transport.requests.isEmpty)
        #expect(rig.credential.reads == 0)
        #expect(rig.client.validate("text_to_speech_full", arguments: ["voice_id": "v", "text": "hi"]).isEmpty)
        #expect(!rig.client.validate("get_voices", arguments: ["nope": 1]).isEmpty)
        #expect(rig.client.validate("no_such_operation") == ["There is no ElevenLabs operation named \"no_such_operation\"."])
    }

    @Test func anUnknownOperationIsRefusedByName() async {
        let rig = Rig(replies: [])
        defer { rig.cleanUp() }
        await #expect(throws: ElevenLabsError.unknownOperation("launch_rockets")) {
            try await rig.client.call("launch_rockets")
        }
    }

    // MARK: - Multipart

    @Test func multipartUploadsStreamFilesFromDiskAndRemoveTheirTemporaryBody() async throws {
        let rig = Rig(replies: [.json(["voice_id": "new-voice"])])
        defer { rig.cleanUp() }
        let first = try Self.scratchFile("one.mp3", bytes: Data(repeating: 0xAA, count: 3_000))
        let second = try Self.scratchFile("two \"quoted\".wav", bytes: Data(repeating: 0xBB, count: 1_500))
        defer { Self.removeScratch(first); Self.removeScratch(second) }

        let result = try await rig.client.call(
            "add_voice",
            arguments: ["name": "Narrator", "labels": ["accent": "british"], "remove_background_noise": true],
            files: ["files": [ElevenLabsFile(url: first), ElevenLabsFile(url: second)]]
        )
        guard case .json(let value, _) = result else { Issue.record("expected JSON"); return }
        #expect(value["voice_id"] == "new-voice")

        let recorded = try #require(rig.transport.recorded.first)
        let contentType = try #require(recorded.request.header("Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let parts = MultipartMixed.split(recorded.body, boundary: boundary)
        #expect(parts.count == 5)
        let byName = Dictionary(grouping: parts) { part in
            part.headers["content-disposition"]?.components(separatedBy: "name=\"").dropFirst().first?
                .components(separatedBy: "\"").first ?? ""
        }
        #expect(byName["name"]?.first.map { String(decoding: $0.body, as: UTF8.self) } == "Narrator")
        #expect(byName["labels"]?.first.map { String(decoding: $0.body, as: UTF8.self) } == #"{"accent":"british"}"#)
        #expect(byName["remove_background_noise"]?.first.map { String(decoding: $0.body, as: UTF8.self) } == "true")
        let uploads = try #require(byName["files"])
        #expect(uploads.map(\.body) == [Data(repeating: 0xAA, count: 3_000), Data(repeating: 0xBB, count: 1_500)])
        #expect(uploads.map(\.contentType) == ["audio/mpeg", "audio/wav"])
        #expect(uploads[1].headers["content-disposition"]?.contains("filename=\"two %22quoted%22.wav\"") == true)

        guard case .file(let body) = recorded.request.body else { Issue.record("expected a file body"); return }
        #expect(!FileManager.default.fileExists(atPath: body.path), "the multipart body should be removed")
    }

    @Test func fileProblemsAreReportedBeforeAnythingIsSent() async throws {
        var limits = Self.fastLimits
        limits.uploadBytes = 100
        let rig = Rig(limits: limits) { _ in .json([:]) }
        defer { rig.cleanUp() }
        let big = try Self.scratchFile("big.mp3", bytes: Data(count: 200))
        defer { Self.removeScratch(big) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("elevenlabs-missing-\(UUID()).mp3")

        let problems = rig.client.validate(
            "speech_to_text", arguments: ["model_id": "scribe_v1"],
            files: ["file": [ElevenLabsFile(url: big), ElevenLabsFile(url: missing)], "photo": [ElevenLabsFile(url: big)]]
        )
        #expect(problems.contains("\"file\" takes one file, not 2"))
        #expect(problems.contains { $0.contains("does not exist") })
        #expect(problems.contains { $0.hasPrefix("\"photo\" is not a file field") })
        #expect(problems.contains { $0.contains("past the 100-byte upload limit") })
        #expect(rig.client.validate("add_voice", arguments: ["name": "x"]) == ["missing required file \"files\""])
        #expect(rig.client.validate("get_voices", files: ["x": [ElevenLabsFile(url: big)]]) == ["this operation takes no files"])
        #expect(rig.transport.requests.isEmpty)
    }

    // MARK: - Errors

    @Test func elevenLabsErrorShapesBecomeOneReadableError() async throws {
        let rig = Rig(replies: [
            .jsonText(#"{"detail":[{"loc":["body","text"],"msg":"Field required","type":"missing"},{"loc":["query","output_format"],"msg":"bad"}]}"#, status: 422),
            .jsonText(#"{"detail":{"status":"voice_not_found","message":"A voice with that id does not exist."}}"#, status: 404, headers: ["request-id": "r-9"]),
            .jsonText(#"{"detail":"Plain words."}"#, status: 400),
            .init(status: 502, headers: ["content-type": "text/html"], body: Data("<html>bad gateway</html>".utf8)),
        ])
        defer { rig.cleanUp() }
        await #expect(throws: ElevenLabsError.api(status: 422, code: "validation_error",
                                                  message: "text: Field required; query.output_format: bad", requestID: nil)) {
            try await rig.client.call("sound_generation", arguments: ["text": "rain"])
        }
        await #expect(throws: ElevenLabsError.api(status: 404, code: "voice_not_found",
                                                  message: "A voice with that id does not exist.", requestID: "r-9")) {
            try await rig.client.call("sound_generation", arguments: ["text": "rain"])
        }
        await #expect(throws: ElevenLabsError.api(status: 400, code: nil, message: "Plain words.", requestID: nil)) {
            try await rig.client.call("sound_generation", arguments: ["text": "rain"])
        }
        await #expect(throws: ElevenLabsError.api(status: 502, code: nil, message: "<html>bad gateway</html>", requestID: nil)) {
            try await rig.client.call("sound_generation", arguments: ["text": "rain"])
        }
    }

    @Test func aRejectedKeyOnAResidencyRegionSaysItMayBelongElsewhere() async {
        let rig = Rig(region: .singapore, replies: [
            .jsonText(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#, status: 401),
        ])
        defer { rig.cleanUp() }
        await #expect {
            try await rig.client.call("get_user_info")
        } throws: { error in
            guard case ElevenLabsError.api(401, "invalid_api_key", let message, _) = error else { return false }
            return message.hasPrefix("Invalid API key") && message.contains("different region")
        }
    }

    @Test func theKeyNeverSurvivesIntoAnErrorWhereverItCameFrom() async throws {
        let legacy = String(repeating: "c0ffee", count: 6)
        let rig = Rig(replies: [
            .jsonText(#"{"detail":{"status":"bad","message":"key \#(Self.key) rejected"}}"#, status: 403),
            .jsonText(#"{"detail":"key \#(legacy) rejected"}"#, status: 400),
            .failure(.network("dropped while sending \(Self.key)")),
        ])
        defer { rig.cleanUp() }
        for _ in 0..<3 {
            do {
                _ = try await rig.client.call("sound_generation", arguments: ["text": "x"])
                Issue.record("expected an error")
            } catch {
                let text = "\(error) \(error.localizedDescription)"
                #expect(!text.contains(Self.key))
                #expect(!text.contains(legacy))
                #expect(text.contains(ElevenLabsRedaction.placeholder))
            }
        }
    }

    @Test func noKeyMeansNotLinkedAndALockedKeychainSaysSo() async {
        let rig = Rig(key: nil) { _ in .json([:]) }
        defer { rig.cleanUp() }
        await #expect(throws: ElevenLabsError.notLinked) { try await rig.client.call("get_voices") }
        rig.credential.setFailure(.credentialUnavailable("locked"))
        await #expect(throws: ElevenLabsError.credentialUnavailable("locked")) { try await rig.client.call("get_voices") }
        #expect(rig.transport.requests.isEmpty)
    }

    // MARK: - Retries

    @Test func aReadIsRetriedAfterA429ButAGenerationIsNeverSentTwice() async throws {
        let read = Rig(replies: [.jsonText("{}", status: 429, headers: ["retry-after": "0"]), .json(["ok": true])])
        defer { read.cleanUp() }
        _ = try await read.client.call("get_models")
        #expect(read.transport.requests.count == 2)

        let billable = Rig(replies: [.jsonText(#"{"detail":"busy"}"#, status: 429, headers: ["retry-after": "3"]),
                                     .audio(Data([1]))])
        defer { billable.cleanUp() }
        await #expect(throws: ElevenLabsError.rateLimited(retryAfter: 3)) {
            try await billable.client.call("sound_generation", arguments: ["text": "rain"])
        }
        #expect(billable.transport.requests.count == 1)
    }

    @Test func aLostConnectionIsRetriedOnlyForReads() async throws {
        let read = Rig(replies: [.failure(.network("reset")), .json(["ok": true])])
        defer { read.cleanUp() }
        _ = try await read.client.call("get_models")
        #expect(read.transport.requests.count == 2)

        for operation in ["sound_generation", "add_voice"] {
            let rig = Rig(replies: [.failure(.network("reset")), .json([:])])
            defer { rig.cleanUp() }
            let file = try Self.scratchFile("s.mp3", bytes: Data([1]))
            defer { Self.removeScratch(file) }
            await #expect(throws: ElevenLabsError.network("reset")) {
                if operation == "add_voice" {
                    _ = try await rig.client.call(operation, arguments: ["name": "n"], files: ["files": [ElevenLabsFile(url: file)]])
                } else {
                    _ = try await rig.client.call(operation, arguments: ["text": "rain"])
                }
            }
            #expect(rig.transport.requests.count == 1, "\(operation) was sent twice")
        }
    }

    @Test func serverErrorsAreRetriedForReadsAndBoundedInNumber() async throws {
        let rig = Rig { _ in .jsonText(#"{"detail":"down"}"#, status: 503) }
        defer { rig.cleanUp() }
        await #expect(throws: ElevenLabsError.self) { try await rig.client.call("get_models") }
        #expect(rig.transport.requests.count == 1 + Self.fastLimits.retries)

        let generate = Rig { _ in .jsonText(#"{"detail":"down"}"#, status: 503) }
        defer { generate.cleanUp() }
        await #expect(throws: ElevenLabsError.self) {
            try await generate.client.call("sound_generation", arguments: ["text": "rain"])
        }
        #expect(generate.transport.requests.count == 1)
    }

    // MARK: - Concurrency and cancellation

    @Test func noMoreThanThePlansConcurrencyRunAtOnce() async throws {
        let counter = Counter()
        let rig = Rig { request in
            if request.url.path == "/v1/user" { return .json(["user_id": "u"]) }
            if request.url.path == "/v1/user/subscription" { return .json(["tier": "creator"]) }
            counter.enter()
            try? await Task.sleep(for: .milliseconds(40))
            counter.leave()
            return .json([:])
        }
        defer { rig.cleanUp() }
        #expect(await rig.client.concurrencyLimit == 2)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 { group.addTask { _ = try await rig.client.call("get_models") } }
            try await group.waitForAll()
        }
        #expect(counter.peak == 2)

        let account = try await rig.client.account()
        #expect(account.concurrencyLimit == 5)
        #expect(await rig.client.concurrencyLimit == 5)
    }

    @Test func cancellingACallCancelsItsRequest() async throws {
        let rig = Rig(replies: [.init(status: 200, body: Data("{}".utf8), delay: .seconds(30))])
        defer { rig.cleanUp() }
        let task = Task { try await rig.client.call("get_models") }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let started = ContinuousClock.now
        await #expect(throws: ElevenLabsError.cancelled) { try await task.value }
        // Well inside the 30 s the answer would take; room for a loaded run.
        #expect(ContinuousClock.now - started < .seconds(15))
    }

    @Test func cancellingAStreamStopsTheTransportStream() async throws {
        let chunks = (0..<50).map { Data([UInt8($0)]) }
        let rig = Rig(replies: [.init(status: 200, headers: ["content-type": "audio/mpeg"],
                                      chunks: chunks, delay: .milliseconds(20))])
        defer { rig.cleanUp() }
        var received = 0
        for try await chunk in rig.client.stream("text_to_speech_stream", arguments: ["voice_id": "v", "text": "hi"]) {
            if case .audio = chunk { received += 1 }
            if received == 3 { break }
        }
        // The transport hears of it on its own task: waited for, not slept for.
        let deadline = ContinuousClock.now + .seconds(15)
        while rig.transport.cancelledStreams == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rig.transport.cancelledStreams == 1)
    }

    // MARK: - Answers of every kind

    @Test func chunkedAudioStreamsAfterItsHeaders() async throws {
        let rig = Rig(replies: [.audio(Data(), contentType: "audio/mpeg", chunks: [Data([1, 2]), Data([3])],
                                       headers: ["character-cost": "4"])])
        defer { rig.cleanUp() }
        var chunks: [ElevenLabsChunk] = []
        for try await chunk in rig.client.stream("text_to_speech_stream", arguments: ["voice_id": "v", "text": "hi"]) {
            chunks.append(chunk)
        }
        guard case .started(let meta) = chunks.first else { Issue.record("expected .started first"); return }
        #expect(meta.characterCost == 4)
        let audio = chunks.compactMap { if case .audio(let data) = $0 { data } else { nil } }
        #expect(audio == [Data([1, 2]), Data([3])])
        #expect(rig.transport.recorded.first?.streamed == true)
    }

    @Test func aStreamThatFailsReportsTheAPIErrorNotChunks() async {
        let rig = Rig(replies: [.jsonText(#"{"detail":"quota_exceeded"}"#, status: 401)])
        defer { rig.cleanUp() }
        await #expect(throws: ElevenLabsError.self) {
            for try await _ in rig.client.stream("text_to_speech_stream", arguments: ["voice_id": "v", "text": "hi"]) {}
        }
    }

    @Test func streamedJSONWithTimestampsIsSplitIntoAudioAndAlignment() async throws {
        let first = Data([1, 2, 3]).base64EncodedString()
        let second = Data([4, 5]).base64EncodedString()
        let body = #"{"audio_base64":"\#(first)","alignment":{"characters":["H"]}}"# + "\n"
            + #"{"audio_base64":"\#(second)","alignment":{"characters":["i"]}}"# + "\n"
        let bytes = Data(body.utf8)
        let pieces = stride(from: 0, to: bytes.count, by: 7).map { bytes[$0..<min($0 + 7, bytes.count)] }.map { Data($0) }
        let rig = Rig(replies: [.init(status: 200, headers: ["content-type": "application/json"], chunks: pieces)])
        defer { rig.cleanUp() }
        let result = try await rig.client.call("text_to_speech_stream_with_timestamps",
                                               arguments: ["voice_id": "v", "text": "Hi"])
        guard case .parts(let parts, _) = result, case .file(let url, "audio/mpeg", 5) = parts.first,
              case .json(let events) = parts.last
        else { Issue.record("unexpected \(result)"); return }
        #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4, 5]))
        #expect(events == [
            ["alignment": ["characters": ["H"]], "audio_base64_bytes": 3],
            ["alignment": ["characters": ["i"]], "audio_base64_bytes": 2],
        ])
    }

    @Test func serverSentEventsAreParsedAcrossChunkBoundaries() async throws {
        let audio = Data((0..<100).map { UInt8($0) }).base64EncodedString()
        let stream = "event: composition_plan\ndata: {\"sections\":[]}\n\n"
            + ": keep-alive\n\n"
            + "event: audio_chunk\r\ndata: {\"audio_base64\":\"\(audio)\",\"words_timestamps\":[]}\r\n\r\n"
            + "event: done\ndata: {\"song_id\":\"s1\"}\n\n"
        let bytes = Data(stream.utf8)
        let pieces = stride(from: 0, to: bytes.count, by: 11).map { Data(bytes[$0..<min($0 + 11, bytes.count)]) }
        let rig = Rig(replies: [.init(status: 200, headers: ["content-type": "text/event-stream", "song-id": "s1"],
                                      chunks: pieces)])
        defer { rig.cleanUp() }
        let result = try await rig.client.call("compose_detailed_stream", arguments: ["prompt": "piano"])
        guard case .parts(let parts, let meta) = result, case .file(let url, _, 100) = parts.first,
              case .json(.array(let events)) = parts.last
        else { Issue.record("unexpected \(result)"); return }
        #expect(meta.headers["song-id"] == "s1")
        #expect(try Data(contentsOf: url) == Data((0..<100).map { UInt8($0) }))
        #expect(events.map { $0["event"].stringValue } == ["composition_plan", "audio_chunk", "done"])
        #expect(events[1]["audio_base64_bytes"] == 100)
    }

    @Test func multipartMixedGivesTheMetadataAndTheSong() async throws {
        let song = Data((0..<500).map { UInt8($0 % 256) })
        var body = Data("--b0undary\r\nContent-Type: application/json\r\n\r\n{\"song_metadata\":{\"title\":\"T\"}}\r\n".utf8)
        body.append(Data("--b0undary\r\nContent-Type: audio/mpeg\r\nContent-Disposition: attachment; filename=\"song.mp3\"\r\n\r\n".utf8))
        body.append(song)
        body.append(Data("\r\n--b0undary--\r\n".utf8))
        let rig = Rig(replies: [.init(status: 200, headers: ["content-type": "multipart/mixed; boundary=b0undary"], body: body)])
        defer { rig.cleanUp() }
        let result = try await rig.client.call("compose_detailed", arguments: ["prompt": "piano"])
        guard case .parts(let parts, _) = result, case .json(let metadata) = parts.first,
              case .file(let url, "audio/mpeg", 500) = parts.last
        else { Issue.record("unexpected \(result)"); return }
        #expect(metadata["song_metadata"]["title"] == "T")
        #expect(url.lastPathComponent == "song.mp3")
        #expect(try Data(contentsOf: url) == song)
    }

    @Test func base64AudioInsideJSONIsSavedAsFiles() async throws {
        let clip = Data(repeating: 7, count: 30)
        let rig = Rig(replies: [.json([
            "previews": [
                ["generated_voice_id": "g1", "audio_base_64": .string(clip.base64EncodedString())],
                ["generated_voice_id": "g2", "audio_base_64": .string(clip.base64EncodedString())],
            ],
        ])])
        defer { rig.cleanUp() }
        let result = try await rig.client.call("text_to_voice_design", arguments: ["voice_description": "a calm narrator voice for audiobooks"])
        guard case .parts(let parts, _) = result, case .json(let json) = parts.first else {
            Issue.record("unexpected \(result)"); return
        }
        #expect(json["previews"][0] == ["generated_voice_id": "g1", "audio_base_64_bytes": 30])
        #expect(result.files.count == 2)
        for url in result.files { #expect(try Data(contentsOf: url) == clip) }
    }

    @Test func emptyTextAndZipAnswersComeBackAsWhatTheyAre() async throws {
        let rig = Rig(replies: [
            .init(status: 204),
            .init(status: 200, headers: ["content-type": "text/html; charset=utf-8"], body: Data("<p>doc</p>".utf8)),
            .init(status: 200, headers: ["content-type": "application/zip"], body: Data("PK\u{3}\u{4}zip".utf8)),
        ])
        defer { rig.cleanUp() }
        guard case .json(.null, let meta) = try await rig.client.call("delete_voice", arguments: ["voice_id": "v"]) else {
            Issue.record("expected an empty JSON answer"); return
        }
        #expect(meta.status == 204)
        guard case .text("<p>doc</p>", _) = try await rig.client.call("get_knowledge_base_content", arguments: ["documentation_id": "d"]) else {
            Issue.record("expected text"); return
        }
        let zip = try await rig.client.call("download_speech_history_items", arguments: ["history_item_ids": ["h1", "h2"]])
        guard case .file(let url, "application/zip", _, _) = zip else { Issue.record("expected a zip"); return }
        #expect(url.pathExtension == "zip")
    }

    @Test func theAccountIsReadFromTheTwoFreeCalls() async throws {
        let rig = Rig(replies: [
            .json(["user_id": "user-1", "first_name": "Sam", "xi_api_key_preview": "sk_…abcd",
                   "subscription": ["tier": "starter"]]),
            .json(["tier": "starter", "status": "active", "character_count": 1_200, "character_limit": 30_000,
                   "next_character_count_reset_unix": 1_790_000_000, "voice_slots_used": 3, "voice_limit": 10,
                   "can_use_instant_voice_cloning": true]),
        ])
        defer { rig.cleanUp() }
        let account = try await rig.client.account()
        #expect(account.userID == "user-1")
        #expect(account.firstName == "Sam")
        #expect(account.tier == "starter")
        #expect(account.remainingCharacters == 28_800)
        #expect(account.nextResetAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(account.concurrencyLimit == 3)
        #expect(account.canUseInstantVoiceCloning == true)
        #expect(rig.transport.requests.map(\.url.path) == ["/v1/user", "/v1/user/subscription"])
        #expect(rig.transport.requests.allSatisfy { $0.method == "GET" })
    }

    // MARK: - Show API call

    @Test func describingACallShowsEverythingButTheKey() throws {
        let rig = Rig(replies: [])
        defer { rig.cleanUp() }
        let file = try Self.scratchFile("sample.wav", bytes: Data(count: 64))
        defer { Self.removeScratch(file) }
        let speech = try rig.client.describe("text_to_speech_full", arguments: [
            "voice_id": "v1", "text": "Hi", "output_format": "mp3_44100_128",
        ])
        #expect(speech.method == "POST")
        #expect(speech.url == "https://api.elevenlabs.io/v1/text-to-speech/v1?output_format=mp3_44100_128")
        #expect(speech.headers["xi-api-key"] == ElevenLabsRedaction.placeholder)
        #expect(speech.body == ["text": "Hi"])

        let upload = try rig.client.describe("audio_isolation", files: ["audio": [ElevenLabsFile(url: file)]])
        #expect(upload.body == ["audio": ["file": "sample.wav", "contentType": "audio/wav", "bytes": 64]])

        let podcast = try rig.client.describe("create_podcast", arguments: [
            "safety-identifier": "user-42", "model_id": "m", "mode": ["type": "conversation"],
            "source": ["type": "text", "text": "x"],
        ])
        #expect(podcast.headers["safety-identifier"] == "user-42")
        #expect(throws: ElevenLabsError.self) { try rig.client.describe("text_to_speech_full") }
        #expect(rig.credential.reads == 0)
    }

    // MARK: - Helpers

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private var _peak = 0
        func enter() { lock.withLock { current += 1; _peak = max(_peak, current) } }
        func leave() { lock.withLock { current -= 1 } }
        var peak: Int { lock.withLock { _peak } }
    }

    static func scratchFile(_ name: String, bytes: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    static func removeScratch(_ file: URL) {
        TemporaryFileSink.removeScratch(file.deletingLastPathComponent())
    }
}

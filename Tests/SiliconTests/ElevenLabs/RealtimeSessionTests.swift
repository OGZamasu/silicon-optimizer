import Foundation
import Testing
@testable import SiliconElevenLabs

/// The four realtime sessions against the in-memory socket: what each sends, in what order,
/// with what auth; how every spelling of every server message decodes; and the rules no caller
/// may be left to remember (pong at once, interrupted audio dropped, approvals once, declines on
/// the way out, no reconnect). Nothing here opens a network connection.
@Suite("ElevenLabs realtime sessions")
struct RealtimeSessionTests {

    static let key = "sk_" + String(repeating: "sessionfixture", count: 3)

    // MARK: - Speech, one context

    @Test func aSpeechStreamOpensOnItsRegionWithTheKeyInTheHeaderOnly() async throws {
        for region in ElevenLabsRegion.allCases {
            let rig = RealtimeRig(region: region)
            defer { rig.clean() }
            var config = ElevenLabsSpeechStreamConfig(voiceID: "voice_1", modelID: "eleven_flash_v2_5", outputFormat: "pcm_24000")
            config.inactivityTimeout = 60
            config.syncAlignment = true
            config.voiceSettings = .init(stability: 0.5, similarityBoost: 0.75, speed: 1.1)
            config.chunkLengthSchedule = [120, 160, 250, 290]
            config.pronunciationDictionaries = [.init(dictionaryID: "dict1", versionID: "v2")]
            let stream = try await rig.realtime.speechStream(config)
            let request = try #require(rig.connector.requests.first)
            #expect(request.url.scheme == "wss")
            #expect(request.url.host == region.host)
            #expect(request.url.path == "/v1/text-to-speech/voice_1/stream-input")
            #expect(request.header("xi-api-key") == Self.key)
            #expect(!request.url.absoluteString.contains(Self.key))
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value ?? "") })
            #expect(query == ["model_id": "eleven_flash_v2_5", "output_format": "pcm_24000",
                              "inactivity_timeout": "60", "sync_alignment": "true"])
            let socket = try #require(rig.connector.sockets.first)
            let first = try #require(await socket.nextSent())
            #expect(first == [
                "text": " ",
                "voice_settings": ["stability": 0.5, "similarity_boost": 0.75, "speed": 1.1],
                "generation_config": ["chunk_length_schedule": [120, 160, 250, 290]],
                "pronunciation_dictionary_locators": [["pronunciation_dictionary_id": "dict1", "version_id": "v2"]],
            ])
            #expect(rig.transport.requests.isEmpty, "no REST call is needed for speech")
            await stream.close()
        }
    }

    @Test func textGoesOutEndingInOneSpaceAndTheEndIsTheOnlyEmptyMessage() async throws {
        let rig = RealtimeRig()
        defer { rig.clean() }
        let stream = try await rig.realtime.speechStream(.init(voiceID: "v1", outputFormat: "pcm_16000"))
        let socket = try #require(rig.connector.sockets.first)
        _ = await socket.nextSent()
        try await stream.send("Hello")
        try await stream.send("there. ", flush: true)
        await #expect(throws: ElevenLabsRealtimeError.self) { try await stream.send("") }
        await #expect(throws: ElevenLabsRealtimeError.self) { try await stream.send("   ") }
        try await stream.keepAlive()
        try await stream.flush()
        try await stream.finish()
        await #expect(throws: ElevenLabsRealtimeError.ended) { try await stream.send("more") }
        await #expect(throws: ElevenLabsRealtimeError.ended) { try await stream.keepAlive() }
        var sent: [JSONValue] = []
        while let next = await socket.nextSent(timeout: .milliseconds(200)) { sent.append(next) }
        #expect(sent == [
            ["text": "Hello "], ["text": "there. ", "flush": true], ["text": " "], ["text": " ", "flush": true], ["text": ""],
        ])
        // A keepalive is a single space: never the empty text that ends the stream.
        #expect(sent.filter { $0["text"] == "" }.count == 1)
        #expect(stream.usage.charactersSent == "Hello".count + "there.".count)
        await stream.close()
    }

    @Test func speakingSplitsAtSentenceEndsAndFlushesTheLastPiece() async throws {
        let rig = RealtimeRig()
        defer { rig.clean() }
        let stream = try await rig.realtime.speechStream(.init(voiceID: "v1"))
        let socket = try #require(rig.connector.sockets.first)
        _ = await socket.nextSent()
        try await stream.speak("Welcome back to the show, everyone. Today we talk about sound!\nAnd then about light.")
        var sent: [JSONValue] = []
        while let next = await socket.nextSent(timeout: .milliseconds(200)) { sent.append(next) }
        let texts = sent.compactMap { $0["text"].stringValue }
        #expect(texts.allSatisfy { $0.hasSuffix(" ") && !$0.hasSuffix("  ") })
        #expect(texts.joined() == "Welcome back to the show, everyone. Today we talk about sound! And then about light. ")
        #expect(texts.count >= 2)
        #expect(sent.last?["flush"] == true)
        #expect(sent.dropLast().allSatisfy { $0["flush"] == .null })
        #expect(ElevenLabsTextChunker.chunks("   \n ").isEmpty)
        await stream.close()
    }

    /// camelCase from the schema, snake_case from the example frames: both, every key.
    @Test func speechAudioAlignmentAndTheEndDecodeInEitherSpelling() async throws {
        let rig = RealtimeRig(server: { socket in
            _ = await socket.nextSent()
            socket.push(["audio": .string(Data([1, 2, 3, 4]).base64EncodedString()), "isFinal": .null,
                         "alignment": ["chars": ["a", "b"], "charStartTimesMs": [0, 10], "charDurationsMs": [10, 20]],
                         "normalizedAlignment": ["chars": ["a"], "charStartTimesMs": [0], "charDurationsMs": [10]]])
            socket.push(["audio": .string(Data([5, 6]).base64EncodedString()), "is_final": false,
                         "alignment": ["chars": ["c"], "char_start_times_ms": [0], "char_durations_ms": [15]],
                         "normalized_alignment": ["chars": ["c"], "char_start_times_ms": [0], "char_durations_ms": [15]]])
            socket.push(["audio": .null, "isFinal": false])
            socket.push(["message": .string("Voice not found: " + Self.key)])
            socket.push(["surprise": true])
            socket.push(["is_final": true])
            socket.serverClose(code: 1000, reason: "")
        })
        defer { rig.clean() }
        let stream = try await rig.realtime.speechStream(.init(voiceID: "v1", outputFormat: "pcm_16000"))
        var events: [ElevenLabsSpeechStreamEvent] = []
        for await event in stream.events { events.append(event) }
        #expect(events == [
            .audio(Data([1, 2, 3, 4]), alignment: .init(characters: ["a", "b"], startTimesMs: [0, 10], durationsMs: [10, 20]),
                   normalizedAlignment: .init(characters: ["a"], startTimesMs: [0], durationsMs: [10])),
            .audio(Data([5, 6]), alignment: .init(characters: ["c"], startTimesMs: [0], durationsMs: [15]),
                   normalizedAlignment: .init(characters: ["c"], startTimesMs: [0], durationsMs: [15])),
            .message("Voice not found: ‹redacted›"),
            .unknown(["surprise"]),
            .final,
            .ended(.init(code: 1000, reason: "")),
        ])
        #expect(stream.usage.audioBytesReceived == 6)
        #expect(abs(stream.usage.audioSecondsReceived - 6.0 / 32_000) < 1e-12)
    }

    @Test func speechSettingsElevenLabsWouldRefuseOpenNothing() async throws {
        let rig = RealtimeRig()
        defer { rig.clean() }
        let refused: [(ElevenLabsSpeechStreamConfig, String)] = [
            (.init(voiceID: "v1", modelID: "eleven_v3"), "eleven_v3 is not available"),
            (.init(voiceID: "v1", modelID: "eleven_v4_alpha"), "not available when streaming"),
            (.init(voiceID: "a/b"), "voice_id must be an id"),
            (.init(voiceID: "a b"), "voice_id must be an id"),
            (.init(voiceID: ".."), "voice_id must be an id"),
            (.init(voiceID: ""), "voice_id is required"),
            (.init(voiceID: "v1", outputFormat: "pcm_48000"), "output_format must be one of"),
            (.init(voiceID: "v1", inactivityTimeout: 181), "inactivity_timeout"),
            (.init(voiceID: "v1", seed: -1), "seed"),
            (.init(voiceID: "v1", applyTextNormalization: "maybe"), "apply_text_normalization"),
            (.init(voiceID: "v1", voiceSettings: .init(speed: 1.5)), "speed must be from 0.7 to 1.2"),
            (.init(voiceID: "v1", voiceSettings: .init(stability: 2)), "stability"),
            (.init(voiceID: "v1", chunkLengthSchedule: [40]), "chunk_length_schedule"),
        ]
        for (config, words) in refused {
            do {
                _ = try await rig.realtime.speechStream(config)
                Issue.record("\(config) was not refused")
            } catch ElevenLabsRealtimeError.invalidConfiguration(let problems) {
                #expect(problems.joined(separator: " ").contains(words), "\(problems)")
            }
        }
        #expect(rig.connector.requests.isEmpty)
        #expect(rig.credentials.reads == 0, "the key is not read for settings that are refused")
    }

    @Test func noKeyOrALockedKeychainOpensNothing() async throws {
        let unlinked = RealtimeRig(key: nil)
        defer { unlinked.clean() }
        await #expect(throws: ElevenLabsRealtimeError.notLinked) {
            _ = try await unlinked.realtime.transcriptionStream(.init())
        }
        #expect(unlinked.connector.requests.isEmpty)

        let locked = RealtimeRig()
        defer { locked.clean() }
        locked.credentials.setFailure(.credentialUnavailable("the Keychain is locked"))
        await #expect(throws: ElevenLabsRealtimeError.credentialUnavailable("the Keychain is locked")) {
            _ = try await locked.realtime.speechStream(.init(voiceID: "v1"))
        }
        #expect(locked.connector.requests.isEmpty)
    }

    // MARK: - Speech, several contexts

    @Test func everyMessageNamesItsContextAndAtMostFiveAreOpen() async throws {
        let rig = RealtimeRig()
        defer { rig.clean() }
        let stream = try await rig.realtime.multiContextSpeechStream(.init(voiceID: "v1", voiceSettings: .init(stability: 0.3)))
        let request = try #require(rig.connector.requests.first)
        #expect(request.url.path == "/v1/text-to-speech/v1/multi-stream-input")
        #expect(request.header("xi-api-key") == Self.key)
        let socket = try #require(rig.connector.sockets.first)
        for index in 1...5 { try await stream.openContext("c\(index)") }
        await #expect(throws: ElevenLabsRealtimeError.self) { try await stream.openContext("c6") }
        try await stream.send("Hello", context: "c1", flush: true)
        try await stream.flush(context: "c2")
        try await stream.keepAlive(context: "c3")
        try await stream.closeContext("c4")
        await #expect(throws: ElevenLabsRealtimeError.self) { try await stream.send("x", context: "c4") }
        try await stream.openContext("c6", text: "Now me")
        await #expect(throws: ElevenLabsRealtimeError.self) { try await stream.openContext("bad/id") }
        try await stream.closeSocket()
        var sent: [JSONValue] = []
        while let next = await socket.nextSent(timeout: .milliseconds(200)) { sent.append(next) }
        #expect(sent[0] == ["text": " ", "context_id": "c1", "voice_settings": ["stability": 0.3]])
        #expect(Array(sent[5...]) == [
            ["context_id": "c1", "text": "Hello ", "flush": true],
            ["context_id": "c2", "flush": true],
            // Here "" with a context id is that context's keepalive, not an end.
            ["context_id": "c3", "text": ""],
            ["context_id": "c4", "close_context": true],
            ["context_id": "c6", "text": "Now me ", "voice_settings": ["stability": 0.3]],
            ["close_socket": true],
        ])
        #expect(sent.allSatisfy { $0["contextId"] == .null }, "the client sends context_id, never contextId")
        await stream.close()
    }

    @Test func audioForAClosedContextIsDroppedAndBothSpellingsDecode() async throws {
        let rig = RealtimeRig(server: { socket in
            _ = await socket.nextSent()  // c1
            _ = await socket.nextSent()  // c2
            _ = await socket.nextSent()  // close c1
            socket.push(["audio": .string(Data([1]).base64EncodedString()), "contextId": "c1"])
            socket.push(["audio": .string(Data([2]).base64EncodedString()), "context_id": "c2", "is_final": false])
            socket.push(["isFinal": true, "context_id": "c2"])
            socket.push(["is_final": true, "contextId": "c1"])
            socket.serverClose(code: 1000, reason: "")
        })
        defer { rig.clean() }
        let stream = try await rig.realtime.multiContextSpeechStream(.init(voiceID: "v1"))
        try await stream.openContext("c1")
        try await stream.openContext("c2")
        try await stream.closeContext("c1")
        var events: [ElevenLabsSpeechMultiStreamEvent] = []
        for await event in stream.events { events.append(event) }
        #expect(events == [
            .audio(context: "c2", Data([2]), alignment: nil, normalizedAlignment: nil),
            .contextFinished("c2"),
            .contextFinished("c1"),
            .ended(.init(code: 1000, reason: "")),
        ])
    }

    // MARK: - Transcription

    @Test func theTranscriptionQueryCarriesTheSettingsAndTheHeaderTheKey() async throws {
        let rig = RealtimeRig(region: .eu)
        defer { rig.clean() }
        var config = ElevenLabsTranscriptionStreamConfig(audioFormat: .ulaw)
        config.commitStrategy = .vad
        config.vadSilenceThresholdSeconds = 1.5
        config.vadThreshold = 0.4
        config.minSpeechDurationMs = 100
        config.minSilenceDurationMs = 200
        config.languageCode = "en"
        config.secondaryLanguages = ["de", "fra"]
        config.includeTimestamps = true
        config.includeLanguageDetection = false
        config.keyterms = ["Silicon", "ElevenLabs"]
        config.noVerbatim = true
        config.entityDetection = ["pii", "email_address"]
        config.enableLogging = false
        let stream = try await rig.realtime.transcriptionStream(config)
        let request = try #require(rig.connector.requests.first)
        #expect(request.url.host == "api.eu.residency.elevenlabs.io")
        #expect(request.url.path == "/v1/speech-to-text/realtime")
        #expect(request.header("xi-api-key") == Self.key)
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!.map { "\($0.name)=\($0.value ?? "")" }
        #expect(items == [
            "model_id=scribe_v2_realtime", "audio_format=ulaw_8000", "commit_strategy=vad",
            "vad_silence_threshold_secs=1.5", "vad_threshold=0.4", "min_speech_duration_ms=100",
            "min_silence_duration_ms=200", "language_code=en", "secondary_languages=de", "secondary_languages=fra",
            "include_timestamps=true", "include_language_detection=false", "keyterms=Silicon", "keyterms=ElevenLabs",
            "no_verbatim=true", "entity_detection=pii", "entity_detection=email_address", "enable_logging=false",
        ])
        #expect(!request.url.absoluteString.contains(Self.key))
        #expect(config.costAddOns == ["Key terms add 20 % to the transcription cost."])
        await stream.close()
    }

    @Test func transcriptionSettingsElevenLabsWouldRefuseOpenNothing() async throws {
        let rig = RealtimeRig()
        defer { rig.clean() }
        func refused(_ change: (inout ElevenLabsTranscriptionStreamConfig) -> Void, _ words: String) async {
            var config = ElevenLabsTranscriptionStreamConfig()
            change(&config)
            do {
                _ = try await rig.realtime.transcriptionStream(config)
                Issue.record("not refused: \(words)")
            } catch ElevenLabsRealtimeError.invalidConfiguration(let problems) {
                #expect(problems.joined(separator: " ").contains(words), "\(problems)")
            } catch {
                Issue.record("\(error)")
            }
        }
        await refused({ $0.transcriptEdit = "Fix names"; $0.entityDetection = ["all"] }, "cannot be combined with entity_detection")
        await refused({ $0.filterBackgroundAudio = true; $0.includeTimestamps = true }, "cannot be combined with include_timestamps")
        await refused({ $0.keyterms = (0...50).map { "t\($0)" } }, "At most 50 key terms")
        await refused({ $0.keyterms = [String(repeating: "x", count: 21)] }, "1 to 20 characters")
        await refused({ $0.vadThreshold = 0.95 }, "vad_threshold")
        await refused({ $0.vadSilenceThresholdSeconds = 0.1 }, "vad_silence_threshold_secs")
        await refused({ $0.minSpeechDurationMs = 10 }, "min_speech_duration_ms")
        await refused({ $0.audioFormat = .pcm(rate: 32_000) }, "audio_format must be one of")
        await refused({ $0.languageCode = "english" }, "language code")
        await refused({ $0.transcriptEdit = String(repeating: "e", count: 2_001) }, "at most 2000")
        #expect(rig.connector.requests.isEmpty)
    }

    @Test func audioGoesInPiecesOfASecondWithPreviousTextOnTheFirstOnly() async throws {
        let rig = RealtimeRig()
        defer { rig.clean() }
        var config = ElevenLabsTranscriptionStreamConfig()
        config.previousText = "A talk about sound."
        config.transcriptEdit = "Spell brand names correctly."
        let stream = try await rig.realtime.transcriptionStream(config)
        let socket = try #require(rig.connector.sockets.first)
        try await stream.sendAudio(Data(repeating: 1, count: 80_000))  // 2.5 s at 16 kHz
        try await stream.commit()
        try await stream.sendAudio(Data(repeating: 2, count: 3_200))
        var sent: [JSONValue] = []
        while let next = await socket.nextSent(timeout: .milliseconds(200)) { sent.append(next) }
        #expect(sent.count == 5)
        #expect(sent.allSatisfy { $0["message_type"] == "input_audio_chunk" && $0["sample_rate"] == 16_000 })
        let sizes = sent.map { Data(base64Encoded: $0["audio_base_64"].stringValue ?? "")?.count ?? -1 }
        #expect(sizes == [32_000, 32_000, 16_000, 0, 3_200])
        #expect(sent[0]["previous_text"] == "A talk about sound.")
        #expect(sent.dropFirst().allSatisfy { $0["previous_text"] == .null })
        #expect(sent[3] == ["message_type": "input_audio_chunk", "audio_base_64": "", "commit": true, "sample_rate": 16_000])
        #expect(sent.enumerated().allSatisfy { $0.element["commit"] == .bool($0.offset == 3) })
        #expect(stream.usage.audioSecondsSent == 2.6)
        #expect(stream.usage.commits == 1)
        #expect(config.costAddOns.contains("A transcript edit adds 30 %, billed for at least 10 seconds of audio per commit."))
        await stream.close()
        await #expect(throws: ElevenLabsRealtimeError.ended) { try await stream.sendAudio(Data([0, 0])) }
    }

    @Test func everyTranscriptionMessageDecodes() async throws {
        let errors = ["auth_error", "quota_exceeded", "transcriber_error", "input_error", "invalid_request", "error",
                      "commit_throttled", "unaccepted_terms", "rate_limited", "queue_overflow", "resource_exhausted",
                      "session_time_limit_exceeded", "chunk_size_exceeded", "insufficient_audio_activity"]
        let rig = RealtimeRig(server: { socket in
            socket.push(["message_type": "session_started", "session_id": "s1", "config": ["sample_rate": 16_000]])
            socket.push(["message_type": "partial_transcript", "text": "hel"])
            socket.push(["message_type": "committed_transcript", "text": "hello"])
            socket.push(["message_type": "committed_transcript_with_timestamps", "text": "hello", "language_code": "en",
                         "words": [["text": "hello", "start": 0.1, "end": 0.5, "type": "word", "speaker_id": "s0",
                                    "characters": ["h", "e"]],
                                   ["text": "(laughs)", "start": "0.6", "end": 0.9, "type": "audio_event",
                                    "characters": [["text": "(", "start": 0.6]]]]])
            socket.push(["message_type": "committed_transcript_entities", "text": "mail a@b.c",
                         "entities": [["text": "a@b.c", "entity_type": "email_address", "start_char": 5, "end_char": 10]]])
            socket.push(["message_type": "edited_transcript", "text": "hello", "edited_text": "Hello."])
            socket.push(["message_type": "warning", "warning": "zero retention was not applied"])
            socket.push(["message_type": "final_transcript", "text": "hello"])
            for type in errors { socket.push(["message_type": .string(type), "error": .string("bad \(type)")]) }
            socket.push(["message_type": "something_new", "text": "?"])
            socket.serverClose(code: 1008, reason: "quota")
        })
        defer { rig.clean() }
        let stream = try await rig.realtime.transcriptionStream(.init())
        var events: [ElevenLabsTranscriptionStreamEvent] = []
        for await event in stream.events { events.append(event) }
        #expect(Array(events.prefix(8)) == [
            .started(sessionID: "s1", config: ["sample_rate": 16_000]),
            .partial("hel"),
            .committed("hello"),
            .committedWithTimestamps(text: "hello", languageCode: "en", words: [
                .init(text: "hello", start: 0.1, end: 0.5, type: "word", speakerID: "s0"),
                .init(text: "(laughs)", start: 0.6, end: 0.9, type: "audio_event", speakerID: nil),
            ]),
            .entities(text: "mail a@b.c", [ElevenLabsTranscriptEntity(json: ["text": "a@b.c", "entity_type": "email_address",
                                                                             "start_char": 5, "end_char": 10])!]),
            .edited(text: "hello", editedText: "Hello."),
            .warning("zero retention was not applied"),
            .finalTranscript("hello"),
        ])
        #expect(Array(events.dropFirst(8).prefix(errors.count)) == errors.map { .error(type: $0, message: "bad \($0)") })
        #expect(events.dropLast().last == .unknown("something_new"))
        #expect(events.last == .ended(.init(code: 1008, reason: "quota")))
        #expect(stream.usage.connectedAt != nil)
    }

    // MARK: - Agents: reaching the agent

    @Test func aPublicAgentIsReachedByItsIdAndTheSocketGetsNoKey() async throws {
        let rig = RealtimeRig(replies: { request in
            request.operationID == "get_agent_route"
                ? .json(["agent_id": "agent_1", "name": "Support", "platform_settings": ["auth": ["enable_auth": false]]])
                : .jsonText("{}", status: 500)
        }, server: RealtimeRig.agentServer())
        defer { rig.clean() }
        let conversation = try await rig.realtime.agentConversation(.init(agentID: "agent_1"))
        let request = try #require(rig.connector.requests.first)
        #expect(request.url.absoluteString == "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=agent_1")
        #expect(request.headers.isEmpty)
        #expect(rig.transport.requests.map(\.operationID) == ["get_agent_route"])
        #expect(rig.transport.requests.first?.header("xi-api-key") == Self.key, "the key goes to REST only")
        #expect(conversation.startedWith == .init(conversationID: "conv_1", agentOutputAudioFormat: "pcm_16000",
                                                  userInputAudioFormat: "pcm_16000"))
        await conversation.end()
    }

    @Test func anAgentWithAuthIsReachedByASignedURLThatIsNeverShown() async throws {
        let signed = "wss://api.us.elevenlabs.io/v1/convai/conversation?agent_id=agent_2&conversation_signature=sig_SECRET_123"
        let rig = RealtimeRig(replies: { request in
            switch request.operationID {
            case "get_agent_route":
                .json(["agent_id": "agent_2", "platform_settings": ["auth": ["enable_auth": true]]])
            case "get_conversation_signed_link":
                .json(["signed_url": .string(signed)])
            default:
                .jsonText("{}", status: 500)
            }
        }, server: RealtimeRig.agentServer())
        defer { rig.clean() }
        let conversation = try await rig.realtime.agentConversation(.init(agentID: "agent_2"))
        #expect(rig.transport.requests.map(\.operationID) == ["get_agent_route", "get_conversation_signed_link"])
        let mint = try #require(rig.transport.requests.last)
        #expect(mint.url.query?.contains("agent_id=agent_2") == true)
        let request = try #require(rig.connector.requests.first)
        #expect(request.url.absoluteString == signed, "the signed URL is used exactly as ElevenLabs made it")
        #expect(request.headers.isEmpty, "no key on the agent's socket")
        #expect(!request.description.contains("sig_SECRET_123"))
        #expect(!String(reflecting: request).contains("sig_SECRET_123"))
        var dumped = ""
        dump(request, to: &dumped)
        #expect(!dumped.contains("sig_SECRET_123"))
        #expect(request.description.contains("agent_id=agent_2"))
        await conversation.end()
    }

    @Test func aSignedURLThatIsNotAnElevenLabsConversationIsNeverOpened() async throws {
        for signed in [
            "wss://evil.example.com/v1/convai/conversation?conversation_signature=x",
            "ws://api.elevenlabs.io/v1/convai/conversation?conversation_signature=x",
            "https://api.elevenlabs.io/v1/convai/conversation?conversation_signature=x",
            "wss://api.elevenlabs.io/v1/speech-to-text/realtime?token=x",
            "wss://user:pass@api.elevenlabs.io/v1/convai/conversation",
            "wss://api.elevenlabs.io:9443/v1/convai/conversation",
        ] {
            let rig = RealtimeRig(replies: { _ in .json(["signed_url": .string(signed)]) }, server: RealtimeRig.agentServer())
            defer { rig.clean() }
            await #expect(throws: ElevenLabsRealtimeError.self, "\(signed)") {
                _ = try await rig.realtime.agentConversation(.init(agentID: "agent_2", auth: .signedURL))
            }
            #expect(rig.connector.requests.isEmpty, "\(signed)")
        }
    }

    @Test func aFailedSignedLinkOpensNothingAndSaysWhy() async throws {
        let rig = RealtimeRig(replies: { _ in .jsonText(#"{"detail":"upstream"}"#, status: 503) }, server: RealtimeRig.agentServer())
        defer { rig.clean() }
        do {
            _ = try await rig.realtime.agentConversation(.init(agentID: "agent_2", auth: .signedURL))
            Issue.record("expected a failure")
        } catch ElevenLabsRealtimeError.signedLink(let inner) {
            guard case .api(503, _, _, _) = inner else { Issue.record("\(inner)"); return }
        }
        #expect(rig.connector.requests.isEmpty)
        // A read, so the client retried it; nothing was opened meanwhile.
        #expect(rig.transport.requests.allSatisfy { $0.operationID == "get_conversation_signed_link" })
    }

    @Test func textOnlyFollowsWhatTheAgentAllows() async throws {
        func preflight(textOnly: Bool, overrideAllowed: Bool) -> ElevenLabsAgentPreflight {
            ElevenLabsAgentPreflight(agentID: "agent_1", json: [
                "platform_settings": ["auth": ["enable_auth": false],
                                      "overrides": ["conversation_config_override": ["conversation": ["text_only": .bool(overrideAllowed)]]]],
                "conversation_config": ["conversation": ["text_only": .bool(textOnly)]],
            ])
        }
        let config = ElevenLabsAgentConversationConfig(agentID: "agent_1", textOnly: true)
        // Not allowed: refused before anything opens, saying what to change.
        let rig = RealtimeRig(server: RealtimeRig.agentServer())
        defer { rig.clean() }
        do {
            _ = try await rig.realtime.agentConversation(config, preflight: preflight(textOnly: false, overrideAllowed: false))
            Issue.record("expected a refusal")
        } catch ElevenLabsRealtimeError.invalidConfiguration(let problems) {
            #expect(problems.first?.contains("does not allow text-only") == true)
        }
        #expect(rig.connector.requests.isEmpty)
        // Allowed: the override is sent. Already text-only: none is needed.
        let allowed = try config.initiation(preflight: preflight(textOnly: false, overrideAllowed: true))
        #expect(allowed["conversation_config_override"]["conversation"]["text_only"] == true)
        let already = try config.initiation(preflight: preflight(textOnly: true, overrideAllowed: false))
        #expect(already["conversation_config_override"] == .null)
        // A voice conversation sends no override at all, and never claims to be one of the SDKs.
        let voice = try ElevenLabsAgentConversationConfig(agentID: "agent_1").initiation(preflight: nil)
        #expect(voice == ["type": "conversation_initiation_client_data"])
    }

    /// Before a conversation, every tool the agent has is named with where it reaches, and the
    /// ones that act beyond the conversation are marked: webhooks (their host), transfers, keypad
    /// tones, MCP servers, workspace tools this app cannot see into.
    @Test func anAgentsToolsAreNamedWithWhereTheyReach() {
        let preflight = ElevenLabsAgentPreflight(agentID: "a", json: ["conversation_config": ["agent": ["prompt": [
            "tools": [
                ["type": "webhook", "name": "lookup_order", "api_schema": ["url": "https://API.example.com:8443/orders/{order_id}?x=1"]],
                ["type": "client", "name": "open_page"],
                ["type": "system", "name": "end_call", "params": ["system_tool_type": "end_call"]],
                ["type": "system", "name": "transfer", "params": ["system_tool_type": "transfer_to_number"]],
                ["type": "mcp", "name": "x", "mcp_tool_name": "send_email", "mcp_server_name": "Mail", "mcp_server_id": "mcp_1"],
                ["type": "api_integration_webhook", "name": "crm_update"],
                ["type": "something_new", "name": "mystery"],
            ],
            "built_in_tools": ["play_keypad_touch_tone": ["name": "play_keypad_touch_tone"], "language_detection": ["name": "x"], "skip_turn": nil],
            "tool_ids": ["tool_9"],
            "mcp_server_ids": ["mcp_2"],
        ]]]])
        #expect(preflight.tools == [
            .init(name: "lookup_order", kind: .webhook, host: "api.example.com", actsInTheRealWorld: true),
            .init(name: "open_page", kind: .client, actsInTheRealWorld: false),
            .init(name: "end_call", kind: .system, actsInTheRealWorld: false),
            .init(name: "transfer", kind: .system, actsInTheRealWorld: true),
            .init(name: "send_email", kind: .mcp, host: "Mail", actsInTheRealWorld: true),
            .init(name: "crm_update", kind: .integration, actsInTheRealWorld: true),
            .init(name: "mystery", kind: .other, actsInTheRealWorld: true),
            .init(name: "language_detection", kind: .system, actsInTheRealWorld: false),
            .init(name: "play_keypad_touch_tone", kind: .system, actsInTheRealWorld: true),
            .init(name: "tool_9", kind: .workspace, actsInTheRealWorld: true),
            .init(name: "tools of MCP server mcp_2", kind: .mcp, host: "mcp_2", actsInTheRealWorld: true),
        ])
        #expect(preflight.realWorldTools.count == 8)
        #expect(ElevenLabsAgentToolSummary.host(of: "https://user:pw@hooks.example.com/x") == "hooks.example.com")
        #expect(ElevenLabsAgentToolSummary.host(of: "not a url") == nil)
        #expect(ElevenLabsAgentPreflight(agentID: "a", json: [:]).tools.isEmpty)
    }

    /// A caller's own `conversation.text_only` never reaches the agent: text-only stays text-only.
    @Test func aCallersOverrideCannotTurnTextOnlyOff() throws {
        func preflight(textOnly: Bool, allowed: Bool) -> ElevenLabsAgentPreflight {
            ElevenLabsAgentPreflight(agentID: "a", json: [
                "platform_settings": ["overrides": ["conversation_config_override": ["conversation": ["text_only": .bool(allowed)]]]],
                "conversation_config": ["conversation": ["text_only": .bool(textOnly)]],
            ])
        }
        var config = ElevenLabsAgentConversationConfig(agentID: "a", textOnly: true)
        config.overrides = ["conversation": ["text_only": false, "max_duration_seconds": 120], "agent": ["language": "en"]]
        let byDefault = try config.initiation(preflight: preflight(textOnly: true, allowed: true))
        #expect(byDefault["conversation_config_override"]["conversation"] == ["max_duration_seconds": 120])
        #expect(byDefault["conversation_config_override"]["agent"] == ["language": "en"])
        let overridden = try config.initiation(preflight: preflight(textOnly: false, allowed: true))
        #expect(overridden["conversation_config_override"]["conversation"] == ["text_only": true, "max_duration_seconds": 120])
        config.overrides = ["conversation": ["text_only": false]]
        let only = try config.initiation(preflight: preflight(textOnly: true, allowed: false))
        #expect(only["conversation_config_override"] == .null)
    }

    @Test func anAgentThatDoesNotSayWhetherItNeedsAuthGetsASignedURL() {
        #expect(ElevenLabsAgentPreflight(agentID: "a", json: [:]).requiresAuthentication)
        #expect(!ElevenLabsAgentPreflight(agentID: "a", json: ["platform_settings": ["auth": ["enable_auth": false]]]).requiresAuthentication)
    }

    // MARK: - Agents: the conversation

    @Test func theInitiationGoesFirstAndTheConversationStartsOnItsMetadata() async throws {
        let rig = RealtimeRig(server: { socket in
            guard let first = await socket.nextSent(), first["type"] == "conversation_initiation_client_data" else { return }
            socket.push(["type": "conversation_initiation_metadata", "conversation_initiation_metadata_event": [
                "conversation_id": "conv_9", "agent_output_audio_format": "pcm_44100", "user_input_audio_format": "ulaw_8000",
            ]])
        })
        defer { rig.clean() }
        var config = ElevenLabsAgentConversationConfig(agentID: "agent_1", auth: .publicAgent)
        config.dynamicVariables = ["user_name": "Ada"]
        config.overrides = ["agent": ["first_message": "Hi Ada"]]
        config.keywords = ["Silicon"]
        config.userID = "owner"
        let conversation = try await rig.realtime.agentConversation(config)
        let socket = try #require(rig.connector.sockets.first)
        #expect(socket.sentJSON.first == [
            "type": "conversation_initiation_client_data",
            "conversation_config_override": ["agent": ["first_message": "Hi Ada"], "asr": ["keywords": ["Silicon"]]],
            "dynamic_variables": ["user_name": "Ada"], "user_id": "owner",
        ])
        #expect(conversation.startedWith?.outputEncoding == .pcm(rate: 44_100))
        #expect(conversation.startedWith?.inputEncoding == .ulaw)
        try await conversation.sendAudio(Data(repeating: 0xFF, count: 800))
        #expect(socket.sentJSON.last == ["user_audio_chunk": .string(Data(repeating: 0xFF, count: 800).base64EncodedString())])
        #expect(conversation.usage.audioSecondsSent == 0.1)
        await conversation.end()
    }

    @Test func aConversationClosedBeforeItStartedSaysHow() async throws {
        let rig = RealtimeRig(server: { socket in
            _ = await socket.nextSent()
            socket.serverClose(code: 1008, reason: "Invalid conversation signature")
        })
        defer { rig.clean() }
        await #expect(throws: ElevenLabsRealtimeError.closed(.init(code: 1008, reason: "Invalid conversation signature"))) {
            _ = try await rig.realtime.agentConversation(.init(agentID: "agent_1", auth: .publicAgent))
        }
    }

    @Test func anAgentThatNeverStartsTimesOutAndIsClosed() async throws {
        var rig = RealtimeRig(server: { _ in })
        defer { rig.clean() }
        rig.realtime.limits.agentStartTimeout = 0.3
        await #expect(throws: ElevenLabsRealtimeError.self) {
            _ = try await rig.realtime.agentConversation(.init(agentID: "agent_1", auth: .publicAgent))
        }
        let socket = try #require(rig.connector.sockets.first)
        #expect(socket.closedByClient?.code == 1000)
    }

    @Test func everyPingIsAnsweredAtOnceWithItsEventID() async throws {
        let rig = RealtimeRig(server: RealtimeRig.agentServer { socket in
            socket.push(["type": "ping", "ping_event": ["event_id": "12", "ping_ms": 40]])
            socket.push(["type": "ping", "ping_event": ["event_id": 13]])
        })
        defer { rig.clean() }
        let conversation = try await rig.realtime.agentConversation(.init(agentID: "agent_1", auth: .publicAgent))
        let socket = try #require(rig.connector.sockets.first)
        #expect(await socket.waitForSent(3))
        #expect(Array(socket.sentJSON.dropFirst().prefix(2)) == [["type": "pong", "event_id": 12], ["type": "pong", "event_id": 13]])
        var pings: [ElevenLabsAgentEvent] = []
        for await event in conversation.events {
            if case .ping = event { pings.append(event) }
            if pings.count == 2 { break }
        }
        #expect(pings == [.ping(eventID: 12, latencyMs: 40), .ping(eventID: 13, latencyMs: nil)])
        await conversation.end()
    }

    @Test func audioOfAnInterruptedResponseIsDropped() async throws {
        @Sendable func audio(_ id: Int) -> JSONValue {
            ["type": "audio", "audio_event": ["audio_base_64": .string(Data([UInt8(id)]).base64EncodedString()), "event_id": .number(Double(id))]]
        }
        let rig = RealtimeRig(server: RealtimeRig.agentServer { socket in
            socket.push(audio(3))
            socket.push(["type": "interruption", "interruption_event": ["event_id": 3]])
            socket.push(audio(3))
            socket.push(audio(2))
            socket.push(audio(4))
            socket.serverClose(code: 1000, reason: "")
        })
        defer { rig.clean() }
        let conversation = try await rig.realtime.agentConversation(.init(agentID: "agent_1", auth: .publicAgent))
        var played: [Int] = []
        for await event in conversation.events {
            if case .audio(let data, _, _, _) = event { played.append(Int(data[data.startIndex])) }
        }
        #expect(played == [3, 4])
        #expect(conversation.droppedAudioChunks == 2)
        #expect(ElevenLabsAgentConversation.dropsAudioAtTheInterruptedEvent)
    }

    @Test func anApprovalIsAnsweredOnceAndOnlyWhileElevenLabsWaits() async throws {
        let rig = RealtimeRig(server: RealtimeRig.agentServer { socket in
            socket.push(Self.mcpCall("call_1", state: "awaiting_approval"))
            socket.push(Self.mcpCall("call_2", state: "awaiting_approval"))
            socket.push(Self.mcpCall("call_2", state: "success"))
        })
        defer { rig.clean() }
        let conversation = try await rig.realtime.agentConversation(.init(agentID: "agent_1", auth: .publicAgent))
        var seen = 0
        for await event in conversation.events {
            if case .mcpToolCall = event { seen += 1 }
            if seen == 3 { break }
        }
        #expect(conversation.approvalsWaiting == ["call_1"])
        #expect(await conversation.answerApproval("call_1", approved: true))
        #expect(await conversation.answerApproval("call_1", approved: false) == false, "at most one answer")
        #expect(await conversation.answerApproval("call_2", approved: true) == false, "it moved on")
        #expect(await conversation.answerApproval("call_x", approved: true) == false)
        let socket = try #require(rig.connector.sockets.first)
        let answers = socket.sentJSON.filter { $0["type"] == "mcp_tool_approval_result" }
        #expect(answers == [["type": "mcp_tool_approval_result", "tool_call_id": "call_1", "is_approved": true]])
        await conversation.end()
    }

    @Test func endingDeclinesEveryApprovalStillWaitingBeforeItCloses() async throws {
        let rig = RealtimeRig(server: RealtimeRig.agentServer { socket in
            socket.push(Self.mcpCall("call_a", state: "awaiting_approval"))
            socket.push(Self.mcpCall("call_b", state: "awaiting_approval"))
        })
        defer { rig.clean() }
        let conversation = try await rig.realtime.agentConversation(.init(agentID: "agent_1", auth: .publicAgent))
        var seen = 0
        for await event in conversation.events {
            if case .mcpToolCall = event { seen += 1 }
            if seen == 2 { break }
        }
        await conversation.end()
        let socket = try #require(rig.connector.sockets.first)
        let tail = socket.sentJSON.suffix(2)
        #expect(Array(tail) == [
            ["type": "mcp_tool_approval_result", "tool_call_id": "call_a", "is_approved": false],
            ["type": "mcp_tool_approval_result", "tool_call_id": "call_b", "is_approved": false],
        ])
        #expect(socket.closedByClient == .init(code: 1000, reason: "User ended conversation"))
        #expect(await conversation.answerApproval("call_a", approved: true) == false)
    }

    /// A stalled connection cannot keep the conversation from ending: the close waits two
    /// seconds at most for what is queued.
    @Test func endingAStalledConversationStillCloses() async throws {
        let rig = RealtimeRig(server: RealtimeRig.agentServer { socket in
            socket.push(Self.mcpCall("call_s", state: "awaiting_approval"))
            socket.stallSends()
        })
        defer { rig.clean() }
        let conversation = try await rig.realtime.agentConversation(.init(agentID: "agent_1", auth: .publicAgent))
        for await event in conversation.events {
            if case .mcpToolCall = event { break }
        }
        let started = ContinuousClock.now
        await conversation.end()
        #expect(ContinuousClock.now - started < .seconds(4))
        let socket = try #require(rig.connector.sockets.first)
        #expect(socket.closedByClient == .init(code: 1000, reason: "User ended conversation"))
    }

    @Test func aClientToolCallIsAnsweredOnce() async throws {
        let rig = RealtimeRig(server: RealtimeRig.agentServer { socket in
            socket.push(["type": "client_tool_call", "client_tool_call": [
                "tool_name": "open_page", "tool_call_id": "tc_1", "parameters": ["url": "https://example.com"],
                "event_id": 5, "expects_response": true,
            ]])
        })
        defer { rig.clean() }
        let conversation = try await rig.realtime.agentConversation(.init(agentID: "agent_1", auth: .publicAgent))
        for await event in conversation.events {
            if case .clientToolCall(let call) = event {
                #expect(call == .init(toolCallID: "tc_1", toolName: "open_page", parameters: ["url": "https://example.com"],
                                      eventID: 5, expectsResponse: true))
                break
            }
        }
        try await conversation.answerClientTool("tc_1", result: "Not available here.", errorType: "user_rejected")
        await #expect(throws: ElevenLabsRealtimeError.self) { try await conversation.answerClientTool("tc_1", result: "again") }
        await #expect(throws: ElevenLabsRealtimeError.self) { try await conversation.answerClientTool("tc_2", result: "never asked") }
        let socket = try #require(rig.connector.sockets.first)
        #expect(socket.sentJSON.last == ["type": "client_tool_result", "tool_call_id": "tc_1", "result": "Not available here.",
                                         "is_error": true, "error_type": "user_rejected"])
        await conversation.end()
    }

    @Test func theOtherClientMessagesHaveTheirDocumentedShapes() async throws {
        let rig = RealtimeRig(server: RealtimeRig.agentServer())
        defer { rig.clean() }
        let conversation = try await rig.realtime.agentConversation(.init(agentID: "agent_1", auth: .publicAgent))
        try await conversation.sendUserMessage("  Hello  ")
        try await conversation.sendContextualUpdate("Opened pricing", contextID: "page")
        try await conversation.sendUserActivity()
        try await conversation.sendFeedback(eventID: 43, liked: true)
        try await conversation.sendFeedback(eventID: 43, liked: nil)
        try await conversation.sendMultimodal(text: "What is this?", fileIDs: ["file_1"])
        await #expect(throws: ElevenLabsRealtimeError.self) { try await conversation.sendUserMessage("   ") }
        await #expect(throws: ElevenLabsRealtimeError.self) { try await conversation.sendMultimodal(text: "x", fileIDs: []) }
        let socket = try #require(rig.connector.sockets.first)
        #expect(Array(socket.sentJSON.dropFirst()) == [
            ["type": "user_message", "text": "Hello"],
            ["type": "contextual_update", "text": "Opened pricing", "context_id": "page"],
            ["type": "user_activity"],
            ["type": "feedback", "event_id": 43, "score": "like"],
            ["type": "feedback", "event_id": 43, "score": nil],
            ["type": "multimodal_message", "text": ["type": "user_message", "text": "What is this?"],
             "files": [["type": "file_input", "file_id": "file_1"]]],
        ])
        #expect(conversation.usage.messagesSent == 2)
        await conversation.end()
        await #expect(throws: ElevenLabsRealtimeError.ended) { try await conversation.sendUserMessage("late") }
    }

    /// Every server event the sources list, nested under its documented key or flat, and both
    /// spellings of the error event.
    @Test func everyAgentEventDecodes() {
        let cases: [(JSONValue, ElevenLabsAgentEvent)] = [
            (["type": "user_transcript", "user_transcription_event": ["user_transcript": "hi", "event_id": 1]], .userTranscript("hi", eventID: 1)),
            (["type": "tentative_user_transcript", "tentative_user_transcription_event": ["user_transcript": "h", "event_id": "2"]],
             .tentativeUserTranscript("h", eventID: 2)),
            (["type": "agent_response", "agent_response_event": ["agent_response": "Hello", "event_id": 3, "response_id": "r1"]],
             .agentResponse("Hello", eventID: 3, responseID: "r1")),
            (["type": "agent_response_correction", "agent_response_correction_event": [
                "original_agent_response": "Hello there", "corrected_agent_response": "Hello", "event_id": 3]],
             .agentResponseCorrection(original: "Hello there", corrected: "Hello", eventID: 3)),
            (["type": "agent_chat_response_part", "text_response_part": ["text": "He", "type": "delta", "event_id": 4, "response_id": "r2"]],
             .agentResponsePart(text: "He", kind: "delta", eventID: 4, responseID: "r2")),
            (["type": "agent_response_complete", "agent_response_complete_event": ["event_id": 4]], .agentResponseComplete(eventID: 4)),
            (["type": "agent_response_metadata", "agent_response_metadata_event": ["metadata": ["k": 1], "event_id": 4]],
             .agentResponseMetadata(["k": 1], eventID: 4)),
            (["type": "context_usage", "context_usage_event": ["event_id": 4, "model": "m", "context_tokens": 10, "context_limit_tokens": 100]],
             .contextUsage(model: "m", tokens: 10, limit: 100)),
            (["type": "vad_score", "vad_score_event": ["vad_score": 0.75]], .vadScore(0.75)),
            (["type": "interruption", "interruption_event": ["event_id": 9]], .interruption(eventID: 9, reason: nil)),
            (["type": "interruption", "interruption_event": ["reason": "user"]], .interruption(eventID: nil, reason: "user")),
            (["type": "agent_tool_request", "agent_tool_request": ["tool_name": "transfer_to_number", "tool_call_id": "t1",
                                                                   "tool_type": "system", "event_id": 5]],
             .agentToolRequest(.init(toolCallID: "t1", toolName: "transfer_to_number", toolType: "system", eventID: 5))),
            (["type": "agent_tool_response", "agent_tool_response": ["tool_name": "lookup", "tool_call_id": "t2", "tool_type": "webhook",
                                                                     "is_error": false, "status": "success", "event_id": 6]],
             .agentToolResponse(.init(toolCallID: "t2", toolName: "lookup", toolType: "webhook", eventID: 6, status: "success", isError: false))),
            (["type": "agent_tool_response_full_payload", "agent_tool_response_full_payload": [
                "tool_name": "lookup", "tool_call_id": "t2", "full_tool_result": "{}", "truncated": false]],
             .agentToolResponse(.init(toolCallID: "t2", toolName: "lookup", fullResult: "{}", truncated: false))),
            (["type": "mcp_connection_status", "mcp_connection_status": ["integrations": []]], .mcpConnectionStatus(["integrations": []])),
            (["type": "queue_status", "queue_status_event": ["status": "waiting"]], .queueStatus("waiting")),
            (["type": "client_error", "error_event": ["code": 1008, "error_name": "override_error", "message": "not allowed"]],
             .error(.init(code: 1008, name: "override_error", message: "not allowed"))),
            (["type": "error", "error_event": ["code": 1000, "error_type": "max_duration_exceeded", "reason": "time"]],
             .error(.init(code: 1000, name: "max_duration_exceeded", message: "time"))),
            (["type": "error", "code": 1011, "message": .string("flat " + Self.key)], .error(.init(code: 1011, name: nil, message: "flat ‹redacted›"))),
            (["type": "guardrail_triggered", "guardrail_triggered_event": ["guardrail_name": "pii"]], .guardrailTriggered("pii")),
            (["type": "guardrail_triggered"], .guardrailTriggered(nil)),
            (["type": "agent_typing", "is_typing": true], .other(type: "agent_typing", payload: ["type": "agent_typing", "is_typing": true])),
            (["type": "brand_new_event"], .unknown("brand_new_event")),
        ]
        for (frame, expected) in cases {
            #expect(ElevenLabsAgentEvent.decode(frame) == expected, "\(frame)")
        }
    }

    /// No session reconnects: a dropped socket ends the session, and nothing opens another.
    @Test func aDroppedSocketEndsTheSessionAndNothingReconnects() async throws {
        let rig = RealtimeRig(server: RealtimeRig.agentServer { socket in socket.drop() })
        defer { rig.clean() }
        let conversation = try await rig.realtime.agentConversation(.init(agentID: "agent_1", auth: .publicAgent))
        var last: ElevenLabsAgentEvent?
        for await event in conversation.events { last = event }
        guard case .ended(let close) = last else { Issue.record("\(String(describing: last))"); return }
        #expect(close.kind == .error)
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.connector.requests.count == 1)
        #expect(conversation.usage.endedAt != nil)
    }

    @Test func errorsNeverCarryTheKey() {
        let wrapped = ElevenLabsRealtimeError(wrapping: ElevenLabsError.network("failed with \(Self.key)"), redactingKey: Self.key)
        #expect(!wrapped.description.contains(Self.key))
        let close = ElevenLabsSocketClose(code: 1008, reason: "bad key \(Self.key)")
        #expect(!close.description.contains(Self.key))
        let url = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime?token=sutkn_abc&model_id=scribe_v2_realtime&xi-api-key=\(Self.key)")!
        let shown = ElevenLabsRealtimeRedaction.describe(url)
        #expect(!shown.contains("sutkn_abc"))
        #expect(!shown.contains(Self.key))
        #expect(shown.contains("model_id=scribe_v2_realtime"))
    }

    static func mcpCall(_ id: String, state: String) -> JSONValue {
        ["type": "mcp_tool_call", "mcp_tool_call": [
            "service_id": "mcp_1", "tool_call_id": .string(id), "tool_name": "send_email", "tool_description": "Sends an email",
            "parameters": ["to": "someone@example.com"], "timestamp": "2026-09-30T10:00:00Z", "state": .string(state),
            "approval_timeout_secs": 300,
        ]]
    }
}

/// A client on the in-memory transport and socket, with a key that is not a real one.
struct RealtimeRig {
    let transport: FakeElevenLabsTransport
    let sink = TemporaryFileSink()
    let credentials: FakeCredentialSource
    let client: ElevenLabsClient
    let connector: FakeElevenLabsSocketConnector
    var realtime: ElevenLabsRealtime

    init(
        region: ElevenLabsRegion = .global, key: String? = RealtimeSessionTests.key,
        replies: @escaping @Sendable (ElevenLabsRequest) async throws -> FakeElevenLabsTransport.Reply = { _ in
            .jsonText(#"{"detail":"not scripted"}"#, status: 404)
        },
        server: @escaping FakeElevenLabsSocketConnector.Server = { _ in }
    ) {
        transport = FakeElevenLabsTransport(handler: replies)
        credentials = FakeCredentialSource(key: key)
        var limits = ElevenLabsClient.Limits()
        limits.firstBackoff = 0.01
        limits.longestRetryWait = 0.02
        client = ElevenLabsClient(credentials: credentials, region: region, transport: transport, sink: sink, limits: limits)
        connector = FakeElevenLabsSocketConnector(server: server)
        realtime = ElevenLabsRealtime(client: client, connector: connector)
    }

    func clean() {
        sink.removeAll()
        transport.removeTemporaryFiles()
    }

    /// An agent that starts the conversation (pcm_16000 both ways), then runs `then`.
    static func agentServer(
        then: @escaping @Sendable (FakeElevenLabsSocket) async -> Void = { _ in }
    ) -> FakeElevenLabsSocketConnector.Server {
        { socket in
            guard let first = await socket.nextSent(), first["type"] == "conversation_initiation_client_data" else { return }
            socket.push(["type": "conversation_initiation_metadata", "conversation_initiation_metadata_event": [
                "conversation_id": "conv_1", "agent_output_audio_format": "pcm_16000", "user_input_audio_format": "pcm_16000",
            ]])
            await then(socket)
        }
    }
}

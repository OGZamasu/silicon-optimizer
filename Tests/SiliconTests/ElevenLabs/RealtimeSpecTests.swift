import CryptoKit
import Foundation
import Testing
@testable import SiliconElevenLabs

/// The WebSocket APIs are not in the OpenAPI spec. Their AsyncAPI documents are pinned under
/// `Scripts/elevenlabs/asyncapi/`, the drift script compares them with the live docs, and these
/// tests hold the script's diff to two local files — nothing here fetches anything.
@Suite("ElevenLabs realtime spec snapshots")
struct RealtimeSpecTests {

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let pinnedFolder = repository.appendingPathComponent("Scripts/elevenlabs/asyncapi", isDirectory: true)
    static let names = ["tts-stream-input", "tts-multi-stream-input", "stt-realtime", "agents-conversation"]

    /// A refresh is deliberate: the new file's digest goes here, and the fidelity tests run again.
    static let pinnedDigests = [
        "tts-stream-input": "2731e1edc519b26d7c7f68d095fa0e38e5cf43b653896fdacf2b50d7398d33a8",
        "tts-multi-stream-input": "14e73703b3c4738215c1cd653d1891962d9dc149a83e5eb7d748310fdc18534f",
        "stt-realtime": "deb6c49fcb80c0c057f36e3b3bf44fdec573488978dd56be663bd988b636ad61",
        "agents-conversation": "400b77fce9ef545af88face872a69622085dd753d832245ac21d54d0354b837c",
    ]

    @Test func theFourSnapshotsArePinned() throws {
        for name in Self.names {
            let data = try Data(contentsOf: Self.pinnedFolder.appendingPathComponent("\(name).yaml"))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(digest == Self.pinnedDigests[name], "\(name).yaml changed; update the digest after reviewing the drift")
            #expect(String(decoding: data, as: UTF8.self).hasPrefix("asyncapi: 2.6.0"))
        }
    }

    @Test func theDiffListsWhatChangedInTheSockets() throws {
        let scratch = try Self.scratch()
        defer { TemporaryFileSink.removeScratch(scratch) }
        for name in Self.names {
            try FileManager.default.copyItem(
                at: Self.pinnedFolder.appendingPathComponent("\(name).yaml"),
                to: scratch.appendingPathComponent("\(name).yaml")
            )
        }
        let same = try Self.run(["Scripts/check-elevenlabs-spec.sh", "--only-asyncapi", "--asyncapi-against", scratch.path])
        #expect(same.status == 0, "\(same.output)")
        #expect(same.output.components(separatedBy: ": no drift").count - 1 == 4)

        // A renamed query parameter, a new audio format, reworded prose; and the live side given
        // as the docs page it comes in (the YAML inside a .md), as a live run fetches it.
        let tts = scratch.appendingPathComponent("tts-stream-input.yaml")
        var text = try String(contentsOf: tts, encoding: .utf8)
        text = text.replacingOccurrences(of: "            inactivity_timeout:\n", with: "            idle_timeout:\n")
        try text.write(to: tts, atomically: true, encoding: .utf8)
        let stt = scratch.appendingPathComponent("stt-realtime.yaml")
        text = try String(contentsOf: stt, encoding: .utf8)
        text = text.replacingOccurrences(of: "        - ulaw_8000\n", with: "        - ulaw_8000\n        - pcm_96000\n")
        text = text.replacingOccurrences(of: "Audio encoding format for speech-to-text.", with: "Audio encoding.")
        try FileManager.default.removeItem(at: stt)
        try ("# WebSocket\n\n```yaml\n" + text + "```\n").write(
            to: scratch.appendingPathComponent("stt-realtime.md"), atomically: true, encoding: .utf8
        )

        let drift = try Self.run(["Scripts/check-elevenlabs-spec.sh", "--only-asyncapi", "--asyncapi-against", scratch.path])
        #expect(drift.status == 3, "\(drift.output)")
        #expect(drift.output.contains("+ channels./v1/text-to-speech/{voice_id}/stream-input.bindings.ws.query.properties.idle_timeout.maximum = 180"))
        #expect(drift.output.contains("- channels./v1/text-to-speech/{voice_id}/stream-input.bindings.ws.query.properties.inactivity_timeout.maximum = 180"))
        #expect(drift.output.contains("~ components.schemas.AudioFormatEnum.enum[]:"))
        #expect(drift.output.contains("pcm_96000"))
        #expect(drift.output.contains("wording changed at"))
        #expect(drift.output.contains("asyncapi tts-multi-stream-input: no drift"))
        #expect(drift.output.contains("asyncapi agents-conversation: no drift"))
    }

    /// A local OpenAPI comparison stays local: the socket check runs only when asked for. Run
    /// with a `curl` on PATH that only notes it was called and fails, so a regression shows here
    /// as a call, not as a fetch.
    @Test func anOpenAPIComparisonAloneDoesNotCheckTheSockets() throws {
        try Self.withCurlShim { environment, calls in
            let pinned = Self.repository.appendingPathComponent("Scripts/elevenlabs/openapi.json")
            let result = try Self.run(["Scripts/check-elevenlabs-spec.sh", "--against", pinned.path], environment: environment)
            #expect(result.status == 0, "\(result.output)")
            #expect(result.output.contains("no drift"))
            #expect(!result.output.contains("asyncapi"))
            #expect(calls() == 0, "curl was called")
        }
    }

    /// Every local comparison is local; and `--only-asyncapi` next to `--against` — which
    /// promises no network but gives nothing local for the sockets — is refused, not fetched.
    @Test func noLocalComparisonFetches() throws {
        try Self.withCurlShim { environment, calls in
            let pinned = Self.repository.appendingPathComponent("Scripts/elevenlabs/openapi.json").path
            let folder = Self.pinnedFolder.path
            for arguments in [
                ["--against", pinned, "--asyncapi-against", folder],
                ["--only-asyncapi", "--asyncapi-against", folder],
            ] {
                let result = try Self.run(["Scripts/check-elevenlabs-spec.sh"] + arguments, environment: environment)
                #expect(result.status == 0, "\(arguments): \(result.output)")
            }
            let refused = try Self.run(
                ["Scripts/check-elevenlabs-spec.sh", "--against", pinned, "--only-asyncapi"], environment: environment
            )
            #expect(refused.status == 2, "\(refused.output)")
            #expect(refused.output.contains("--asyncapi-against"))
            #expect(calls() == 0, "curl was called")
        }
    }

    // MARK: - Fidelity: the sessions speak the pinned spec

    /// Every query parameter a session can send is one the pinned AsyncAPI names for that socket,
    /// so a refresh that renames one fails here rather than at the owner's.
    @Test func everyQueryParameterTheSessionsSendIsInThePinnedSpec() throws {
        var speech = ElevenLabsSpeechStreamConfig(
            voiceID: "v", modelID: "m", outputFormat: "pcm_16000", languageCode: "en", inactivityTimeout: 30,
            syncAlignment: true, autoMode: true, applyTextNormalization: "auto", seed: 1, enableSSMLParsing: true,
            enableLogging: false
        )
        speech.voiceSettings = .init(stability: 0.5)
        let speechNames = Set(speech.queryItems().map(\.name))
        #expect(speechNames.count == 10)
        #expect(speechNames.isSubset(of: try Self.queryNames("tts-stream-input", "/v1/text-to-speech/{voice_id}/stream-input")))
        #expect(speechNames.isSubset(of: try Self.queryNames("tts-multi-stream-input", "/v1/text-to-speech/{voice_id}/multi-stream-input")))

        var transcription = ElevenLabsTranscriptionStreamConfig()
        transcription.commitStrategy = .vad
        transcription.vadSilenceThresholdSeconds = 1
        transcription.vadThreshold = 0.5
        transcription.minSpeechDurationMs = 100
        transcription.minSilenceDurationMs = 100
        transcription.languageCode = "en"
        transcription.secondaryLanguages = ["de"]
        transcription.includeTimestamps = true
        transcription.includeLanguageDetection = true
        transcription.keyterms = ["x"]
        transcription.noVerbatim = true
        transcription.transcriptEdit = "y"
        transcription.filterBackgroundAudio = false
        transcription.enableLogging = true
        let transcriptionNames = Set(transcription.queryItems().map(\.name))
        #expect(transcriptionNames.count == 16)
        #expect(transcriptionNames.isSubset(of: try Self.queryNames("stt-realtime", "/v1/speech-to-text/realtime")))
        #expect(try Self.queryNames("stt-realtime", "/v1/speech-to-text/realtime").contains("entity_detection"))

        #expect(try Self.queryNames("agents-conversation", "/v1/convai/conversation") == ["agent_id"])
    }

    /// The bounds and lists the sessions check against are the pinned spec's own.
    @Test func theBoundsAndListsAreThePinnedSpecs() throws {
        let tts = try Self.outline("tts-stream-input")
        #expect(tts.contains("channels./v1/text-to-speech/{voice_id}/stream-input.bindings.ws.query.properties.inactivity_timeout.maximum = 180"))
        #expect(tts.contains("channels./v1/text-to-speech/{voice_id}/stream-input.bindings.ws.headers.properties.xi-api-key.type = string"))
        let stt = try Self.outline("stt-realtime")
        let formats = Set(stt.compactMap { $0.hasPrefix("components.schemas.AudioFormatEnum.enum[] = ") ? $0.components(separatedBy: " = ").last : nil })
        #expect(formats == Set(ElevenLabsTranscriptionStreamConfig.audioFormats.map(\.name)))
        #expect(stt.contains("components.schemas._v1_speech-to-text_realtime_model_id.enum[] = scribe_v2_realtime"))
        let agents = try Self.outline("agents-conversation")
        let outputs = Set(agents.compactMap {
            $0.hasPrefix("components.schemas.ConversationInitiationMetadataConversationInitiationMetadataEventAgentOutputAudioFormat.enum[] = ")
                ? $0.components(separatedBy: " = ").last : nil
        })
        #expect(!outputs.isEmpty)
        #expect(outputs.allSatisfy { ElevenLabsAudioEncoding(name: $0) != nil }, "every negotiated format decodes: \(outputs)")
    }

    /// Every message type the pinned specs name is one the sessions decode (server side) or
    /// send (client side) — a new event in a refresh fails here until it is handled.
    @Test func everyMessageTypeInThePinnedSpecsIsHandled() throws {
        let clientTypes: Set<String> = [
            "conversation_initiation_client_data", "user_message", "contextual_update", "user_activity", "pong",
            "client_tool_result", "mcp_tool_approval_result", "feedback", "multimodal_message", "file_input",
        ]
        let agentTypes = Set(try Self.outline("agents-conversation").compactMap { line -> String? in
            guard line.contains(".properties.type.enum[] = ") else { return nil }
            return line.components(separatedBy: " = ").last
        })
        #expect(agentTypes.isSuperset(of: clientTypes.subtracting(["file_input"])))
        for type in agentTypes.subtracting(clientTypes) {
            let decoded = ElevenLabsAgentEvent.decode(["type": .string(type)])
            if case .unknown = decoded { Issue.record("the agent event \(type) is in the spec but not decoded") }
        }
        let sttTypes = Set(try Self.outline("stt-realtime").compactMap { line -> String? in
            guard line.contains(".properties.message_type.enum[] = ") else { return nil }
            return line.components(separatedBy: " = ").last
        })
        #expect(sttTypes.contains("input_audio_chunk"))
        for type in sttTypes.subtracting(["input_audio_chunk"]) {
            let decoded = ElevenLabsTranscriptionStreamEvent.decode(["message_type": .string(type), "error": "e"])
            if case .unknown = decoded { Issue.record("the transcription message \(type) is in the spec but not decoded") }
        }
        #expect(sttTypes.subtracting(["input_audio_chunk", "session_started", "partial_transcript", "committed_transcript",
                                      "committed_transcript_with_timestamps", "committed_transcript_entities", "warning",
                                      "edited_transcript"])
            .isSubset(of: ElevenLabsTranscriptionStreamEvent.errorTypes))
    }

    /// The transcription cost notes quote ElevenLabs: the same premiums the pinned REST spec states
    /// for file transcription, so a price change there fails here.
    @Test func theTranscriptionCostNotesHaveTheirEvidence() throws {
        let repository = Self.repository
        // The pinned spec itself: the catalog keeps descriptions short.
        let spec = try JSONValue.parse(Data(contentsOf: repository.appendingPathComponent("Scripts/elevenlabs/openapi.json")))
        let body = spec["paths"]["/v1/speech-to-text"]["post"]["requestBody"]["content"]["multipart/form-data"]["schema"]
        let name = try #require(body["$ref"].stringValue?.components(separatedBy: "/").last)
        let properties = spec["components"]["schemas"][name]["properties"]
        let keyterms = properties["keyterms"]["description"].stringValue ?? ""
        let edit = properties["transcript_edit"]["description"].stringValue ?? ""
        #expect(keyterms.contains("20% surcharge"), "\(keyterms)")
        #expect(edit.contains("30% surcharge") && edit.contains("at least 10 seconds"), "\(edit)")
    }

    static func queryNames(_ name: String, _ channel: String) throws -> Set<String> {
        let prefix = "channels.\(channel).bindings.ws.query.properties."
        return Set(try outline(name).compactMap { line -> String? in
            guard line.hasPrefix(prefix) else { return nil }
            return line.dropFirst(prefix.count).split(separator: ".").first.map(String.init)
        })
    }

    // MARK: - Helpers

    static func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-asyncapi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Runs a repository script on local files only.
    static func run(_ arguments: [String], environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = repository
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The environment with a `curl` first on PATH that writes a line to a file and exits 1, and
    /// a count of those lines. The folder is a scratch folder, removed afterwards.
    static func withCurlShim(_ body: (_ environment: [String: String], _ calls: () -> Int) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-curl-shim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { TemporaryFileSink.removeScratch(folder) }
        let log = folder.appendingPathComponent("calls")
        let shim = folder.appendingPathComponent("curl")
        try "#!/bin/sh\necho called >> \"\(log.path)\"\nexit 1\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = folder.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        try body(environment) {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
        }
    }

    /// `path = value` lines of a pinned snapshot, through the drift script's own reader.
    static func outline(_ name: String) throws -> [String] {
        let result = try run(["python3", "Scripts/elevenlabs-asyncapi.py", "outline",
                              pinnedFolder.appendingPathComponent("\(name).yaml").path])
        #expect(result.status == 0)
        return result.output.components(separatedBy: "\n")
    }
}

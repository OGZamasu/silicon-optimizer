@preconcurrency import AVFoundation
import Foundation
import SiliconElevenLabs
import Testing
@testable import SiliconUI

/// The three live screens' models against the fake socket, the fake transport and the fake
/// devices: one session per screen whatever is pressed twice, settings captured at the start,
/// the microphone off until Start, approvals answered only for the call they were asked about,
/// declines sent, sessions ended with the account, and no reconnect.
@Suite("ElevenLabs live screens", .serialized)
@MainActor
struct LiveScreenTests {

    // MARK: - Live speech

    nonisolated static func speechServer(audioSeconds: Double = 0.3) -> FakeElevenLabsSocketConnector.Server {
        { socket in
            guard await socket.nextSent() != nil else { return }  // the first message
            while let message = await socket.nextSent(timeout: .seconds(60)) {
                guard message["flush"] == true else { continue }
                socket.push([
                    "audio": .string(LiveSignal.pcm(seconds: audioSeconds, rate: 24_000).base64EncodedString()),
                    "alignment": ["chars": ["H", "i", " ", "y", "o", "u"], "charStartTimesMs": [0, 50, 100, 150, 200, 250],
                                  "charDurationsMs": [50, 50, 50, 50, 50, 50]],
                ])
                socket.push(["isFinal": true])
            }
        }
    }

    @Test func speakOpensOneStreamPlaysItAndShowsTheWords() async throws {
        let rig = LiveRig(server: Self.speechServer())
        defer { rig.clean() }
        let screen = LiveSpeechModel(context: rig.context)
        screen.voiceID = "voice_1"
        screen.text = "Hi you."
        await screen.speak()
        #expect(screen.text.isEmpty)
        #expect(screen.phase == .live)
        #expect(screen.spoken == ["Hi you."])
        #expect(rig.pane.billableRunsInFlight == 1)
        await rig.until { !screen.words.isEmpty }
        #expect(screen.words.map(\.text) == ["Hi", "you"])
        #expect(rig.audio.scheduledSeconds > 0.29)
        let request = try #require(rig.connector.requests.first)
        #expect(request.url.path == "/v1/text-to-speech/voice_1/stream-input")
        #expect(request.url.query?.contains("output_format=pcm_24000") == true)
        #expect(request.url.query?.contains("sync_alignment=true") == true)
        // More text goes on the same socket.
        screen.text = "Again."
        await screen.speak()
        #expect(rig.connector.requests.count == 1)
        #expect(screen.spoken == ["Hi you.", "Again."])
        await screen.stop()
        #expect(screen.phase == .ended)
        #expect(rig.pane.billableRunsInFlight == 0)
        #expect(rig.connector.sockets.first?.closedByClient?.code == 1000)
    }

    /// Speak pressed twice while the socket opens: one socket, and the text sent once.
    @Test func speakingTwiceQuicklyOpensOneStreamAndSendsTheTextOnce() async throws {
        let rig = LiveRig(server: Self.speechServer())
        defer { rig.clean() }
        rig.connector.setConnectDelay(.milliseconds(200))
        let screen = LiveSpeechModel(context: rig.context)
        screen.voiceID = "voice_1"
        screen.text = "Only once."
        async let first: Void = screen.speak()
        async let second: Void = screen.speak()
        _ = await (first, second)
        #expect(rig.connector.requests.count == 1)
        let socket = try #require(rig.connector.sockets.first)
        let texts = socket.sentJSON.compactMap { $0["text"].stringValue }.filter { $0 != " " }
        #expect(texts == ["Only once. "])
        await screen.stop()
    }

    /// The voice and model are the ones on screen when Speak opened the socket; changing them
    /// while it opens changes nothing.
    @Test func theSettingsAreTheOnesCapturedWhenTheStreamOpened() async throws {
        let rig = LiveRig(server: Self.speechServer())
        defer { rig.clean() }
        rig.connector.setConnectDelay(.milliseconds(200))
        let screen = LiveSpeechModel(context: rig.context)
        screen.voiceID = "voice_A"
        screen.text = "Hello."
        let speaking = Task { await screen.speak() }
        await rig.until { screen.phase == .connecting }
        screen.voiceID = "voice_B"
        screen.modelID = "eleven_multilingual_v2"
        await speaking.value
        let request = try #require(rig.connector.requests.first)
        #expect(request.url.path == "/v1/text-to-speech/voice_A/stream-input")
        #expect(request.url.query?.contains("model_id=eleven_flash_v2_5") == true)
        #expect(screen.settingsLocked)
        await screen.stop()
    }

    @Test func stopWhileConnectingLeavesNothingOpen() async throws {
        let rig = LiveRig(server: Self.speechServer())
        defer { rig.clean() }
        rig.connector.setConnectDelay(.milliseconds(300))
        let screen = LiveSpeechModel(context: rig.context)
        screen.voiceID = "voice_1"
        screen.text = "Never mind."
        let speaking = Task { await screen.speak() }
        await rig.until { screen.phase == .connecting }
        await screen.stop()
        await speaking.value
        #expect(screen.outcome == .notStarted("Cancelled before any text was sent."))
        let socket = try #require(rig.connector.sockets.first)
        #expect(socket.closedByClient?.code == 1000, "the socket that opened late was closed at once")
        #expect(!socket.sentJSON.contains { $0["text"] == "Never mind. " })
        #expect(rig.pane.billableRunsInFlight == 0)
    }

    @Test func aDroppedStreamSaysItMayHaveBeenBilledAndDoesNotReconnect() async throws {
        let rig = LiveRig(server: { socket in
            _ = await socket.nextSent()
            _ = await socket.nextSent()
            socket.drop()
        })
        defer { rig.clean() }
        let screen = LiveSpeechModel(context: rig.context)
        screen.voiceID = "voice_1"
        screen.text = "Hello."
        await screen.speak()
        await rig.until { screen.phase == .ended }
        guard case .mayHaveBeenBilled(let text) = screen.outcome else { Issue.record("\(String(describing: screen.outcome))"); return }
        #expect(text.contains("may have been billed"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.connector.requests.count == 1)
    }

    /// Another key or region, through Settings (the pane resets): the stream ends at once, its
    /// late audio is ignored, and the pane says a request may have gone to the previous account.
    @Test func anAccountChangeEndsTheStreamAndItsLateAudioIsIgnored() async throws {
        let rig = LiveRig(server: { socket in
            _ = await socket.nextSent()
            _ = await socket.nextSent()
            try? await Task.sleep(for: .milliseconds(200))
            socket.push(["audio": .string(LiveSignal.pcm(seconds: 0.5).base64EncodedString()),
                         "alignment": ["chars": ["L", "a", "t", "e"], "charStartTimesMs": [0, 1, 2, 3], "charDurationsMs": [1, 1, 1, 1]]])
        })
        defer { rig.clean() }
        let screen = LiveSpeechModel(context: rig.context)
        screen.voiceID = "voice_1"
        screen.text = "Hello."
        await screen.speak()
        rig.switchAccount()
        rig.pane.reset()
        #expect(screen.phase == .ended)
        #expect(screen.outcome == .mayHaveBeenBilled(LiveOutcome.accountChanged))
        #expect(rig.pane.previousAccountNotice == ElevenLabsPaneState.previousAccountMessage)
        try await Task.sleep(for: .milliseconds(400))
        #expect(screen.words.isEmpty)
        #expect(rig.audio.scheduled.isEmpty)
        #expect(rig.connector.sockets.first?.closedByClient != nil)
        #expect(rig.pane.billableRunsInFlight == 0)
    }

    /// A client swapped without a pane reset (a region change from elsewhere) is caught by the
    /// screen's own watch.
    @Test func aClientChangeWithoutAResetIsCaughtByTheWatch() async throws {
        let rig = LiveRig(server: Self.speechServer())
        defer { rig.clean() }
        let screen = LiveSpeechModel(context: rig.context)
        screen.voiceID = "voice_1"
        screen.text = "Hello."
        await screen.speak()
        rig.switchAccount(region: .eu)
        screen.tick()
        #expect(screen.phase == .ended)
        #expect(screen.outcome == .mayHaveBeenBilled(LiveOutcome.accountChanged))
    }

    @Test func savingWritesTheSessionsAudioAsAWAV() async throws {
        let rig = LiveRig(server: Self.speechServer(audioSeconds: 0.5))
        defer { rig.clean() }
        let screen = LiveSpeechModel(context: rig.context)
        screen.voiceID = "voice_1"
        screen.text = "Hi you."
        await screen.speak()
        await rig.until { screen.audio.count >= 24_000 }
        await screen.stop()
        await screen.save()
        let saved = try #require(screen.savedFile)
        let data = try Data(contentsOf: saved)
        #expect(saved.pathExtension == "wav")
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(data.count == 44 + 24_000)
        #expect(rig.sink.written.contains(saved))
    }

    @Test func leavingTheScreenEndsTheStream() async throws {
        let rig = LiveRig(server: Self.speechServer())
        defer { rig.clean() }
        let screen = LiveSpeechModel(context: rig.context)
        screen.voiceID = "voice_1"
        screen.text = "Hello."
        await screen.speak()
        screen.leave()
        #expect(screen.outcome == .ended(LiveOutcome.leftScreen))
        await rig.until { rig.connector.sockets.first?.closedByClient != nil }
        #expect(rig.connector.sockets.first?.closedByClient != nil)
    }

    // MARK: - Live transcription

    nonisolated static func transcriptionServer() -> FakeElevenLabsSocketConnector.Server {
        { socket in
            socket.push(["message_type": "session_started", "session_id": "s1", "config": [:]])
            var heard = 0
            while let message = await socket.nextSent(timeout: .seconds(60)) {
                if message["commit"] == true {
                    socket.push(["message_type": "committed_transcript", "text": "the rest"])
                    continue
                }
                heard += 1
                if heard == 3 {
                    socket.push(["message_type": "partial_transcript", "text": "hello wor"])
                    socket.push(["message_type": "committed_transcript", "text": "hello world"])
                    socket.push(["message_type": "committed_transcript_with_timestamps", "text": "hello world", "language_code": "en",
                                 "words": [["text": "hello", "start": 0.0, "end": 0.4, "type": "word"],
                                           ["text": " ", "start": 0.4, "end": 0.45, "type": "spacing"],
                                           ["text": "world", "start": 0.45, "end": 0.9, "type": "word"]]])
                    socket.push(["message_type": "edited_transcript", "text": "hello world", "edited_text": "Hello, world."])
                }
            }
        }
    }

    @Test func theMicrophoneIsOffUntilStartAndOnlyWhileTranscribing() async throws {
        let rig = LiveRig(server: Self.transcriptionServer())
        defer { rig.clean() }
        let screen = LiveTranscriptionModel(context: rig.context)
        screen.commitStrategy = .manual
        #expect(!rig.audio.capturing)
        #expect(!rig.audio.hear(seconds: 0.1), "nothing listens before Start")
        await screen.start()
        #expect(screen.phase == .live)
        #expect(rig.audio.asked == 1)
        #expect(rig.audio.capturing)
        #expect(rig.audio.echoCancellation == false)
        #expect(screen.microphoneOn)
        for _ in 0..<4 { rig.audio.hear(seconds: 0.1) }
        await rig.until { screen.segments.first?.edited != nil && screen.segments.first?.words.isEmpty == false }
        #expect(screen.segments.first?.text == "hello world")
        #expect(screen.segments.first?.edited == "Hello, world.")
        #expect(screen.segments.first?.languageCode == "en")
        #expect(screen.segments.first?.words.count == 3)
        let socket = try #require(rig.connector.sockets.first)
        let chunks = socket.sentJSON.filter { $0["message_type"] == "input_audio_chunk" && $0["commit"] == false }
        #expect(chunks.count >= 3)
        #expect(chunks.allSatisfy { Data(base64Encoded: $0["audio_base_64"].stringValue ?? "")?.count == 3_200 })
        #expect(chunks.allSatisfy { $0["sample_rate"] == 16_000 })
        await screen.stop()
        #expect(!rig.audio.capturing)
        #expect(!screen.microphoneOn)
        #expect(socket.sentJSON.contains { $0["commit"] == true })
        #expect(screen.segments.map(\.text) == ["hello world", "the rest"])
        #expect(screen.phase == .ended)
        guard case .ended = screen.outcome else { Issue.record("\(String(describing: screen.outcome))"); return }
        #expect(rig.pane.billableRunsInFlight == 0)
        #expect(screen.fullText == "Hello, world. the rest")
    }

    @Test func aRefusedMicrophoneOpensNothing() async throws {
        let rig = LiveRig(permission: false, server: Self.transcriptionServer())
        defer { rig.clean() }
        let screen = LiveTranscriptionModel(context: rig.context)
        await screen.start()
        #expect(rig.connector.requests.isEmpty)
        #expect(rig.credentials.reads == 0)
        guard case .notStarted(let text) = screen.outcome else { Issue.record("\(String(describing: screen.outcome))"); return }
        #expect(text.contains("Microphone"))
    }

    @Test func mutedSendsSilence() async throws {
        let rig = LiveRig(server: Self.transcriptionServer())
        defer { rig.clean() }
        let screen = LiveTranscriptionModel(context: rig.context)
        await screen.start()
        screen.muted = true
        rig.audio.hear(seconds: 0.25)
        let socket = try #require(rig.connector.sockets.first)
        await rig.until { socket.sentJSON.count >= 2 }
        let audio = socket.sentJSON.compactMap { Data(base64Encoded: $0["audio_base_64"].stringValue ?? "") }.filter { !$0.isEmpty }
        #expect(!audio.isEmpty)
        #expect(audio.allSatisfy { $0.allSatisfy { $0 == 0 } })
        await screen.stop()
    }

    @Test func startingTwiceOpensOneSession() async throws {
        let rig = LiveRig(server: Self.transcriptionServer())
        defer { rig.clean() }
        rig.connector.setConnectDelay(.milliseconds(150))
        let screen = LiveTranscriptionModel(context: rig.context)
        async let first: Void = screen.start()
        async let second: Void = screen.start()
        _ = await (first, second)
        #expect(rig.connector.requests.count == 1)
        #expect(rig.audio.captureStarts == 1)
        await screen.stop()
    }

    @Test func aFileIsSentCommittedAndClosed() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { TemporaryFileSink.removeScratch(folder) }
        let url = folder.appendingPathComponent("talk.wav")
        let samples = (0..<Int(2.5 * 16_000)).map { Float(0.3 * sin(2 * Double.pi * 200 * Double($0) / 16_000)) }
        try MicRecorder.wavData(samples: samples, sampleRate: 16_000).write(to: url)
        let rig = LiveRig(server: Self.transcriptionServer())
        defer { rig.clean() }
        LiveTranscriptionModel.filePace = .milliseconds(5)
        let screen = LiveTranscriptionModel(context: rig.context)
        screen.source = .file
        screen.file = url
        await screen.start()
        await rig.until { screen.phase == .ended }
        #expect(!rig.audio.capturing)
        #expect(rig.audio.asked == 0, "a file needs no microphone")
        let socket = try #require(rig.connector.sockets.first)
        let audio = socket.sentJSON.filter { $0["commit"] == false }
        #expect(audio.count == 3)
        #expect(socket.sentJSON.last?["commit"] == true)
        #expect(socket.request.url.query?.contains("commit_strategy=manual") == true)
        #expect(screen.segments.map(\.text).contains("the rest"))
        #expect(screen.fileProgress.map { abs($0.sent - 2.5) < 0.05 } == true)
        await screen.export()
        #expect(screen.exported.count == 2)
        #expect(screen.exported.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func anAccountChangeStopsTheMicrophoneAndTheSession() async throws {
        let rig = LiveRig(server: Self.transcriptionServer())
        defer { rig.clean() }
        let screen = LiveTranscriptionModel(context: rig.context)
        await screen.start()
        #expect(rig.audio.capturing)
        rig.pane.reset()
        #expect(!rig.audio.capturing)
        #expect(screen.outcome == .mayHaveBeenBilled(LiveOutcome.accountChanged))
        await rig.until { rig.connector.sockets.first?.closedByClient != nil }
        #expect(rig.connector.sockets.first?.closedByClient != nil)
    }

    // MARK: - Talk to an agent

    nonisolated static func agentReplies(
        tools: JSONValue = [], auth: Bool = false, textOnlyAllowed: Bool = true, failingListsFirst: Int = 0
    ) -> @Sendable (ElevenLabsRequest) async throws -> FakeElevenLabsTransport.Reply {
        let failures = Counter(failingListsFirst)
        return { request in
            switch request.operationID {
            case "get_agents_route":
                if failures.take() { return .jsonText(#"{"detail":"agents are down"}"#, status: 503) }
                return .json(["agents": [["agent_id": "agent_1", "name": "Support"], ["agent_id": "agent_2", "name": "Sales"]],
                              "has_more": false])
            case "get_agent_route":
                let id = request.url.lastPathComponent
                return .json([
                    "agent_id": .string(id), "name": .string(id == "agent_1" ? "Support" : "Sales"),
                    "platform_settings": ["auth": ["enable_auth": .bool(auth)],
                                          "overrides": ["conversation_config_override": ["conversation": ["text_only": .bool(textOnlyAllowed)]]]],
                    "conversation_config": ["agent": ["prompt": ["tools": tools]]],
                ])
            case "list_mcp_servers_route":
                return .json(["mcp_servers": [["id": "mcp_1", "config": ["name": "Mail", "url": "https://mcp.mail.example.com/sse",
                                                                       "secret_token": "never shown"]]]])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 404)
            }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var left: Int
        init(_ count: Int) { left = count }
        func take() -> Bool { lock.withLock { if left > 0 { left -= 1; return true }; return false } }
    }

    nonisolated static func agent(_ then: @escaping @Sendable (FakeElevenLabsSocket) async -> Void = { _ in }) -> FakeElevenLabsSocketConnector.Server {
        { socket in
            guard let first = await socket.nextSent(), first["type"] == "conversation_initiation_client_data" else { return }
            socket.push(["type": "conversation_initiation_metadata", "conversation_initiation_metadata_event": [
                "conversation_id": "conv_42", "agent_output_audio_format": "pcm_16000", "user_input_audio_format": "pcm_16000",
            ]])
            await then(socket)
        }
    }

    nonisolated static func approval(_ id: String, timeout: Double = 300) -> JSONValue {
        ["type": "mcp_tool_call", "mcp_tool_call": [
            "service_id": "mcp_1", "tool_call_id": .string(id), "tool_name": "send_email",
            "tool_description": "Sends an email", "parameters": ["to": "someone@example.com"], "state": "awaiting_approval",
            "approval_timeout_secs": .number(timeout),
        ]]
    }

    @Test func agentsLoadAndAFailureSaysWhyAndCanBeRetried() async throws {
        let rig = LiveRig(replies: Self.agentReplies(failingListsFirst: 4))
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        guard case .failed(let reason) = screen.agentsLoad else { Issue.record("\(screen.agentsLoad)"); return }
        #expect(reason.contains("agents are down"))
        await screen.loadAgents()
        #expect(screen.agentsLoad == .loaded)
        #expect(screen.agents.map(\.name) == ["Support", "Sales"])
        #expect(screen.selectedAgentID == "agent_1")
    }

    @Test func anAgentWithNothingRealWorldStartsAtOnceWithTheMicrophoneAndEchoCancellation() async throws {
        let rig = LiveRig(replies: Self.agentReplies(), server: Self.agent { socket in
            socket.push(["type": "agent_response", "agent_response_event": ["agent_response": "Hello! How can I help?", "event_id": 1]])
            socket.push(["type": "audio", "audio_event": ["audio_base_64": .string(LiveSignal.pcm(seconds: 0.3).base64EncodedString()), "event_id": 1]])
            socket.push(["type": "user_transcript", "user_transcription_event": ["user_transcript": "What are your hours?", "event_id": 2]])
        })
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        await screen.requestStart()
        #expect(screen.phase == .live)
        #expect(screen.question == nil)
        #expect(rig.audio.asked == 1)
        #expect(rig.audio.capturing)
        #expect(rig.audio.echoCancellation == true)
        let request = try #require(rig.connector.requests.first)
        #expect(request.headers.isEmpty, "the agent's socket never gets the key")
        #expect(request.url.query == "agent_id=agent_1")
        await rig.until { screen.lines.count >= 2 }
        #expect(screen.lines.map(\.role) == [.agent, .user])
        #expect(screen.lines.first?.text == "Hello! How can I help?")
        await rig.until { rig.audio.scheduledSeconds > 0.25 }
        // Microphone audio goes to the agent in its format.
        rig.audio.hear(seconds: 0.2)
        let socket = try #require(rig.connector.sockets.first)
        await rig.until { socket.sentJSON.contains { $0["user_audio_chunk"] != .null } }
        let chunk = try #require(socket.sentJSON.first { $0["user_audio_chunk"] != .null })
        #expect(Data(base64Encoded: chunk["user_audio_chunk"].stringValue ?? "")?.count == 3_200)
        #expect(screen.conversationID == "conv_42")
        await screen.end()
        await rig.until { screen.phase == .ended }
        #expect(!rig.audio.capturing)
        #expect(screen.outcome.map { $0.message.hasPrefix("You ended the conversation.") } == true)
        #expect(socket.closedByClient == .init(code: 1000, reason: "User ended conversation"))
        await rig.until { screen.savedTranscript != nil }
        let saved = try String(contentsOf: try #require(screen.savedTranscript), encoding: .utf8)
        #expect(saved.contains("agent: Hello! How can I help?"))
        #expect(rig.pane.billableRunsInFlight == 0)
    }

    /// An agent that can act on ElevenLabs' side is asked about first, naming each tool and host;
    /// nothing opens until the owner agrees, and what opens is the agent the question named.
    @Test func anAgentThatCanActInTheWorldIsAskedAboutFirst() async throws {
        let tools: JSONValue = [
            ["type": "webhook", "name": "lookup_order", "api_schema": ["url": "https://api.shop.example.com/orders/{id}"]],
            ["type": "system", "name": "transfer_to_number", "params": ["system_tool_type": "transfer_to_number"]],
            ["type": "client", "name": "open_page"],
        ]
        let rig = LiveRig(replies: Self.agentReplies(tools: tools), server: Self.agent())
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        screen.textOnly = true
        await screen.requestStart()
        #expect(screen.phase == .asking)
        let question = try #require(screen.question)
        #expect(question.agentName == "Support")
        #expect(question.tools == ["“lookup_order” calls api.shop.example.com", "can transfer the call to a phone number"])
        #expect(rig.connector.requests.isEmpty)
        #expect(rig.audio.asked == 0)
        // The selection moves while the question is open: the question's agent is the one started.
        screen.selectedAgentID = "agent_2"
        await screen.confirmStart()
        #expect(screen.phase == .live)
        let request = try #require(rig.connector.requests.first)
        #expect(request.url.query == "agent_id=agent_1")
        #expect(rig.audio.asked == 0, "text only never asks for the microphone")
        await screen.end()
    }

    @Test func cancellingTheQuestionOpensNothing() async throws {
        let tools: JSONValue = [["type": "webhook", "name": "lookup", "api_schema": ["url": "https://hooks.example.com/x"]]]
        let rig = LiveRig(replies: Self.agentReplies(tools: tools), server: Self.agent())
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        await screen.requestStart()
        #expect(screen.phase == .asking)
        screen.cancelStart()
        #expect(screen.phase == .idle)
        await screen.confirmStart()
        #expect(rig.connector.requests.isEmpty)
        #expect(rig.pane.billableRunsInFlight == 0)
    }

    @Test func startingTwiceReadsAndOpensOnce() async throws {
        let rig = LiveRig(replies: Self.agentReplies(), server: Self.agent())
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        screen.textOnly = true
        async let first: Void = screen.requestStart()
        async let second: Void = screen.requestStart()
        _ = await (first, second)
        #expect(rig.transport.requests.filter { $0.operationID == "get_agent_route" }.count == 1)
        #expect(rig.connector.requests.count == 1)
        await screen.end()
    }

    /// The approval names the tool, its server and host, and is answered for the tool call it
    /// was asked with — once.
    @Test func anApprovalNamesItsToolAndHostAndIsAnsweredOnce() async throws {
        let rig = LiveRig(replies: Self.agentReplies(), server: Self.agent { socket in socket.push(Self.approval("call_1")) })
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        screen.textOnly = true
        await screen.requestStart()
        await rig.until { !screen.waitingApprovals.isEmpty }
        let approval = try #require(screen.waitingApprovals.first)
        #expect(approval.toolName == "send_email")
        #expect(approval.serverName == "Mail")
        #expect(approval.serverHost == "mcp.mail.example.com")
        #expect(approval.agentName == "Support")
        await screen.answer(approval.id, session: approval.session, approved: true)
        await screen.answer(approval.id, session: approval.session, approved: false)
        let socket = try #require(rig.connector.sockets.first)
        let answers = socket.sentJSON.filter { $0["type"] == "mcp_tool_approval_result" }
        #expect(answers == [["type": "mcp_tool_approval_result", "tool_call_id": "call_1", "is_approved": true]])
        #expect(screen.approvals.first?.state == .approved)
        await screen.end()
    }

    /// An approval asked in one conversation, pressed after it ended and a new one started,
    /// reaches nothing — not the new conversation.
    @Test func anApprovalFromAnEndedConversationNeverReachesTheNextOne() async throws {
        let rig = LiveRig(replies: Self.agentReplies(), server: Self.agent { socket in socket.push(Self.approval("call_old")) })
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        screen.textOnly = true
        await screen.requestStart()
        await rig.until { !screen.waitingApprovals.isEmpty }
        let old = try #require(screen.waitingApprovals.first)
        await screen.end()
        await rig.until { screen.phase == .ended }
        // Ending declined it — the decline was sent, not left silent.
        let first = try #require(rig.connector.sockets.first)
        #expect(first.sentJSON.contains(["type": "mcp_tool_approval_result", "tool_call_id": "call_old", "is_approved": false]))
        await screen.requestStart()
        #expect(screen.phase == .live)
        await screen.answer(old.id, session: old.session, approved: true)
        let second = try #require(rig.connector.sockets.last)
        #expect(second !== first)
        #expect(!second.sentJSON.contains { $0["type"] == "mcp_tool_approval_result" && $0["is_approved"] == true })
        await screen.end()
    }

    @Test func anApprovalThatTimesOutIsDeclinedNotLeftSilent() async throws {
        let rig = LiveRig(replies: Self.agentReplies(), server: Self.agent { socket in socket.push(Self.approval("call_t", timeout: 0.3)) })
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        screen.textOnly = true
        await screen.requestStart()
        let socket = try #require(rig.connector.sockets.first)
        await rig.until { socket.sentJSON.contains { $0["type"] == "mcp_tool_approval_result" } }
        #expect(socket.sentJSON.contains(["type": "mcp_tool_approval_result", "tool_call_id": "call_t", "is_approved": false]))
        #expect(screen.approvals.first?.state == .declined("it timed out"))
        await screen.end()
    }

    /// Another account mid-conversation: approvals declined (sent) before the close, microphone
    /// off, and the session ended for good.
    @Test func anAccountChangeDeclinesClosesAndStopsTheMicrophone() async throws {
        let rig = LiveRig(replies: Self.agentReplies(), server: Self.agent { socket in socket.push(Self.approval("call_acct")) })
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        await screen.requestStart()
        await rig.until { !screen.waitingApprovals.isEmpty }
        #expect(rig.audio.capturing)
        rig.switchAccount()
        rig.pane.reset()
        #expect(screen.phase == .ended)
        #expect(!rig.audio.capturing)
        #expect(screen.outcome == .mayHaveBeenBilled(LiveOutcome.accountChanged))
        let socket = try #require(rig.connector.sockets.first)
        await rig.until { socket.closedByClient != nil }
        #expect(socket.sentJSON.contains(["type": "mcp_tool_approval_result", "tool_call_id": "call_acct", "is_approved": false]))
        #expect(socket.closedByClient?.code == 1000)
        #expect(screen.approvals.allSatisfy { if case .declined = $0.state { true } else { false } })
    }

    @Test func textOnlySendsTypedMessagesAndReturnNeverStartsAConversation() async throws {
        let rig = LiveRig(replies: Self.agentReplies(), server: Self.agent { socket in
            guard await socket.nextSent(ofType: "user_message") != nil else { return }
            socket.push(["type": "agent_chat_response_part", "text_response_part": ["text": "We open", "type": "start", "event_id": 3, "response_id": "r"]])
            socket.push(["type": "agent_chat_response_part", "text_response_part": ["text": " at nine.", "type": "delta", "event_id": 3, "response_id": "r"]])
            socket.push(["type": "agent_chat_response_part", "text_response_part": ["text": "", "type": "stop", "event_id": 3, "response_id": "r"]])
        })
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        screen.textOnly = true
        screen.message = "Hours?"
        await screen.sendMessage()  // what Return does: nothing is open, so nothing starts
        #expect(rig.connector.requests.isEmpty)
        #expect(screen.message == "Hours?")
        await screen.requestStart()
        await screen.sendMessage()
        #expect(screen.message.isEmpty)
        await rig.until { screen.lines.contains { $0.role == .agent && !$0.tentative } }
        #expect(screen.lines.map(\.text) == ["Hours?", "We open at nine."])
        let socket = try #require(rig.connector.sockets.first)
        #expect(socket.sentJSON.first?["conversation_config_override"]["conversation"]["text_only"] == true)
        #expect(rig.audio.asked == 0)
        await screen.end()
    }

    @Test func aClientToolCallIsAnsweredThatNothingRan() async throws {
        let rig = LiveRig(replies: Self.agentReplies(), server: Self.agent { socket in
            socket.push(["type": "client_tool_call", "client_tool_call": ["tool_name": "open_page", "tool_call_id": "tc_1",
                                                                       "parameters": ["url": "https://example.com"], "event_id": 4]])
        })
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        screen.textOnly = true
        await screen.requestStart()
        let socket = try #require(rig.connector.sockets.first)
        await rig.until { socket.sentJSON.contains { $0["type"] == "client_tool_result" } }
        let answer = try #require(socket.sentJSON.first { $0["type"] == "client_tool_result" })
        #expect(answer["tool_call_id"] == "tc_1")
        #expect(answer["error_type"] == "user_rejected")
        #expect(answer["is_error"] == true)
        #expect(screen.lines.contains { $0.role == .tool && $0.text.contains("open_page") && $0.text.contains("nothing ran") })
        await screen.end()
    }

    @Test func anInterruptionSilencesThePlayerAndStopTalkingDropsTheRest() async throws {
        let rig = LiveRig(replies: Self.agentReplies(), server: Self.agent { socket in
            socket.push(["type": "audio", "audio_event": ["audio_base_64": .string(LiveSignal.pcm(seconds: 0.3).base64EncodedString()), "event_id": 5]])
            try? await Task.sleep(for: .milliseconds(150))
            socket.push(["type": "interruption", "interruption_event": ["event_id": 5]])
            try? await Task.sleep(for: .milliseconds(150))
            socket.push(["type": "audio", "audio_event": ["audio_base_64": .string(LiveSignal.pcm(seconds: 0.3).base64EncodedString()), "event_id": 6]])
        })
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        await screen.requestStart()
        await rig.until { rig.audio.flushes >= 1 }
        #expect(rig.audio.flushes >= 1)
        await rig.until { rig.audio.scheduledSeconds > 0.55 }
        // "Stop talking": the rest of event 6 is not played.
        screen.interrupt()
        let before = rig.audio.scheduledSeconds
        let socket = try #require(rig.connector.sockets.first)
        socket.push(["type": "audio", "audio_event": ["audio_base_64": .string(LiveSignal.pcm(seconds: 0.3).base64EncodedString()), "event_id": 6]])
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.audio.scheduledSeconds == before)
        await screen.end()
    }

    @Test func aRefusedTextOnlyAgentStartsNothing() async throws {
        let rig = LiveRig(replies: Self.agentReplies(textOnlyAllowed: false), server: Self.agent())
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        screen.textOnly = true
        await screen.requestStart()
        #expect(rig.connector.requests.isEmpty)
        guard case .notStarted(let text) = screen.outcome else { Issue.record("\(String(describing: screen.outcome))"); return }
        #expect(text.contains("does not allow text-only"))
        #expect(rig.pane.billableRunsInFlight == 0)
    }

    @Test func leavingTheScreenEndsTheConversation() async throws {
        let rig = LiveRig(replies: Self.agentReplies(), server: Self.agent())
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        await screen.requestStart()
        screen.leave()
        #expect(screen.phase == .ended)
        #expect(!rig.audio.capturing)
        await rig.until { rig.connector.sockets.first?.closedByClient != nil }
        #expect(rig.connector.sockets.first?.closedByClient?.code == 1000)
    }
}

import Foundation
import Testing
@testable import SiliconElevenLabs

/// Two sessions end to end over the production socket and a loopback server: a speech stream
/// and an agent conversation. Nothing here leaves 127.0.0.1.
@Suite("ElevenLabs realtime sessions on the wire", .serialized)
struct RealtimeSessionWireTests {

    static let key = "sk_" + String(repeating: "wiresession", count: 3)

    @Test func aSpeechStreamSendsItsSettingsFirstAndReadsAudioAndTheEnd() async throws {
        let audio = Data((0..<3_200).map { UInt8(truncatingIfNeeded: $0) })
        let server = try RealtimeLoopbackServer { _ in
            .accept { connection in
                _ = await connection.text(0)
                connection.sendJSON([
                    "audio": .string(audio.base64EncodedString()), "isFinal": false,
                    "alignment": ["chars": ["H", "i"], "charStartTimesMs": [0, 40], "charDurationsMs": [40, 60]],
                ])
                connection.sendJSON(["isFinal": true])
                connection.close(code: 1000, reason: "")
            }
        }
        defer { server.stop() }
        let connector = URLSessionWebSocketConnector.loopbackForTesting(port: Int(server.port))
        let socket = try await connector.connect(ElevenLabsSocketRequest(
            url: server.url("/v1/text-to-speech/voice1/stream-input?output_format=pcm_16000"),
            headers: ["xi-api-key": Self.key]
        ))
        let stream = try await ElevenLabsSpeechStream.start(
            on: socket, config: .init(voiceID: "voice1", outputFormat: "pcm_16000", voiceSettings: .init(stability: 0.4))
        )
        var events: [ElevenLabsSpeechStreamEvent] = []
        for await event in stream.events { events.append(event) }

        let connection = try #require(server.openedConnections.first)
        let first = try #require(connection.texts.first.flatMap { try? JSONValue.parse(Data($0.utf8)) })
        #expect(first["text"] == " ")
        #expect(first["voice_settings"]["stability"] == 0.4)
        #expect(connection.texts.allSatisfy { !$0.contains(Self.key) })
        guard case .audio(let received, let alignment, _) = events.first else {
            Issue.record("expected audio first, got \(events)")
            return
        }
        #expect(received == audio)
        #expect(alignment?.characters == ["H", "i"])
        #expect(events.contains(.final))
        guard case .ended(let close) = events.last else { Issue.record("\(events)"); return }
        #expect(close.kind == .normal)
        #expect(stream.usage.audioSecondsReceived == 0.1)
    }

    /// The initiation first, no key anywhere on the agent's socket, the pong for a ping with its
    /// event id, a text exchange, a normal close.
    @Test func anAgentConversationOnTheWire() async throws {
        let server = try RealtimeLoopbackServer { _ in
            .accept { connection in
                guard let first = await connection.text(0), first.contains("conversation_initiation_client_data") else { return }
                connection.sendJSON(["type": "conversation_initiation_metadata", "conversation_initiation_metadata_event": [
                    "conversation_id": "conv_1", "agent_output_audio_format": "pcm_16000", "user_input_audio_format": "pcm_16000",
                ]])
                connection.sendJSON(["type": "ping", "ping_event": ["event_id": 7, "ping_ms": 30]])
                _ = await connection.text(2)  // the pong, then the user's message
                connection.sendJSON(["type": "agent_response", "agent_response_event": ["agent_response": "Hello.", "event_id": 8]])
                _ = await connection.waitForClose()
            }
        }
        defer { server.stop() }
        let connector = URLSessionWebSocketConnector.loopbackForTesting(port: Int(server.port))
        let socket = try await connector.connect(ElevenLabsSocketRequest(url: server.url("/v1/convai/conversation?agent_id=agent_1")))
        let config = ElevenLabsAgentConversationConfig(agentID: "agent_1", auth: .publicAgent, textOnly: true)
        let conversation = try await ElevenLabsAgentConversation.start(
            on: socket, config: config, initiation: try config.initiation(preflight: nil), startTimeout: 10
        )
        #expect(conversation.startedWith?.conversationID == "conv_1")
        try await conversation.sendUserMessage("Hi")
        var reply: String?
        for await event in conversation.events {
            if case .agentResponse(let text, _, _) = event { reply = text; break }
        }
        #expect(reply == "Hello.")
        await conversation.end()
        let connection = try #require(server.openedConnections.first)
        let texts = connection.texts.compactMap { try? JSONValue.parse(Data($0.utf8)) }
        #expect(texts.first?["type"] == "conversation_initiation_client_data")
        #expect(texts.first?["conversation_config_override"]["conversation"]["text_only"] == true)
        #expect(texts.contains { $0["type"] == "pong" && $0["event_id"] == 7 })
        #expect(texts.contains { $0["type"] == "user_message" && $0["text"] == "Hi" })
        let upgrade = try #require(server.receivedUpgrades.first)
        #expect(upgrade.headers["xi-api-key"] == nil)
        #expect(upgrade.headers["authorization"] == nil)
        // The close frame itself is `RealtimeWireTests.closingSendsTheCodeAndReason`'s, which
        // tries several sockets: in a busy run URLSession now and then ends the connection with
        // a FIN and no close frame. Here: a frame that is read is a normal one, and the
        // connection has ended either way.
        if let close = await connection.waitForClose() {
            #expect(close.code == 1000)
            #expect(close.reason == "User ended conversation")
        } else {
            #expect(connection.isEnded)
        }
    }
}

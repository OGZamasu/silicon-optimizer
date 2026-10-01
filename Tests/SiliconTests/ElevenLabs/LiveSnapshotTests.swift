import AppKit
import Foundation
import SiliconElevenLabs
import SwiftUI
import Testing
@testable import SiliconUI

/// The three live screens drawn with fake sessions — light and dark, narrow and wide — the way
/// the other ElevenLabs screens are: opt-in (`ELEVENLABS_DRAW=1`, or `ELEVENLABS_SNAPSHOT_DIR`
/// to keep the PNGs), since drawing holds the main actor for seconds. Each screen is brought to
/// its state through its model, the fake socket and the fake devices; nothing is real.
@Suite("ElevenLabs live screens, drawn", .serialized, .enabled(if: ElevenLabsSnapshot.enabled))
@MainActor
struct LiveSnapshotTests {

    @Test func liveSpeech() async throws {
        let rig = LiveRig(server: LiveScreenTests.speechServer(audioSeconds: 1.2))
        defer { rig.clean() }
        let voices = ElevenLabsVoiceDirectory(client: { nil })
        voices.set([ElevenLabsVoice(id: "voice_1", name: "Rachel", category: "premade")])
        let screen = LiveSpeechModel(context: rig.context)
        screen.voiceID = "voice_1"
        screen.overridesVoiceSettings = true
        screen.stability = 0.4
        screen.text = "Hi you."
        await screen.speak()
        await rig.until { !screen.words.isEmpty }
        screen.text = "And here is what comes next, typed while the first part plays."
        screen.tick()
        try draw(LiveSpeechScreen(screen: screen, voices: voices), name: "live-speech")
        await screen.stop()
        await screen.save()
        try draw(LiveSpeechScreen(screen: screen, voices: voices), name: "live-speech-ended")
    }

    @Test func liveTranscription() async throws {
        let rig = LiveRig(server: LiveScreenTests.transcriptionServer())
        defer { rig.clean() }
        let screen = LiveTranscriptionModel(context: rig.context)
        screen.keyterms = "ElevenLabs, Silicon"
        screen.transcriptEdit = "Capitalise product names."
        await screen.start()
        for _ in 0..<4 { rig.audio.hear(seconds: 0.1) }
        await rig.until { !screen.segments.isEmpty }
        screen.tick()
        try draw(LiveTranscriptionScreen(screen: screen), name: "live-transcription")
        await screen.stop()
        try draw(LiveTranscriptionScreen(screen: screen), name: "live-transcription-ended")
    }

    @Test func talkToAnAgent() async throws {
        let rig = LiveRig(replies: LiveScreenTests.agentReplies(), server: LiveScreenTests.agent { socket in
            socket.push(["type": "agent_response", "agent_response_event": ["agent_response": "Hi! I'm the support agent. How can I help today?", "event_id": 1]])
            socket.push(["type": "user_transcript", "user_transcription_event": ["user_transcript": "Can you email me my last invoice?", "event_id": 2]])
            socket.push(["type": "agent_tool_request", "agent_tool_request": ["tool_name": "lookup_invoice", "tool_call_id": "t1", "tool_type": "webhook", "event_id": 3]])
            socket.push(["type": "agent_tool_response", "agent_tool_response": ["tool_name": "lookup_invoice", "tool_call_id": "t1", "tool_type": "webhook", "status": "success", "event_id": 3]])
            socket.push(["type": "agent_response", "agent_response_event": ["agent_response": "I found it. I'll send it by email — please approve that.", "event_id": 4]])
            socket.push(LiveScreenTests.approval("call_1"))
        })
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        await screen.requestStart()
        await rig.until { !screen.waitingApprovals.isEmpty }
        screen.tick()
        try draw(LiveAgentScreen(screen: screen), name: "talk-to-an-agent")

        let asking = LiveRig(replies: LiveScreenTests.agentReplies(tools: [
            ["type": "webhook", "name": "lookup_order", "api_schema": ["url": "https://api.shop.example.com/orders/{id}"]],
            ["type": "system", "name": "transfer_to_number", "params": ["system_tool_type": "transfer_to_number"]],
        ]))
        defer { asking.clean() }
        let question = LiveAgentModel(context: asking.context)
        await question.loadAgents()
        await question.requestStart()
        try draw(LiveAgentScreen(screen: question), name: "talk-to-an-agent-question")
        await screen.end()
    }

    // MARK: - Drawing

    func draw(_ view: some View, name: String) throws {
        for width in ElevenLabsSnapshot.Width.allCases {
            let images = try ElevenLabsSnapshot.render(view, name: name, width: width, height: 1_100)
            #expect(images.count == 2)
            #expect(images.allSatisfy(ElevenLabsSnapshot.hasContent), "\(name) \(width) drew nothing")
        }
    }
}

@preconcurrency import AVFoundation
import Foundation
import SiliconElevenLabs
import Testing
@testable import SiliconUI

/// Every way a live session ends lets go of the devices: the engine stopped (so the system's
/// microphone indicator goes out) and voice processing off (so other apps' audio is no longer
/// ducked). The fake keeps the real engine's bookkeeping — removing the tap alone is not enough.
@Suite("ElevenLabs live screens let go of the devices", .serialized)
@MainActor
struct LiveReleaseTests {

    enum Exit: String, CaseIterable, Sendable {
        case stop, serverClose, drop, leave, accountChange
    }

    // MARK: - Live transcription

    nonisolated static func transcriptionServer(_ exit: Exit) -> FakeElevenLabsSocketConnector.Server {
        { socket in
            socket.push(["message_type": "session_started", "session_id": "s1", "config": [:]])
            _ = await socket.nextSent()
            switch exit {
            case .serverClose: socket.serverClose(code: 1000, reason: "")
            case .drop: socket.drop()
            default:
                while let message = await socket.nextSent(timeout: .seconds(60)) {
                    if message["commit"] == true { socket.push(["message_type": "committed_transcript", "text": "done"]) }
                }
            }
        }
    }

    @Test(arguments: Exit.allCases)
    func aTranscriptionLetsGoOfTheMicrophone(exit: Exit) async throws {
        let rig = LiveRig(server: Self.transcriptionServer(exit))
        defer { rig.clean() }
        let screen = LiveTranscriptionModel(context: rig.context)
        await screen.start()
        #expect(rig.audio.engineRunning)
        rig.audio.hear(seconds: 0.2)
        switch exit {
        case .stop: await screen.stop()
        case .leave: screen.leave()
        case .accountChange: rig.pane.reset()
        case .serverClose, .drop: break
        }
        await rig.until { screen.phase == .ended }
        #expect(screen.phase == .ended)
        #expect(!rig.audio.holdsDevices, "\(exit): the engine or the tap is still held")
        #expect(rig.audio.releases == 1)
        #expect(!screen.microphoneOn)
    }

    @Test func aMicrophoneThatFailsToStartIsLetGo() async throws {
        let rig = LiveRig(server: Self.transcriptionServer(.stop))
        defer { rig.clean() }
        rig.audio.captureFailure = NSError(domain: "fixture", code: 1)
        let screen = LiveTranscriptionModel(context: rig.context)
        await screen.start()
        await rig.until { screen.phase == .ended }
        #expect(!rig.audio.holdsDevices)
        #expect(rig.audio.releases == 1)
    }

    // MARK: - Talk to an agent

    nonisolated static func agentServer(_ exit: Exit) -> FakeElevenLabsSocketConnector.Server {
        LiveScreenTests.agent { socket in
            socket.push(["type": "audio", "audio_event": ["audio_base_64": .string(LiveSignal.pcm(seconds: 0.3).base64EncodedString()), "event_id": 1]])
            try? await Task.sleep(for: .milliseconds(100))
            switch exit {
            case .serverClose: socket.serverClose(code: 1000, reason: "")
            case .drop: socket.drop()
            default: break
            }
        }
    }

    @Test(arguments: Exit.allCases)
    func aVoiceConversationLetsGoOfTheMicrophoneAndVoiceProcessing(exit: Exit) async throws {
        let rig = LiveRig(replies: LiveScreenTests.agentReplies(), server: Self.agentServer(exit))
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        await screen.requestStart()
        #expect(rig.audio.voiceProcessing)
        #expect(rig.audio.engineRunning)
        await rig.until { rig.audio.scheduledSeconds > 0.25 }
        switch exit {
        case .stop: await screen.end()
        case .leave: screen.leave()
        case .accountChange: rig.pane.reset()
        case .serverClose, .drop: break
        }
        await rig.until { screen.phase == .ended }
        #expect(screen.phase == .ended)
        #expect(!rig.audio.voiceProcessing, "\(exit): voice processing is still on")
        #expect(!rig.audio.holdsDevices, "\(exit): the engine or the tap is still held")
        #expect(rig.audio.releases == 1)
    }

    // MARK: - Live speech

    @Test(arguments: [Exit.stop, .leave, .accountChange, .drop])
    func aSilencedStreamLetsGoAtOnce(exit: Exit) async throws {
        let rig = LiveRig(server: { socket in
            _ = await socket.nextSent()
            _ = await socket.nextSent()
            socket.push(["audio": .string(LiveSignal.pcm(seconds: 0.4, rate: 24_000).base64EncodedString())])
            if exit == .drop {
                try? await Task.sleep(for: .milliseconds(100))
                socket.drop()
            }
        })
        defer { rig.clean() }
        let screen = LiveSpeechModel(context: rig.context)
        screen.voiceID = "voice_1"
        screen.text = "Hello."
        await screen.speak()
        await rig.until { rig.audio.engineRunning }
        switch exit {
        case .stop: await screen.stop()
        case .leave: screen.leave()
        case .accountChange: rig.pane.reset()
        default: break
        }
        await rig.until { screen.phase == .ended }
        #expect(!rig.audio.holdsDevices, "\(exit)")
        #expect(rig.audio.releases == 1)
    }

    /// A stream that ends normally plays out what it holds, then lets go — not before.
    @Test func aFinishedStreamLetsGoOnceItsAudioHasPlayed() async throws {
        let rig = LiveRig(server: LiveScreenTests.speechServer(audioSeconds: 0.4))
        defer { rig.clean() }
        let screen = LiveSpeechModel(context: rig.context)
        screen.voiceID = "voice_1"
        screen.text = "Hi you."
        await screen.speak()
        await rig.until { rig.audio.scheduledSeconds > 0.35 }
        await screen.finish()
        let socket = try #require(rig.connector.sockets.first)
        socket.serverClose(code: 1000, reason: "")
        await rig.until { screen.phase == .ended }
        #expect(rig.audio.engineRunning, "the last audio is still playing")
        #expect(rig.audio.releases == 0)
        rig.audio.finishPlaying()
        await rig.until { rig.audio.releases == 1 }
        #expect(!rig.audio.holdsDevices)
    }

    /// A new stream opened while the last one's audio plays out keeps the devices: the old
    /// stream's pending release is withdrawn.
    @Test func aNewStreamKeepsTheDevicesTheLastOneWasAboutToRelease() async throws {
        let rig = LiveRig(server: LiveScreenTests.speechServer(audioSeconds: 0.4))
        defer { rig.clean() }
        let screen = LiveSpeechModel(context: rig.context)
        screen.voiceID = "voice_1"
        screen.text = "One."
        await screen.speak()
        await rig.until { rig.audio.scheduledSeconds > 0.35 }
        await screen.finish()
        try #require(rig.connector.sockets.first).serverClose(code: 1000, reason: "")
        await rig.until { screen.phase == .ended }
        screen.text = "Two."
        await screen.speak()
        #expect(screen.phase == .live)
        rig.audio.finishPlaying()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.audio.releases == 0, "the first stream's release stopped the second one's devices")
        await screen.stop()
        #expect(rig.audio.releases == 1)
    }
}

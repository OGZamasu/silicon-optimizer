@preconcurrency import AVFoundation
import Foundation
import SiliconElevenLabs
import Testing
@testable import SiliconUI

/// Review follow-ups on the live screens, each pinned by the test that failed without it.
/// In-memory transport, fake socket and fake devices only.
@Suite("ElevenLabs live screens: review follow-ups", .serialized)
@MainActor
struct LiveFollowUpTests {

    /// A text-only Start on an agent that refuses text-only, cancelled while the agent is read,
    /// then a voice Start: the first read's late refusal must not end the second Start.
    @Test func aCancelledStartsLateRefusalLeavesTheNextStartAlone() async throws {
        let base = LiveScreenTests.agentReplies(textOnlyAllowed: false)
        let rig = LiveRig(replies: { request in
            if request.operationID == "get_agent_route" { try? await Task.sleep(for: .milliseconds(400)) }
            return try await base(request)
        }, server: LiveScreenTests.agent())
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        screen.textOnly = true
        let first = Task { await screen.requestStart() }
        await rig.until { screen.phase == .preparing }
        screen.cancelStart()
        screen.textOnly = false
        try await Task.sleep(for: .milliseconds(100))
        let second = Task { await screen.requestStart() }
        await first.value
        await second.value
        await rig.until { screen.phase == .live || screen.phase == .ended }
        #expect(screen.phase == .live, "the voice Start was dropped: \(screen.outcome?.message ?? "no outcome")")
        #expect(rig.connector.requests.count == 1)
        await screen.end()
    }

    /// A file that is not audio is found out before anything opens: no socket, nothing billed.
    @Test(arguments: ["not audio at all", ""])
    func aFileThatIsNotAudioOpensNoSocket(contents: String) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { TemporaryFileSink.removeScratch(folder) }
        let url = folder.appendingPathComponent("talk.wav")
        try Data(contents.utf8).write(to: url)
        let rig = LiveRig(server: LiveScreenTests.transcriptionServer())
        defer { rig.clean() }
        let screen = LiveTranscriptionModel(context: rig.context)
        screen.source = .file
        screen.file = url
        await screen.start()
        await rig.until { screen.phase == .ended }
        #expect(rig.connector.requests.isEmpty, "a socket was opened for a file that is not audio")
        guard case .notStarted(let why) = screen.outcome else {
            Issue.record("expected nothing started, got \(String(describing: screen.outcome))")
            return
        }
        #expect(why.contains("talk.wav"))
        #expect(why.contains("nothing was sent"))
    }

    /// Stop pressed while a (slow) file is read: nothing opens afterwards.
    @Test func aStartStoppedWhileItsFileIsReadOpensNothing() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { TemporaryFileSink.removeScratch(folder) }
        let url = folder.appendingPathComponent("long.wav")
        let samples = (0..<Int(60 * 16_000)).map { Float(0.3 * sin(2 * Double.pi * 200 * Double($0) / 16_000)) }
        try MicRecorder.wavData(samples: samples, sampleRate: 16_000).write(to: url)
        let rig = LiveRig(server: LiveScreenTests.transcriptionServer())
        defer { rig.clean() }
        let screen = LiveTranscriptionModel(context: rig.context)
        screen.source = .file
        screen.file = url
        let starting = Task { await screen.start() }
        await rig.until { screen.phase != .idle }
        // Still reading the minute-long file (it is read whole before anything opens).
        try #require(screen.phase == .connecting)
        await screen.stop()
        await starting.value
        #expect(screen.phase == .ended)
        #expect(screen.outcome == .notStarted("Cancelled before any audio was sent."))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.connector.requests.isEmpty)
    }

    /// Cancel while connecting stops the connect itself: the socket is closed at once, not
    /// held open until the agent's metadata arrives (seconds later) and ended then.
    @Test func cancellingWhileConnectingClosesTheSocketAtOnce() async throws {
        let rig = LiveRig(replies: LiveScreenTests.agentReplies(), server: { socket in
            guard await socket.nextSent() != nil else { return }
            // A slow agent: the metadata comes two seconds after the initiation.
            try? await Task.sleep(for: .seconds(2))
            socket.push(["type": "conversation_initiation_metadata", "conversation_initiation_metadata_event": [
                "conversation_id": "conv_late", "agent_output_audio_format": "pcm_16000", "user_input_audio_format": "pcm_16000",
            ]])
        })
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        screen.textOnly = true
        let starting = Task { await screen.requestStart() }
        await rig.until { rig.connector.sockets.first?.sentJSON.isEmpty == false }
        let socket = try #require(rig.connector.sockets.first)
        #expect(screen.phase == .connecting)
        let cancelled = ContinuousClock.now
        screen.cancelStart()
        await rig.until { socket.closedByClient != nil }
        #expect(socket.closedByClient != nil)
        #expect(ContinuousClock.now - cancelled < .seconds(1), "the socket stayed open until the agent answered")
        await starting.value
        #expect(screen.phase == .ended)
        #expect(screen.conversationID == nil)
        #expect(rig.connector.requests.count == 1)
    }

    /// Mute says what it costs: the silence it sends is billed like speech.
    @Test func muteSaysTheMutedTimeIsStillBilled() {
        #expect(LiveMicrophoneIndicator.label(muted: true).contains("still billed"))
        #expect(LiveMicrophoneIndicator.label(muted: false) == "Microphone on")
        #expect(LiveMicrophoneIndicator.muteHelp.contains("still billed"))
    }

    /// A socket that stops taking microphone audio: the chunks are not queued without limit
    /// (and none is dropped from the middle) — the session ends and says why.
    @Test func aTranscriptionWhoseSocketStopsTakingAudioEnds() async throws {
        let rig = LiveRig(server: { socket in
            socket.push(["message_type": "session_started", "session_id": "s1", "config": [:]])
            socket.stallSends()
            _ = await socket.waitUntilEnded(timeout: .seconds(60))
        })
        defer { rig.clean() }
        var context = rig.context
        context.microphoneQueueCapacity = 5
        let screen = LiveTranscriptionModel(context: context)
        await screen.start()
        #expect(screen.phase == .live)
        let socket = try #require(rig.connector.sockets.first)
        for _ in 0..<3 { _ = rig.audio.hear(seconds: 0.5) }
        await rig.until { screen.phase == .ended }
        #expect(screen.outcome == .mayHaveBeenBilled(LiveContext.microphoneFellBehind))
        #expect(!rig.audio.holdsDevices)
        await rig.until { socket.endedWith != nil }
        #expect(socket.endedWith != nil)
    }

    @Test func aConversationWhoseSocketStopsTakingAudioEnds() async throws {
        let rig = LiveRig(replies: LiveScreenTests.agentReplies(), server: LiveScreenTests.agent { socket in
            socket.stallSends()
            _ = await socket.waitUntilEnded(timeout: .seconds(60))
        })
        defer { rig.clean() }
        var context = rig.context
        context.microphoneQueueCapacity = 5
        let screen = LiveAgentModel(context: context)
        await screen.loadAgents()
        await screen.requestStart()
        await rig.until { screen.microphoneOn }
        try #require(screen.phase == .live)
        for _ in 0..<3 { _ = rig.audio.hear(seconds: 0.5) }
        await rig.until { screen.phase == .ended }
        #expect(screen.outcome == .mayHaveBeenBilled(LiveContext.microphoneFellBehind))
        #expect(!rig.audio.holdsDevices)
        #expect(!rig.audio.voiceProcessing)
    }

    /// Headphones plugged in mid-session stop the engine: the session ends and says why,
    /// instead of showing "Microphone on" while nothing is heard (and an agent keeps billing).
    @Test func aDeviceChangeEndsATranscription() async throws {
        let rig = LiveRig(server: LiveReleaseTests.transcriptionServer(.stop))
        defer { rig.clean() }
        let screen = LiveTranscriptionModel(context: rig.context)
        await screen.start()
        #expect(screen.microphoneOn)
        rig.audio.simulateDeviceChange()
        await rig.until { screen.phase == .ended }
        #expect(screen.outcome == .mayHaveBeenBilled(LiveContext.devicesChanged))
        #expect(!screen.microphoneOn)
        #expect(!rig.audio.holdsDevices)
        let socket = try #require(rig.connector.sockets.first)
        await rig.until { socket.closedByClient != nil }
        #expect(socket.closedByClient != nil)
    }

    @Test func aDeviceChangeEndsAVoiceConversation() async throws {
        let rig = LiveRig(replies: LiveScreenTests.agentReplies(), server: LiveScreenTests.agent())
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        await screen.requestStart()
        await rig.until { screen.microphoneOn }
        rig.audio.simulateDeviceChange()
        await rig.until { screen.phase == .ended }
        #expect(screen.outcome == .mayHaveBeenBilled(LiveContext.devicesChanged))
        #expect(!rig.audio.holdsDevices)
        #expect(!rig.audio.voiceProcessing)
        let socket = try #require(rig.connector.sockets.first)
        await rig.until { socket.closedByClient != nil }
        #expect(socket.closedByClient?.code == 1000)
    }

    /// A stream that fails part-way through a text: what was sent stays sent (it was billed),
    /// and only the rest goes back in the box.
    @Test func aFailurePartWayRestoresOnlyTheUnsentText() async throws {
        let rig = LiveRig(server: { socket in
            // The settings, the first piece — and the connection drops as the second goes.
            socket.drop(atSend: 3)
            _ = await socket.waitUntilEnded(timeout: .seconds(60))
        })
        defer { rig.clean() }
        let screen = LiveSpeechModel(context: rig.context)
        screen.voiceID = "voice_1"
        let first = "This is the first sentence here."
        let rest = "This is the second sentence here. And this is the third one here."
        #expect(ElevenLabsTextChunker.chunks(first + " " + rest).count == 3)
        screen.text = first + " " + rest
        await screen.speak()
        await rig.until { screen.phase == .ended }
        #expect(screen.text == rest, "the box holds \(screen.text)")
        #expect(screen.spoken == [first])
        #expect(screen.serverMessage?.contains("Part of the text was sent") == true)
        let socket = try #require(rig.connector.sockets.first)
        #expect(socket.sentJSON.count == 2)
        #expect(socket.sentJSON.last?["text"] == .string(first + " "))
    }
}

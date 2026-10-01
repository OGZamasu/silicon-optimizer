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
}

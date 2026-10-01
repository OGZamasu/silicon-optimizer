@preconcurrency import AVFoundation
import Foundation
import SiliconElevenLabs
import Testing
@testable import SiliconUI

/// The three live screens share one set of devices. A session lets go of them only under its own
/// claim, so nothing one screen leaves behind — Live speech's last audio playing out, a
/// transcription waiting for its last text, a conversation waiting for its socket — can take the
/// microphone, the engine, voice processing or the device-change handler from a session started
/// since on another screen. The fake keeps the real engine's bookkeeping.
@Suite("ElevenLabs live screens: who owns the devices", .serialized)
@MainActor
struct LiveDeviceOwnershipTests {

    enum Screen: String, Sendable, CaseIterable {
        case speech, transcription, agent
    }

    /// Opens when the test says so; a server script waits on it.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        func open() { lock.withLock { isOpen = true } }
        func wait() async {
            let deadline = ContinuousClock.now + .seconds(60)
            while !lock.withLock({ isOpen }), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// Speech, transcription and an agent on one fake connector, by socket path. The
    /// transcription answers a commit only once `finalText` opens; the agent, when `stallAgent`,
    /// asks for an approval and then stops taking the client's frames (so an End waits on it).
    nonisolated static func servers(finalText: Gate, stallAgent: Bool) -> FakeElevenLabsSocketConnector.Server {
        let speech = LiveScreenTests.speechServer(audioSeconds: 0.4)
        let agent = LiveScreenTests.agent { socket in
            guard stallAgent else { return }
            socket.push(LiveScreenTests.approval("call_own"))
            socket.stallSends()
        }
        return { socket in
            let path = socket.request.url.path
            if path.contains("stream-input") {
                await speech(socket)
            } else if path.contains("speech-to-text") {
                socket.push(["message_type": "session_started", "session_id": "s1", "config": [:]])
                while let message = await socket.nextSent(timeout: .seconds(60)) {
                    guard message["commit"] == true else { continue }
                    await finalText.wait()
                    socket.push(["message_type": "committed_transcript", "text": "the last words"])
                }
            } else {
                await agent(socket)
            }
        }
    }

    // MARK: - The sessions

    final class Sessions {
        var speech: LiveSpeechModel?
        var transcription: LiveTranscriptionModel?
        var agent: LiveAgentModel?
    }

    /// Starts `screen`'s session and waits until it holds what it needs.
    func start(_ screen: Screen, _ rig: LiveRig, into sessions: Sessions) async throws {
        switch screen {
        case .speech:
            let model = LiveSpeechModel(context: rig.context)
            sessions.speech = model
            model.voiceID = "voice_1"
            model.text = "Hi you."
            let before = rig.audio.scheduledSeconds
            await model.speak()
            await rig.until { rig.audio.scheduledSeconds > before + 0.35 }
            try #require(model.phase == .live && rig.audio.engineRunning, "speech did not start playing")
        case .transcription:
            let model = LiveTranscriptionModel(context: rig.context)
            sessions.transcription = model
            await model.start()
            try #require(model.phase == .live && rig.audio.capturing, "the transcription did not start listening")
        case .agent:
            let model = LiveAgentModel(context: rig.context)
            sessions.agent = model
            await model.loadAgents()
            await model.requestStart()
            await rig.until { model.microphoneOn }
            try #require(model.phase == .live && rig.audio.capturing && rig.audio.voiceProcessing,
                         "the conversation did not start listening")
        }
    }

    /// Whether `screen`'s session still has what it needs.
    func holds(_ screen: Screen, _ rig: LiveRig, _ sessions: Sessions) -> Bool {
        switch screen {
        case .speech:
            sessions.speech?.phase == .live && rig.audio.engineRunning
        case .transcription:
            sessions.transcription?.phase == .live && sessions.transcription?.microphoneOn == true
                && rig.audio.capturing && rig.audio.engineRunning
        case .agent:
            sessions.agent?.phase == .live && sessions.agent?.microphoneOn == true
                && rig.audio.capturing && rig.audio.engineRunning && rig.audio.voiceProcessing
        }
    }

    /// Ends `screen`'s session the ordinary way and waits until it has.
    func end(_ screen: Screen, _ rig: LiveRig, _ sessions: Sessions) async {
        switch screen {
        case .speech:
            await sessions.speech?.stop()
            await rig.until { sessions.speech?.phase == .ended }
        case .transcription:
            sessions.transcription?.leave()
        case .agent:
            await sessions.agent?.end()
            await rig.until { sessions.agent?.phase == .ended }
        }
    }

    /// Live speech ends normally: its last audio is still playing, its release pending.
    func speechFinishedButStillPlaying(_ rig: LiveRig, _ sessions: Sessions) async throws {
        try await start(.speech, rig, into: sessions)
        let speech = try #require(sessions.speech)
        await speech.finish()
        try #require(rig.connector.sockets.last).serverClose(code: 1000, reason: "")
        await rig.until { speech.phase == .ended }
        try #require(speech.phase == .ended)
        #expect(rig.audio.releases == 0, "the release waits for the audio to play")
        #expect(rig.audio.engineRunning)
    }

    // MARK: - Live speech's pending release, then another screen

    /// The critic's probes: the speech's audio finishes playing after a transcription or a voice
    /// conversation started — its release is stale and does nothing; the new session keeps the
    /// microphone, the engine, voice processing and its device-change handler.
    @Test(arguments: [Screen.transcription, .agent])
    func aSpeechsLateReleaseLeavesTheNextSessionItsDevices(next: Screen) async throws {
        let rig = LiveRig(replies: LiveScreenTests.agentReplies(), server: Self.servers(finalText: Gate(), stallAgent: false))
        defer { rig.clean() }
        let sessions = Sessions()
        try await speechFinishedButStillPlaying(rig, sessions)
        try await start(next, rig, into: sessions)

        rig.audio.finishPlaying()
        await rig.until { rig.audio.staleReleases > 0 }
        #expect(rig.audio.staleReleases == 1, "the speech never tried to let go")
        #expect(rig.audio.releases == 0)
        #expect(holds(next, rig, sessions), "\(next) lost its devices to the speech's late release")

        // Its device-change handler survived too: a device change still reaches it.
        rig.audio.simulateDeviceChange()
        await rig.until { sessions.transcription?.phase == .ended || sessions.agent?.phase == .ended }
        let outcome = next == .transcription ? sessions.transcription?.outcome : sessions.agent?.outcome
        #expect(outcome == .mayHaveBeenBilled(LiveContext.devicesChanged))
        #expect(!rig.audio.holdsDevices, "\(next)'s own release did not let go")
    }

    /// Leaving Live speech while its last audio plays out does not leave the release armed:
    /// the rest is silenced and the devices let go then, before the next screen starts.
    @Test(arguments: [Screen.transcription, .agent])
    func leavingSpeechLetsGoAtOnceAndTheNextSessionKeepsItsDevices(next: Screen) async throws {
        let rig = LiveRig(replies: LiveScreenTests.agentReplies(), server: Self.servers(finalText: Gate(), stallAgent: false))
        defer { rig.clean() }
        let sessions = Sessions()
        try await speechFinishedButStillPlaying(rig, sessions)
        sessions.speech?.leave()
        #expect(rig.audio.releases == 1)
        #expect(!rig.audio.holdsDevices)

        try await start(next, rig, into: sessions)
        rig.audio.finishPlaying()
        try await Task.sleep(for: .milliseconds(200))  // anything still armed would have fired
        #expect(rig.audio.releases == 1)
        #expect(holds(next, rig, sessions), "\(next) lost its devices after the speech screen was left")
        await end(next, rig, sessions)
        await rig.until { !rig.audio.holdsDevices }
        #expect(!rig.audio.holdsDevices)
    }

    // MARK: - A transcription or a conversation still ending, then another screen

    /// The other pairs, in the order the app allows: the first session is left while it is
    /// still ending (a transcription waiting for its last text, a conversation whose End waits
    /// on a stalled socket), the next one starts, and then the first one's late work completes.
    /// Nothing of it touches the devices the next session holds.
    @Test(arguments: [(Screen.transcription, Screen.agent), (.transcription, .speech), (.agent, .transcription), (.agent, .speech)])
    func aSessionLeftWhileEndingLeavesTheNextSessionItsDevices(first: Screen, next: Screen) async throws {
        let finalText = Gate()
        let rig = LiveRig(replies: LiveScreenTests.agentReplies(), server: Self.servers(finalText: finalText, stallAgent: true))
        defer { rig.clean() }
        let sessions = Sessions()
        try await start(first, rig, into: sessions)
        let firstSocket = try #require(rig.connector.sockets.last)

        // Stop / End pressed: the session is ending, waiting on ElevenLabs.
        let ending: Task<Void, Never>
        switch first {
        case .transcription:
            let model = try #require(sessions.transcription)
            ending = Task { await model.stop() }
            await rig.until { model.phase == .finishing }
            try #require(model.phase == .finishing)
        case .agent:
            let model = try #require(sessions.agent)
            await rig.until { !model.waitingApprovals.isEmpty }
            ending = Task { await model.end() }
            await rig.until { model.phase == .ending }
            try #require(model.phase == .ending)
        case .speech:
            Issue.record("not a first screen here")
            return
        }
        // The owner goes to the other screen: the first one is left, the next one started.
        sessions.transcription?.leave()
        sessions.agent?.leave()
        let releasesAtLeave = rig.audio.releases
        #expect(releasesAtLeave == 1)
        try await start(next, rig, into: sessions)

        // The first one's late work completes: its last text arrives, its stalled End gives up.
        finalText.open()
        await ending.value
        await rig.until { firstSocket.endedWith != nil }
        #expect(firstSocket.endedWith != nil)
        if first == .agent {
            // The End's own fallback finishes the session after three seconds — on its own token.
            try await Task.sleep(for: .seconds(3.5))
        }
        #expect(rig.audio.releases == releasesAtLeave, "the first session let go again")
        #expect(holds(next, rig, sessions), "\(next) lost its devices to \(first)'s late work")
        await end(next, rig, sessions)
        await rig.until { !rig.audio.holdsDevices }
        #expect(!rig.audio.holdsDevices)
    }
}

@preconcurrency import AVFoundation
import Foundation
import SiliconElevenLabs
import Testing
@testable import SiliconUI

/// Stop waits for the text of ITS commit — the last stretch was sent and billed, and must reach
/// the screen and the export — and says so when it does not come in time. In-memory fakes only.
@Suite("ElevenLabs live transcription: the last text", .serialized)
@MainActor
struct LiveTranscriptionFinalTextTests {

    static func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-live-final-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func wav(seconds: Double, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("talk.wav")
        let samples = (0..<Int(seconds * 16_000)).map { Float(0.3 * sin(2 * Double.pi * 200 * Double($0) / 16_000)) }
        try MicRecorder.wavData(samples: samples, sampleRate: 16_000).write(to: url)
        return url
    }

    /// The export's text file, read back.
    static func exportedText(_ screen: LiveTranscriptionModel) async throws -> String {
        await screen.export()
        let text = try #require(screen.exported.first { $0.pathExtension == "txt" })
        return try String(contentsOf: text, encoding: .utf8)
    }

    // MARK: - By hand: the answer to the last commit

    /// What a fake server holds back until the test lets it go: the late answer of a race,
    /// released once the test has seen what must come first, however loaded the machine is (no
    /// delay to outrun). A session that ends lets it go too, so a server never outlives its test.
    final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        func release() { lock.withLock { released = true } }
        func wait(for socket: FakeElevenLabsSocket) async {
            while !lock.withLock({ released }), socket.endedWith == nil {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// A clock the test steps: Stop's quiet is then a moment the test chooses.
    final class SteppedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        func now() -> ContinuousClock.Instant { lock.withLock { instant } }
        func advance(by step: Duration) { lock.withLock { instant += step } }
    }

    /// A file longer than one commit interval (20 s in the app; one second here, so the file is
    /// one and a half seconds rather than twenty-one and a half — the same two commits, without
    /// twenty sends for a busy run to hold up): its periodic commit is answered only after Stop's
    /// commit has gone. The first text after Stop is that earlier answer, not the last text —
    /// Stop waits for the answer to its own commit, the second. The second answer is held until
    /// the test has seen the first on screen and, with the quiet already passed on a clock the
    /// test steps, the session still waiting — the count, not the quiet, is what holds it.
    @Test func aFileWhoseEarlierCommitIsAnsweredLateKeepsItsLastText() async throws {
        let folder = try Self.scratch()
        defer { TemporaryFileSink.removeScratch(folder) }
        let url = try Self.wav(seconds: 1.5, in: folder)
        let second = Hold()
        let rig = LiveRig(server: { socket in
            socket.push(["message_type": "session_started", "session_id": "s1", "config": [:]])
            var commits = 0
            while let message = await socket.nextSent(timeout: .seconds(60)) {
                guard message["commit"] == true else { continue }
                commits += 1
                // The periodic commit is answered only once Stop's has arrived, and Stop's own
                // answer only when the test lets it go.
                guard commits == 2 else { continue }
                socket.push(["message_type": "committed_transcript", "text": "the first twenty seconds"])
                await second.wait(for: socket)
                socket.push(["message_type": "committed_transcript", "text": "and the last one and a half"])
            }
        })
        defer { rig.clean() }
        let clock = SteppedClock()
        var context = rig.context
        context.transcription.commitEvery = 1
        context.transcription.commitCap = 1  // a loud sine: never quiet, so the cap commits
        context.transcription.now = { clock.now() }
        let screen = LiveTranscriptionModel(context: context)
        screen.source = .file
        screen.file = url
        await screen.start()
        // The earlier commit's answer is on screen, and it is quiet: only the count — Stop's
        // commit still owed its own answer — keeps the session waiting.
        await rig.until { screen.segments.count == 1 || screen.phase == .ended }
        clock.advance(by: context.transcription.finalQuiet + .milliseconds(1))
        try await Task.sleep(for: .milliseconds(300))  // room for a wrong rule to end it
        #expect(screen.phase == .finishing, "Stop took the earlier commit's answer for its own")
        second.release()
        await rig.until { screen.segments.count == 2 || screen.phase == .ended }
        clock.advance(by: context.transcription.finalQuiet + .milliseconds(1))
        await rig.until { screen.phase == .ended }
        try #require(screen.phase == .ended)
        let socket = try #require(rig.connector.sockets.first)
        #expect(socket.sentJSON.filter { $0["commit"] == true }.count == 2, "a periodic commit and Stop's")
        #expect(screen.segments.map(\.text) == ["the first twenty seconds", "and the last one and a half"])
        #expect(screen.outcome.map { !$0.message.contains("may be missing") } == true, "\(String(describing: screen.outcome))")
        let exported = try await Self.exportedText(screen)
        #expect(exported.contains("and the last one and a half"))
        #expect(exported.contains("the first twenty seconds"))
    }

    /// The critic's round-3 probe: the held periodic commit is answered twice, both landing after
    /// Stop's commit; Stop's own answer comes when the test lets it go. The duplicate brings the
    /// count up to the commits sent; Stop still waits for a quiet moment — on a clock the test
    /// steps only once Stop's own answer is on screen — so that answer is not lost.
    @Test func aDuplicateAnswerAfterStopDoesNotEndTheWait() async throws {
        let folder = try Self.scratch()
        defer { TemporaryFileSink.removeScratch(folder) }
        let url = try Self.wav(seconds: 1.5, in: folder)
        let last = Hold()
        let rig = LiveRig(server: { socket in
            socket.push(["message_type": "session_started", "session_id": "s1", "config": [:]])
            var commits = 0
            while let message = await socket.nextSent(timeout: .seconds(60)) {
                guard message["commit"] == true else { continue }
                commits += 1
                guard commits == 2 else { continue }
                socket.push(["message_type": "committed_transcript", "text": "part one"])
                socket.push(["message_type": "committed_transcript", "text": "part one"])
                await last.wait(for: socket)
                socket.push(["message_type": "committed_transcript", "text": "the last part"])
            }
        })
        defer { rig.clean() }
        let clock = SteppedClock()
        var context = rig.context
        context.transcription.commitEvery = 1
        context.transcription.commitCap = 1  // a loud sine: never quiet, so the cap commits
        context.transcription.now = { clock.now() }
        let screen = LiveTranscriptionModel(context: context)
        screen.source = .file
        screen.file = url
        await screen.start()
        // Two answers for two commits — one of them a duplicate. The clock has not moved, so it
        // is not quiet yet, and Stop is still waiting.
        await rig.until { screen.segments.count == 2 || screen.phase == .ended }
        try await Task.sleep(for: .milliseconds(300))  // room for a wrong rule to end it
        #expect(screen.phase == .finishing, "a duplicate answer ended Stop's wait")
        last.release()
        await rig.until { screen.segments.count == 3 || screen.phase == .ended }
        clock.advance(by: context.transcription.finalQuiet + .milliseconds(1))
        await rig.until { screen.phase == .ended }
        try #require(screen.phase == .ended)
        #expect(screen.segments.last?.text == "the last part", "\(screen.segments.map(\.text))")
        #expect(screen.outcome.map { !$0.message.contains("may be missing") } == true)
        let exported = try await Self.exportedText(screen)
        #expect(exported.contains("the last part"))
    }

    /// Committing by hand from the microphone, the app commits every `commitEvery` seconds too, so
    /// ElevenLabs never commits on its own (which would add an answer nobody counted).
    @Test func theMicrophoneCommittingByHandCommitsAsItGoes() async throws {
        let rig = LiveRig(server: { socket in
            socket.push(["message_type": "session_started", "session_id": "s1", "config": [:]])
            var commits = 0
            while let message = await socket.nextSent(timeout: .seconds(60)) {
                guard message["commit"] == true else { continue }
                commits += 1
                socket.push(["message_type": "committed_transcript", "text": .string("part \(commits)")])
            }
        })
        defer { rig.clean() }
        var context = rig.context
        context.transcription.commitEvery = 0.3
        context.transcription.commitCap = 0.3  // a loud sine: never quiet, so the cap commits
        let screen = LiveTranscriptionModel(context: context)
        screen.commitStrategy = .manual
        await screen.start()
        rig.audio.hear(seconds: 0.5)
        let socket = try #require(rig.connector.sockets.first)
        await rig.until { socket.sentJSON.contains { $0["commit"] == true } }
        #expect(socket.sentJSON.contains { $0["commit"] == true }, "no commit before Stop")
        await screen.stop()
        let commits = socket.sentJSON.filter { $0["commit"] == true }.count
        #expect(commits >= 2, "a commit as it went, and Stop's (unless nothing was sent since)")
        #expect(screen.segments.map(\.text) == (1...commits).map { "part \($0)" })
        #expect(screen.outcome.map { !$0.message.contains("may be missing") } == true)
    }

    // MARK: - At pauses: an automatic commit just before Stop's

    /// ElevenLabs commits at a pause just as Stop is pressed: that commit's text lands after
    /// Stop's commit went, and the answer to Stop's comes after it (when the test lets it go).
    /// Stop waits for a quiet moment after the first text — on a clock the test steps only once
    /// the second is on screen — so both stay.
    @Test func anAutomaticCommitLandingJustAfterStopsKeepsTheLastText() async throws {
        let stopsAnswer = Hold()
        let rig = LiveRig(server: { socket in
            socket.push(["message_type": "session_started", "session_id": "s1", "config": [:]])
            var heard = false
            while let message = await socket.nextSent(timeout: .seconds(60)) {
                if message["commit"] == true {
                    socket.push(["message_type": "committed_transcript", "text": "words before the pause"])
                    await stopsAnswer.wait(for: socket)
                    socket.push(["message_type": "committed_transcript", "text": "the end of it"])
                    continue
                }
                if !heard {
                    heard = true
                    socket.push(["message_type": "partial_transcript", "text": "words before the pause the end"])
                }
            }
        })
        defer { rig.clean() }
        let clock = SteppedClock()
        var context = rig.context
        context.transcription.now = { clock.now() }
        let screen = LiveTranscriptionModel(context: context)
        #expect(screen.commitStrategy == .vad)
        await screen.start()
        rig.audio.hear(seconds: 0.3)
        await rig.until { !screen.partial.isEmpty }
        let stopping = Task { await screen.stop() }
        // The automatic commit's text is on screen; the clock has not moved, so it is not quiet.
        await rig.until { screen.segments.count == 1 || screen.phase == .ended }
        try await Task.sleep(for: .milliseconds(300))  // room for a wrong rule to end it
        #expect(screen.phase == .finishing, "the first text after Stop's commit ended the wait")
        stopsAnswer.release()
        await rig.until { screen.segments.count == 2 || screen.phase == .ended }
        clock.advance(by: context.transcription.finalQuiet + .milliseconds(1))
        await stopping.value
        #expect(screen.phase == .ended)
        #expect(screen.segments.map(\.text) == ["words before the pause", "the end of it"])
        #expect(screen.outcome.map { !$0.message.contains("may be missing") } == true, "\(String(describing: screen.outcome))")
        let exported = try await Self.exportedText(screen)
        #expect(exported.contains("the end of it"))
    }

    // MARK: - When the last text never comes

    /// By hand: Stop's commit is never answered. After the limit, the session ends and says the
    /// last words may be missing — they were sent and billed.
    @Test func anUnansweredCommitEndsWithTheNote() async throws {
        let folder = try Self.scratch()
        defer { TemporaryFileSink.removeScratch(folder) }
        let url = try Self.wav(seconds: 1.5, in: folder)
        let rig = LiveRig(server: { socket in
            socket.push(["message_type": "session_started", "session_id": "s1", "config": [:]])
            while await socket.nextSent(timeout: .seconds(60)) != nil {}
        })
        defer { rig.clean() }
        var context = rig.context
        context.transcription.finalWait = .milliseconds(600)
        let screen = LiveTranscriptionModel(context: context)
        screen.source = .file
        screen.file = url
        await screen.start()
        await rig.until { screen.phase == .ended }
        guard case .ended(let message) = screen.outcome else {
            Issue.record("\(String(describing: screen.outcome))")
            return
        }
        #expect(message.contains(LiveTranscriptionModel.lastWordsMayBeMissing))
    }

    /// At pauses: words were on screen, not yet committed, and nothing answers Stop: the note.
    /// With nothing pending (the last pause already committed everything), no note.
    @Test(arguments: [true, false])
    func atPausesTheNoteDependsOnWordsPending(pending: Bool) async throws {
        let rig = LiveRig(server: { socket in
            socket.push(["message_type": "session_started", "session_id": "s1", "config": [:]])
            var heard = false
            while let message = await socket.nextSent(timeout: .seconds(60)) {
                guard message["commit"] != true, !heard else { continue }
                heard = true
                if pending {
                    socket.push(["message_type": "partial_transcript", "text": "half a sent"])
                } else {
                    socket.push(["message_type": "committed_transcript", "text": "all said"])
                }
            }
        })
        defer { rig.clean() }
        var context = rig.context
        context.transcription.finalWait = .milliseconds(600)
        let screen = LiveTranscriptionModel(context: context)
        await screen.start()
        rig.audio.hear(seconds: 0.3)
        await rig.until { pending ? !screen.partial.isEmpty : !screen.segments.isEmpty }
        await screen.stop()
        guard case .ended(let message) = screen.outcome else {
            Issue.record("\(String(describing: screen.outcome))")
            return
        }
        #expect(message.contains(LiveTranscriptionModel.lastWordsMayBeMissing) == pending, "\(message)")
    }

    // MARK: - Committing by hand at a quiet moment

    /// The audio bytes sent before the first commit.
    static func bytesBeforeFirstCommit(_ socket: FakeElevenLabsSocket) -> Int {
        var bytes = 0
        for message in socket.sentJSON {
            if message["commit"] == true { return bytes }
            bytes += Data(base64Encoded: message["audio_base_64"].stringValue ?? "")?.count ?? 0
        }
        return bytes
    }

    /// Past the interval while someone is speaking, the commit waits for the next quiet moment,
    /// so the word is not cut.
    @Test func aCommitByHandWaitsForAQuietMoment() async throws {
        let rig = LiveRig(server: Self.answeringEveryCommit())
        defer { rig.clean() }
        var context = rig.context
        context.transcription.commitEvery = 0.3
        context.transcription.commitCap = 5
        let screen = LiveTranscriptionModel(context: context)
        screen.commitStrategy = .manual
        await screen.start()
        rig.audio.hear(seconds: 0.6, amplitude: 0.5)    // speech, past the 0.3 s interval
        rig.audio.hear(seconds: 0.3, amplitude: 0.0005) // then a pause
        let socket = try #require(rig.connector.sockets.first)
        await rig.until { socket.sentJSON.contains { $0["commit"] == true } }
        let bytes = Self.bytesBeforeFirstCommit(socket)
        // Not at 0.3 s (9,600 bytes) mid-word: after the 0.6 s of speech (19,200), give or take
        // the resampler's latency.
        #expect(bytes >= 17_600, "committed after \(bytes) bytes, inside the speech")
        await screen.stop()
        #expect(screen.outcome.map { !$0.message.contains("may be missing") } == true)
    }

    /// A loud room is never quiet: the commit is made at the cap anyway, before ElevenLabs would
    /// make its own.
    @Test func aLoudRoomStillCommitsAtTheCap() async throws {
        let rig = LiveRig(server: Self.answeringEveryCommit())
        defer { rig.clean() }
        var context = rig.context
        context.transcription.commitEvery = 0.3
        context.transcription.commitCap = 0.6
        let screen = LiveTranscriptionModel(context: context)
        screen.commitStrategy = .manual
        await screen.start()
        rig.audio.hear(seconds: 1.0, amplitude: 0.5)
        let socket = try #require(rig.connector.sockets.first)
        await rig.until { socket.sentJSON.contains { $0["commit"] == true } }
        let bytes = Self.bytesBeforeFirstCommit(socket)
        #expect((19_200...22_400).contains(bytes), "committed after \(bytes) bytes; the cap is 0.6 s (19,200)")
        await screen.stop()
    }

    /// The picker says what committing by hand does now.
    @Test func theHandCommitChoiceSaysItAlsoCommitsAsItGoes() {
        let label = LiveTranscriptionTiming().handCommitLabel
        #expect(label.contains("Stop"))
        #expect(label.contains("20–28 s"))
        #expect(label.contains("quiet"))
    }

    nonisolated static func answeringEveryCommit() -> FakeElevenLabsSocketConnector.Server {
        { socket in
            socket.push(["message_type": "session_started", "session_id": "s1", "config": [:]])
            var commits = 0
            while let message = await socket.nextSent(timeout: .seconds(60)) {
                guard message["commit"] == true else { continue }
                commits += 1
                socket.push(["message_type": "committed_transcript", "text": .string("part \(commits)")])
            }
        }
    }
}

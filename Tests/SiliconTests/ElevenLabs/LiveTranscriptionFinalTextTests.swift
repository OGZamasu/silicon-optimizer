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

    /// A file longer than one commit interval (20 s): its periodic commit is answered only after
    /// Stop's commit has gone. The first text after Stop is that earlier answer, not the last
    /// text — Stop waits for the answer to its own commit, the second.
    @Test func aFileWhoseEarlierCommitIsAnsweredLateKeepsItsLastText() async throws {
        let folder = try Self.scratch()
        defer { TemporaryFileSink.removeScratch(folder) }
        let url = try Self.wav(seconds: 21.5, in: folder)
        let rig = LiveRig(server: { socket in
            socket.push(["message_type": "session_started", "session_id": "s1", "config": [:]])
            var commits = 0
            while let message = await socket.nextSent(timeout: .seconds(60)) {
                guard message["commit"] == true else { continue }
                commits += 1
                // The 20-second commit is held until Stop's has arrived, then both are answered.
                guard commits == 2 else { continue }
                socket.push(["message_type": "committed_transcript", "text": "the first twenty seconds"])
                try? await Task.sleep(for: .milliseconds(100))
                socket.push(["message_type": "committed_transcript", "text": "and the last one and a half"])
            }
        })
        defer { rig.clean() }
        let screen = LiveTranscriptionModel(context: rig.context)
        screen.source = .file
        screen.file = url
        await screen.start()
        await rig.until { screen.phase == .ended }
        try #require(screen.phase == .ended)
        let socket = try #require(rig.connector.sockets.first)
        #expect(socket.sentJSON.filter { $0["commit"] == true }.count == 2, "a commit at 20 s and Stop's")
        #expect(screen.segments.map(\.text) == ["the first twenty seconds", "and the last one and a half"])
        #expect(screen.outcome.map { !$0.message.contains("may be missing") } == true, "\(String(describing: screen.outcome))")
        let exported = try await Self.exportedText(screen)
        #expect(exported.contains("and the last one and a half"))
        #expect(exported.contains("the first twenty seconds"))
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
    /// Stop's commit went, and the answer to Stop's comes a moment later. Both stay.
    @Test func anAutomaticCommitLandingJustAfterStopsKeepsTheLastText() async throws {
        let rig = LiveRig(server: { socket in
            socket.push(["message_type": "session_started", "session_id": "s1", "config": [:]])
            var heard = false
            while let message = await socket.nextSent(timeout: .seconds(60)) {
                if message["commit"] == true {
                    socket.push(["message_type": "committed_transcript", "text": "words before the pause"])
                    try? await Task.sleep(for: .milliseconds(300))
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
        var context = rig.context
        // The quiet after the first text, far longer than the 300 ms between the two answers.
        context.transcription.finalQuiet = .seconds(3)
        let screen = LiveTranscriptionModel(context: context)
        #expect(screen.commitStrategy == .vad)
        await screen.start()
        rig.audio.hear(seconds: 0.3)
        await rig.until { !screen.partial.isEmpty }
        await screen.stop()
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
}

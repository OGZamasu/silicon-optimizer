import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Smaller findings from the shell and creative critics: sample rates only from the list
/// ElevenLabs sells (C2), headerless audio decoded off the main actor, a cancelled run failing
/// late while the next runs (C3), Decline then Run asks again (nit 5), a stopped run leaves no
/// stale "Show API call" (nit 13), and curl text fields sent as text (nit 1).
@Suite("ElevenLabs shell, round-4 findings")
@MainActor
struct ShellRound4Tests {

    typealias Gate = ShellRunnerGenerationTests.Gate

    // MARK: - C2

    @Test func onlyTheRatesElevenLabsSellsAreTakenFromAnOutputFormat() {
        for format in ["pcm_inf", "pcm_1e10", "pcm_0.001", "pcm_0", "pcm_-16000", "pcm_12345", "pcm_", "pcm_nan"] {
            #expect(ElevenLabsRawAudio.sampleRate(outputFormat: format) == nil, "\(format)")
        }
        #expect(ElevenLabsRawAudio.sampleRate(outputFormat: "pcm_32000") == 32_000)
        #expect(ElevenLabsRawAudio.sampleRate(outputFormat: "ulaw_8000") == 8_000)
        #expect(ElevenLabsRawAudio.sampleRate(outputFormat: "mp3_44100_128") == 44_100)
    }

    @Test func theWAVWriterRefusesRatherThanTraps() {
        let data = Data([1, 2, 3, 4])
        for rate in [Double.infinity, -.infinity, .nan, 0, 0.001, 1e10] {
            #expect(ElevenLabsRawAudio.wav(from: data, encoding: .pcm16, sampleRate: rate).isEmpty, "\(rate)")
        }
        #expect(ElevenLabsRawAudio.wav(from: data, encoding: .pcm16, sampleRate: 24_000).count == 48)
    }

    @Test func headerlessAudioIsDecodedOffTheMainActorThenPlayable() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-round4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { TemporaryFileSink.removeScratch(folder) }
        let file = folder.appendingPathComponent("take.pcm")
        try Data(count: 48_000).write(to: file)
        let player = ElevenLabsAudioPlayer(url: file, raw: .init(encoding: .pcm16, sampleRate: 24_000))
        player.prepare()
        #expect(player.preparing)
        try await ShellExplorerTests.waitUntil { !player.preparing }
        #expect(player.problem == nil)
        #expect(abs(player.duration - 1) < 0.01)
    }

    // MARK: - C3

    /// With the generation guard on the error path taken away, a cancelled run's late failure
    /// would mark the run after it failed while it is still going.
    @Test func aCancelledRunFailingLateLeavesTheNextRunRunning() async throws {
        let first = Gate(), second = Gate()
        let count = ShellRunnerGenerationTests.Counter()
        let fixture = ShellExplorerTests.Fixture(handler: { _ in
            if count.next() == 1 {
                await first.wait()
                return .jsonText(#"{"detail":"late failure"}"#, status: 400)
            }
            await second.wait()
            return .json(["n": 2])
        })
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "get_models", context: fixture.context))
        let one = Task { await runner.perform(arguments: [:]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .running && fixture.transport.requests.count == 1 }
        runner.cancel()
        let two = Task { await runner.perform(arguments: [:]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .running && fixture.transport.requests.count == 2 }

        first.open()
        #expect(await one.value == nil)
        #expect(runner.phase == .running)
        #expect(runner.failure == nil)
        #expect(runner.isRunning)

        second.open()
        #expect(ShellRunnerGenerationTests.number(await two.value) == 2)
        #expect(runner.phase == .succeeded)
    }

    // MARK: - Nits

    @Test func declineThenRunAtOnceAsksAgain() async throws {
        let fixture = ShellExplorerTests.Fixture(replies: [.json(["status": "ok"])])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "delete_voice", context: fixture.context))
        let first = Task { await runner.perform(arguments: ["voice_id": "a"]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .awaitingConfirmation }
        let firstQuestion = try #require(runner.confirmation)
        runner.decline()
        #expect(runner.phase == .idle)
        #expect(fixture.pane.confirming == nil)
        let second = Task { await runner.perform(arguments: ["voice_id": "a"]) }
        _ = await first.value
        try await ShellExplorerTests.waitUntil { runner.phase == .awaitingConfirmation }
        #expect(runner.refusal == nil)
        #expect(runner.confirmation?.id != firstQuestion.id)
        #expect(fixture.pane.confirming === runner)
        runner.decline()
        _ = await second.value
        #expect(fixture.transport.requests.isEmpty)
    }

    @Test func aRunStoppedEarlyLeavesNoStaleAPICall() async throws {
        let fixture = ShellExplorerTests.Fixture(replies: [.audio(Data([1]))])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "text_to_speech_full", context: fixture.context))
        await runner.perform(arguments: ["voice_id": "v1", "text": "Hi"])
        #expect(runner.apiCall != nil)
        await runner.perform(arguments: ["voice_id": "v1"])
        #expect(runner.phase == .failed)
        #expect(runner.apiCall == nil)
    }

    @Test func curlSendsTextFieldsAsTextNeverAsAFileToRead() {
        let call = ElevenLabsCallDescription(
            operationID: "speech_to_text", method: "POST", url: "https://api.elevenlabs.io/v1/speech-to-text",
            headers: [:], body: ["model_id": "@/etc/hosts", "note": "<secret.txt"]
        )
        let file = ElevenLabsFile(url: URL(fileURLWithPath: "/tmp/take.mp3"))
        let command = ElevenLabsCurl.command(for: call, files: ["file": [file]])
        #expect(command.contains("--form-string 'model_id=@/etc/hosts'"))
        #expect(command.contains("--form-string 'note=<secret.txt'"))
        #expect(!command.contains("-F 'model_id="))
        #expect(command.contains("-F 'file=@/tmp/take.mp3'"))
    }
}

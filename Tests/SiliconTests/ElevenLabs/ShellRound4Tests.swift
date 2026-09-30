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

/// The shell critic's cheaper nits: a missing key says so, labels are short, the session's
/// files are the session's, and environment-variable values are typed hidden.
@Suite("ElevenLabs shell nits")
@MainActor
struct ShellNitTests {

    @Test func aKeyMissingFromTheKeychainSaysSo() {
        let pane = ElevenLabsPaneState(defaults: nil, client: { nil })
        pane.noteFailure(ElevenLabsError.notLinked)
        #expect(pane.connectionProblem == .keyMissing)
    }

    @Test func sentenceLongSpecTitlesGiveWayToTheFieldName() throws {
        let tts = try #require(ElevenLabsCatalog.operation("text_to_speech_full"))
        let latency = try #require(ElevenLabsFormField.fields(for: tts).first { $0.name == "optimize_streaming_latency" })
        #expect(latency.title == "Optimize streaming latency")
        #expect(ElevenLabsFormField.shortTitle("Voice Id") == "Voice Id")
        #expect(ElevenLabsFormField.shortTitle(String(repeating: "x", count: 41)) == nil)
        #expect(ElevenLabsFormField.shortTitle("DEPRECATED. Old") == nil)
    }

    @Test func filesWrittenThisSessionAreThisAccountSessions() {
        let start = Date()
        let before = ElevenLabsOutput(url: URL(fileURLWithPath: "/tmp/a.mp3"), contentType: "audio/mpeg",
                                      operationID: "x", mediaID: nil, createdAt: start.addingTimeInterval(-10))
        let after = ElevenLabsOutput(url: URL(fileURLWithPath: "/tmp/b.mp3"), contentType: "audio/mpeg",
                                     operationID: "x", mediaID: nil, createdAt: start.addingTimeInterval(1))
        #expect(ElevenLabsRecentResultsView.outputs([after, before], since: start).map(\.url.lastPathComponent) == ["b.mp3"])
        let pane = ElevenLabsPaneState(defaults: nil, client: { nil })
        let first = pane.sessionStarted
        pane.reset()
        #expect(pane.sessionStarted >= first)
    }

    @Test func environmentVariableValuesAreTypedHidden() throws {
        for id in ["create_environment_variable", "update_environment_variable"] {
            let operation = try #require(ElevenLabsCatalog.operation(id))
            let values = ShellSecretsTests.allFields(ElevenLabsFormField.fields(for: operation)).filter { $0.name == "values" }
            #expect(!values.isEmpty, "\(id)")
            for field in values {
                #expect(field.kind == .headerMap && field.isSecret, "\(id): \(field.id)")
            }
            let body = try #require(ElevenLabsFormField.fields(for: operation).first { $0.location == .body })
            #expect(ElevenLabsFormField.containsSecret(body), "\(id)")
        }
        let tts = try #require(ElevenLabsCatalog.operation("text_to_speech_full"))
        #expect(!ElevenLabsFormField.fields(for: tts).contains(where: ElevenLabsFormField.containsSecret))
    }
}

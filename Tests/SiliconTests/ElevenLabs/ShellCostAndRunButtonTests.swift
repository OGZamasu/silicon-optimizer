import Foundation
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// What a run costs, in the terms it is billed by, and why a Run button cannot run.
@Suite("ElevenLabs cost notes and the Run button")
@MainActor
struct ShellCostAndRunButtonTests {

    // MARK: - Cost notes

    @Test func whatIsBilledByLengthSaysSo() throws {
        func note(_ id: String, characters: Int? = nil, seconds: Double? = nil) throws -> String? {
            ElevenLabsCostNote.text(for: try #require(ElevenLabsCatalog.operation(id)), characters: characters, seconds: seconds)
        }
        #expect(try note("text_to_speech_full") == "Uses credits by the characters sent.")
        #expect(try note("text_to_speech_full", characters: 1_200) == "Uses credits — about 1,200 characters' worth.")
        #expect(try note("speech_to_speech_full") == "Uses credits by the length of the audio.")
        #expect(try note("audio_isolation", seconds: 200) == "Uses credits by the length of the audio — about 3 min 20 s of it.")
        #expect(try note("speech_to_text") == "Uses credits by the length of the audio.")
        #expect(try note("create_dubbing")?.contains("length of the source") == true)
        #expect(try note("compose_detailed", seconds: 45) == "Uses credits by the length of the music — about 45 s of it.")
        #expect(try note("get_models") == nil)
    }

    // MARK: - Run button

    @Test func theRunButtonSaysWhyItCannotRun() async throws {
        let fixture = ShellExplorerTests.Fixture()
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "text_to_speech_full", context: fixture.context))
        #expect(ElevenLabsRunButton(runner: runner, disabled: true, disabledReason: "Choose a voice first") {}.blocker
                == "Choose a voice first")
        #expect(ElevenLabsRunButton(runner: runner) {}.blocker == nil)
        await runner.perform(arguments: [:])
        let blocker = try #require(ElevenLabsRunButton(runner: runner) {}.blocker)
        #expect(blocker.hasPrefix(runner.problems[0]))
        #expect(runner.problems.count == 1 || blocker.contains("more"))
    }
}

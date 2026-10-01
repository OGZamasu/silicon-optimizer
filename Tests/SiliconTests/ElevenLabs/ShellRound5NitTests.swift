import Darwin
import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// The shell critic's round-3 nits: a new key on the same region stops a stale question (T5),
/// text answers are scrubbed of keys (T6), and a key file is read with limits.
@Suite("ElevenLabs round-3 nits")
@MainActor
struct ShellRound5NitTests {

    /// T5: another key linked on the same region without the pane being reset (a path that is
    /// not Settings), then a stale question confirmed: the runner's own check stops it.
    @Test func aNewKeyOnTheSameRegionStopsAStaleQuestion() async throws {
        let (model, transport, _) = ShellSettingsTests.model(linkedKey: "fixture-key-t5-a-0005") { request in
            if request.url.path.hasPrefix("/v1/user") { return ShellSettingsTests.accountAnswer(request) }
            return .json(["ok": true])
        }
        defer { ShellSettingsTests.clean(model, transport) }
        let runner = try #require(ElevenLabsRunner(operationID: "delete_voice", model: model))
        let running = Task { await runner.perform(arguments: ["voice_id": "v1"]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .awaitingConfirmation }
        _ = try await model.linkElevenLabs(key: "fixture-key-t5-b-0006")
        runner.confirm()
        _ = await running.value
        #expect(transport.requests.filter { $0.method == "DELETE" }.isEmpty)
        #expect(runner.errorMessage == ElevenLabsRunner.accountChangedMessage)
    }

    /// T6: a text answer of an ordinary operation is scrubbed of anything key-shaped.
    @Test func aTextAnswerIsScrubbedOfKeys() throws {
        let key = "sk_" + String(repeating: "0a", count: 16)
        let operation = try #require(ElevenLabsCatalog.operation("get_models"))
        guard case .text(let text, _) = ElevenLabsRevealedCredential.masked(.text("export \(key)", ElevenLabsMeta(status: 200)), for: operation) else {
            Issue.record("expected text")
            return
        }
        #expect(!text.contains(key))
        #expect(text.hasPrefix("export "))
    }

    /// A key or certificate file: regular, at most 256 KB, text, and it is read off the main
    /// actor anyway. (No named pipe here: a regression in the check would block the read — and
    /// the test process — forever. `ShellFollowupTests` covers the other kinds of file.)
    @Test func aKeyFileIsReadWithLimits() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-keyfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { TemporaryFileSink.removeScratch(folder) }

        let pem = folder.appendingPathComponent("client.pem")
        try Data("-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n".utf8).write(to: pem)
        #expect(try ElevenLabsSecretFile.read(pem).get().contains("\nabc\n"))

        let big = folder.appendingPathComponent("big.pem")
        try Data(count: ElevenLabsSecretFile.sizeLimit + 1).write(to: big)
        #expect((try? ElevenLabsSecretFile.read(big).get()) == nil)

        #expect((try? ElevenLabsSecretFile.read(folder).get()) == nil)
    }
}

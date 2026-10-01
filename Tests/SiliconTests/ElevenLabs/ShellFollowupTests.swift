import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// The shell critic's last nits, taken after the merge: the key file is read through one
/// descriptor, and a refused second Connect leaves no stale line once the first works.
@Suite("ElevenLabs shell follow-ups")
@MainActor
struct ShellFollowupTests {

    // MARK: - Key files

    /// One scratch folder per test, removed only if it is still one.
    struct Scratch {
        let folder: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("elevenlabs-keyfile-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func file(_ name: String, _ data: Data) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }

        func link(_ name: String, to target: URL) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            return url
        }

        func remove() { TemporaryFileSink.removeScratch(folder) }
    }

    static let pem = Data("-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n".utf8)

    static func problem(_ result: Result<String, ElevenLabsSecretFile.Problem>) -> String? {
        if case .failure(let problem) = result { return problem.message }
        return nil
    }

    /// Every kind of file the owner might pick, each refused with its own reason or read. (No
    /// named pipe: a regression would block the read, and the test process, for good.)
    @Test func aKeyFileIsCheckedAndReadThroughOneDescriptor() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }

        let pem = try scratch.file("client.pem", Self.pem)
        #expect((try? ElevenLabsSecretFile.read(pem).get())?.contains("\nabc\n") == true)

        // A link the owner picked is followed to its file.
        let linkToPEM = try scratch.link("linked.pem", to: pem)
        #expect((try? ElevenLabsSecretFile.read(linkToPEM).get())?.contains("\nabc\n") == true)

        let linkToDevice = try scratch.link("null.pem", to: URL(fileURLWithPath: "/dev/null"))
        #expect(Self.problem(ElevenLabsSecretFile.read(linkToDevice)) == "null.pem is not a regular file.")
        #expect(Self.problem(ElevenLabsSecretFile.read(scratch.folder))?.hasSuffix("is not a regular file.") == true)

        let empty = try scratch.file("empty.pem", Data())
        #expect(Self.problem(ElevenLabsSecretFile.read(empty)) == "empty.pem is empty.")

        let big = try scratch.file("big.pem", Data(repeating: 0x61, count: 257 * 1024))
        #expect(Self.problem(ElevenLabsSecretFile.read(big))?.contains("too big") == true)

        let exact = try scratch.file("exact.pem", Data(repeating: 0x61, count: ElevenLabsSecretFile.sizeLimit))
        #expect((try? ElevenLabsSecretFile.read(exact).get())?.count == ElevenLabsSecretFile.sizeLimit)

        let utf16 = try scratch.file("utf16.pem", Data([0xFF, 0xFE]) + "key".data(using: .utf16LittleEndian)!)
        #expect(Self.problem(ElevenLabsSecretFile.read(utf16)) == "utf16.pem could not be read as text.")

        let missing = scratch.folder.appendingPathComponent("missing.pem")
        #expect(Self.problem(ElevenLabsSecretFile.read(missing)) == "missing.pem could not be opened.")
    }

    /// A file that passes the check and then grows: what is read is capped and judged by what
    /// was read, not by the size seen at the check.
    @Test func aKeyFileThatGrowsAfterTheCheckIsStillCapped() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let growing = try scratch.file("growing.pem", Data("small".utf8))
        let result = ElevenLabsSecretFile.read(growing) {
            guard let handle = try? FileHandle(forWritingTo: growing) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(repeating: 0x61, count: 300 * 1024))
        }
        #expect(Self.problem(result)?.contains("too big") == true)
    }

    // MARK: - Failures carry their status

    /// A failed run keeps ElevenLabs' HTTP status, so the sections judge "did anything happen?"
    /// by it instead of parsing words: a 4xx refusal proves nothing was done; a 408, a 429, a
    /// 5xx, a lost connection and a cancel do not.
    @Test func aFailureCarriesItsHTTPStatusAndSaysWhetherAnythingWasDone() {
        func failure(_ status: Int) -> ElevenLabsRunnerFailure {
            ElevenLabsRunnerFailure(ElevenLabsError.api(status: status, code: nil, message: "No", requestID: nil))
        }
        #expect(failure(422) == .api(status: 422, message: "ElevenLabs answered 422: No"))
        #expect(failure(422).message == "ElevenLabs answered 422: No")
        for refused in [400, 401, 403, 404, 409, 413, 422] {
            #expect(failure(refused).provesNothingWasDone, "\(refused) is a refusal")
        }
        for unknown in [408, 500, 502, 503, 504] {
            #expect(!failure(unknown).provesNothingWasDone, "\(unknown) may have been carried out")
        }
        #expect(!ElevenLabsRunnerFailure(ElevenLabsError.rateLimited(retryAfter: 3)).provesNothingWasDone)
        #expect(!ElevenLabsRunnerFailure(ElevenLabsError.network("timed out")).provesNothingWasDone)
        #expect(!ElevenLabsRunnerFailure(ElevenLabsError.cancelled).provesNothingWasDone)
        #expect(ElevenLabsRunnerFailure(ElevenLabsError.invalidArguments(["x"])).provesNothingWasDone)
        #expect(ElevenLabsRunnerFailure(ElevenLabsError.notLinked).provesNothingWasDone)
    }

    // MARK: - Connect

    /// Return in the key field while a key is being checked: the second Connect is refused with
    /// a line saying so — and once the first one works, that line is gone, not left in red
    /// under a connected key.
    @Test func aRefusedSecondConnectLeavesNoLineOnceTheFirstWorks() async throws {
        let gate = ShellRunnerGenerationTests.Gate()
        let (model, transport, store) = ShellSettingsTests.model(linkedKey: nil) { request in
            await gate.wait()
            return ShellSettingsTests.accountAnswer(request)
        }
        defer { ShellSettingsTests.clean(model, transport) }
        let connection = model.elevenLabsPane.connection
        let connecting = Task { await connection.connect(key: ShellSettingsTests.candidate, model: model) }
        try await ShellExplorerTests.waitUntil { transport.requests.count >= 1 }

        #expect(await connection.connect(key: ShellSettingsTests.candidate, model: model) == false)
        #expect(connection.failure == ElevenLabsConnectionModel.alreadyCheckingMessage)

        gate.open()
        #expect(await connecting.value)
        #expect(connection.connected)
        #expect(connection.failure == nil, "still showing: \(connection.failure ?? "")")
        #expect(store.key == ShellSettingsTests.candidate)
    }
}

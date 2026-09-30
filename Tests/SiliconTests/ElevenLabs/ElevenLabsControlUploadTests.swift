import Darwin
import Foundation
import Testing
import SiliconControl
import SiliconElevenLabs
@testable import SiliconUI

/// `files: [{field, path}]`: read on this Mac, only regular files of this user's, within the
/// size limit, copied before the client sees them, removed afterwards — and the path never
/// in an answer. Everything here lives in a scratch folder the test makes and removes.
@Suite("ElevenLabs control: uploads")
struct ElevenLabsControlUploadTests {

    @Test func aFileIsReadOnTheMacAndItsPathNeverComesBack() async throws {
        try await withScratch { scratch in
            let audio = scratch.appendingPathComponent("voice sample.wav")
            let bytes = Data("RIFF....WAVEfmt fixture audio".utf8)
            try bytes.write(to: audio)
            let backend = RecordingBackend()
            let answer = await ELFixture.handler(backend: backend).call(
                ELFixture.body("isolate", files: [("audio", audio.path)])
            )
            #expect(answer.status == 200)
            let call = try #require(backend.calls.first)
            let sent = try #require(call.files["audio"]?.first)
            #expect(call.files["audio"]?.count == 1)
            #expect(call.contents["audio"] == [bytes])
            // The upload carries the file's own name, from a copy that is not the file.
            #expect(sent.filename == "voice sample.wav")
            #expect(sent.contentType == "audio/wav")
            #expect(sent.url.path != audio.path)
            // The copy is gone once the call is over; the original is untouched.
            #expect(!FileManager.default.fileExists(atPath: sent.url.deletingLastPathComponent().path))
            #expect(try Data(contentsOf: audio) == bytes)
            let text = String(decoding: answer.body, as: UTF8.self)
            #expect(!text.contains(scratch.lastPathComponent))
            #expect(!text.contains("voice sample"))
        }
    }

    @Test func severalFilesGoToAFieldThatTakesSeveralInOrder() async throws {
        try await withScratch { scratch in
            var paths: [(String, String)] = []
            for index in 1...3 {
                let file = scratch.appendingPathComponent("sample-\(index).mp3")
                try Data("sample \(index)".utf8).write(to: file)
                paths.append(("files", file.path))
            }
            let backend = RecordingBackend()
            let answer = await ELFixture.handler(backend: backend).call(
                ELFixture.body("clone_voice", arguments: ["name": "Narrator"], files: paths)
            )
            #expect(answer.status == 200)
            #expect(backend.calls.first?.files["files"]?.map(\.filename)
                == ["sample-1.mp3", "sample-2.mp3", "sample-3.mp3"])
            #expect(backend.calls.first?.contents["files"]
                == (1...3).map { Data("sample \($0)".utf8) })
        }
    }

    /// Everything that is not a regular file of this user's is refused by name — its place in
    /// the list and its field, never its path — all at once, and nothing reaches the client.
    /// The pipe matters most: opened the ordinary way it would hang the call for ever.
    @Test func whatIsNotARegularFileIsRefusedWithoutEchoingThePath() async throws {
        try await withScratch { scratch in
            let folder = scratch.appendingPathComponent("a folder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let real = scratch.appendingPathComponent("real.wav")
            try Data("audio".utf8).write(to: real)
            let linkToFolder = scratch.appendingPathComponent("link-to-folder")
            try FileManager.default.createSymbolicLink(at: linkToFolder, withDestinationURL: folder)
            let linkToFile = scratch.appendingPathComponent("link-to-file.wav")
            try FileManager.default.createSymbolicLink(at: linkToFile, withDestinationURL: real)
            let pipe = scratch.appendingPathComponent("a-pipe")
            #expect(mkfifo(pipe.path, 0o600) == 0)

            let cases: [(path: String, says: String)] = [
                (scratch.appendingPathComponent("missing.wav").path, "there is no file at that path"),
                (folder.path, "not a regular file"),
                (linkToFolder.path, "symbolic link"),
                (linkToFile.path, "symbolic link"),
                (pipe.path, "not a regular file"),
                ("/dev/null", "device path"),
                ("relative/voice.wav", "the path must be absolute"),
            ]
            for (path, says) in cases {
                let backend = RecordingBackend()
                let answer = await ELFixture.handler(backend: backend).call(
                    ELFixture.body("isolate", files: [("audio", path)])
                )
                #expect(answer.status == 400, "\(path)")
                let refusal = try ELFixture.decode(ElevenLabsWire.Refusal.self, answer)
                #expect(refusal.error.contains("files[0] (audio)"), "\(path)")
                #expect(refusal.error.contains(says), "\(path): \(refusal.error)")
                let text = String(decoding: answer.body, as: UTF8.self)
                #expect(!text.contains(scratch.lastPathComponent) && !text.contains(path), "\(path)")
                #expect(backend.calls.isEmpty)
            }

            // Several at once: every one named.
            let backend = RecordingBackend()
            let answer = await ELFixture.handler(backend: backend).call(ELFixture.body(
                "clone_voice", arguments: ["name": "N"],
                files: [("files", real.path), ("files", pipe.path), ("files", folder.path)]
            ))
            #expect(answer.status == 400)
            #expect(try ELFixture.decode(ElevenLabsWire.Refusal.self, answer).problems?.count == 2)
            #expect(backend.calls.isEmpty)
        }
    }

    /// `/dev/fd/N` is not a symlink, so `O_NOFOLLOW` lets it through, and it opens a
    /// descriptor the app already holds — a file the caller never named. Refused, however it is
    /// spelled: directly, through `/dev/stdin`, through a folder link into /dev, or as
    /// /private/dev; and the app's open file is never read.
    @Test func aDescriptorTheAppHoldsCannotBeUploadedByAnySpelling() async throws {
        try await withScratch { scratch in
            let secret = scratch.appendingPathComponent("app-private-state.db")
            try Data("app state \(UUID().uuidString)".utf8).write(to: secret)
            let descriptor = open(secret.path, O_RDONLY)
            try #require(descriptor >= 0)
            defer { close(descriptor) }
            let intoDev = scratch.appendingPathComponent("devlink")
            try FileManager.default.createSymbolicLink(at: intoDev, withDestinationURL: URL(fileURLWithPath: "/dev"))
            for path in [
                "/dev/fd/\(descriptor)", "/dev/stdin", "/dev/fd/0", "/private/dev/fd/\(descriptor)",
                intoDev.appendingPathComponent("fd/\(descriptor)").path, "/dev/../dev/fd/\(descriptor)",
            ] {
                let backend = RecordingBackend()
                let answer = await ELFixture.handler(backend: backend).call(
                    ELFixture.body("isolate", files: [("audio", path)])
                )
                #expect(answer.status == 400, "\(path)")
                #expect(try ELFixture.decode(ElevenLabsWire.Refusal.self, answer).error.contains("device path"), "\(path)")
                #expect(backend.calls.isEmpty, "\(path)")
            }
        }
    }

    @Test func fieldsAreCheckedAgainstTheOperation() async throws {
        try await withScratch { scratch in
            let real = scratch.appendingPathComponent("real.wav")
            try Data("audio".utf8).write(to: real)
            let backend = RecordingBackend()
            let handler = ELFixture.handler(backend: backend)

            let unknown = try ELFixture.decode(ElevenLabsWire.Refusal.self, await handler.call(
                ELFixture.body("isolate", files: [("sample", real.path)])
            ))
            #expect(unknown.error.contains("files[0] (sample)"))
            #expect(unknown.error.contains("its file fields are audio"))

            let twice = await handler.call(ELFixture.body(
                "isolate", files: [("audio", real.path), ("audio", real.path)]
            ))
            #expect(twice.status == 400)
            #expect(try ELFixture.decode(ElevenLabsWire.Refusal.self, twice).error
                .contains("\"audio\" takes one file; 2 were given."))

            let none = await handler.call(ELFixture.body(
                "speak", arguments: ["voice_id": "v", "text": "Hi"], files: [("audio", real.path)]
            ))
            #expect(none.status == 400)
            #expect(try ELFixture.decode(ElevenLabsWire.Refusal.self, none).error
                .contains("speak takes no files"))
            #expect(backend.calls.isEmpty)
        }
    }

    @Test func uploadsAreHeldToTheLimitForTheWholeCall() async throws {
        try await withScratch { scratch in
            let big = scratch.appendingPathComponent("big.wav")
            try Data(count: 2_000).write(to: big)
            let half = scratch.appendingPathComponent("half.wav")
            try Data(count: 600).write(to: half)
            let backend = RecordingBackend()
            var handler = ELFixture.handler(backend: backend)
            handler.uploadBytes = 1_000

            let one = await handler.call(ELFixture.body("isolate", files: [("audio", big.path)]))
            #expect(one.status == 413)
            #expect(try ELFixture.decode(ElevenLabsWire.Refusal.self, one).error.contains("in all"))

            let together = await handler.call(ELFixture.body(
                "clone_voice", arguments: ["name": "N"], files: [("files", half.path), ("files", half.path)]
            ))
            #expect(together.status == 413)
            #expect(try ELFixture.decode(ElevenLabsWire.Refusal.self, together).problems
                == ["files[1] (files): it would take this call's uploads past 1 KB in all."])

            #expect(await handler.call(ELFixture.body(
                "clone_voice", arguments: ["name": "N"], files: [("files", half.path)]
            )).status == 200)
            #expect(backend.calls.count == 1)
        }
    }

    /// A failed call removes its copies too, and a client error that quotes one — or the
    /// caller's own path — has it taken out.
    @Test func aFailedCallCleansUpAndItsErrorNamesNoPath() async throws {
        try await withScratch { scratch in
            let audio = scratch.appendingPathComponent("take.wav")
            try Data("audio".utf8).write(to: audio)
            let seen = SeenFiles()
            let backend = RecordingBackend(answerFiles: { _, files in
                let copy = files["audio"]?.first?.url.path ?? "?"
                seen.set(copy)
                throw ElevenLabsError.network("could not read \(copy) (from \(audio.path))")
            })
            let answer = await ELFixture.handler(backend: backend).call(
                ELFixture.body("isolate", files: [("audio", audio.path)])
            )
            #expect(answer.status == 502)
            let text = String(decoding: answer.body, as: UTF8.self)
            let copy = try #require(seen.path)
            #expect(!text.contains(copy))
            #expect(!text.contains(audio.path))
            #expect(!text.contains(ElevenLabsControlHandler.stagingPrefix))
            #expect(text.contains("(upload)"))
            #expect(!FileManager.default.fileExists(atPath: copy))
        }
    }

    /// The gate and the link come first: a refused call never opens its uploads. A pipe would
    /// be a 400 if it were looked at, so a 403 and a 409 prove it was not.
    @Test func aRefusedCallNeverOpensItsUploads() async throws {
        try await withScratch { scratch in
            let pipe = scratch.appendingPathComponent("a-pipe")
            #expect(mkfifo(pipe.path, 0o600) == 0)
            let risky = ElevenLabsControlCatalog(ELFixture.catalog.operations.map { operation in
                var operation = operation
                if operation.id == "isolate" { operation.risk = .destructive }
                return operation
            })
            var handler = ELFixture.handler()
            handler.catalog = risky
            #expect(await handler.call(ELFixture.body("isolate", files: [("audio", pipe.path)])).status == 403)
            #expect(await ELFixture.handler(linked: false).call(
                ELFixture.body("isolate", files: [("audio", pipe.path)])
            ).status == 409)
        }
    }

    // MARK: Scratch

    private func withScratch(_ body: (URL) async throws -> Void) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-control-uploads-test-\(UUID().uuidString)", isDirectory: true)
        try requireTemporaryDirectory(scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { removeTemporaryDirectory(scratch) }
        try await body(scratch)
    }
}

private final class SeenFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var _path: String?
    var path: String? { lock.withLock { _path } }
    func set(_ path: String) { lock.withLock { _path = path } }
}

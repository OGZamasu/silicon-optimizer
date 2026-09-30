import CryptoKit
import Foundation
import Testing
@testable import SiliconElevenLabs

/// The WebSocket APIs are not in the OpenAPI spec. Their AsyncAPI documents are pinned under
/// `Scripts/elevenlabs/asyncapi/`, the drift script compares them with the live docs, and these
/// tests hold the script's diff to two local files — nothing here fetches anything.
@Suite("ElevenLabs realtime spec snapshots")
struct RealtimeSpecTests {

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let pinnedFolder = repository.appendingPathComponent("Scripts/elevenlabs/asyncapi", isDirectory: true)
    static let names = ["tts-stream-input", "tts-multi-stream-input", "stt-realtime", "agents-conversation"]

    /// A refresh is deliberate: the new file's digest goes here, and the fidelity tests run again.
    static let pinnedDigests = [
        "tts-stream-input": "2731e1edc519b26d7c7f68d095fa0e38e5cf43b653896fdacf2b50d7398d33a8",
        "tts-multi-stream-input": "14e73703b3c4738215c1cd653d1891962d9dc149a83e5eb7d748310fdc18534f",
        "stt-realtime": "deb6c49fcb80c0c057f36e3b3bf44fdec573488978dd56be663bd988b636ad61",
        "agents-conversation": "400b77fce9ef545af88face872a69622085dd753d832245ac21d54d0354b837c",
    ]

    @Test func theFourSnapshotsArePinned() throws {
        for name in Self.names {
            let data = try Data(contentsOf: Self.pinnedFolder.appendingPathComponent("\(name).yaml"))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(digest == Self.pinnedDigests[name], "\(name).yaml changed; update the digest after reviewing the drift")
            #expect(String(decoding: data, as: UTF8.self).hasPrefix("asyncapi: 2.6.0"))
        }
    }

    @Test func theDiffListsWhatChangedInTheSockets() throws {
        let scratch = try Self.scratch()
        defer { TemporaryFileSink.removeScratch(scratch) }
        for name in Self.names {
            try FileManager.default.copyItem(
                at: Self.pinnedFolder.appendingPathComponent("\(name).yaml"),
                to: scratch.appendingPathComponent("\(name).yaml")
            )
        }
        let same = try Self.run(["Scripts/check-elevenlabs-spec.sh", "--only-asyncapi", "--asyncapi-against", scratch.path])
        #expect(same.status == 0, "\(same.output)")
        #expect(same.output.components(separatedBy: ": no drift").count - 1 == 4)

        // A renamed query parameter, a new audio format, reworded prose; and the live side given
        // as the docs page it comes in (the YAML inside a .md), as a live run fetches it.
        let tts = scratch.appendingPathComponent("tts-stream-input.yaml")
        var text = try String(contentsOf: tts, encoding: .utf8)
        text = text.replacingOccurrences(of: "            inactivity_timeout:\n", with: "            idle_timeout:\n")
        try text.write(to: tts, atomically: true, encoding: .utf8)
        let stt = scratch.appendingPathComponent("stt-realtime.yaml")
        text = try String(contentsOf: stt, encoding: .utf8)
        text = text.replacingOccurrences(of: "        - ulaw_8000\n", with: "        - ulaw_8000\n        - pcm_96000\n")
        text = text.replacingOccurrences(of: "Audio encoding format for speech-to-text.", with: "Audio encoding.")
        try FileManager.default.removeItem(at: stt)
        try ("# WebSocket\n\n```yaml\n" + text + "```\n").write(
            to: scratch.appendingPathComponent("stt-realtime.md"), atomically: true, encoding: .utf8
        )

        let drift = try Self.run(["Scripts/check-elevenlabs-spec.sh", "--only-asyncapi", "--asyncapi-against", scratch.path])
        #expect(drift.status == 3, "\(drift.output)")
        #expect(drift.output.contains("+ channels./v1/text-to-speech/{voice_id}/stream-input.bindings.ws.query.properties.idle_timeout.maximum = 180"))
        #expect(drift.output.contains("- channels./v1/text-to-speech/{voice_id}/stream-input.bindings.ws.query.properties.inactivity_timeout.maximum = 180"))
        #expect(drift.output.contains("~ components.schemas.AudioFormatEnum.enum[]:"))
        #expect(drift.output.contains("pcm_96000"))
        #expect(drift.output.contains("wording changed at"))
        #expect(drift.output.contains("asyncapi tts-multi-stream-input: no drift"))
        #expect(drift.output.contains("asyncapi agents-conversation: no drift"))
    }

    /// A local OpenAPI comparison stays local: the socket check runs only when asked for.
    @Test func anOpenAPIComparisonAloneDoesNotCheckTheSockets() throws {
        let pinned = Self.repository.appendingPathComponent("Scripts/elevenlabs/openapi.json")
        let result = try Self.run(["Scripts/check-elevenlabs-spec.sh", "--against", pinned.path])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("no drift"))
        #expect(!result.output.contains("asyncapi"))
    }

    // MARK: - Helpers

    static func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-asyncapi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Runs a repository script on local files only.
    static func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = repository
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// `path = value` lines of a pinned snapshot, through the drift script's own reader.
    static func outline(_ name: String) throws -> [String] {
        let result = try run(["python3", "Scripts/elevenlabs-asyncapi.py", "outline",
                              pinnedFolder.appendingPathComponent("\(name).yaml").path])
        #expect(result.status == 0)
        return result.output.components(separatedBy: "\n")
    }
}

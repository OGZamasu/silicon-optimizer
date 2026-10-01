import CryptoKit
import Foundation
import Testing
@testable import SiliconElevenLabs

/// The catalog is the pinned spec, all of it, and nothing the running app has to fetch.
@Suite("ElevenLabs catalog")
struct CoreCatalogTests {

    static let pinnedSHA256 = "0b2f5145d7e6d04db439123076de5780da7402bc7e763ba49783c918323f942b"

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func theCatalogHoldsEveryOperationOfThePinnedSpecOnce() {
        let all = ElevenLabsCatalog.all
        #expect(all.count == 403)
        #expect(all.count == ElevenLabsCatalog.generatedOperationCount)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(ElevenLabsCatalog.groups.map(\.count).reduce(0, +) == 403)
        #expect(ElevenLabsCatalog.groups.count == ElevenLabsCatalog.generatedGroupCount)
        for operation in all {
            #expect(ElevenLabsCatalog.operation(operation.id) == operation)
            #expect(["GET", "POST", "PUT", "PATCH", "DELETE"].contains(operation.method))
            #expect(operation.path.hasPrefix("/"))
            #expect(!operation.group.isEmpty)
        }
    }

    @Test func theCatalogIsPinnedToTheSnapshotInTheRepository() throws {
        #expect(ElevenLabsCatalog.specSHA256 == Self.pinnedSHA256)
        let snapshot = Self.repository.appendingPathComponent("Scripts/elevenlabs/openapi.json")
        let digest = SHA256.hash(data: try Data(contentsOf: snapshot))
        #expect(digest.map { String(format: "%02x", $0) }.joined() == Self.pinnedSHA256)
    }

    @Test func theCommittedCatalogIsWhatTheScriptGeneratesToday() throws {
        let result = try Self.run(["python3", "Scripts/elevenlabs-catalog.py", "--check"])
        #expect(result.status == 0, "\(result.output)")
    }

    /// Generating into a folder outside the repository (to compare with the committed catalog)
    /// writes the file and ends cleanly; the summary used to crash after writing it.
    @Test func theScriptWritesACatalogOutsideTheRepositoryAndSaysWhere() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { TemporaryFileSink.removeScratch(folder) }
        let out = folder.appendingPathComponent("catalog.swift")
        let result = try Self.run(["python3", "Scripts/elevenlabs-catalog.py", "--out", out.path])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("403 operations") && result.output.contains(out.lastPathComponent))
        let committed = Self.repository.appendingPathComponent("Sources/SiliconElevenLabs/Generated/ElevenLabsCatalogData.swift")
        #expect(try Data(contentsOf: out) == Data(contentsOf: committed), "the same catalog as the committed one")
    }

    @Test func theKeyHeaderIsNeverAParameterTheClientAddsIt() {
        for operation in ElevenLabsCatalog.all {
            #expect(!operation.parameters.contains { $0.name.lowercased() == "xi-api-key" })
        }
        let safety = ElevenLabsCatalog.all.filter { $0.parameter(named: "safety-identifier") != nil }
        #expect(safety.count == 1)
        #expect(safety.first?.parameter(named: "safety-identifier")?.location == .header)
    }

    @Test func textToSpeechIsDescribedAsTheSpecSaysIncludingItsStreamingVariant() throws {
        let speech = try #require(ElevenLabsCatalog.operation("text_to_speech_full"))
        #expect(speech.method == "POST")
        #expect(speech.path == "/v1/text-to-speech/{voice_id}")
        #expect(speech.group == "Text to speech")
        #expect(speech.response == .audio)
        #expect(!speech.supportsStreaming)
        #expect(speech.body?.contentType == .json)
        #expect(speech.body?.requiredFields == ["text"])
        #expect(speech.parameter(named: "voice_id")?.location == .path)
        #expect(speech.parameter(named: "voice_id")?.required == true)
        #expect(speech.parameter(named: "output_format")?.location == .query)
        #expect(speech.body?.schema["properties"]["model_id"]["type"].stringValue == "string")

        let stream = try #require(ElevenLabsCatalog.operation("text_to_speech_stream"))
        #expect(stream.supportsStreaming)
        #expect(stream.response == .audio)
        let timed = try #require(ElevenLabsCatalog.operation("text_to_speech_stream_with_timestamps"))
        #expect(timed.supportsStreaming)
        #expect(timed.response == .json)
    }

    @Test func multipartUploadsNameTheirFileFieldsIncludingArraysOfFiles() throws {
        let clone = try #require(ElevenLabsCatalog.operation("add_voice"))
        #expect(clone.body?.contentType == .multipart)
        #expect(clone.body?.fileFields == ["files"])
        #expect(clone.body?.acceptsMultipleFiles("files") == true)

        let transcribe = try #require(ElevenLabsCatalog.operation("speech_to_text"))
        #expect(transcribe.body?.contentType == .multipart)
        #expect(transcribe.body?.fileFields.contains("file") == true)
        #expect(transcribe.body?.acceptsMultipleFiles("file") == false)

        let multipart = ElevenLabsCatalog.all.filter { $0.body?.contentType == .multipart }
        #expect(multipart.count == 31)
        #expect(ElevenLabsCatalog.all.filter { $0.body?.contentType == .json }.count == 156)
    }

    @Test func everyResponseKindInTheSpecIsRecognised() throws {
        let kinds = Dictionary(grouping: ElevenLabsCatalog.all, by: \.response.name).mapValues(\.count)
        #expect(kinds == ["json": 375, "audio": 19, "binary": 5, "text": 2, "events": 1, "multipartMixed": 1])
        #expect(ElevenLabsCatalog.operation("compose_detailed")?.response == .multipartMixed)
        #expect(ElevenLabsCatalog.operation("compose_detailed_stream")?.response == .events)
        #expect(ElevenLabsCatalog.operation("download_speech_history_items")?.response == .binary("application/zip"))
        #expect(ElevenLabsCatalog.operation("export_batch_call")?.response == .binary("text/csv"))
        #expect(ElevenLabsCatalog.operation("get_pronunciation_dictionary_version_pls")?.response == .binary("text/plain"))
        #expect(ElevenLabsCatalog.operation("register_twilio_call")?.response == .text)
        // The spec gives this one no content type; its description says it streams audio.
        #expect(ElevenLabsCatalog.operation("stream_project_snapshot_audio_endpoint")?.response == .audio)
        #expect(ElevenLabsCatalog.all.filter(\.supportsStreaming).count == 14)
    }

    @Test func operationsTheSpecLeavesUntaggedStillLandInAGroup() {
        #expect(ElevenLabsCatalog.operation("get_user_info")?.group == "Account and usage")
        #expect(ElevenLabsCatalog.operation("get_user_subscription_info")?.group == "Account and usage")
        #expect(ElevenLabsCatalog.operation("create_agent_response_test_route")?.group == "Agent testing")
        #expect(ElevenLabsCatalog.operation("add_ticket_comment_route")?.group == "Triage tickets")
        #expect(ElevenLabsCatalog.operation("redirect_to_mintlify")?.group == "Documentation")
        #expect(ElevenLabsCatalog.groups.first?.name == "Account and usage")
    }

    @Test func schemasAreResolvedInlineAndCutOffByNameWhereTheyRecurse() throws {
        let agent = try #require(ElevenLabsCatalog.operation("create_agent_route"))
        let config = agent.body?.schema["properties"]["conversation_config"]
        #expect(config?["properties"].objectValue?.isEmpty == false)
        // Somewhere below the depth bound a reference is kept by name, not expanded.
        #expect(agent.body.map { Self.containsTruncation($0.schema) } == true)
        #expect(!Self.containsRawReference(agent.body!.schema))
    }

    @Test func searchMatchesEveryWordAndFilters() {
        let speech = ElevenLabsCatalog.search("text speech")
        #expect(speech.contains { $0.id == "text_to_speech_full" })
        #expect(ElevenLabsCatalog.search("").count == 403)
        #expect(ElevenLabsCatalog.search("", group: "Voices").allSatisfy { $0.group == "Voices" })
        let deletes = ElevenLabsCatalog.search("voice", risk: .destructive)
        #expect(deletes.contains { $0.id == "delete_voice" })
        #expect(deletes.allSatisfy { $0.risk == .destructive })
    }

    @Test func theResponseKindCodesAsKindAndContentType() throws {
        let data = try JSONEncoder().encode(ElevenLabsResponseKind.binary("application/zip"))
        #expect(try JSONValue(data: data) == ["kind": "binary", "contentType": "application/zip"])
        #expect(try JSONDecoder().decode(ElevenLabsResponseKind.self, from: data) == .binary("application/zip"))
        let operation = try #require(ElevenLabsCatalog.operation("get_models"))
        let round = try JSONDecoder().decode(ElevenLabsOperation.self, from: JSONEncoder().encode(operation))
        #expect(round == operation)
    }

    // MARK: - Drift check

    @Test func theDriftCheckListsAddedRemovedAndChangedOperations() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-drift-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { TemporaryFileSink.removeScratch(scratch) }
        let old: JSONValue = ["openapi": "3.1.0", "paths": [
            "/v1/a": ["get": ["operationId": "get_a", "responses": ["200": ["content": ["application/json": [:]]]]]],
            "/v1/b": ["post": ["operationId": "post_b", "responses": ["200": [:]]]],
            "/v1/c": ["delete": ["operationId": "delete_c", "responses": ["204": [:]]]],
        ]]
        let new: JSONValue = ["openapi": "3.1.0", "paths": [
            "/v1/a": ["get": ["operationId": "get_a", "responses": ["200": ["content": ["audio/mpeg": [:]]]]]],
            "/v1/b": ["post": ["operationId": "post_b", "responses": ["200": [:]]]],
            "/v1/d": ["post": ["operationId": "post_d", "responses": ["200": [:]]]],
        ]]
        let pinned = scratch.appendingPathComponent("pinned.json")
        let live = scratch.appendingPathComponent("live.json")
        try old.encoded().write(to: pinned)
        try new.encoded().write(to: live)

        let drift = try Self.run(["Scripts/check-elevenlabs-spec.sh", "--pinned", pinned.path, "--against", live.path])
        #expect(drift.status == 3)
        #expect(drift.output.contains("+ post_d  POST /v1/d"))
        #expect(drift.output.contains("- delete_c  DELETE /v1/c"))
        #expect(drift.output.contains("~ get_a  (responses)"))
        #expect(!drift.output.contains("post_b"))

        let same = try Self.run(["Scripts/check-elevenlabs-spec.sh", "--pinned", pinned.path, "--against", pinned.path])
        #expect(same.status == 0)
        #expect(same.output.contains("no drift"))
    }

    // MARK: - Helpers

    static func containsTruncation(_ schema: JSONValue) -> Bool {
        switch schema {
        case .object(let object):
            if object["x-truncated"] == .bool(true) { return true }
            return object.values.contains(where: containsTruncation)
        case .array(let array): return array.contains(where: containsTruncation)
        default: return false
        }
    }

    static func containsRawReference(_ schema: JSONValue) -> Bool {
        switch schema {
        case .object(let object):
            if object["$ref"] != nil { return true }
            return object.values.contains(where: containsRawReference)
        case .array(let array): return array.contains(where: containsRawReference)
        default: return false
        }
    }

    /// Runs a repository script with no network in play (every use here reads local files).
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
}

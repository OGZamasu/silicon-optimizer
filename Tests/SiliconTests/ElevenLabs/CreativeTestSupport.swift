import Foundation
import SiliconElevenLabs
import Testing
@testable import SiliconUI

/// A creative session over the public fakes: an in-memory transport that answers by
/// operation, a key that is not one, files in a scratch folder removed at the end. Nothing
/// leaves the process and nothing touches the Keychain.
@MainActor
final class CreativeRig {
    let transport: FakeElevenLabsTransport
    let credentials = FakeCredentialSource(key: "creative-fixture-not-a-key")
    let sink = TemporaryFileSink()
    let client: ElevenLabsClient
    let voices: ElevenLabsVoiceDirectory
    let session: CreativeSession
    let scratch: URL
    private let router: Router

    /// Answers by operation id; an unscripted operation gets a 599 so a test sees it.
    final class Router: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: [FakeElevenLabsTransport.Reply]] = [:]
        private var fallbacks: [String: FakeElevenLabsTransport.Reply] = [:]

        /// `reply` for every call of `operationID`.
        func always(_ operationID: String, _ reply: FakeElevenLabsTransport.Reply) {
            lock.withLock { fallbacks[operationID] = reply }
        }

        /// `replies` in order for the next calls of `operationID`, then its `always` reply.
        func queue(_ operationID: String, _ replies: [FakeElevenLabsTransport.Reply]) {
            lock.withLock { self.replies[operationID, default: []] += replies }
        }

        func reply(for request: ElevenLabsRequest) -> FakeElevenLabsTransport.Reply {
            lock.withLock {
                if var queued = replies[request.operationID], !queued.isEmpty {
                    let next = queued.removeFirst()
                    replies[request.operationID] = queued
                    return next
                }
                return fallbacks[request.operationID]
                    ?? .jsonText(#"{"detail":"not scripted in this test"}"#, status: 599)
            }
        }
    }

    init() {
        let router = Router()
        self.router = router
        transport = FakeElevenLabsTransport { request in router.reply(for: request) }
        var limits = ElevenLabsClient.Limits()
        limits.firstBackoff = 0.01
        limits.longestRetryWait = 0.02
        limits.retries = 0
        client = ElevenLabsClient(credentials: credentials, region: .global, transport: transport, sink: sink, limits: limits)
        let client = client
        let sink = sink
        voices = ElevenLabsVoiceDirectory(client: { client })
        session = CreativeSession(context: .init(client: { client }, sink: { sink }), voices: voices)
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-creative-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    func always(_ operationID: String, _ reply: FakeElevenLabsTransport.Reply) {
        router.always(operationID, reply)
    }

    func queue(_ operationID: String, _ replies: FakeElevenLabsTransport.Reply...) {
        router.queue(operationID, replies)
    }

    /// The requests sent for `operationID`, in order.
    func requests(_ operationID: String) -> [FakeElevenLabsTransport.Recorded] {
        transport.recorded.filter { $0.request.operationID == operationID }
    }

    /// The JSON body of the last request sent for `operationID`.
    func lastBody(_ operationID: String) -> JSONValue? {
        requests(operationID).last.flatMap { try? JSONValue(data: $0.body) }
    }

    /// The multipart body of the last request, as text (the fixtures upload small files).
    func lastMultipart(_ operationID: String) -> String? {
        requests(operationID).last.map { String(decoding: $0.body, as: UTF8.self) }
    }

    /// A short, valid, silent WAV file in the scratch folder: something every player opens.
    func wav(named name: String = "clip.wav", seconds: Double = 1.5, channels: Int = 1) -> URL {
        let url = scratch.appendingPathComponent(name)
        try? CreativeRig.wavData(seconds: seconds, channels: channels).write(to: url)
        return url
    }

    /// 16-bit PCM at 16 kHz with a WAV header, with a soft tone so a waveform shows.
    static func wavData(seconds: Double, channels: Int = 1) -> Data {
        let rate = 16_000
        let frames = Int(Double(rate) * seconds)
        let bytes = frames * 2 * channels
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(channels)); append(UInt32(rate))
        append(UInt32(rate * 2 * channels)); append(UInt16(2 * channels)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for index in 0..<frames {
            let value = Int16(sin(Double(index) * 2 * .pi * 220 / Double(rate)) * 1200)
            for _ in 0..<channels { append(value) }
        }
        return data
    }

    /// The pinned OpenAPI snapshot, parsed — for the full text of descriptions the catalog
    /// shortens (prices, limits).
    static let rawSpec: [String: Any] = {
        let url = CoreCatalogTests.repository.appendingPathComponent("Scripts/elevenlabs/openapi.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }()

    /// An operation of the raw spec by id.
    static func rawOperation(_ id: String) -> [String: Any]? {
        for case let methods as [String: Any] in (rawSpec["paths"] as? [String: Any] ?? [:]).values {
            for case let operation as [String: Any] in methods.values where operation["operationId"] as? String == id {
                return operation
            }
        }
        return nil
    }

    /// The full description of a body property of a raw-spec operation.
    static func rawBodyDescription(_ id: String, _ property: String) -> String {
        guard let content = (rawOperation(id)?["requestBody"] as? [String: Any])?["content"] as? [String: Any] else { return "" }
        for case let media as [String: Any] in content.values {
            guard let ref = (media["schema"] as? [String: Any])?["$ref"] as? String else { continue }
            let name = String(ref.split(separator: "/").last ?? "")
            let schemas = (rawSpec["components"] as? [String: Any])?["schemas"] as? [String: Any]
            let properties = (schemas?[name] as? [String: Any])?["properties"] as? [String: Any]
            if let text = (properties?[property] as? [String: Any])?["description"] as? String { return text }
        }
        return ""
    }

    /// Removes what this rig wrote: the sink's folder, the fake's, and its own scratch folder,
    /// each only if it is still a scratch folder in the system temporary directory.
    func clean() {
        sink.removeAll()
        transport.removeTemporaryFiles()
        Self.removeScratch(scratch)
    }

    static func removeScratch(_ directory: URL) {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let target = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard target.deletingLastPathComponent().path == temporary.path,
              target.lastPathComponent.hasPrefix("elevenlabs-creative-")
        else { return }
        try? FileManager.default.removeItem(at: target)
    }

    /// Voices a screen can offer.
    static let sampleVoices: [ElevenLabsVoice] = [
        ElevenLabsVoice(id: "voice-rachel", name: "Rachel", category: "premade",
                        labels: ["accent": "american", "age": "young", "use_case": "narration"]),
        ElevenLabsVoice(id: "voice-adam", name: "Adam", category: "premade",
                        labels: ["accent": "american", "age": "middle_aged"]),
        ElevenLabsVoice(id: "voice-mine", name: "My studio voice", category: "cloned"),
    ]

    /// Models shaped like `GET /v1/models`.
    static let modelsJSON: JSONValue = [
        [
            "model_id": "eleven_multilingual_v2", "name": "Eleven Multilingual v2",
            "description": "Our most lifelike model with rich emotional expression.",
            "can_do_text_to_speech": true, "can_do_voice_conversion": false, "can_use_style": true,
            "can_use_speaker_boost": true, "can_be_finetuned": true, "serves_pro_voices": true,
            "requires_alpha_access": false, "token_cost_factor": 1,
            "max_characters_request_free_user": 2500, "max_characters_request_subscribed_user": 10000,
            "maximum_text_length_per_request": 10000,
            "languages": [["language_id": "en", "name": "English"], ["language_id": "es", "name": "Spanish"],
                          ["language_id": "de", "name": "German"], ["language_id": "ja", "name": "Japanese"]],
            "model_rates": ["character_cost_multiplier": 1], "concurrency_group": "standard",
        ],
        [
            "model_id": "eleven_flash_v2_5", "name": "Eleven Flash v2.5",
            "description": "Ultra low latency.", "can_do_text_to_speech": true,
            "can_do_voice_conversion": false, "can_use_style": false, "can_use_speaker_boost": true,
            "can_be_finetuned": true, "serves_pro_voices": true, "requires_alpha_access": false,
            "token_cost_factor": 0.5, "max_characters_request_free_user": 2500,
            "max_characters_request_subscribed_user": 40000, "maximum_text_length_per_request": 40000,
            "languages": [["language_id": "en", "name": "English"], ["language_id": "fr", "name": "French"]],
            "model_rates": ["character_cost_multiplier": 0.5], "concurrency_group": "turbo",
        ],
        [
            "model_id": "eleven_english_sts_v2", "name": "Eleven English v2 (speech to speech)",
            "description": "Speech to speech in English.", "can_do_text_to_speech": false,
            "can_do_voice_conversion": true, "can_use_style": true, "can_use_speaker_boost": true,
            "can_be_finetuned": false, "serves_pro_voices": false, "requires_alpha_access": false,
            "token_cost_factor": 1, "max_characters_request_free_user": 0,
            "max_characters_request_subscribed_user": 0, "maximum_text_length_per_request": 0,
            "languages": [["language_id": "en", "name": "English"]],
            "model_rates": ["character_cost_multiplier": 1], "concurrency_group": "standard",
        ],
    ]

    /// A character alignment for `text`, 80 ms a character.
    static func alignment(for text: String, start: Double = 0) -> JSONValue {
        let characters = text.map { String($0) }
        return [
            "characters": .array(characters.map(JSONValue.string)),
            "character_start_times_seconds": .array(characters.indices.map { .number(start + Double($0) * 0.08) }),
            "character_end_times_seconds": .array(characters.indices.map { .number(start + Double($0 + 1) * 0.08) }),
        ]
    }

    /// Waits for a runner to ask, then answers.
    static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting")
    }
}

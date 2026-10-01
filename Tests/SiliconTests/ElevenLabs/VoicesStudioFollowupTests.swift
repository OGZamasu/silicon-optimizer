import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

extension VoicesStudioFixture {
    /// A fixture whose fake ElevenLabs answers through `handler` — by id rather than in order,
    /// for answers that must wait on each other.
    init(handler: @escaping @Sendable (ElevenLabsRequest) async throws -> FakeElevenLabsTransport.Reply) {
        routes = VoicesStudioRoutes([:])
        transport = FakeElevenLabsTransport(handler: handler)
        var limits = ElevenLabsClient.Limits()
        limits.retries = 0
        limits.firstBackoff = 0.01
        client = ElevenLabsClient(credentials: credentials, region: .global, transport: transport, sink: sink, limits: limits)
        let client = client
        voices = ElevenLabsVoiceDirectory(client: { client })
    }
}

/// The voices-and-studio critic's last nits, taken after the merge. Hermetic: the section
/// fixture (fake transport, fake key, temporary sink).
@Suite("ElevenLabs voices & studio follow-ups", .timeLimit(.minutes(1)))
@MainActor
struct VoicesStudioFollowupTests {

    // MARK: - Known and unknown outcomes, by status

    /// A spending call answered 408, 429 or 5xx may have been carried out — it holds the next
    /// spending call until the owner has checked; a 409 is ElevenLabs' refusal and holds nothing.
    /// Judged by the failure's HTTP status, not by the words "answered 4xx".
    @Test func aTimeoutRateLimitOrServerErrorIsAnUnknownOutcomeAndARefusalIsNot() async throws {
        let fixture = VoicesStudioFixture([
            "create_podcast": [
                .jsonText(#"{"detail":"Request timeout"}"#, status: 408),
                .jsonText(#"{"detail":"busy"}"#, status: 429),
                .jsonText(#"{"detail":"Bad gateway"}"#, status: 502),
                .jsonText(#"{"detail":{"status":"conflict","message":"Already exists"}}"#, status: 409),
            ],
            "get_projects": [.json(["projects": []]), .json(["projects": []]), .json(["projects": []])],
        ])
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        model.podcast.modelID = "eleven_multilingual_v2"
        model.podcast.hostVoiceID = "v1"
        model.podcast.guestVoiceID = "v2"
        model.podcast.text = "Why the road is long."
        for status in [408, 429, 502] {
            await model.createPodcast()
            #expect(model.actions.unknownOutcomes["create_podcast"] != nil, "\(status) may have made the podcast")
            model.actions.acknowledgeUnknownOutcomes()
        }
        await model.createPodcast()
        #expect(fixture.sent("create_podcast").count == 4)
        #expect(model.actions.unknownOutcomes.isEmpty, "a 409 is ElevenLabs' refusal: nothing was made")
    }

    // MARK: - Helpers

    static let slow: Duration = .milliseconds(600)

    /// Starts `action`, answers any question it puts on screen, and returns once its call is on
    /// the wire.
    func sending(
        _ actions: VoicesStudioActions, _ operationID: String, _ action: @escaping @MainActor () async -> Void
    ) async throws -> Task<Void, Never> {
        let task = Task { await action() }
        try await voicesStudioWait {
            if actions.presentedQuestion != nil { actions.answer(true) }
            return actions.runner(operationID)?.isRunning == true
        }
        return task
    }

    /// A JSON answer that takes `delay` to arrive.
    static func late(_ value: JSONValue, _ delay: Duration) -> FakeElevenLabsTransport.Reply {
        .init(status: 200, headers: ["content-type": "application/json"], body: value.encoded(), delay: delay)
    }

    // MARK: - N1: each changed item is fetched again on its own runner

    /// Things the fake ElevenLabs has been asked, for answers that wait on each other.
    final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: Set<String> = []
        private var counts: [String: Int] = [:]

        /// Notes `name` and returns how many times it has been noted, this one included.
        @discardableResult
        func note(_ name: String) -> Int {
            lock.withLock {
                seen.insert(name)
                counts[name, default: 0] += 1
                return counts[name] ?? 0
            }
        }

        func has(_ name: String) -> Bool { lock.withLock { seen.contains(name) } }

        /// Waits (up to 5 s) until `name` has been noted.
        func wait(for name: String) async {
            for _ in 0..<500 where !has(name) { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    /// Voice B's sample delete is on its way; A is opened, renamed and saved. B's delete answers
    /// only once A's fetch after the save is on its way, and A's fetch answers only once B's
    /// fetch after the delete has started — so the two overlap however loaded the machine is.
    /// Both land: A's row and the open voice show A's new name.
    @Test func twoChangesToTwoVoicesBothFetchTheirVoiceAgain() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            let path = request.url.path
            switch request.operationID {
            case "delete_sample":
                await signals.wait(for: "refetch v-a")
                return .json(["status": "ok"])
            case "edit_voice":
                return .json(["status": "ok"])
            case "get_voice_by_id" where path.hasSuffix("/v-a"):
                if signals.note("get v-a") == 1 { return .json(VoicesStudioFakes.voice("v-a", "Voice A")) }
                signals.note("refetch v-a")
                await signals.wait(for: "refetch v-b")
                return .json(VoicesStudioFakes.voice("v-a", "Voice A renamed"))
            case "get_voice_by_id" where path.hasSuffix("/v-b"):
                signals.note("refetch v-b")
                return .json(VoicesStudioFakes.voice("v-b", "Voice B"))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let a = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-a", "Voice A")))
        let b = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-b", "Voice B", samples: [
            VoicesStudioFakes.sample("s-b", "b.mp3"),
        ])))
        model.load(rows: [a, b], selected: b)
        let sample = try #require(b.samples.first)
        let deleting = try await sending(model.actions, "delete_sample") { await model.deleteSample(sample) }
        await model.select("v-a")
        model.editDraft.name = "Voice A renamed"
        let saving = Task { await model.saveEdit() }
        await deleting.value
        await saving.value
        #expect(fixture.sent("get_voice_by_id").count == 3)
        #expect(model.rows.first { $0.id == "v-a" }?.name == "Voice A renamed",
                "A's fetch after its own edit was abandoned: the row still reads “\(model.rows.first { $0.id == "v-a" }?.name ?? "")”")
        #expect(model.selected?.id == "v-a")
        #expect(model.selected?.name == "Voice A renamed")
    }

    nonisolated static func dictionary(_ id: String, name: String) -> JSONValue {
        ["id": .string(id), "name": .string(name), "latest_version_id": "ver1", "latest_version_rules_num": 1,
         "rules": [["string_to_replace": "Nguyen", "type": "alias", "alias": "Win"]]]
    }

    /// Pronunciation, the same overlap: rules added to B, A opened and renamed; B's add answers
    /// once A's fetch after the rename is on its way. A's row still takes its new name.
    @Test func twoChangesToTwoDictionariesBothFetchTheirDictionaryAgain() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            let path = request.url.path
            switch request.operationID {
            case "add_rules":
                await signals.wait(for: "refetch d-a")
                return .json(["id": "d-b", "version_id": "ver2"])
            case "patch_pronunciation_dictionary":
                return .json(["id": "d-a"])
            case "get_pronunciation_dictionary_metadata" where path.hasSuffix("/d-a"):
                if signals.note("get d-a") == 1 { return .json(Self.dictionary("d-a", name: "Dict A")) }
                signals.note("refetch d-a")
                await signals.wait(for: "refetch d-b")
                return .json(Self.dictionary("d-a", name: "Dict A renamed"))
            case "get_pronunciation_dictionary_metadata" where path.hasSuffix("/d-b"):
                signals.note("refetch d-b")
                return .json(Self.dictionary("d-b", name: "Dict B"))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        let a = try #require(PronunciationDictionary(json: Self.dictionary("d-a", name: "Dict A")))
        let b = try #require(PronunciationDictionary(json: Self.dictionary("d-b", name: "Dict B")))
        model.load(dictionaries: [a, b], selected: b)
        var rule = PronunciationRule()
        rule.stringToReplace = "Siobhan"
        rule.alias = "Shivawn"
        model.rules = [rule]
        let adding = try await sending(model.actions, "add_rules") { await model.addRules() }
        await model.select("d-a")
        model.rename = "Dict A renamed"
        let renaming = Task { await model.saveName() }
        await adding.value
        await renaming.value
        #expect(fixture.sent("get_pronunciation_dictionary_metadata").count == 3)
        #expect(model.dictionaries.first { $0.id == "d-a" }?.name == "Dict A renamed",
                "A's fetch after its rename was abandoned")
        #expect(model.selected?.id == "d-a")
        #expect(model.selected?.name == "Dict A renamed")
    }
}

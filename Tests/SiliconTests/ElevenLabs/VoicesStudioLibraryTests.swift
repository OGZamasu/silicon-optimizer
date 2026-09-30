import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// The shared voice library: filters sent as the spec names them, pages by number, filters
/// offering what the library has shown, and a voice added under the name chosen for it.
@Suite("ElevenLabs voice library section")
@MainActor
struct VoicesStudioLibraryTests {

    @Test func theLibrarySearchSendsItsFiltersAndOffersWhatItHasSeen() async throws {
        let entry: (String, String, String) -> JSONValue = { id, name, accent in
            ["public_owner_id": "owner", "voice_id": .string(id), "name": .string(name), "accent": .string(accent),
             "gender": "female", "age": "young", "descriptive": "calm", "use_case": "narration",
             "category": "professional", "date_unix": 1, "usage_character_count_1y": 10,
             "usage_character_count_7d": 1, "play_api_usage_character_count_1y": 1, "cloned_by_count": 7,
             "free_users_allowed": true, "live_moderation_enabled": false, "featured": true]
        }
        let fixture = VoicesStudioFixture([
            "get_library_voices": [
                .json(["voices": [entry("l1", "Lena", "british")], "has_more": true, "total_count": 2]),
                .json(["voices": [entry("l2", "Mia", "american")], "has_more": false, "total_count": 2]),
            ],
            "add_sharing_voice": [.json(["voice_id": "m1"])],
        ])
        defer { fixture.clean() }
        let model = VoiceLibrarySectionModel(environment: fixture.environment)
        model.search = "calm"
        model.useCase = "narration"
        model.sort = "trending"
        await model.refresh()
        let query = fixture.query("get_library_voices")
        #expect(query.contains { $0 == ("search", "calm") })
        #expect(query.contains { $0 == ("use_cases", "narration") })
        #expect(query.contains { $0 == ("sort", "trending") })
        #expect(query.contains { $0 == ("page", "0") })
        await model.loadMore()
        #expect(fixture.query("get_library_voices").contains { $0 == ("page", "1") })
        #expect(model.rows.map(\.name) == ["Lena", "Mia"])
        #expect(model.options("accent", current: "") == ["american", "british"])

        model.names[model.rows[0].id] = "Lena (library)"
        await model.add(model.rows[0])
        #expect(fixture.path("add_sharing_voice") == "/v1/voices/add/owner/l1")
        #expect(fixture.body("add_sharing_voice") == ["new_name": "Lena (library)", "bookmarked": true])
        #expect(model.isAdded(model.rows[0]))
    }
}

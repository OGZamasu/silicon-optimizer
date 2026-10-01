import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

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
}

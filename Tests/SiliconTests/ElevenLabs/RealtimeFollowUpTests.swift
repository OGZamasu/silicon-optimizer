import Foundation
import Testing
@testable import SiliconElevenLabs

/// Review follow-ups on the protocol layer, each pinned by the test that failed without it.
@Suite("ElevenLabs realtime: review follow-ups")
struct RealtimeFollowUpTests {

    /// A closed socket reads as one sentence, never "The connection the connection dropped."
    @Test(arguments: [
        (0, "", "The connection dropped."),
        (1000, "", "The connection closed normally (1000)."),
        (1005, "", "The connection closed normally (1005)."),
        (1011, "boom", "The connection closed with code 1011: boom."),
        (4300, "", "The call queue timed out (4300)."),
    ])
    func aClosedSocketReadsAsOneSentence(code: Int, reason: String, expected: String) {
        let close = ElevenLabsSocketClose(code: code, reason: reason)
        #expect(ElevenLabsRealtimeError.closed(close).description == expected)
        #expect(!ElevenLabsRealtimeError.closed(close).description.lowercased().contains("connection the connection"))
        // As a clause after "ended early: ", it carries its own subject.
        #expect(close.description.hasPrefix("the "))
    }
}

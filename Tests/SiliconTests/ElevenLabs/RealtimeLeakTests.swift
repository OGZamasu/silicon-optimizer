import Foundation
import Testing
import SiliconElevenLabs
@testable import SiliconControl
@testable import SiliconUI

/// A signed URL, a token or a failing URL in error text never reaches the screen, a close reason
/// or an MCP answer — however it got into the text.
@Suite("ElevenLabs realtime error text carries no signed URL", .serialized)
struct RealtimeLeakTests {

    static let signature = "SIGleakSECRETzz"
    static let signed = "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=agent_1&conversation_signature=\(signature)"

    /// What URLSession's failures look like: an NSError with the failing URL in its userInfo,
    /// which `"\(error)"` would print whole.
    @Test func aFailingURLInAnNSErrorNeverReachesTheText() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: 57, userInfo: [
            NSLocalizedDescriptionKey: "Socket is not connected",
            NSURLErrorFailingURLStringErrorKey: Self.signed,
            NSURLErrorFailingURLErrorKey: URL(string: Self.signed)!,
        ])
        #expect("\(error)".contains(Self.signature), "the fixture must carry the signature to prove anything")
        let wrapped = ElevenLabsRealtimeError(wrapping: error)
        #expect(!wrapped.description.contains(Self.signature), "\(wrapped.description)")
        #expect(wrapped.description.contains("Socket is not connected"))
        #expect(wrapped.description.contains("NSPOSIXErrorDomain 57"))
        let close = ElevenLabsSocketClose(code: 0, reason: wrapped.description)
        #expect(!close.description.contains(Self.signature))
    }

    @Test func urlsTokensAndSignaturesAreMaskedWhereverTheyStand() {
        let text = "failed at \(Self.signed). Also https://example.com/x?token=abc123&page=2, "
            + "a loose conversation_signature=\(Self.signature) and token=zzz"
        let scrubbed = ElevenLabsRealtimeRedaction.scrub(text)
        #expect(!scrubbed.contains(Self.signature))
        #expect(!scrubbed.contains("abc123"))
        #expect(!scrubbed.contains("token=zzz"))
        #expect(scrubbed.contains("agent_id=agent_1"))
        #expect(scrubbed.contains("next_page_token=x") == false)
        #expect(ElevenLabsRealtimeRedaction.scrub("next_page_token=keep") == "next_page_token=keep")
        // A close reason, a realtime error and an outcome are all scrubbed, whoever built them.
        #expect(!ElevenLabsSocketClose(code: 1008, reason: "bad \(Self.signed)").description.contains(Self.signature))
        #expect(!ElevenLabsRealtimeError.network("at \(Self.signed)").description.contains(Self.signature))
    }

    /// The critic's shapes (round 2): a signature written every way text could carry it —
    /// percent-encoded, as a JSON field, as `name: value`, after a comma inside the value — as
    /// well as the shapes that were already masked.
    @Test(arguments: [
        ("json-escaped", #"failed: wss:\/\/api.elevenlabs.io\/v1\/convai\/conversation?agent_id=a&conversation_signature=SIGleakSECRETzz"#),
        ("parenthesised", "failed (wss://api.elevenlabs.io/v1/convai/conversation?agent_id=a&conversation_signature=SIGleakSECRETzz)"),
        ("comma-inside", "failed: wss://api.elevenlabs.io/v1/convai/conversation?agent_id=a&conversation_signature=ab,SIGleakSECRETzz"),
        ("percent-encoded", "failed: wss%3A%2F%2Fapi.elevenlabs.io%2Fv1%2Fconvai%2Fconversation%3Fagent_id%3Da%26conversation_signature%3DSIGleakSECRETzz"),
        ("double-encoded", "failed: conversation_signature%253DSIGleakSECRETzz"),
        ("unknown-name", "failed: wss://api.elevenlabs.io/v1/convai/conversation?agent_id=a&cvsig=SIGleakSECRETzz"),
        ("json-field", #"{"conversation_signature":"SIGleakSECRETzz"}"#),
        ("json-field-spaced", #"{"token" : "SIGleakSECRETzz", "other": 1}"#),
        ("key-colon", "conversation_signature: SIGleakSECRETzz"),
        ("loose-comma", "conversation_signature=ab,SIGleakSECRETzz"),
        ("upper", "TOKEN=SIGleakSECRETzz"),
        ("no-scheme", "api.elevenlabs.io/v1/convai/conversation?agent_id=a&conversation_signature=SIGleakSECRETzz"),
    ])
    func aSignatureIsMaskedInEveryShape(name: String, text: String) {
        let scrubbed = ElevenLabsRealtimeRedaction.scrub(text)
        #expect(!scrubbed.contains("SIGleakSECRETzz"), "\(name): \(scrubbed)")
        #expect(!scrubbed.contains("SIGleak"), "\(name): \(scrubbed)")
    }

    /// Ordinary text is left as it is: a percent sign, a colon, a word that only contains "token".
    @Test func ordinaryTextIsLeftAlone() {
        for text in ["50% done", "next_page_token=keep", "status: ok", "agent_id=agent_1", "tokens used: 12"] {
            #expect(ElevenLabsRealtimeRedaction.scrub(text) == text, "\(text)")
        }
    }

    @MainActor
    @Test func theAgentScreensOutcomeCarriesNoSignature() async throws {
        let rig = LiveRig(replies: LiveScreenTests.agentReplies(), server: LiveScreenTests.agent { socket in
            socket.serverClose(code: 1011, reason: "internal error at \(Self.signed)")
        })
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        screen.textOnly = true
        await screen.requestStart()
        await rig.until { screen.phase == .ended }
        let message = try #require(screen.outcome?.message)
        #expect(message.contains("1011"))
        #expect(!message.contains(Self.signature), "\(message)")
    }

    @Test func theConverseAnswerAndRefusalCarryNoSignature() async throws {
        let ended = ConverseRig(allowRisky: true, server: { socket in
            _ = await socket.nextSent()
            socket.push(ConverseRig.metadata)
            _ = await socket.nextSent(ofType: "user_message")
            socket.push(ConverseRig.response("One moment.", 1))
            socket.serverClose(code: 1011, reason: "lost at \(Self.signed)")
        })
        defer { ended.clean() }
        let (status, answer) = await ended.converse(["agent_id": "agent_1", "messages": ["Hi", "Again"], "confirm": true])
        #expect(status == 200)
        #expect((answer["ended"].stringValue ?? "").contains("1011"))
        #expect(!answer.jsonString().contains(Self.signature), "\(answer.jsonString())")

        let refused = ConverseRig(allowRisky: true, server: { socket in
            _ = await socket.nextSent()
            socket.serverClose(code: 1008, reason: "signature rejected for \(Self.signed)")
        })
        defer { refused.clean() }
        let (refusedStatus, refusal) = await refused.converse(["agent_id": "agent_1", "messages": ["Hi"], "confirm": true])
        #expect(refusedStatus == 502)
        #expect((refusal["error"].stringValue ?? "").contains("1008"))
        #expect(!refusal.jsonString().contains(Self.signature), "\(refusal.jsonString())")
    }
}

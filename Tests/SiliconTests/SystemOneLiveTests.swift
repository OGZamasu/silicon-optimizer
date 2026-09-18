import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime

/// Against a real llama-server, when `SILICON_LIVE_LLAMA_PORT` names one. Not part of the
/// normal run; this is how the lane was checked on a loaded 27B.
@Suite("Local decision lane, live")
struct SystemOneLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SILICON_LIVE_LLAMA_PORT"] != nil))
    func decidesASupportTicket() async throws {
        let port = ProcessInfo.processInfo.environment["SILICON_LIVE_LLAMA_PORT"]!
        let decider = LocalDecider(endpoint: URL(string: "http://127.0.0.1:\(port)")!, modelName: "live")
        let response = try await decider.decide(.init(
            state: .object([
                "subject": .string("Duplicate charge"),
                "message": .string("I was charged twice for order A-104. Fix this now, I want my money back."),
            ]),
            questions: [
                "team": .init(type: "choice", instructions: .string("Which team should handle this?"),
                              criteria: .object(["billing": .string("payments, refunds, duplicate charges"),
                                                 "technical": .string("bugs and outages"),
                                                 "sales": .string("pricing and plans")])),
                "refund": .init(type: "noul", instructions: .string("The customer explicitly asks for a refund.")),
                "urgency": .init(type: "score", instructions: .string("How urgent is this?"),
                                 criteria: .array([.string("can wait"), .string("this week"), .string("today")])),
                "tone": .init(type: "choice", criteria: .object(["calm": .null, "frustrated": .null, "abusive": .null])),
            ]
        ))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print("LIVE DECISION (\(String(format: "%.0f", response.latencyMS ?? 0)) ms, \(response.usage.inputTokens) input tokens):")
        print(String(decoding: try encoder.encode(response.answers), as: UTF8.self))
        guard case .choice(let team, let confidence, _) = response.answers["team"] else { Issue.record("team"); return }
        #expect(team == "billing" && confidence > 0.5)
        guard case .noul(let refund) = response.answers["refund"] else { Issue.record("refund"); return }
        #expect(refund > 0.5)
        guard case .score(let urgency, _, _, _) = response.answers["urgency"] else { Issue.record("urgency"); return }
        #expect(urgency > 1.0)
    }
}

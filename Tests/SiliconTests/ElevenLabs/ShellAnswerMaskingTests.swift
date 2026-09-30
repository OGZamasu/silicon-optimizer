import Foundation
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// Every answer the app shows is masked, not only a credential operation's: an `sk_…` key in
/// a tool's header and the account's key preview in `GET /v1/user` never reach the screen or
/// Recent results. Header values otherwise stay real. Probe shapes from the shell critic
/// (R1b, R1c). Key-shaped fixtures are built at run time.
@Suite("ElevenLabs answers are always masked")
@MainActor
struct ShellAnswerMaskingTests {

    static let skKey = "sk_" + String(repeating: "a1", count: 16)

    @Test func anSKKeyInAToolAnswerIsMaskedInTheResultAndTheRecentList() async throws {
        let answer: JSONValue = ["id": "t1", "tool_config": ["api_schema": ["request_headers": [
            "Authorization": .string("Bearer \(Self.skKey)"),
            "X-Plain": "not-a-key",
        ]]]]
        let fixture = ShellExplorerTests.Fixture(replies: [.json(answer)])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "get_tool_route", context: fixture.context))
        #expect(!runner.operation.returnsCredential)
        await runner.perform(arguments: ["tool_id": "t1"])
        #expect(runner.credential == nil)
        guard case .json(let shown, _)? = runner.result,
              case .json(let kept, _)? = fixture.pane.recents.first?.result else {
            Issue.record("expected JSON in the result and the recent list")
            return
        }
        for value in [shown, kept] {
            let headers = value["tool_config"]["api_schema"]["request_headers"]
            #expect(!value.jsonString().contains(Self.skKey))
            #expect(headers["Authorization"].stringValue?.hasPrefix("Bearer ") == true)
            #expect(headers["X-Plain"] == "not-a-key")
        }
    }

    @Test func theAccountsKeyPreviewIsMasked() async throws {
        let answer: JSONValue = ["user_id": "u1", "xi_api_key_preview": "sk_ab…xyz", "first_name": "Sam"]
        let fixture = ShellExplorerTests.Fixture(replies: [.json(answer)])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "get_user_info", context: fixture.context))
        await runner.perform(arguments: [:])
        guard case .json(let shown, _)? = runner.result else {
            Issue.record("expected JSON")
            return
        }
        #expect(shown["xi_api_key_preview"] == .string(ElevenLabsRedaction.placeholder))
        #expect(shown["first_name"] == "Sam")
        guard case .json(let kept, _)? = fixture.pane.recents.first?.result else {
            Issue.record("expected a recent result")
            return
        }
        #expect(kept["xi_api_key_preview"] == .string(ElevenLabsRedaction.placeholder))
    }

    @Test func eventsAndPartsAreMaskedTooAndPlainTextIsNot() {
        let operation = ShellInterfaceTests.operation(id: "plain")
        let meta = ElevenLabsMeta(status: 200)
        guard case .events(let events, _) = ElevenLabsRevealedCredential.masked(
            .events([["key": .string(Self.skKey)]], meta), for: operation
        ) else { Issue.record("expected events"); return }
        #expect(!events[0].jsonString().contains(Self.skKey))
        guard case .parts(let parts, _) = ElevenLabsRevealedCredential.masked(
            .parts([.json(["k": .string(Self.skKey)])], meta), for: operation
        ), case .json(let part) = parts[0] else { Issue.record("expected a JSON part"); return }
        #expect(!part.jsonString().contains(Self.skKey))
        guard case .text(let text, _) = ElevenLabsRevealedCredential.masked(.text("hello", meta), for: operation) else {
            Issue.record("expected text"); return
        }
        #expect(text == "hello")
    }
}

import AppKit
import Foundation
import SwiftUI
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// In answers, only an operation's named credential fields go on the shown-once card; header
/// values stay in the result, real, because the owner's editor writes them back and they are
/// not credentials ElevenLabs "will not show again".
@Suite("ElevenLabs credentials in answers")
@MainActor
struct ShellAnswerSecretsTests {

    // MARK: - Answers

    /// A get_agent_route answer carries the agent's shareable token (a credential the risk
    /// table names) and a tool's literal Authorization header (not one).
    @Test func onlyNamedCredentialsGoOnTheCardAndHeaderValuesStayReal() async throws {
        let answer: JSONValue = [
            "agent_id": "a1",
            "platform_settings": ["auth": ["shareable_token": "share-tok-123"]],
            "conversation_config": ["agent": ["prompt": ["tools": [[
                "type": "webhook",
                "api_schema": ["url": "https://example.com/hook", "request_headers": ["Authorization": "Bearer header-value-1"]],
            ]]]]],
        ]
        let fixture = ShellExplorerTests.Fixture(replies: [.json(answer)])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "get_agent_route", context: fixture.context))
        #expect(runner.operation.returnsCredential)
        await runner.perform(arguments: ["agent_id": "a1"])
        #expect(runner.phase == .succeeded)
        #expect(runner.credential?.fields == [.init(path: "platform_settings.auth.shareable_token", value: "share-tok-123")])
        guard case .json(let shown, _)? = runner.result else {
            Issue.record("expected JSON")
            return
        }
        #expect(shown["platform_settings"]["auth"]["shareable_token"] == .string(ElevenLabsRedaction.placeholder))
        let header = shown["conversation_config"]["agent"]["prompt"]["tools"][0]["api_schema"]["request_headers"]["Authorization"]
        #expect(header == "Bearer header-value-1")
    }

    /// A tool's own answer is not a credential answer at all: the header comes back as it is
    /// and no card appears.
    @Test func aToolsHeaderComesBackAsItIs() async throws {
        let answer: JSONValue = ["id": "t1", "tool_config": ["api_schema": ["request_headers": ["Authorization": "Bearer header-value-2"]]]]
        let fixture = ShellExplorerTests.Fixture(replies: [.json(answer)])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "get_tool_route", context: fixture.context))
        await runner.perform(arguments: ["tool_id": "t1"])
        #expect(runner.credential == nil)
        guard case .json(let shown, _)? = runner.result else {
            Issue.record("expected JSON")
            return
        }
        #expect(shown["tool_config"]["api_schema"]["request_headers"]["Authorization"] == "Bearer header-value-2")
    }
}

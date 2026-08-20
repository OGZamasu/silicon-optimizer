import Foundation
import Testing
@testable import SiliconRuntime

@Suite("Codex configuration")
struct CodexConfigTests {

    @Test func configPointsCodexAtTheGateway() {
        let document = CodexRuntime.configuration(
            gatewayPort: 9414, defaultModel: "local/qwen3.8-27b-Q4_K_M",
            mcpServerPath: "/Applications/Silicon Optimizer.app/Contents/Resources/bin/silicon-mcp",
            trustedProjectPath: "/Users/someone"
        )
        #expect(document.contains("model = \"local/qwen3.8-27b-Q4_K_M\""))
        #expect(document.contains("model_provider = \"silicon\""))
        #expect(document.contains("[model_providers.silicon]"))
        #expect(document.contains("base_url = \"http://127.0.0.1:9414/v1\""))
        // Not a choice: Codex dropped chat-completions support in early 2026.
        #expect(document.contains("wire_api = \"responses\""))
        #expect(document.contains("[mcp_servers.silicon-optimizer]"))
        #expect(document.contains(
            "command = \"/Applications/Silicon Optimizer.app/Contents/Resources/bin/silicon-mcp\""
        ))
    }

    /// Trusting the picked folder is load-bearing: without it, any working directory whose
    /// ancestors hold a `.codex` project layer wedges every turn after sampling.
    @Test func configTrustsTheWorkingFolder() {
        let document = CodexRuntime.configuration(
            gatewayPort: 9414, defaultModel: "m", mcpServerPath: nil,
            trustedProjectPath: "/Users/o\"brien/code"
        )
        #expect(document.contains("[projects.\"/Users/o\\\"brien/code\"]"))
        #expect(document.contains("trust_level = \"trusted\""))
    }

    @Test func configOmitsToolsWhenNoBridgeExists() {
        let document = CodexRuntime.configuration(
            gatewayPort: 9414, defaultModel: "local/x", mcpServerPath: nil,
            trustedProjectPath: nil
        )
        #expect(!document.contains("mcp_servers"))
        #expect(!document.contains("[projects."))
    }

    /// The config is rendered wholesale into an app-private home; the header must say so,
    /// because a hand edit there is a lost edit.
    @Test func configDeclaresItsOwnership() {
        let document = CodexRuntime.configuration(
            gatewayPort: 1, defaultModel: "m", mcpServerPath: nil, trustedProjectPath: nil
        )
        #expect(document.hasPrefix("# Managed by Silicon Optimizer"))
    }
}

@Suite("Codex JSON-RPC plumbing")
struct CodexJSONTests {

    @Test func valuesRoundTripThroughCoding() throws {
        let original: JSONValue = [
            "id": 7,
            "method": "turn/start",
            "params": ["input": [["type": "text", "text": "hi"]], "flag": true],
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == original)
        #expect(decoded["params"]["input"].arrayValue?.count == 1)
        #expect(decoded["params"]["flag"].boolValue == true)
        #expect(decoded["id"].intValue == 7)
    }

    /// Ids must round-trip in the peer's own type: a string id answered as a number is a
    /// dropped response on their side.
    @Test func integerIDsEncodeWithoutDecimals() throws {
        let line = try CodexRuntime.encodeLine(.object(["id": .number(42)]))
        let text = String(decoding: line, as: UTF8.self)
        #expect(text.contains("\"id\":42"))
        #expect(!text.contains("42.0"))
        #expect(text.hasSuffix("\n"))
    }

    @Test func renamedDeltaKeysStillRead() {
        let params: JSONValue = ["itemId": "item_1", "textDelta": "hello"]
        #expect(params.firstString("delta", "textDelta", "chunk") == "hello")
        #expect(params.firstString("nope") == nil)
        #expect(params["missing"].isNull)
    }
}

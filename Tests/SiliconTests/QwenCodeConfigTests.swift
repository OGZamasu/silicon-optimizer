import Foundation
import Testing
@testable import SiliconRuntime

@Suite("Qwen Code configuration")
struct QwenCodeConfigTests {

    private func settings(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func settingsListEveryGatewayModelAgainstTheGateway() throws {
        let data = QwenCodeRuntime.settingsJSON(
            gatewayPort: 9414,
            models: [
                .init(id: "local/hf:unsloth/Qwen3.8-27B-GGUF@Q6_K", name: "Qwen3.8-27B (Q6_K)"),
                .init(id: "node/silicon-node/qwen3.8-27b", name: "qwen3.8-27b — silicon-node"),
            ],
            mcpServerPath: nil
        )
        let parsed = try settings(data)

        // The shipped v4 shape: an object keyed by protocol, each holding the model
        // array — not the docs' flat array.
        let byProtocol = try #require(parsed["modelProviders"] as? [String: Any])
        let providers = try #require(byProtocol["openai"] as? [[String: Any]])
        #expect(providers.count == 2)
        #expect(providers.allSatisfy {
            ($0["baseUrl"] as? String) == "http://127.0.0.1:9414/v1"
        })
        #expect(providers.first?["id"] as? String == "local/hf:unsloth/Qwen3.8-27B-GGUF@Q6_K")
        #expect(providers.last?["name"] as? String == "qwen3.8-27b — silicon-node")
        #expect(parsed["$version"] as? Int == 4)

        let security = parsed["security"] as? [String: Any]
        let auth = security?["auth"] as? [String: Any]
        #expect(auth?["selectedType"] as? String == "openai")
        #expect(parsed["mcpServers"] == nil)
    }

    @Test func settingsWireTheToolBridgeWithAVideoSizedTimeout() throws {
        let data = QwenCodeRuntime.settingsJSON(
            gatewayPort: 9414, models: [.init(id: "local/x", name: "X")],
            mcpServerPath: "/Applications/Silicon Optimizer.app/Contents/Resources/bin/silicon-mcp"
        )
        let parsed = try settings(data)
        let servers = try #require(parsed["mcpServers"] as? [String: Any])
        let silicon = try #require(servers["silicon-optimizer"] as? [String: Any])
        #expect(silicon["command"] as? String
            == "/Applications/Silicon Optimizer.app/Contents/Resources/bin/silicon-mcp")
        // A video render holds the tool call for up to ten minutes.
        #expect(silicon["timeout"] as? Int == 1_800_000)
    }
}

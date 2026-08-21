import Foundation
import Testing
@testable import SiliconRuntime

/// Pi runs headless over RPC in an app-private workspace; these pin the pieces the
/// live process depends on — the workspace layout and the settings that select the
/// silicon provider.
@Suite("Pi engine configuration")
struct PiConfigTests {

    private func temporaryWorkspace() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-test-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("the workspace gets project settings selecting the silicon provider")
    func settingsSelectSilicon() throws {
        let workspace = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try PiRuntime.ensureConfigured(
            workspace: workspace,
            defaultModel: "local/hf:unsloth/Qwen3.8-27B-GGUF@Q4_K_M",
            extensionSource: nil
        )

        let settingsURL = workspace.appendingPathComponent(".pi/settings.json")
        let settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)
        ) as? [String: Any]
        #expect(settings?["defaultProvider"] as? String == "silicon")
        #expect(settings?["defaultModel"] as? String
                == "local/hf:unsloth/Qwen3.8-27B-GGUF@Q4_K_M")
        // Local models manage thinking through the gateway's own controls; Pi's
        // budgets would just eat context.
        #expect(settings?["defaultThinkingLevel"] as? String == "off")
    }

    @Test("the extension is copied in and refreshed only when it changes")
    func extensionCopying() throws {
        let workspace = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-\(UUID().uuidString).ts")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("// v1".utf8).write(to: source)

        try PiRuntime.ensureConfigured(
            workspace: workspace, defaultModel: nil, extensionSource: source
        )
        let destination = workspace.appendingPathComponent(".pi/extensions/silicon.ts")
        #expect(try Data(contentsOf: destination) == Data("// v1".utf8))

        // A changed source lands on the next configure.
        try Data("// v2".utf8).write(to: source)
        try PiRuntime.ensureConfigured(
            workspace: workspace, defaultModel: nil, extensionSource: source
        )
        #expect(try Data(contentsOf: destination) == Data("// v2".utf8))

        // No default model means the key is simply absent, not null.
        let settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: workspace.appendingPathComponent(".pi/settings.json"))
        ) as? [String: Any]
        #expect(settings?["defaultModel"] == nil)
    }

    @Test("the pinned package spec never floats")
    func pinnedSpec() {
        // `--yes latest` would let an upstream release change the app under users;
        // the spec must carry an exact version.
        #expect(PiRuntime.packageSpec.contains("@earendil-works/pi-coding-agent@"))
        let version = PiRuntime.packageSpec.split(separator: "@").last ?? ""
        #expect(version.split(separator: ".").count == 3)
    }
}
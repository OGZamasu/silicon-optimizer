import Foundation
import Testing
@testable import SiliconRuntime

@Suite("Harness provider configuration")
struct HarnessConfigTests {

    @Test func writesAFreshDocumentWhenNoneExists() {
        let document = HarnessRuntime.providerConfiguration(existing: nil, inferencePort: 9131)

        #expect(document.contains("llm-pi-ai:"))
        #expect(document.contains("  providers:"))
        #expect(document.contains("    silicon-local:"))
        #expect(document.contains("      baseURL: http://127.0.0.1:9131/v1"))
        #expect(document.contains("      api: openai-completions"))
        #expect(document.contains("      apiKeyEnv: SILICON_LOCAL_API_KEY"))
        #expect(document.contains("        - id: silicon-local"))
    }

    @Test func isIdempotentWhenNothingChanged() {
        let first = HarnessRuntime.providerConfiguration(existing: nil, inferencePort: 9131)
        let second = HarnessRuntime.providerConfiguration(existing: first, inferencePort: 9131)
        #expect(first == second)
    }

    @Test func updatesOnlyTheBaseURLWhenThePortChanges() {
        let first = HarnessRuntime.providerConfiguration(existing: nil, inferencePort: 9131)
        let moved = HarnessRuntime.providerConfiguration(existing: first, inferencePort: 9200)

        #expect(moved.contains("baseURL: http://127.0.0.1:9200/v1"))
        #expect(!moved.contains("9131"))
        // Everything else survives byte for byte.
        #expect(
            first.replacingOccurrences(of: "9131", with: "9200") == moved
        )
    }

    @Test func preservesForeignSettingsSections() {
        let existing = """
        appearance:
          theme: dark
        """
        let document = HarnessRuntime.providerConfiguration(existing: existing, inferencePort: 9131)

        #expect(document.contains("appearance:"))
        #expect(document.contains("  theme: dark"))
        #expect(document.contains("llm-pi-ai:"))
        #expect(document.contains("    silicon-local:"))
    }

    @Test func joinsAnExistingProviderSectionInsteadOfDuplicatingTheKey() {
        let existing = """
        llm-pi-ai:
          providers:
            my-gateway:
              apiKeyEnv: GATEWAY_KEY
              api: openai-completions
              baseURL: https://gateway.example/v1
              models:
                - id: some-model
        """
        let document = HarnessRuntime.providerConfiguration(existing: existing, inferencePort: 9131)

        // One top-level section, both providers inside it.
        let sections = document.components(separatedBy: "llm-pi-ai:").count - 1
        #expect(sections == 1)
        #expect(document.contains("    my-gateway:"))
        #expect(document.contains("      baseURL: https://gateway.example/v1"))
        #expect(document.contains("    silicon-local:"))
        #expect(document.contains("      baseURL: http://127.0.0.1:9131/v1"))
    }

    @Test func updatesThePortWithoutTouchingAForeignProvidersBaseURL() {
        let existing = HarnessRuntime.providerConfiguration(
            existing: """
            llm-pi-ai:
              providers:
                my-gateway:
                  baseURL: https://gateway.example/v1
            """,
            inferencePort: 9131
        )
        let moved = HarnessRuntime.providerConfiguration(existing: existing, inferencePort: 9200)

        #expect(moved.contains("https://gateway.example/v1"))
        #expect(moved.contains("http://127.0.0.1:9200/v1"))
        #expect(!moved.contains("9131"))
    }

    @Test func advertisesTheLoadedModelsNameAndContext() {
        let document = HarnessRuntime.providerConfiguration(
            existing: nil, inferencePort: 9131,
            model: .init(name: "Qwen3 Coder 30B (Q4_K_M)", contextLength: 32_768)
        )
        #expect(document.contains("          name: \"Qwen3 Coder 30B (Q4_K_M)\""))
        #expect(document.contains("          contextWindow: 32768"))
    }

    @Test func replacesTheModelEntryWhenTheModelChanges() {
        let first = HarnessRuntime.providerConfiguration(
            existing: "appearance:\n  theme: dark\n", inferencePort: 9131,
            model: .init(name: "Old Model", contextLength: 8192)
        )
        let second = HarnessRuntime.providerConfiguration(
            existing: first, inferencePort: 9131,
            model: .init(name: "New Model", contextLength: 32_768)
        )
        #expect(!second.contains("Old Model"))
        #expect(!second.contains("8192"))
        #expect(second.contains("name: \"New Model\""))
        #expect(second.contains("contextWindow: 32768"))
        #expect(second.contains("  theme: dark"))
    }

    @Test func dropsNameAndContextWhenNoModelIsLoaded() {
        let named = HarnessRuntime.providerConfiguration(
            existing: nil, inferencePort: 9131,
            model: .init(name: "Some Model", contextLength: 16_384)
        )
        let cleared = HarnessRuntime.providerConfiguration(existing: named, inferencePort: 9131)
        #expect(!cleared.contains("Some Model"))
        #expect(!cleared.contains("contextWindow"))
        #expect(cleared.contains("    silicon-local:"))
    }

    @Test func escapesQuotesInModelNames() {
        let document = HarnessRuntime.providerConfiguration(
            existing: nil, inferencePort: 9131,
            model: .init(name: "A \"quoted\" model", contextLength: nil)
        )
        #expect(document.contains("name: \"A \\\"quoted\\\" model\""))
    }

    // MARK: - Swarm provider retirement

    /// A settings document as this app used to write it: the local provider plus one
    /// managed per-peer entry, and a remembered pick pointing at the peer.
    private let legacySwarmDocument = """
    llm-pi-ai:
      providers:
        silicon-swarm-silicon-node:
          apiKeyEnv: SILICON_LOCAL_API_KEY
          api: openai-completions
          baseURL: http://100.118.191.121:8081/v1
          models:
            - id: qwen3.8-27b
              name: "qwen3.8-27b on silicon-node"
        silicon-local:
          apiKeyEnv: SILICON_LOCAL_API_KEY
          api: openai-completions
          baseURL: http://127.0.0.1:9131/v1
          models:
            - id: silicon-local
    agent-default-model:
      provider: silicon-swarm-silicon-node
      model: qwen3.8-27b
    other-default:
      provider: someone-elses
      model: qwen3.8-27b
    """

    @Test func retirementRemovesManagedSwarmProvidersOnly() {
        let document = HarnessRuntime.retiringSwarmProviders(existing: legacySwarmDocument)

        #expect(document?.contains("silicon-swarm-silicon-node:") == false)
        #expect(document?.contains("100.118.191.121") == false)
        // The local provider and everything foreign survive untouched.
        #expect(document?.contains("    silicon-local:") == true)
        #expect(document?.contains("baseURL: http://127.0.0.1:9131/v1") == true)
        #expect(document?.contains("provider: someone-elses") == true)
    }

    /// Saved picks must keep working across the migration: the pair
    /// (silicon-swarm-<peer>, <model>) is exactly (silicon, node/<peer>/<model>) in the
    /// plugin's world, so the rewrite is mechanical.
    @Test func retirementRewritesRememberedPicksToGatewayIDs() {
        let document = HarnessRuntime.retiringSwarmProviders(existing: legacySwarmDocument)

        #expect(document?.contains("  provider: silicon\n") == true)
        #expect(document?.contains("  model: node/silicon-node/qwen3.8-27b") == true)
        // The foreign block keeps both its provider and its model — not ours to correct.
        #expect(document?.contains("provider: someone-elses") == true)
        let foreign = (document ?? "").components(separatedBy: "model: qwen3.8-27b").count - 1
        #expect(foreign == 1)
    }

    @Test func retirementIsIdempotent() {
        let once = HarnessRuntime.retiringSwarmProviders(existing: legacySwarmDocument)
        let twice = HarnessRuntime.retiringSwarmProviders(existing: once)
        #expect(once == twice)
        #expect(HarnessRuntime.retiringSwarmProviders(existing: nil) == nil)
        // A document with nothing to retire comes back byte-identical.
        let clean = "llm-pi-ai:\n  providers:\n    mine:\n      baseURL: http://x/v1\n"
        #expect(HarnessRuntime.retiringSwarmProviders(existing: clean) == clean)
    }

    // MARK: - The silicon models plugin

    @Test func overlayLoadsThePluginAgainstTheGateway() {
        let overlay = HarnessRuntime.siliconOverlay(
            pluginIndexPath: "/Users/o'brien/Library/dsh/plugins/dsh-llm-silicon/lib/index.js",
            gatewayPort: 9414
        )
        #expect(overlay.contains("- insert:"))
        #expect(overlay.contains("id: silicon-models"))
        // Single-quoted with the apostrophe doubled, per YAML.
        #expect(overlay.contains("name: '/Users/o''brien/Library/dsh/plugins/dsh-llm-silicon/lib/index.js'"))
        #expect(overlay.contains("baseURL: http://127.0.0.1:9414/v1"))
        // Without a bridge on disk there is no tools row at all.
        #expect(!overlay.contains("silicon-tools"))
    }

    /// The tools row rides the same insert list as the models row, so the harness's model
    /// can call the app — images, 3D, video on the node — under mcp__silicon__* names.
    @Test func overlayWiresTheToolBridgeWhenPresent() {
        let overlay = HarnessRuntime.siliconOverlay(
            pluginIndexPath: "/plugins/dsh-llm-silicon/lib/index.js",
            gatewayPort: 9414,
            mcpServerPath: "/Applications/Silicon Optimizer.app/Contents/Resources/bin/silicon-mcp"
        )
        #expect(overlay.contains("id: silicon-tools"))
        #expect(overlay.contains("name: '@deepseek-ai/dsh-mcp-client'"))
        #expect(overlay.contains("serverName: silicon"))
        #expect(overlay.contains(
            "command: '/Applications/Silicon Optimizer.app/Contents/Resources/bin/silicon-mcp'"
        ))
        // A video render holds the tool call for up to ten minutes; the default 60s
        // timeout would kill every clip.
        #expect(overlay.contains("toolCallTimeoutMs: 1800000"))
        // One insert list, two rows: both dashes sit at the same indentation.
        let modelsIndent = overlay.range(of: "- id: silicon-models").map {
            overlay[..<$0.lowerBound].reversed().prefix { $0 == " " }.count
        }
        let toolsIndent = overlay.range(of: "- id: silicon-tools").map {
            overlay[..<$0.lowerBound].reversed().prefix { $0 == " " }.count
        }
        #expect(modelsIndent == toolsIndent)
    }

    @Test func pluginInstallCopiesOnceAndUpdatesOnChange() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-install-\(UUID().uuidString)")
        let source = base.appendingPathComponent("source")
        let home = base.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("lib"), withIntermediateDirectories: true
        )
        try "{\"version\":\"1.0.0\"}".write(
            to: source.appendingPathComponent("package.json"), atomically: true, encoding: .utf8
        )
        try "export const name = 'llm-silicon'".write(
            to: source.appendingPathComponent("lib/index.js"), atomically: true, encoding: .utf8
        )

        let installed = try HarnessRuntime.ensureSiliconPluginInstalled(home: home, source: source)
        #expect(installed.path.hasSuffix("profiles/plugins/dsh-llm-silicon/lib/index.js"))
        #expect(try String(contentsOf: installed, encoding: .utf8).contains("llm-silicon"))

        // A changed source lands on the next ensure; an unchanged one is left alone.
        try "export const name = 'llm-silicon' // v2".write(
            to: source.appendingPathComponent("lib/index.js"), atomically: true, encoding: .utf8
        )
        _ = try HarnessRuntime.ensureSiliconPluginInstalled(home: home, source: source)
        #expect(try String(contentsOf: installed, encoding: .utf8).contains("// v2"))
    }

    @Test func parsesNodeVersions() {
        #expect(HarnessRuntime.parseNodeVersion("v24.19.0\n") ?? (0, 0, 0) == (24, 19, 0))
        #expect(HarnessRuntime.parseNodeVersion("v20.12.2") ?? (0, 0, 0) == (20, 12, 2))
        #expect(HarnessRuntime.parseNodeVersion("garbage") == nil)
        #expect(HarnessRuntime.parseNodeVersion("") == nil)

        // The comparison that decides old-versus-new must be lexicographic by component:
        // v20.10 is older than the v20.12 floor, v24 is newer.
        let floor = HarnessRuntime.minimumNodeVersion
        let old = HarnessRuntime.parseNodeVersion("v20.10.0")!
        let new = HarnessRuntime.parseNodeVersion("v24.19.0")!
        #expect(old < (floor.major, floor.minor, floor.patch))
        #expect(new > (floor.major, floor.minor, floor.patch))
    }

    @Test func insertsAProvidersKeyWhenTheSectionExistsWithoutOne() {
        let existing = "llm-pi-ai:\n  somethingElse: true"
        let document = HarnessRuntime.providerConfiguration(existing: existing, inferencePort: 9131)

        let sections = document.components(separatedBy: "llm-pi-ai:").count - 1
        #expect(sections == 1)
        #expect(document.contains("  providers:"))
        #expect(document.contains("    silicon-local:"))
        #expect(document.contains("  somethingElse: true"))
    }
}

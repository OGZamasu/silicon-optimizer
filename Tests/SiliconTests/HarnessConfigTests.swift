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

    // MARK: - Swarm providers

    private let node = HarnessRuntime.SwarmProvider(
        peerName: "silicon-node",
        baseURL: "http://100.118.191.121:8081/v1",
        modelID: "qwen3.8-27b",
        displayName: "qwen3.8-27b on silicon-node"
    )

    @Test func addsAPeerProviderBesideTheLocalOne() {
        let local = HarnessRuntime.providerConfiguration(existing: nil, inferencePort: 9131)
        let document = HarnessRuntime.swarmConfiguration(existing: local, providers: [node])

        let sections = (document ?? "").components(separatedBy: "llm-pi-ai:").count - 1
        #expect(sections == 1)
        #expect(document?.contains("    silicon-local:") == true)
        #expect(document?.contains("    silicon-swarm-silicon-node:") == true)
        #expect(document?.contains("      baseURL: http://100.118.191.121:8081/v1") == true)
        #expect(document?.contains("        - id: qwen3.8-27b") == true)
        #expect(document?.contains("name: \"qwen3.8-27b on silicon-node\"") == true)
    }

    @Test func removesTheProviderWhenThePeerLeaves() {
        let local = HarnessRuntime.providerConfiguration(existing: nil, inferencePort: 9131)
        let added = HarnessRuntime.swarmConfiguration(existing: local, providers: [node])
        let removed = HarnessRuntime.swarmConfiguration(existing: added, providers: [])

        #expect(removed?.contains("silicon-swarm-silicon-node") == false)
        // The local provider and its section survive untouched.
        #expect(removed?.contains("    silicon-local:") == true)
        #expect(removed?.contains("baseURL: http://127.0.0.1:9131/v1") == true)
    }

    @Test func updatesAPeerProviderInPlace() {
        let first = HarnessRuntime.swarmConfiguration(existing: nil, providers: [node])
        var moved = node
        moved.baseURL = "http://192.168.4.23:8081/v1"
        let second = HarnessRuntime.swarmConfiguration(existing: first, providers: [moved])

        #expect(second?.contains("http://192.168.4.23:8081/v1") == true)
        #expect(second?.contains("100.118.191.121") == false)
        let entries = (second ?? "").components(separatedBy: "silicon-swarm-silicon-node:").count - 1
        #expect(entries == 1)
    }

    @Test func swarmSyncWithNothingToSayTouchesNothing() {
        #expect(HarnessRuntime.swarmConfiguration(existing: nil, providers: []) == nil)
    }

    /// The exact failure from the wild: the node renamed its model ("qwen3.8.27b" →
    /// "qwen3.8-27b"), the harness's remembered pick still said the old spelling, and
    /// every request 404ed. The sync must repair its own provider's dangling reference —
    /// and only its own.
    @Test func repairsTheHarnessesRememberedPickWhenTheModelIDChanges() {
        let existing = """
        agent-default-model:
          provider: silicon-swarm-silicon-node
          model: qwen3.8.27b
        other-default:
          provider: someone-elses
          model: qwen3.8.27b
        """
        let document = HarnessRuntime.swarmConfiguration(existing: existing, providers: [node])

        #expect(document?.contains("  model: qwen3.8-27b") == true)
        // The foreign block keeps its value — it is not ours to correct.
        let stale = (document ?? "").components(separatedBy: "model: qwen3.8.27b").count - 1
        #expect(stale == 1)
        #expect(document?.contains("provider: someone-elses") == true)
    }

    @Test func peerNamesBecomeSafeProviderIDs() {
        #expect(
            HarnessRuntime.SwarmProvider.providerID(peerName: "My PC #2")
                == "silicon-swarm-my-pc--2"
        )
        #expect(
            HarnessRuntime.SwarmProvider.providerID(peerName: "silicon-node")
                == "silicon-swarm-silicon-node"
        )
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

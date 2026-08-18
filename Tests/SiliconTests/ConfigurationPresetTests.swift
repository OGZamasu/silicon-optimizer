import Foundation
import Testing
@testable import SiliconPlanner
@testable import SiliconUI

@Suite("Configuration presets")
struct ConfigurationPresetTests {

    private var stored: LoadConfiguration {
        LoadConfiguration(
            contextLength: 32_768, batchSize: 1024, microBatchSize: 256,
            kvCachePrecision: .q8_0, flashAttention: true, gpuLayerFraction: 0.5,
            expertStreaming: ExpertStreamingConfiguration(slotCount: 32), threads: 4
        )
    }

    @Test func appliesKnobsButKeepsMachineFacts() {
        let preset = ConfigurationPreset(
            name: "Long context", configuration: stored, extraArguments: "--mlock"
        )
        let base = LoadConfiguration(contextLength: 8192, threads: 10)
        let applied = preset.applied(to: base, isMoE: true)

        #expect(applied.contextLength == 32_768)
        #expect(applied.kvCachePrecision == .q8_0)
        #expect(applied.expertStreaming?.slotCount == 32)
        // The machine's own facts are not part of a preset.
        #expect(applied.threads == 10)
        #expect(applied.gpuLayerFraction == 1.0)
    }

    @Test func dropsExpertStreamingForDenseModels() {
        let preset = ConfigurationPreset(
            name: "Streamed", configuration: stored, extraArguments: ""
        )
        let applied = preset.applied(to: LoadConfiguration(), isMoE: false)
        #expect(applied.expertStreaming == nil)
    }

    @Test func survivesTheSettingsRoundTrip() throws {
        var settings = Settings()
        settings.configurationPresets = [
            ConfigurationPreset(name: "A", configuration: stored, extraArguments: "--x")
        ]
        let decoded = try JSONDecoder().decode(
            Settings.self, from: JSONEncoder().encode(settings)
        )
        #expect(decoded.configurationPresets == settings.configurationPresets)
    }
}

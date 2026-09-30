import SiliconElevenLabs

/// What the voices-and-studio sections reach natively, and what they leave to the Explorer
/// with a reason — held to the catalog by `VoicesStudioSpecTests`, so every operation in these
/// sections is accounted for and a spec refresh that adds one fails a test until it is placed.
enum VoicesStudioCoverage {
    struct Entry {
        var section: ElevenLabsSection
        var controls: [VoicesStudioControl]
        var callsWithoutControls: Set<String>
        var explorerOnly: [String: String]
    }

    @MainActor static let entries: [Entry] = [
        Entry(section: .voices, controls: VoicesSectionModel.controls,
              callsWithoutControls: VoicesSectionModel.callsWithoutControls,
              explorerOnly: VoicesSectionModel.explorerOnly),
        Entry(section: .voiceDesign, controls: VoiceDesignSectionModel.controls,
              callsWithoutControls: VoiceDesignSectionModel.callsWithoutControls,
              explorerOnly: VoiceDesignSectionModel.explorerOnly),
        Entry(section: .voiceLibrary, controls: VoiceLibrarySectionModel.controls,
              callsWithoutControls: VoiceLibrarySectionModel.callsWithoutControls,
              explorerOnly: VoiceLibrarySectionModel.explorerOnly),
    ]

    @MainActor static var controls: [VoicesStudioControl] { entries.flatMap(\.controls) }

    /// Every operation some screen of these sections calls.
    @MainActor static var native: Set<String> {
        Set(entries.flatMap { $0.controls.map(\.operationID) + $0.callsWithoutControls })
    }

    @MainActor static var explorerOnly: [String: String] {
        entries.reduce(into: [:]) { $0.merge($1.explorerOnly) { first, _ in first } }
    }
}

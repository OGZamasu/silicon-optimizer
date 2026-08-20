import Foundation
import Testing
@testable import SiliconUI

/// The Video tab is six panels of tools plus the player. Opening them all at once made the
/// tab a wall to scroll past, so they fold — and what someone folds has to stay folded.
@Suite("Video panels")
@MainActor
struct VideoPanelTests {

    @Test func onlyTheClipComposerIsOpenToBeginWith() {
        let settings = Settings()
        #expect(settings.expandedVideoPanels == [VideoPanel.clip.rawValue])
        for panel in VideoPanel.allCases where panel != .clip {
            #expect(!settings.expandedVideoPanels.contains(panel.rawValue))
        }
    }

    @Test func togglingAPanelWritesItToSettings() {
        let model = AppModel()
        let tracking = model.videoPanel(.tracking)
        #expect(tracking.wrappedValue == false)

        tracking.wrappedValue = true
        #expect(model.settings.expandedVideoPanels.contains(VideoPanel.tracking.rawValue))
        // The composer's own state is untouched by another panel opening.
        #expect(model.videoPanel(.clip).wrappedValue)

        tracking.wrappedValue = false
        #expect(!model.settings.expandedVideoPanels.contains(VideoPanel.tracking.rawValue))
    }

    /// Opening a panel twice must not stack duplicates in the stored list, which would then
    /// need two closes to shut.
    @Test func openingTwiceIsStillOneEntry() {
        let model = AppModel()
        model.videoPanel(.live).wrappedValue = true
        model.videoPanel(.live).wrappedValue = true
        #expect(model.settings.expandedVideoPanels.filter { $0 == VideoPanel.live.rawValue }
            .count == 1)
        model.videoPanel(.live).wrappedValue = false
        #expect(!model.videoPanel(.live).wrappedValue)
    }

    /// A finished clip landing inside a folded panel is the obvious way this could go wrong.
    @Test func aNewResultOpensTheResultPanel() {
        let model = AppModel()
        #expect(model.videoPanel(.result).wrappedValue == false)
        model.revealVideoPanel(.result)
        #expect(model.videoPanel(.result).wrappedValue)
        // Revealing an already-open panel leaves it alone rather than duplicating it.
        model.revealVideoPanel(.result)
        #expect(model.settings.expandedVideoPanels.filter { $0 == VideoPanel.result.rawValue }
            .count == 1)
    }

    /// Settings saved before this feature existed have no such key. They must decode to the
    /// default rather than to nothing — an empty list would fold every panel, including the
    /// one the tab exists for.
    @Test func settingsWrittenBeforeThisFeatureKeepTheDefault() throws {
        let older = #"{"temperature": 0.7, "topP": 0.95}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(older.utf8))
        #expect(decoded.expandedVideoPanels == [VideoPanel.clip.rawValue])
    }

    @Test func aStoredArrangementSurvivesARoundTrip() throws {
        var settings = Settings()
        settings.expandedVideoPanels = [VideoPanel.clip.rawValue, VideoPanel.camera.rawValue]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded.expandedVideoPanels == [VideoPanel.clip.rawValue,
                                                VideoPanel.camera.rawValue])
    }
}

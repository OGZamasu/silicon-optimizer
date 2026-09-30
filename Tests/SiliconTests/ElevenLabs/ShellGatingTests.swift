import Foundation
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// The ElevenLabs pane is a place only while a key is linked: the sidebar and the menu bar
/// list it then and only then, nothing can select it otherwise, and losing the key while it
/// is on screen moves the window to Settings.
@Suite("ElevenLabs tab gating")
@MainActor
struct ShellGatingTests {

    @Test func thePaneIsListedOnlyWhileAKeyIsLinked() {
        #expect(!AppModel.Tab.sidebarOrder(elevenLabsLinked: false).contains(.elevenLabs))
        #expect(!AppModel.Tab.menuOrder(elevenLabsLinked: false).contains(.elevenLabs))
        let linked = AppModel.Tab.sidebarOrder(elevenLabsLinked: true)
        #expect(linked == AppModel.Tab.allCases)
        #expect(AppModel.Tab.menuOrder(elevenLabsLinked: true).contains(.elevenLabs))
        // With the other cloud service, below the places you make things, above Decisions.
        #expect(linked.firstIndex(of: .elevenLabs) == linked.firstIndex(of: .cloud).map { $0 + 1 })
        #expect(AppModel.Tab.elevenLabs.rawValue == "ElevenLabs")
    }

    @Test func unlinkedNothingListsItExceptAllCases() {
        let unlinked = AppModel.Tab.sidebarOrder(elevenLabsLinked: false)
        #expect(Set(unlinked) == Set(AppModel.Tab.allCases).subtracting([.elevenLabs]))
        #expect(AppModel.Tab.menuOrder(elevenLabsLinked: false).first == .chat)
        #expect(!AppModel.Tab.menuOrder(elevenLabsLinked: false).contains(.settings))
    }

    /// A link, a route, or last launch's remembered tab that names the hidden pane leaves the
    /// selection where it was.
    @Test func thePaneCannotBeSelectedWithoutAKey() {
        let model = AppModel(settings: .init())
        #expect(!model.elevenLabsLinked)
        model.selectedTab = .chat
        model.selectedTab = .elevenLabs
        #expect(model.selectedTab == .chat)
        if let remembered = AppModel.Tab(rawValue: "ElevenLabs") { model.selectedTab = remembered }
        #expect(model.selectedTab == .chat)
    }

    @Test func withAKeyThePaneCanBeSelected() {
        let model = AppModel(settings: Self.linkedSettings)
        model.selectedTab = .elevenLabs
        #expect(model.selectedTab == .elevenLabs)
    }

    @Test func losingTheKeyWhileOnThePaneMovesToSettings() {
        let model = AppModel(settings: Self.linkedSettings)
        model.selectedTab = .elevenLabs
        model.settings.elevenLabsLinked = false
        model.leaveHiddenTab()
        #expect(model.selectedTab == .settings)
    }

    @Test func losingTheKeyElsewhereLeavesTheSelectionAlone() {
        let model = AppModel(settings: Self.linkedSettings)
        model.selectedTab = .images
        model.settings.elevenLabsLinked = false
        model.leaveHiddenTab()
        #expect(model.selectedTab == .images)
    }

    /// Remembered in the settings the model holds; written to preferences only by the running
    /// app (a model built for a test has injected settings and saves nothing).
    @Test func theSelectedPaneIsRememberedForNextLaunch() {
        let model = AppModel(settings: Self.linkedSettings)
        model.selectedTab = .elevenLabs
        #expect(model.settings.lastTab == "ElevenLabs")
        model.selectedTab = .video
        #expect(model.settings.lastTab == "Video")
    }

    static var linkedSettings: Settings {
        var settings = Settings()
        settings.elevenLabsLinked = true
        return settings
    }
}

import Foundation
import Testing
@testable import SiliconUI

/// Settings in panes, and Decisions as a place of its own.
///
/// The reorganisation is mostly layout, which a test cannot see. What it can hold is the one
/// piece of behaviour underneath it: which panes are offered, and what happens to a
/// remembered pane that stops being one.
@Suite("Settings panes")
struct SettingsPaneTests {

    /// Advanced was gated behind the Behaviour toggle when it was a section, and it stays
    /// gated now that it is a pane. Everything else is always reachable — the point of the
    /// grouping was to shorten the scroll, not to hide controls behind a switch.
    @Test func advancedIsTheOnlyPaneTheToggleCanTakeAway() {
        let off = SettingsView.Pane.offered(showingAdvanced: false)
        let on = SettingsView.Pane.offered(showingAdvanced: true)

        #expect(on == SettingsView.Pane.allCases)
        #expect(!off.contains(.advanced))
        #expect(off == SettingsView.Pane.allCases.filter { $0 != .advanced })
    }

    /// Turning advanced controls off while sitting on the Advanced pane used to be
    /// impossible — the section simply vanished from the scroll. A pane that vanishes has to
    /// leave you somewhere, and an empty detail view is not somewhere.
    @Test func aRememberedPaneThatIsNoLongerOfferedFallsBack() {
        #expect(
            SettingsView.Pane.resolve(remembered: "Advanced", showingAdvanced: true)
            == .advanced
        )
        #expect(
            SettingsView.Pane.resolve(remembered: "Advanced", showingAdvanced: false)
            == .general
        )
    }

    /// Settings are usually reopened to change the same thing again, so the pane is
    /// remembered across launches. A stored value from a build that spelled the panes
    /// differently must not leave the window blank.
    @Test func aPaneIsRememberedUnlessItIsNotAPane() {
        for pane in SettingsView.Pane.allCases {
            #expect(
                SettingsView.Pane.resolve(remembered: pane.rawValue, showingAdvanced: true)
                == pane
            )
        }
        #expect(SettingsView.Pane.resolve(remembered: "", showingAdvanced: true) == .general)
        #expect(
            SettingsView.Pane.resolve(remembered: "Runtimes", showingAdvanced: true)
            == .general
        )
    }

    /// Decisions is a sidebar destination now, not a heading two thirds of the way down
    /// Settings. The sidebar is built from `Tab.allCases`, so being a case is what puts it
    /// on screen at all.
    @Test func decisionsIsItsOwnPlaceInTheSidebar() {
        let order = AppModel.Tab.allCases
        let decisions = try? #require(order.firstIndex(of: .decisions))
        let settings = try? #require(order.firstIndex(of: .settings))
        #expect(AppModel.Tab.decisions.rawValue == "Decisions")
        // Below the places you make things, above Settings: it is a control panel, not a
        // workspace, and the sidebar should read that way.
        #expect(decisions ?? 0 < settings ?? 0)
    }

    /// The menu bar is the app's real home, and its list of places had quietly stopped
    /// matching the sidebar's — Cloud was not on it. Building it from `allCases` means a new
    /// tab appears in both, and this is what says so.
    @Test func theMenuBarOffersEveryPlaceExceptSettings() {
        let menu = AppModel.Tab.menuOrder
        #expect(menu.first == .chat)
        #expect(!menu.contains(.settings))
        #expect(Set(menu) == Set(AppModel.Tab.allCases).subtracting([.settings]))
        #expect(Set(menu).count == menu.count)
    }

    /// Every sidebar row is an icon and a word. Two rows sharing an icon is the kind of
    /// thing a copied `case` leaves behind and nobody notices.
    @Test func everySidebarRowHasItsOwnIcon() {
        let icons = AppModel.Tab.allCases.map(\.systemImage)
        #expect(Set(icons).count == icons.count)
        #expect(!icons.contains(""))
    }
}

import Foundation
import SwiftUI

/// The foldable sections of the Video tab.
///
/// Named in one place because the identifiers are written to settings: a panel renamed in a
/// view would otherwise quietly lose whatever someone had opened.
public enum VideoPanel: String, CaseIterable, Sendable {
    case clip
    case cast
    case perform
    case live
    case tracking
    case camera
    case result
}

extension AppModel {

    /// Whether a Video panel is open, as a binding the card can drive.
    ///
    /// Reading and writing settings rather than view state is what makes the arrangement
    /// survive a tab switch — the tab is rebuilt from scratch each time it appears, and
    /// `@State` in it would put every panel back the way the app thought best rather than
    /// the way the person left it.
    public func videoPanel(_ panel: VideoPanel) -> Binding<Bool> {
        Binding(
            get: { self.settings.expandedVideoPanels.contains(panel.rawValue) },
            set: { isOpen in
                var open = self.settings.expandedVideoPanels
                if isOpen {
                    guard !open.contains(panel.rawValue) else { return }
                    open.append(panel.rawValue)
                } else {
                    open.removeAll { $0 == panel.rawValue }
                }
                self.settings.expandedVideoPanels = open
            }
        )
    }

    /// Opens a panel that has something new to show.
    ///
    /// A finished clip landing inside a folded panel is the obvious way this feature could
    /// go wrong, so the result panel opens itself when a render arrives.
    public func revealVideoPanel(_ panel: VideoPanel) {
        guard !settings.expandedVideoPanels.contains(panel.rawValue) else { return }
        settings.expandedVideoPanels.append(panel.rawValue)
    }
}

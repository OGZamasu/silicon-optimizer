import SwiftUI

/// Full-window mode for the chat engines: one toolbar button hides the sidebar and the
/// window toolbar so the engine owns the whole window, and a faint floating button —
/// visible on hover — is the way back. One implementation for all three engines.
struct ChatWindowExpansion: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var isHoveringCollapse = false

    /// Toolbar help text naming the engine, e.g. "Give the harness the whole window".
    var expandHelp: String

    private var isExpanded: Bool { model.chatColumnVisibility == .detailOnly }

    func body(content: Content) -> some View {
        content
            // Expanded means the whole window: the toolbar goes away and the content
            // extends into the title bar area, leaving the floating button as the way back.
            .toolbar(isExpanded ? .hidden : .automatic, for: .windowToolbar)
            .ignoresSafeArea(edges: isExpanded ? .top : [])
            .overlay(alignment: .topTrailing) {
                if isExpanded { collapseButton }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.chatColumnVisibility = isExpanded ? .all : .detailOnly
                    } label: {
                        Label(
                            isExpanded ? "Show Sidebar" : "Expand",
                            systemImage: isExpanded
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right"
                        )
                    }
                    .help(isExpanded ? "Bring the sidebar back" : expandHelp)
                }
            }
    }

    /// The way back from full-window mode, kept faint until hovered so it does not sit
    /// visibly on top of the engine's own UI.
    private var collapseButton: some View {
        Button {
            model.chatColumnVisibility = .all
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(7)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(isHoveringCollapse ? 1.0 : 0.3)
        .animation(.easeOut(duration: 0.15), value: isHoveringCollapse)
        .onHover { isHoveringCollapse = $0 }
        .padding(10)
        .help("Exit full window")
    }
}

extension View {
    /// Gives a chat engine view the full-window toggle the harness pioneered.
    func chatWindowExpansion(help: String) -> some View {
        modifier(ChatWindowExpansion(expandHelp: help))
    }
}

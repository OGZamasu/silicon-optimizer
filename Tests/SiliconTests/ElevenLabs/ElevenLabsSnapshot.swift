import AppKit
import Foundation
import SwiftUI

/// Renders a view to a PNG for a person to look at: light and dark, narrow and wide.
///
/// Every ElevenLabs UI builder's tests can use it. It always renders (so a view that cannot
/// draw fails the test), but writes files only when `ELEVENLABS_SNAPSHOT_DIR` names a folder —
/// a scratch folder outside the repository, never the repo itself — so the suite leaves
/// nothing behind by default. Nothing here touches the network, the Keychain or the app.
@MainActor
enum ElevenLabsSnapshot {

    enum Width: String, CaseIterable {
        /// The main window at its minimum, less the app's sidebar.
        case narrow
        case wide

        var points: CGFloat {
            switch self {
            case .narrow: 760
            case .wide: 1180
            }
        }
    }

    /// Whether the drawing tests run at all: only when asked, with `ELEVENLABS_SNAPSHOT_DIR`
    /// or `ELEVENLABS_DRAW=1`. Drawing holds the main actor for seconds at a time, and on a
    /// shared, loaded Mac that starves other suites' timing tests in a full run.
    nonisolated static var enabled: Bool {
        directory != nil || ProcessInfo.processInfo.environment["ELEVENLABS_DRAW"] == "1"
    }

    /// Where PNGs go, when anywhere.
    nonisolated static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["ELEVENLABS_SNAPSHOT_DIR"], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Draws `view` at `width` × `height` in both appearances; returns the images, and writes
    /// them as `<name>-<width>-<light|dark>.png` when a directory is set.
    @discardableResult
    static func render(
        _ view: some View, name: String, width: Width, height: CGFloat = 720
    ) throws -> [NSBitmapImageRep] {
        var images: [NSBitmapImageRep] = []
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: AnyView(
                view
                    .frame(width: width.points, height: height, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
            ))
            let frame = NSRect(x: 0, y: 0, width: width.points, height: height)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = frame
            host.layoutSubtreeIfNeeded()
            // Let `.task` and `onAppear` settle, and SwiftUI finish a second layout pass.
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw SnapshotError.noBitmap(name)
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            images.append(bitmap)
            window.close()

            if let directory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw SnapshotError.noBitmap(name)
                }
                try png.write(to: directory.appendingPathComponent("\(name)-\(width.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
        return images
    }

    /// Whether a bitmap has anything on it besides one flat colour.
    static func hasContent(_ bitmap: NSBitmapImageRep) -> Bool {
        guard let first = bitmap.colorAt(x: 1, y: 1) else { return false }
        let step = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 40)
        for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) where bitmap.colorAt(x: x, y: y) != first {
                return true
            }
        }
        return false
    }

    enum SnapshotError: Error {
        case noBitmap(String)
    }
}

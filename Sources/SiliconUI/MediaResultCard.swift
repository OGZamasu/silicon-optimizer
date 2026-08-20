import AppKit
import AVKit
import SiliconControl
import SwiftUI

/// An inline preview for a media file the chat produced: a real player for video and
/// audio, the picture for images, and a jump into the 3D viewer for meshes — plus the
/// two actions every result deserves, Show in Finder and copy.
///
/// The native twin of the card the harness web view injects; the Codex transcript uses
/// this one directly.
struct MediaResultCard: View {
    @Environment(AppModel.self) private var model
    let path: String

    private var url: URL { URL(fileURLWithPath: path) }
    private var kind: Kind { Kind(extension: url.pathExtension.lowercased()) }

    enum Kind {
        case video, image, audio, mesh, other

        init(extension fileExtension: String) {
            switch fileExtension {
            case "mp4", "mov", "webm": self = .video
            case "png", "jpg", "jpeg", "webp", "gif": self = .image
            case "wav", "mp3", "m4a", "aiff", "flac": self = .audio
            case "glb", "obj": self = .mesh
            default: self = .other
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
            HStack(spacing: 8) {
                if kind == .mesh {
                    Button("Open in 3D viewer") {
                        model.selectedTab = .threeD
                    }
                    .controlSize(.small)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
                .controlSize(.small)
                if kind == .image, let image = NSImage(contentsOf: url) {
                    Button("Copy image") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    }
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            Text(url.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }

    @ViewBuilder
    private var preview: some View {
        switch kind {
        case .video, .audio:
            InlinePlayer(url: url, isAudio: kind == .audio)
                .frame(height: kind == .audio ? 40 : 240)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .image:
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                missing
            }
        case .mesh:
            Label(url.lastPathComponent, systemImage: "cube.transparent")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .other:
            missing
        }
    }

    private var missing: some View {
        Label("The file is gone.", systemImage: "questionmark.folder")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

/// AppKit's `AVPlayerView` rather than SwiftUI's `VideoPlayer`, for the same reason the
/// Video tab uses it: reliable controls, and it plays audio files just as happily with
/// its compact control bar.
private struct InlinePlayer: NSViewRepresentable {
    let url: URL
    let isAudio: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = !isAudio
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard (view.player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        view.player = AVPlayer(url: url)
    }
}

import AppKit
import ImageIO
import Metal
import SceneKit
import SiliconRuntime
import SwiftUI

/// A collapsed-by-default browser of past results on disk.
///
/// The session galleries only know what was generated since launch; everything older sits
/// in the output folder, invisible from the app. This pane is that folder, made browsable —
/// closed it costs one row, open it scrolls like a file browser.
struct RecentsPane<Item: Identifiable, Thumb: View>: View {
    var title: String
    var systemImage: String
    var items: [Item]
    @Binding var isExpanded: Bool
    @ViewBuilder var thumb: (Item) -> Thumb
    var onSelect: (Item) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Label(title, systemImage: systemImage)
                            .font(.headline)
                        if isExpanded {
                            Text("\(items.count)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    if items.isEmpty {
                        Text("Nothing saved yet — everything you generate lands here.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ScrollView {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                                spacing: 8
                            ) {
                                ForEach(items) { item in
                                    Button {
                                        onSelect(item)
                                    } label: {
                                        thumb(item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(maxHeight: 300)
                    }
                }
            }
        }
    }
}

// MARK: - Image thumbnails

/// NSImage is not Sendable; the pixels are immutable once decoded, so carrying it across
/// the decode task's boundary is safe in practice.
private struct ImageBox: @unchecked Sendable {
    let image: NSImage
}

enum Thumbnails {
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    /// Decodes a small thumbnail off the main thread via ImageIO — never the full bitmap,
    /// which for a 2048² render would be 16 MB per grid tile.
    static func image(at url: URL, side: CGFloat = 192) async -> NSImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let boxed = await Task.detached(priority: .utility) { () -> ImageBox? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: Int(side * 2),
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary)
            else { return nil }
            return ImageBox(image: NSImage(cgImage: cg, size: .zero))
        }.value
        if let boxed { cache.setObject(boxed.image, forKey: key) }
        return boxed?.image
    }
}

struct ImageThumbnail: View {
    var url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 96, height: 96)
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 8))
        .task(id: url) {
            image = await Thumbnails.image(at: url)
        }
    }
}

// MARK: - Mesh thumbnails

/// Renders small offscreen snapshots of saved meshes, serialized through an actor so a
/// fast scroll does not spin up a dozen concurrent SceneKit loads, and cached so each
/// file renders once per launch.
actor MeshThumbnails {
    static let shared = MeshThumbnails()
    private var cache: [String: ImageBox] = [:]

    func render(_ url: URL?) async -> NSImage? {
        guard let url else { return nil }
        if let hit = cache[url.path] { return hit.image }
        guard let scene = try? MeshScene.load(url),
              let device = MTLCreateSystemDefaultDevice() else { return nil }

        let (center, floatRadius) = scene.rootNode.boundingSphere
        let radius = CGFloat(max(floatRadius, 0.001))
        let camera = SCNCamera()
        camera.zNear = Double(radius) * 0.01
        camera.zFar = Double(radius) * 20
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(
            center.x + radius * 1.4, center.y + radius * 0.9, center.z + radius * 1.8
        )
        cameraNode.look(at: center)
        scene.rootNode.addChildNode(cameraNode)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = true
        let image = renderer.snapshot(
            atTime: 0, with: CGSize(width: 192, height: 192),
            antialiasingMode: .multisampling4X
        )
        cache[url.path] = ImageBox(image: image)
        return image
    }
}

struct MeshThumbnail: View {
    var result: MeshResult
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 96, height: 96)
            .background(.background.secondary)
            .clipShape(.rect(cornerRadius: 8))

            Text(shortName)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 96)
        }
        .task(id: result.id) {
            image = await MeshThumbnails.shared.render(result.primaryFile)
        }
    }

    /// `silicon3d-2026-08-18-120000-1A2B` reads better as its date and time.
    private var shortName: String {
        let name = result.baseName
        guard name.hasPrefix("silicon3d-") else { return name }
        return String(name.dropFirst("silicon3d-".count).prefix(17))
    }
}

import AppKit
import ImageIO
import Metal
import SceneKit
import UniformTypeIdentifiers

/// A handle the share actions use to reach the live SCNView inside `MeshViewer`, so a
/// snapshot captures exactly what is on screen — same camera, same pose, same moment.
final class MeshViewerLink {
    weak var view: SCNView?
}

/// The camera pose lifted off the live viewer: enough to reproduce the user's framing in
/// an offscreen render. A plain value so it can cross into the render task.
struct CameraPose: Sendable {
    var transform: SCNMatrix4
    var fieldOfView: CGFloat
    var zNear: Double
    var zFar: Double
}

/// Sharing a mesh: a still of the viewer as posed, or a slow full turn as a looping GIF.
/// Both come in two flavors — copied to the clipboard for pasting straight into a chat,
/// or saved as a file.
enum MeshShare {

    /// One full revolution at a stately pace. 10 fps keeps every GIF decoder honest
    /// (many clamp shorter delays), and 72 frames make a smooth 7-second spin.
    static let gifFrameCount = 72
    static let gifFrameDelay = 0.1
    static let gifMaxDimension: CGFloat = 512

    /// The ground behind every share. GIF pixels have no real alpha, and a transparent
    /// snapshot pastes unpredictably, so both formats sit on the same studio dark.
    static let studioBackground = NSColor(calibratedWhite: 0.12, alpha: 1)

    struct RenderFailure: Error {}

    // MARK: - Capturing the viewer

    @MainActor
    static func pose(of view: SCNView?) -> CameraPose? {
        guard let pov = view?.pointOfView, let camera = pov.camera else { return nil }
        return CameraPose(
            transform: pov.presentation.worldTransform,
            fieldOfView: camera.fieldOfView,
            zNear: camera.zNear,
            zFar: camera.zFar
        )
    }

    /// The GIF keeps the viewer's shape so the framing carries over, capped so the file
    /// stays friendly to chat apps.
    @MainActor
    static func gifSize(matching view: SCNView?) -> CGSize {
        let fallback = CGSize(width: 480, height: 480)
        guard let bounds = view?.bounds.size, bounds.width > 0, bounds.height > 0 else {
            return fallback
        }
        let scale = min(1, gifMaxDimension / max(bounds.width, bounds.height))
        return CGSize(
            width: (bounds.width * scale).rounded(),
            height: (bounds.height * scale).rounded()
        )
    }

    /// The viewer draws on a clear background; composited onto the studio ground the
    /// snapshot looks the same everywhere it is pasted.
    @MainActor
    static func still(of view: SCNView) -> NSImage {
        let raw = view.snapshot()
        return NSImage(size: raw.size, flipped: false) { rect in
            studioBackground.setFill()
            rect.fill()
            raw.draw(in: rect)
            return true
        }
    }

    // MARK: - The spinning GIF

    /// Renders the mesh turning through a full revolution and encodes it as a looping
    /// GIF. Runs on its own offscreen scene so the visible viewer never stutters.
    static func turntableGIF(
        mesh url: URL,
        pose: CameraPose?,
        size: CGSize,
        frameCount: Int = gifFrameCount,
        frameDelay: Double = gifFrameDelay,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let scene = try MeshScene.load(url)
            guard let device = MTLCreateSystemDefaultDevice() else { throw RenderFailure() }

            // Same structure as the live viewer — model under a spinnable parent — so a
            // captured camera pose lines up with what the user framed.
            let turntable = SCNNode()
            for child in scene.rootNode.childNodes
            where child.camera == nil && child.light == nil {
                child.removeFromParentNode()
                turntable.addChildNode(child)
            }
            scene.rootNode.addChildNode(turntable)

            let camera = SCNCamera()
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            if let pose {
                camera.fieldOfView = pose.fieldOfView
                camera.zNear = pose.zNear
                camera.zFar = pose.zFar
                cameraNode.transform = pose.transform
            } else {
                let (center, floatRadius) = turntable.boundingSphere
                let radius = CGFloat(max(floatRadius, 0.001))
                camera.zNear = Double(radius) * 0.01
                camera.zFar = Double(radius) * 20
                cameraNode.position = SCNVector3(
                    center.x, center.y + radius * 0.55, center.z + radius * 2.4
                )
                cameraNode.look(at: center)
            }
            scene.rootNode.addChildNode(cameraNode)
            scene.background.contents = studioBackground

            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = scene
            renderer.pointOfView = cameraNode
            renderer.autoenablesDefaultLighting = true

            let output = NSMutableData()
            guard let gif = CGImageDestinationCreateWithData(
                output, UTType.gif.identifier as CFString, frameCount, nil
            ) else { throw RenderFailure() }
            CGImageDestinationSetProperties(gif, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)

            for frame in 0..<frameCount {
                turntable.eulerAngles.y = CGFloat(frame) / CGFloat(frameCount) * 2 * .pi
                let image = renderer.snapshot(
                    atTime: 0, with: size, antialiasingMode: .multisampling4X
                )
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { throw RenderFailure() }
                CGImageDestinationAddImage(gif, cg, [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: frameDelay,
                        kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
                    ]
                ] as CFDictionary)
                progress(Double(frame + 1) / Double(frameCount))
            }
            guard CGImageDestinationFinalize(gif) else { throw RenderFailure() }
            return output as Data
        }.value
    }

    // MARK: - Clipboard and files

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @MainActor
    static func copy(image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    /// A GIF pasted as raw pixels loses its animation in most apps, so the clipboard
    /// gets both a real .gif file and the GIF bytes — whichever the receiving app
    /// prefers, the spin survives.
    @MainActor
    static func copy(gif data: Data, name: String) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiliconOptimizer Shares", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        let url = folder.appendingPathComponent(name).appendingPathExtension("gif")
        try data.write(to: url)

        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
        item.setString(url.absoluteString, forType: .fileURL)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// The standard save panel. Returns nil when the user cancels.
    @MainActor
    static func askWhereToSave(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}

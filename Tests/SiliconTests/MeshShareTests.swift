import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SiliconUI

/// The GIF renderer is tested against a real backend output, like the viewer tests:
/// integration proof on a machine that has the file, a quiet skip elsewhere.
@Suite("Mesh sharing")
struct MeshShareTests {

    private static let shoe = URL(fileURLWithPath: "/Volumes/T9/trellis2/test_shoe.glb")

    @Test func spinsAFullTurnIntoALoopingGIF() async throws {
        guard FileManager.default.fileExists(atPath: Self.shoe.path) else { return }

        let data = try await MeshShare.turntableGIF(
            mesh: Self.shoe,
            pose: nil,
            size: CGSize(width: 96, height: 96),
            frameCount: 12,
            frameDelay: 0.1
        )

        #expect(data.starts(with: Data("GIF8".utf8)))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 12)

        // Loops forever — a share that plays once and freezes reads as broken.
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gifInfo = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect(gifInfo?[kCGImagePropertyGIFLoopCount] as? Int == 0)

        // The turntable must actually turn: a quarter revolution in, the pixels differ.
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let quarter = try #require(CGImageSourceCreateImageAtIndex(source, 3, nil))
        #expect(pixels(first) != pixels(quarter))
    }

    @Test func encodesSnapshotsAsPNG() throws {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let data = try #require(MeshShare.pngData(image))
        #expect(data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))
    }

    private func pixels(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }
}

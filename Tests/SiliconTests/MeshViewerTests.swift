import Foundation
import SceneKit
import Testing
@testable import SiliconUI

/// The GLB loader is deliberately a subset parser, so it is tested against the real thing:
/// actual output files from the backends it exists to display. The tests skip quietly on a
/// machine that does not have those files — they are integration proof, not CI gates.
@Suite("Mesh viewer GLB loading")
struct MeshViewerTests {

    private func geometryCount(_ node: SCNNode) -> Int {
        (node.geometry != nil ? 1 : 0) + node.childNodes.reduce(0) {
            $0 + geometryCount($1)
        }
    }

    /// A TRELLIS.2 output: textured, PBR, trimesh-exported.
    @Test func loadsATrellisGLB() throws {
        let url = URL(fileURLWithPath: "/Volumes/T9/trellis2/test_shoe.glb")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let scene = try MeshScene.load(url)
        #expect(geometryCount(scene.rootNode) > 0)
    }

    /// A Hunyuan3D output: geometry-only, written by hy3d's own GLB writer.
    @Test func loadsAHunyuanGLB() throws {
        let url = URL(fileURLWithPath: "/Volumes/T9/trellis2/mcp_outputs/3bb25a58eac5.glb")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let scene = try MeshScene.load(url)
        #expect(geometryCount(scene.rootNode) > 0)
    }

    /// The OBJ path goes through Model I/O; a plain v/f file must still get a material.
    /// (Not every trellis OBJ qualifies — one early render emitted vertices with no faces —
    /// so this uses the shipped test asset, which is a real mesh.)
    @Test func loadsAnOBJWithAFallbackMaterial() throws {
        let url = URL(fileURLWithPath: "/Volumes/T9/trellis2/test_shoe.obj")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let scene = try MeshScene.load(url)
        #expect(geometryCount(scene.rootNode) > 0)
    }
}

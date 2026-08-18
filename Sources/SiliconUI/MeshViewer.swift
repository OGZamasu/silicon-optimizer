import AppKit
import ModelIO
import SceneKit
import SceneKit.ModelIO
import SwiftUI

/// An interactive preview of a generated mesh: orbit with the mouse, scroll to zoom, with a
/// slow turntable so the result reads as 3D the moment it appears.
struct MeshViewer: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .clear
        load(url, into: view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        load(url, into: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedURL: URL?
    }

    private func load(_ url: URL, into view: SCNView) {
        guard let scene = try? MeshScene.load(url) else { return }

        // A slow turntable, on a parent so camera control (which moves the camera, not the
        // model) composes with it instead of fighting it.
        let turntable = SCNNode()
        for child in scene.rootNode.childNodes where child.camera == nil && child.light == nil {
            child.removeFromParentNode()
            turntable.addChildNode(child)
        }
        scene.rootNode.addChildNode(turntable)
        turntable.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 24)))

        view.scene = scene
        frame(view: view, around: turntable)
    }

    /// Points the default camera at the model, whatever its scale — generated meshes vary
    /// from unit cubes to hundred-unit scans.
    private func frame(view: SCNView, around node: SCNNode) {
        let (center, floatRadius) = node.boundingSphere
        guard floatRadius > 0 else { return }
        let radius = CGFloat(floatRadius)
        let camera = SCNCamera()
        camera.zNear = Double(radius) * 0.01
        camera.zFar = Double(radius) * 20
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let distance = radius * 2.4
        cameraNode.position = SCNVector3(
            center.x,
            center.y + radius * 0.55,
            center.z + distance
        )
        cameraNode.look(at: center)
        view.scene?.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode
    }
}

/// Loads mesh files into SceneKit scenes.
///
/// OBJ, USDZ, STL and PLY go through Model I/O, which handles them natively. GLB — the primary
/// output of every backend here — has no system loader, so a minimal parser below reads the
/// subset of glTF our own generators emit: float attributes, 16/32-bit indices, embedded
/// PNG/JPEG textures, metallic-roughness materials. It makes no attempt at full-spec glTF
/// (no Draco, no sparse accessors, no animations); a file it cannot read throws, and the
/// viewer's caller falls back to "open externally".
enum MeshScene {

    enum LoadError: Error {
        case unreadable(String)
    }

    static func load(_ url: URL) throws -> SCNScene {
        if url.pathExtension.lowercased() == "glb" {
            return try loadGLB(url)
        }
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        let scene = SCNScene(mdlAsset: asset)
        applyFallbackMaterial(scene.rootNode)
        return scene
    }

    /// OBJ files from these backends carry no UVs or materials; a neutral studio material
    /// reads far better than Model I/O's flat default white.
    private static func applyFallbackMaterial(_ node: SCNNode) {
        if let geometry = node.geometry {
            let hasTexture = geometry.firstMaterial?.diffuse.contents is NSImage
            if !hasTexture {
                let material = SCNMaterial()
                material.lightingModel = .physicallyBased
                material.diffuse.contents = NSColor(white: 0.75, alpha: 1)
                material.roughness.contents = 0.55
                material.metalness.contents = 0.05
                geometry.materials = [material]
            }
        }
        node.childNodes.forEach(applyFallbackMaterial)
    }

    // MARK: - GLB

    private static func loadGLB(_ url: URL) throws -> SCNScene {
        let data = try Data(contentsOf: url)
        guard data.count > 20,
              data[0...3] == Data("glTF".utf8) else {
            throw LoadError.unreadable("Not a GLB container.")
        }

        // Chunks: [length][type][payload]…, first JSON then BIN.
        var offset = 12
        var jsonData: Data?
        var binData: Data?
        while offset + 8 <= data.count {
            let length = Int(readUInt32(data, at: offset))
            let type = readUInt32(data, at: offset + 4)
            let start = offset + 8
            guard start + length <= data.count else { break }
            let payload = data.subdata(in: start..<(start + length))
            if type == 0x4E4F_534A { jsonData = payload }        // "JSON"
            if type == 0x004E_4942 { binData = payload }         // "BIN\0"
            offset = start + length
        }
        guard let jsonData,
              let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            throw LoadError.unreadable("No JSON chunk.")
        }
        let bin = binData ?? Data()

        let parser = GLBParser(root: root, bin: bin)
        return try parser.buildScene()
    }

    static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
    }
}

/// The GLB subset parser. One instance per file; builds SCNGeometry per glTF primitive and
/// assembles the node tree with its transforms.
private struct GLBParser {
    let root: [String: Any]
    let bin: Data

    var accessors: [[String: Any]] { root["accessors"] as? [[String: Any]] ?? [] }
    var bufferViews: [[String: Any]] { root["bufferViews"] as? [[String: Any]] ?? [] }
    var meshes: [[String: Any]] { root["meshes"] as? [[String: Any]] ?? [] }
    var nodes: [[String: Any]] { root["nodes"] as? [[String: Any]] ?? [] }
    var materials: [[String: Any]] { root["materials"] as? [[String: Any]] ?? [] }
    var textures: [[String: Any]] { root["textures"] as? [[String: Any]] ?? [] }
    var images: [[String: Any]] { root["images"] as? [[String: Any]] ?? [] }

    func buildScene() throws -> SCNScene {
        let scene = SCNScene()

        // The default scene's roots; a file without a scene block gets every node.
        var rootIndexes: [Int] = []
        if let scenes = root["scenes"] as? [[String: Any]] {
            let sceneIndex = root["scene"] as? Int ?? 0
            rootIndexes = scenes.indices.contains(sceneIndex)
                ? (scenes[sceneIndex]["nodes"] as? [Int] ?? [])
                : []
        }
        if rootIndexes.isEmpty { rootIndexes = Array(nodes.indices) }

        var built = false
        for index in rootIndexes {
            if let node = try buildNode(index) {
                scene.rootNode.addChildNode(node)
                built = true
            }
        }
        // A meshes-only file (no node tree) still deserves to display.
        if !built {
            for meshIndex in meshes.indices {
                let node = SCNNode()
                try attach(meshIndex: meshIndex, to: node)
                scene.rootNode.addChildNode(node)
            }
        }
        return scene
    }

    private func buildNode(_ index: Int) throws -> SCNNode? {
        guard nodes.indices.contains(index) else { return nil }
        let source = nodes[index]
        let node = SCNNode()

        if let matrix = source["matrix"] as? [Double], matrix.count == 16 {
            let values = matrix.map { CGFloat($0) }
            node.transform = SCNMatrix4(
                m11: values[0], m12: values[1], m13: values[2], m14: values[3],
                m21: values[4], m22: values[5], m23: values[6], m24: values[7],
                m31: values[8], m32: values[9], m33: values[10], m34: values[11],
                m41: values[12], m42: values[13], m43: values[14], m44: values[15]
            )
        } else {
            if let translation = source["translation"] as? [Double], translation.count == 3 {
                node.position = SCNVector3(translation[0], translation[1], translation[2])
            }
            if let rotation = source["rotation"] as? [Double], rotation.count == 4 {
                node.orientation = SCNQuaternion(
                    rotation[0], rotation[1], rotation[2], rotation[3]
                )
            }
            if let scale = source["scale"] as? [Double], scale.count == 3 {
                node.scale = SCNVector3(scale[0], scale[1], scale[2])
            }
        }

        if let meshIndex = source["mesh"] as? Int {
            try attach(meshIndex: meshIndex, to: node)
        }
        for childIndex in source["children"] as? [Int] ?? [] {
            if let child = try buildNode(childIndex) {
                node.addChildNode(child)
            }
        }
        return node
    }

    private func attach(meshIndex: Int, to node: SCNNode) throws {
        guard meshes.indices.contains(meshIndex) else { return }
        for primitive in meshes[meshIndex]["primitives"] as? [[String: Any]] ?? [] {
            if let geometry = try buildGeometry(primitive) {
                let child = SCNNode(geometry: geometry)
                node.addChildNode(child)
            }
        }
    }

    private func buildGeometry(_ primitive: [String: Any]) throws -> SCNGeometry? {
        guard let attributes = primitive["attributes"] as? [String: Int],
              let positionIndex = attributes["POSITION"]
        else { return nil }

        var sources: [SCNGeometrySource] = []
        if let positions = geometrySource(accessor: positionIndex, semantic: .vertex) {
            sources.append(positions)
        }
        if let normalIndex = attributes["NORMAL"],
           let normals = geometrySource(accessor: normalIndex, semantic: .normal) {
            sources.append(normals)
        }
        if let uvIndex = attributes["TEXCOORD_0"],
           let uvs = geometrySource(accessor: uvIndex, semantic: .texcoord) {
            sources.append(uvs)
        }
        guard !sources.isEmpty else { return nil }

        guard let element = element(primitive["indices"] as? Int) else { return nil }
        let geometry = SCNGeometry(sources: sources, elements: [element])
        geometry.materials = [material(primitive["material"] as? Int)]
        return geometry
    }

    private func accessorData(_ index: Int) -> (data: Data, offset: Int, stride: Int?)? {
        guard accessors.indices.contains(index),
              let viewIndex = accessors[index]["bufferView"] as? Int,
              bufferViews.indices.contains(viewIndex)
        else { return nil }
        let view = bufferViews[viewIndex]
        let viewOffset = view["byteOffset"] as? Int ?? 0
        let viewLength = view["byteLength"] as? Int ?? 0
        guard viewOffset + viewLength <= bin.count else { return nil }
        return (
            bin.subdata(in: viewOffset..<(viewOffset + viewLength)),
            accessors[index]["byteOffset"] as? Int ?? 0,
            view["byteStride"] as? Int
        )
    }

    private func geometrySource(
        accessor index: Int, semantic: SCNGeometrySource.Semantic
    ) -> SCNGeometrySource? {
        guard let (data, offset, stride) = accessorData(index),
              let accessor = accessors.indices.contains(index) ? accessors[index] : nil,
              let count = accessor["count"] as? Int,
              accessor["componentType"] as? Int == 5126        // float32 only
        else { return nil }
        let components = accessor["type"] as? String == "VEC2" ? 2 : 3
        return SCNGeometrySource(
            data: data,
            semantic: semantic,
            vectorCount: count,
            usesFloatComponents: true,
            componentsPerVector: components,
            bytesPerComponent: 4,
            dataOffset: offset,
            dataStride: stride ?? components * 4
        )
    }

    private func element(_ index: Int?) -> SCNGeometryElement? {
        guard let index, let (data, offset, _) = accessorData(index),
              let accessor = accessors.indices.contains(index) ? accessors[index] : nil,
              let count = accessor["count"] as? Int,
              let componentType = accessor["componentType"] as? Int
        else { return nil }

        let payload = data.subdata(in: offset..<data.count)
        switch componentType {
        case 5123:                                             // uint16
            return SCNGeometryElement(
                data: payload.prefix(count * 2), primitiveType: .triangles,
                primitiveCount: count / 3, bytesPerIndex: 2
            )
        case 5125:                                             // uint32
            return SCNGeometryElement(
                data: payload.prefix(count * 4), primitiveType: .triangles,
                primitiveCount: count / 3, bytesPerIndex: 4
            )
        case 5121:                                             // uint8, widened to 16
            var widened = [UInt16](repeating: 0, count: count)
            for i in 0..<min(count, payload.count) { widened[i] = UInt16(payload[i]) }
            return SCNGeometryElement(
                data: widened.withUnsafeBufferPointer { Data(buffer: $0) },
                primitiveType: .triangles, primitiveCount: count / 3, bytesPerIndex: 2
            )
        default:
            return nil
        }
    }

    private func material(_ index: Int?) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(white: 0.75, alpha: 1)
        material.roughness.contents = 0.55
        material.metalness.contents = 0.05

        guard let index, materials.indices.contains(index),
              let pbr = materials[index]["pbrMetallicRoughness"] as? [String: Any]
        else { return material }

        if let factor = pbr["baseColorFactor"] as? [Double], factor.count >= 3 {
            material.diffuse.contents = NSColor(
                red: factor[0], green: factor[1], blue: factor[2],
                alpha: factor.count > 3 ? factor[3] : 1
            )
        }
        if let image = embeddedImage(textureIndex:
            (pbr["baseColorTexture"] as? [String: Any])?["index"] as? Int
        ) {
            material.diffuse.contents = image
        }
        if let image = embeddedImage(textureIndex:
            (pbr["metallicRoughnessTexture"] as? [String: Any])?["index"] as? Int
        ) {
            // glTF packs roughness in green, metalness in blue.
            material.roughness.contents = image
            material.roughness.textureComponents = .green
            material.metalness.contents = image
            material.metalness.textureComponents = .blue
        } else {
            if let metallic = pbr["metallicFactor"] as? Double {
                material.metalness.contents = metallic
            }
            if let roughness = pbr["roughnessFactor"] as? Double {
                material.roughness.contents = roughness
            }
        }
        return material
    }

    private func embeddedImage(textureIndex: Int?) -> NSImage? {
        guard let textureIndex, textures.indices.contains(textureIndex),
              let imageIndex = textures[textureIndex]["source"] as? Int,
              images.indices.contains(imageIndex),
              let viewIndex = images[imageIndex]["bufferView"] as? Int,
              bufferViews.indices.contains(viewIndex)
        else { return nil }
        let view = bufferViews[viewIndex]
        let offset = view["byteOffset"] as? Int ?? 0
        let length = view["byteLength"] as? Int ?? 0
        guard offset + length <= bin.count else { return nil }
        return NSImage(data: bin.subdata(in: offset..<(offset + length)))
    }
}

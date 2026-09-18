import AppKit
import CoreFoundation
import Darwin
import ImageIO
import ModelIO
import SceneKit
import SceneKit.ModelIO
import SwiftUI

/// An interactive preview of a generated mesh: orbit with the mouse, scroll to zoom, with a
/// slow turntable so the result reads as 3D the moment it appears.
struct MeshViewer: NSViewRepresentable {
    var url: URL
    var link: MeshViewerLink?

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .clear
        link?.view = view
        context.coordinator.loadedURL = url
        load(url, into: view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        link?.view = view
        // Only a genuine file change reloads; any other state change passing through
        // here would otherwise reset the camera the user has carefully posed.
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
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
        guard floatRadius.isFinite, floatRadius > 0,
              center.x.isFinite, center.y.isFinite, center.z.isFinite else { return }
        let radius = CGFloat(floatRadius)
        let camera = SCNCamera()
        camera.zNear = Double(radius) * 0.01
        camera.zFar = Double(radius) * 20
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let distance = radius * 2.4
        let cameraY = CGFloat(center.y) + radius * 0.55
        let cameraZ = CGFloat(center.z) + distance
        guard distance.isFinite, cameraY.isFinite, cameraZ.isFinite,
              abs(distance) <= CGFloat(Float.greatestFiniteMagnitude),
              abs(cameraY) <= CGFloat(Float.greatestFiniteMagnitude),
              abs(cameraZ) <= CGFloat(Float.greatestFiniteMagnitude) else { return }
        cameraNode.position = SCNVector3(
            center.x,
            cameraY,
            cameraZ
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
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw LoadError.unreadable("GLB file could not be opened.")
        }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw LoadError.unreadable("GLB input must be a regular file.")
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize >= 20, fileSize <= UInt64(GLBSafetyLimits.fileBytes) else {
            throw LoadError.unreadable("GLB file size is outside the supported range.")
        }
        try handle.seek(toOffset: 0)

        var data = Data()
        data.reserveCapacity(Int(fileSize))
        while data.count <= GLBSafetyLimits.fileBytes {
            let remaining = GLBSafetyLimits.fileBytes + 1 - data.count
            let chunk = try handle.read(upToCount: min(1_048_576, remaining)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= GLBSafetyLimits.fileBytes else {
            throw LoadError.unreadable("GLB file exceeds the supported size.")
        }
        return try loadGLB(data: data)
    }

    /// Internal data entry point used by the focused parser tests. The URL path above applies
    /// the same byte budget before retaining a file in memory.
    static func loadGLB(data: Data) throws -> SCNScene {
        guard data.count >= 20, data.count <= GLBSafetyLimits.fileBytes,
              readUInt32(data, at: 0) == 0x4654_6C67,          // "glTF"
              readUInt32(data, at: 4) == 2,
              readUInt32(data, at: 8).flatMap(Int.init(exactly:)) == data.count
        else {
            throw LoadError.unreadable("Not a valid GLB 2 container.")
        }

        // Chunks: [length][type][payload]…, with JSON first and at most one BIN chunk.
        var offset = 12
        var chunkCount = 0
        var jsonData: Data?
        var binData: Data?
        while offset < data.count {
            chunkCount += 1
            guard chunkCount <= GLBSafetyLimits.chunks,
                  let headerEnd = checkedAdd(offset, 8), headerEnd <= data.count,
                  let rawLength = readUInt32(data, at: offset),
                  let length = Int(exactly: rawLength), length % 4 == 0,
                  let end = checkedAdd(headerEnd, length), end <= data.count,
                  let type = readUInt32(data, at: offset + 4)
            else {
                throw LoadError.unreadable("Invalid GLB chunk table.")
            }

            switch type {
            case 0x4E4F_534A:                                  // "JSON"
                guard jsonData == nil, offset == 12,
                      length <= GLBSafetyLimits.jsonBytes else {
                    throw LoadError.unreadable("Invalid GLB JSON chunk.")
                }
                jsonData = data.subdata(in: headerEnd..<end)
            case 0x004E_4942:                                  // "BIN\0"
                guard jsonData != nil, binData == nil else {
                    throw LoadError.unreadable("Invalid GLB BIN chunk.")
                }
                binData = data.subdata(in: headerEnd..<end)
            default:
                break                                           // glTF requires unknown chunks be ignored.
            }
            offset = end
        }

        guard offset == data.count, let jsonData else {
            throw LoadError.unreadable("No JSON chunk.")
        }
        try validateJSONStructure(jsonData)
        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw LoadError.unreadable("Invalid GLB JSON metadata.")
        }

        let parser = try GLBParser(root: root, bin: binData ?? Data())
        return try parser.buildScene()
    }

    private static func validateJSONStructure(_ data: Data) throws {
        var containers: [UInt8] = []
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {                        // backslash
                    escaped = true
                } else if byte == 0x22 {                        // quote
                    inString = false
                }
                continue
            }
            switch byte {
            case 0x22:
                inString = true
            case 0x7B, 0x5B:                                    // { [
                containers.append(byte)
                guard containers.count <= GLBSafetyLimits.jsonDepth else {
                    throw LoadError.unreadable("GLB JSON nesting is too deep.")
                }
            case 0x7D:                                          // }
                guard containers.popLast() == 0x7B else {
                    throw LoadError.unreadable("Invalid GLB JSON structure.")
                }
            case 0x5D:                                          // ]
                guard containers.popLast() == 0x5B else {
                    throw LoadError.unreadable("Invalid GLB JSON structure.")
                }
            default:
                break
            }
        }
        guard !inString, containers.isEmpty else {
            throw LoadError.unreadable("Invalid GLB JSON structure.")
        }
    }

    fileprivate static func checkedAdd(_ left: Int, _ right: Int) -> Int? {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? nil : value
    }

    fileprivate static func checkedMultiply(_ left: Int, _ right: Int) -> Int? {
        let (value, overflow) = left.multipliedReportingOverflow(by: right)
        return overflow ? nil : value
    }

    fileprivate static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, let end = checkedAdd(offset, 4), end <= data.count else { return nil }
        return data.withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
}

/// Deliberately generous operational ceilings. They are high enough for generated production
/// meshes, while making every allocation/traversal cost a function of a small, explicit budget.
enum GLBSafetyLimits {
    static let fileBytes = 512 * 1_024 * 1_024
    static let jsonBytes = 16 * 1_024 * 1_024
    static let jsonDepth = 64
    static let chunks = 32
    static let accessors = 65_536
    static let bufferViews = 65_536
    static let meshes = 20_000
    static let primitives = 20_000
    static let nodes = 20_000
    static let nodeDepth = 128
    static let childEdges = 50_000
    static let scenes = 1_024
    static let materials = 16_384
    static let textures = 16_384
    static let images = 16_384
    static let accessorElements = 50_000_000
    static let totalAccessorElements = 100_000_000
    static let retainedBufferViewBytes = 768 * 1_024 * 1_024
    static let geometryElementBytes = 512 * 1_024 * 1_024
    static let imageBytes = 64 * 1_024 * 1_024
    static let totalImageBytes = 256 * 1_024 * 1_024
    static let imageDimension = 16_384
    static let imagePixels = 64_000_000
    static let totalImagePixels = 128_000_000
    static let transformMagnitude = 1.0e12
}

/// The GLB subset parser. One instance per file; builds SCNGeometry per glTF primitive and
/// assembles the node tree with its transforms.
private final class GLBParser {
    let root: [String: Any]
    let bin: Data
    let accessors: [[String: Any]]
    let bufferViews: [[String: Any]]
    let meshes: [[String: Any]]
    let nodes: [[String: Any]]
    let scenes: [[String: Any]]
    let materials: [[String: Any]]
    let textures: [[String: Any]]
    let images: [[String: Any]]

    private var nodeChildren: [[Int]] = []
    private var selectedRootIndexes: [Int] = []
    private var geometryCache: [Int: [SCNGeometry]] = [:]
    private var geometrySourceCache: [GeometrySourceKey: (SCNGeometrySource, Int)] = [:]
    private var elementCache: [Int: (element: SCNGeometryElement, maximumIndex: UInt32)] = [:]
    private var bufferViewDataCache: [Int: Data] = [:]
    private var materialCache: [Int: SCNMaterial] = [:]
    private var imageCache: [Int: NSImage] = [:]
    private var validatedFloatAccessors: Set<Int> = []
    private var retainedBufferViewBytes = 0
    private var retainedElementBytes = 0
    private var processedImageBytes = 0
    private var decodedImagePixels = 0

    private struct GeometrySourceKey: Hashable {
        let accessor: Int
        let semantic: Int
    }

    init(root: [String: Any], bin: Data) throws {
        self.root = root
        self.bin = bin
        accessors = try Self.table(root, named: "accessors", maximum: GLBSafetyLimits.accessors)
        bufferViews = try Self.table(
            root, named: "bufferViews", maximum: GLBSafetyLimits.bufferViews
        )
        meshes = try Self.table(root, named: "meshes", maximum: GLBSafetyLimits.meshes)
        nodes = try Self.table(root, named: "nodes", maximum: GLBSafetyLimits.nodes)
        scenes = try Self.table(root, named: "scenes", maximum: GLBSafetyLimits.scenes)
        materials = try Self.table(
            root, named: "materials", maximum: GLBSafetyLimits.materials
        )
        textures = try Self.table(root, named: "textures", maximum: GLBSafetyLimits.textures)
        images = try Self.table(root, named: "images", maximum: GLBSafetyLimits.images)
        try validateMetadata()
    }

    func buildScene() throws -> SCNScene {
        let scene = SCNScene()
        var builtIndexes: Set<Int> = []
        var built = false
        for index in selectedRootIndexes {
            let node = try buildNode(index, depth: 1, builtIndexes: &builtIndexes)
            scene.rootNode.addChildNode(node)
            built = true
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

    private func buildNode(
        _ index: Int, depth: Int, builtIndexes: inout Set<Int>
    ) throws -> SCNNode {
        guard depth <= GLBSafetyLimits.nodeDepth, nodes.indices.contains(index),
              builtIndexes.insert(index).inserted else {
            throw MeshScene.LoadError.unreadable("Invalid or repeated GLB node graph.")
        }
        let source = nodes[index]
        let node = SCNNode()

        if let rawMatrix = source["matrix"] {
            let matrix = try numericArray(rawMatrix, named: "node matrix", count: 16)
            let values = matrix.map { CGFloat($0) }
            node.transform = SCNMatrix4(
                m11: values[0], m12: values[1], m13: values[2], m14: values[3],
                m21: values[4], m22: values[5], m23: values[6], m24: values[7],
                m31: values[8], m32: values[9], m33: values[10], m34: values[11],
                m41: values[12], m42: values[13], m43: values[14], m44: values[15]
            )
        } else {
            if let rawTranslation = source["translation"] {
                let translation = try numericArray(
                    rawTranslation, named: "node translation", count: 3
                )
                node.position = SCNVector3(translation[0], translation[1], translation[2])
            }
            if let rawRotation = source["rotation"] {
                let rotation = try quaternion(rawRotation)
                node.orientation = SCNQuaternion(
                    rotation[0], rotation[1], rotation[2], rotation[3]
                )
            }
            if let rawScale = source["scale"] {
                let scale = try numericArray(rawScale, named: "node scale", count: 3)
                node.scale = SCNVector3(scale[0], scale[1], scale[2])
            }
        }

        if let meshIndex = try optionalInteger(source["mesh"], named: "node mesh") {
            try attach(meshIndex: meshIndex, to: node)
        }
        for childIndex in nodeChildren[index] {
            let child = try buildNode(
                childIndex, depth: depth + 1, builtIndexes: &builtIndexes
            )
            node.addChildNode(child)
        }
        return node
    }

    private func attach(meshIndex: Int, to node: SCNNode) throws {
        guard meshes.indices.contains(meshIndex) else {
            throw MeshScene.LoadError.unreadable("GLB node references an invalid mesh.")
        }
        if let cached = geometryCache[meshIndex] {
            cached.forEach { node.addChildNode(SCNNode(geometry: $0)) }
            return
        }

        let primitives = try Self.dictionaryArray(
            meshes[meshIndex]["primitives"], named: "mesh primitives",
            maximum: GLBSafetyLimits.primitives
        )
        var geometries: [SCNGeometry] = []
        for primitive in primitives {
            if let geometry = try buildGeometry(primitive) {
                geometries.append(geometry)
                node.addChildNode(SCNNode(geometry: geometry))
            }
        }
        geometryCache[meshIndex] = geometries
    }

    private func buildGeometry(_ primitive: [String: Any]) throws -> SCNGeometry? {
        if let mode = try optionalInteger(primitive["mode"], named: "primitive mode"), mode != 4 {
            return nil                                             // This loader only supports triangles.
        }
        guard let rawAttributes = primitive["attributes"] as? [String: Any] else { return nil }
        guard rawAttributes.count <= 16 else {
            throw MeshScene.LoadError.unreadable("Too many GLB primitive attributes.")
        }
        guard let rawPositionIndex = rawAttributes["POSITION"] else { return nil }
        let positionIndex = try integer(rawPositionIndex, named: "POSITION accessor")

        var sources: [SCNGeometrySource] = []
        let (positions, vertexCount) = try geometrySource(
            accessor: positionIndex, semantic: .vertex, expectedType: "VEC3", cacheSlot: 0
        )
        sources.append(positions)
        if let rawNormalIndex = rawAttributes["NORMAL"] {
            let normalIndex = try integer(rawNormalIndex, named: "NORMAL accessor")
            let (normals, count) = try geometrySource(
                accessor: normalIndex, semantic: .normal, expectedType: "VEC3", cacheSlot: 1
            )
            guard count == vertexCount else {
                throw MeshScene.LoadError.unreadable("GLB attribute counts do not match.")
            }
            sources.append(normals)
        }
        if let rawUVIndex = rawAttributes["TEXCOORD_0"] {
            let uvIndex = try integer(rawUVIndex, named: "TEXCOORD_0 accessor")
            let (uvs, count) = try geometrySource(
                accessor: uvIndex, semantic: .texcoord, expectedType: "VEC2", cacheSlot: 2
            )
            guard count == vertexCount else {
                throw MeshScene.LoadError.unreadable("GLB attribute counts do not match.")
            }
            sources.append(uvs)
        }

        guard let index = try optionalInteger(primitive["indices"], named: "index accessor"),
              let element = try element(index, vertexCount: vertexCount) else { return nil }
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let materialIndex = try optionalInteger(primitive["material"], named: "material")
        geometry.materials = [try material(materialIndex)]
        return geometry
    }

    private struct AccessorSlice {
        let viewIndex: Int
        let relativeOffset: Int
        let offset: Int
        let stride: Int
        let count: Int
        let componentType: Int
        let type: String
        let elementBytes: Int
        let isInterleaved: Bool
    }

    private func accessorData(_ index: Int) throws -> AccessorSlice {
        guard accessors.indices.contains(index) else {
            throw MeshScene.LoadError.unreadable("GLB references an invalid accessor.")
        }
        let accessor = accessors[index]
        guard accessor["sparse"] == nil,
              let viewIndex = try optionalInteger(
                accessor["bufferView"], named: "accessor buffer view"
              ), bufferViews.indices.contains(viewIndex),
              let componentType = try optionalInteger(
                accessor["componentType"], named: "accessor component type"
              ), let type = accessor["type"] as? String,
              let count = try optionalInteger(accessor["count"], named: "accessor count"),
              count > 0, count <= GLBSafetyLimits.accessorElements,
              let componentBytes = Self.componentBytes(componentType),
              let componentCount = Self.componentCount(type),
              let elementBytes = Self.elementBytes(
                type: type, componentBytes: componentBytes, componentCount: componentCount
              )
        else {
            throw MeshScene.LoadError.unreadable("Invalid or unsupported GLB accessor.")
        }

        let view = bufferViews[viewIndex]
        let viewOffset = try integer(view["byteOffset"], named: "buffer view offset", default: 0)
        let viewLength = try integer(view["byteLength"], named: "buffer view length")
        let accessorOffset = try integer(
            accessor["byteOffset"], named: "accessor offset", default: 0
        )
        let rawStride = try optionalInteger(view["byteStride"], named: "buffer view stride")
        let stride = rawStride ?? elementBytes
        guard viewOffset >= 0, viewLength > 0, accessorOffset >= 0,
              accessorOffset % componentBytes == 0,
              stride >= elementBytes, stride <= 252,
              stride % componentBytes == 0,
              let viewEnd = MeshScene.checkedAdd(viewOffset, viewLength), viewEnd <= bin.count,
              let steps = MeshScene.checkedMultiply(count - 1, stride),
              let relativeEnd = MeshScene.checkedAdd(accessorOffset, steps),
              let accessorEnd = MeshScene.checkedAdd(relativeEnd, elementBytes),
              accessorEnd <= viewLength,
              let absoluteOffset = MeshScene.checkedAdd(viewOffset, accessorOffset)
        else {
            throw MeshScene.LoadError.unreadable("GLB accessor range is invalid.")
        }
        return AccessorSlice(
            viewIndex: viewIndex, relativeOffset: accessorOffset, offset: absoluteOffset,
            stride: stride, count: count,
            componentType: componentType, type: type, elementBytes: elementBytes,
            isInterleaved: rawStride != nil
        )
    }

    private func geometrySource(
        accessor index: Int, semantic: SCNGeometrySource.Semantic, expectedType: String,
        cacheSlot: Int
    ) throws -> (SCNGeometrySource, Int) {
        let key = GeometrySourceKey(accessor: index, semantic: cacheSlot)
        if let cached = geometrySourceCache[key] { return cached }
        let slice = try accessorData(index)
        guard slice.componentType == 5126, slice.type == expectedType,
              let components = Self.componentCount(expectedType) else {
            throw MeshScene.LoadError.unreadable("Unsupported GLB vertex attribute.")
        }
        try validateFiniteFloats(slice, accessorIndex: index, components: components)
        let data = try bufferViewData(slice.viewIndex)
        let source = SCNGeometrySource(
            data: data,
            semantic: semantic,
            vectorCount: slice.count,
            usesFloatComponents: true,
            componentsPerVector: components,
            bytesPerComponent: 4,
            dataOffset: slice.relativeOffset,
            dataStride: slice.stride
        )
        let result = (source, slice.count)
        geometrySourceCache[key] = result
        return result
    }

    private func element(_ index: Int, vertexCount: Int) throws -> SCNGeometryElement? {
        if let cached = elementCache[index] {
            guard cached.maximumIndex < UInt32(vertexCount) else {
                throw MeshScene.LoadError.unreadable("GLB index is outside the vertex buffer.")
            }
            return cached.element
        }
        let slice = try accessorData(index)
        guard slice.type == "SCALAR", !slice.isInterleaved,
              slice.count % 3 == 0 else {
            throw MeshScene.LoadError.unreadable("Invalid GLB triangle index accessor.")
        }
        let width: Int
        switch slice.componentType {
        case 5121: width = 1
        case 5123: width = 2
        case 5125: width = 4
        default: return nil
        }
        guard let widenedBytes = MeshScene.checkedMultiply(slice.count, 2) else {
            throw MeshScene.LoadError.unreadable("Invalid GLB index count.")
        }
        guard slice.stride == width,
              let byteCount = MeshScene.checkedMultiply(slice.count, width),
              let end = MeshScene.checkedAdd(slice.offset, byteCount), end <= bin.count,
              let retainedBytes = MeshScene.checkedAdd(
                retainedElementBytes, slice.componentType == 5121 ? widenedBytes : byteCount
              ), retainedBytes <= GLBSafetyLimits.geometryElementBytes else {
            throw MeshScene.LoadError.unreadable("Invalid GLB index range.")
        }
        let payload = bin.subdata(in: slice.offset..<end)
        let maximumIndex = try validateIndices(
            payload, count: slice.count, width: width, vertexCount: vertexCount
        )

        let element: SCNGeometryElement
        switch slice.componentType {
        case 5123:                                             // uint16
            element = SCNGeometryElement(
                data: payload, primitiveType: .triangles,
                primitiveCount: slice.count / 3, bytesPerIndex: 2
            )
        case 5125:                                             // uint32
            element = SCNGeometryElement(
                data: payload, primitiveType: .triangles,
                primitiveCount: slice.count / 3, bytesPerIndex: 4
            )
        case 5121:                                             // uint8, widened to 16
            var widened = [UInt16](repeating: 0, count: slice.count)
            for i in widened.indices { widened[i] = UInt16(payload[i]).littleEndian }
            element = SCNGeometryElement(
                data: widened.withUnsafeBufferPointer { Data(buffer: $0) },
                primitiveType: .triangles, primitiveCount: slice.count / 3, bytesPerIndex: 2
            )
        default:
            return nil
        }
        retainedElementBytes = retainedBytes
        elementCache[index] = (element, maximumIndex)
        return element
    }

    private func material(_ index: Int?) throws -> SCNMaterial {
        if let index, let cached = materialCache[index] { return cached }
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(white: 0.75, alpha: 1)
        material.roughness.contents = 0.55
        material.metalness.contents = 0.05

        guard let index, materials.indices.contains(index),
              let pbr = materials[index]["pbrMetallicRoughness"] as? [String: Any]
        else { return material }

        if let rawFactor = pbr["baseColorFactor"] {
            let factor = try unitArray(rawFactor, named: "base color", counts: 3...4)
            material.diffuse.contents = NSColor(
                red: factor[0], green: factor[1], blue: factor[2],
                alpha: factor.count > 3 ? factor[3] : 1
            )
        }
        let baseColorTexture = try textureIndex(
            pbr["baseColorTexture"], named: "base color texture"
        )
        if let image = try embeddedImage(textureIndex: baseColorTexture) {
            material.diffuse.contents = image
        }
        let metallicRoughnessTexture = try textureIndex(
            pbr["metallicRoughnessTexture"], named: "metallic roughness texture"
        )
        if let image = try embeddedImage(textureIndex: metallicRoughnessTexture) {
            // glTF packs roughness in green, metalness in blue.
            material.roughness.contents = image
            material.roughness.textureComponents = .green
            material.metalness.contents = image
            material.metalness.textureComponents = .blue
        } else {
            if pbr["metallicFactor"] != nil {
                let metallic = try unitNumber(pbr["metallicFactor"], named: "metallic factor")
                material.metalness.contents = metallic
            }
            if pbr["roughnessFactor"] != nil {
                let roughness = try unitNumber(pbr["roughnessFactor"], named: "roughness factor")
                material.roughness.contents = roughness
            }
        }
        materialCache[index] = material
        return material
    }

    private func embeddedImage(textureIndex: Int?) throws -> NSImage? {
        guard let textureIndex else { return nil }
        guard textures.indices.contains(textureIndex),
              let imageIndex = try optionalInteger(
                textures[textureIndex]["source"], named: "texture source"
              ), images.indices.contains(imageIndex) else {
            throw MeshScene.LoadError.unreadable("GLB texture reference is invalid.")
        }
        if let cached = imageCache[imageIndex] { return cached }
        guard let viewIndex = try optionalInteger(
            images[imageIndex]["bufferView"], named: "image buffer view"
        ), bufferViews.indices.contains(viewIndex) else {
            return nil                                             // External images are unsupported.
        }
        let view = bufferViews[viewIndex]
        let offset = try integer(view["byteOffset"], named: "image offset", default: 0)
        let length = try integer(view["byteLength"], named: "image length")
        guard offset >= 0, length > 0, length <= GLBSafetyLimits.imageBytes,
              let end = MeshScene.checkedAdd(offset, length), end <= bin.count,
              let totalBytes = MeshScene.checkedAdd(processedImageBytes, length),
              totalBytes <= GLBSafetyLimits.totalImageBytes else {
            throw MeshScene.LoadError.unreadable("GLB image range is invalid.")
        }
        let data = bin.subdata(in: offset..<end)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        else {
            throw MeshScene.LoadError.unreadable("GLB embedded image is invalid.")
        }
        let metadata = properties as NSDictionary
        guard let width = Self.integerValue(metadata[kCGImagePropertyPixelWidth]),
              let height = Self.integerValue(metadata[kCGImagePropertyPixelHeight]),
              width > 0, height > 0,
              width <= GLBSafetyLimits.imageDimension,
              height <= GLBSafetyLimits.imageDimension,
              let pixels = MeshScene.checkedMultiply(width, height),
              pixels <= GLBSafetyLimits.imagePixels,
              let totalPixels = MeshScene.checkedAdd(decodedImagePixels, pixels),
              totalPixels <= GLBSafetyLimits.totalImagePixels,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              decoded.width == width, decoded.height == height
        else {
            throw MeshScene.LoadError.unreadable("GLB embedded image exceeds safe limits.")
        }
        decodedImagePixels = totalPixels
        processedImageBytes = totalBytes
        let image = NSImage(cgImage: decoded, size: NSSize(width: width, height: height))
        imageCache[imageIndex] = image
        return image
    }

    // MARK: Validation

    private func validateMetadata() throws {
        try validateBufferViews()
        try validateAccessors()
        try validateMeshes()
        try validateNodeGraph()
        try validateScenes()
    }

    private func validateBufferViews() throws {
        for view in bufferViews {
            let buffer = try integer(view["buffer"], named: "buffer view buffer", default: 0)
            let offset = try integer(view["byteOffset"], named: "buffer view offset", default: 0)
            let length = try integer(view["byteLength"], named: "buffer view length")
            let stride = try optionalInteger(view["byteStride"], named: "buffer view stride")
            guard buffer == 0, offset >= 0, length > 0,
                  stride.map({ (4...252).contains($0) && $0 % 4 == 0 }) ?? true,
                  let end = MeshScene.checkedAdd(offset, length), end <= bin.count else {
                throw MeshScene.LoadError.unreadable("Invalid GLB buffer view.")
            }
        }
    }

    private func validateAccessors() throws {
        var totalElements = 0
        for (index, accessor) in accessors.enumerated() {
            guard let count = try optionalInteger(accessor["count"], named: "accessor count"),
                  count > 0, count <= GLBSafetyLimits.accessorElements,
                  let total = MeshScene.checkedAdd(totalElements, count),
                  total <= GLBSafetyLimits.totalAccessorElements else {
                throw MeshScene.LoadError.unreadable("GLB accessor count exceeds safe limits.")
            }
            totalElements = total
            _ = try accessorData(index)                         // Validates offset/stride/range.
        }
    }

    private func validateMeshes() throws {
        var primitiveCount = 0
        for mesh in meshes {
            let primitives = try Self.dictionaryArray(
                mesh["primitives"], named: "mesh primitives",
                maximum: GLBSafetyLimits.primitives
            )
            guard let newCount = MeshScene.checkedAdd(primitiveCount, primitives.count),
                  newCount <= GLBSafetyLimits.primitives else {
                throw MeshScene.LoadError.unreadable("Too many GLB mesh primitives.")
            }
            primitiveCount = newCount
            for primitive in primitives {
                guard let attributes = primitive["attributes"] as? [String: Any],
                      attributes.count <= 16 else {
                    throw MeshScene.LoadError.unreadable("Invalid GLB primitive attributes.")
                }
                for value in attributes.values {
                    let index = try integer(value, named: "attribute accessor")
                    guard accessors.indices.contains(index) else {
                        throw MeshScene.LoadError.unreadable("Invalid GLB attribute accessor.")
                    }
                }
                if let index = try optionalInteger(primitive["indices"], named: "index accessor"),
                   !accessors.indices.contains(index) {
                    throw MeshScene.LoadError.unreadable("Invalid GLB index accessor.")
                }
                if let index = try optionalInteger(primitive["material"], named: "material"),
                   !materials.indices.contains(index) {
                    throw MeshScene.LoadError.unreadable("Invalid GLB material reference.")
                }
            }
        }
    }

    private func validateNodeGraph() throws {
        var incoming = [Int](repeating: 0, count: nodes.count)
        nodeChildren = []
        nodeChildren.reserveCapacity(nodes.count)
        var edgeCount = 0

        for node in nodes {
            if node["matrix"] != nil {
                _ = try numericArray(node["matrix"], named: "node matrix", count: 16)
                guard node["translation"] == nil, node["rotation"] == nil, node["scale"] == nil else {
                    throw MeshScene.LoadError.unreadable("GLB node mixes matrix and TRS transforms.")
                }
            } else {
                if node["translation"] != nil {
                    _ = try numericArray(node["translation"], named: "node translation", count: 3)
                }
                if node["rotation"] != nil {
                    _ = try quaternion(node["rotation"])
                }
                if node["scale"] != nil {
                    _ = try numericArray(node["scale"], named: "node scale", count: 3)
                }
            }
            if let meshIndex = try optionalInteger(node["mesh"], named: "node mesh"),
               !meshes.indices.contains(meshIndex) {
                throw MeshScene.LoadError.unreadable("GLB node references an invalid mesh.")
            }

            let children = try integerArray(
                node["children"], named: "node children", maximum: GLBSafetyLimits.nodes
            )
            guard Set(children).count == children.count,
                  let totalEdges = MeshScene.checkedAdd(edgeCount, children.count),
                  totalEdges <= GLBSafetyLimits.childEdges else {
                throw MeshScene.LoadError.unreadable("GLB node graph exceeds safe limits.")
            }
            edgeCount = totalEdges
            for child in children {
                guard nodes.indices.contains(child) else {
                    throw MeshScene.LoadError.unreadable("GLB node references an invalid child.")
                }
                incoming[child] += 1
                guard incoming[child] == 1 else {
                    throw MeshScene.LoadError.unreadable("GLB node has multiple parents.")
                }
            }
            nodeChildren.append(children)
        }

        var states = [UInt8](repeating: 0, count: nodes.count)
        for index in nodes.indices where states[index] == 0 {
            try validateNode(index, depth: 1, states: &states)
        }
        selectedRootIndexes = nodes.indices.filter { incoming[$0] == 0 }
    }

    private func validateNode(_ index: Int, depth: Int, states: inout [UInt8]) throws {
        guard depth <= GLBSafetyLimits.nodeDepth else {
            throw MeshScene.LoadError.unreadable("GLB node graph is too deep.")
        }
        guard states[index] != 1 else {
            throw MeshScene.LoadError.unreadable("GLB node graph contains a cycle.")
        }
        if states[index] == 2 { return }
        states[index] = 1
        for child in nodeChildren[index] {
            try validateNode(child, depth: depth + 1, states: &states)
        }
        states[index] = 2
    }

    private func validateScenes() throws {
        guard !scenes.isEmpty else {
            if root["scene"] != nil {
                throw MeshScene.LoadError.unreadable("GLB default scene has no scene table.")
            }
            return
        }
        let sceneIndex = try integer(root["scene"], named: "default scene", default: 0)
        guard scenes.indices.contains(sceneIndex) else {
            throw MeshScene.LoadError.unreadable("GLB default scene is invalid.")
        }

        var totalRoots = 0
        for scene in scenes {
            let roots = try integerArray(
                scene["nodes"], named: "scene nodes", maximum: GLBSafetyLimits.nodes
            )
            guard let newTotal = MeshScene.checkedAdd(totalRoots, roots.count),
                  newTotal <= GLBSafetyLimits.childEdges,
                  Set(roots).count == roots.count,
                  roots.allSatisfy({ nodes.indices.contains($0) }) else {
                throw MeshScene.LoadError.unreadable("GLB scene node list is invalid.")
            }
            totalRoots = newTotal
        }

        let requested = try integerArray(
            scenes[sceneIndex]["nodes"], named: "scene nodes", maximum: GLBSafetyLimits.nodes
        )
        if !requested.isEmpty {
            let naturalRoots = Set(selectedRootIndexes)
            guard requested.allSatisfy(naturalRoots.contains) else {
                throw MeshScene.LoadError.unreadable("GLB scene repeats a child node as a root.")
            }
            selectedRootIndexes = requested
        }
    }

    private func validateFiniteFloats(
        _ slice: AccessorSlice, accessorIndex: Int, components: Int
    ) throws {
        if validatedFloatAccessors.contains(accessorIndex) { return }
        for vector in 0..<slice.count {
            guard let step = MeshScene.checkedMultiply(vector, slice.stride),
                  let base = MeshScene.checkedAdd(slice.offset, step) else {
                throw MeshScene.LoadError.unreadable("GLB vertex range overflowed.")
            }
            for component in 0..<components {
                guard let byteOffset = MeshScene.checkedAdd(base, component * 4),
                      let bits = MeshScene.readUInt32(bin, at: byteOffset) else {
                    throw MeshScene.LoadError.unreadable("GLB vertex data is truncated.")
                }
                let value = Float(bitPattern: bits)
                guard value.isFinite, abs(Double(value)) <= GLBSafetyLimits.transformMagnitude else {
                    throw MeshScene.LoadError.unreadable("GLB vertex data is not finite or bounded.")
                }
            }
        }
        validatedFloatAccessors.insert(accessorIndex)
    }

    private func validateIndices(
        _ data: Data, count: Int, width: Int, vertexCount: Int
    ) throws -> UInt32 {
        var maximumIndex: UInt32 = 0
        for index in 0..<count {
            let value: UInt32
            switch width {
            case 1:
                value = UInt32(data[index])
            case 2:
                let offset = index * 2
                value = UInt32(data.withUnsafeBytes { bytes in
                    UInt16(littleEndian: bytes.loadUnaligned(
                        fromByteOffset: offset, as: UInt16.self
                    ))
                })
            case 4:
                let offset = index * 4
                value = data.withUnsafeBytes { bytes in
                    UInt32(littleEndian: bytes.loadUnaligned(
                        fromByteOffset: offset, as: UInt32.self
                    ))
                }
            default:
                throw MeshScene.LoadError.unreadable("Unsupported GLB index width.")
            }
            guard value < UInt32(vertexCount) else {
                throw MeshScene.LoadError.unreadable("GLB index is outside the vertex buffer.")
            }
            maximumIndex = max(maximumIndex, value)
        }
        return maximumIndex
    }

    private func bufferViewData(_ index: Int) throws -> Data {
        if let cached = bufferViewDataCache[index] { return cached }
        guard bufferViews.indices.contains(index) else {
            throw MeshScene.LoadError.unreadable("GLB references an invalid buffer view.")
        }
        let view = bufferViews[index]
        let offset = try integer(view["byteOffset"], named: "buffer view offset", default: 0)
        let length = try integer(view["byteLength"], named: "buffer view length")
        guard let end = MeshScene.checkedAdd(offset, length), end <= bin.count,
              let retained = MeshScene.checkedAdd(retainedBufferViewBytes, length),
              retained <= GLBSafetyLimits.retainedBufferViewBytes else {
            throw MeshScene.LoadError.unreadable("GLB retained geometry data exceeds safe limits.")
        }
        let data = bin.subdata(in: offset..<end)
        retainedBufferViewBytes = retained
        bufferViewDataCache[index] = data
        return data
    }

    private func numericArray(_ raw: Any?, named name: String, count: Int) throws -> [Double] {
        guard let values = raw as? [Any], values.count == count else {
            throw MeshScene.LoadError.unreadable("Invalid GLB \(name).")
        }
        return try values.map {
            let value = try number($0, named: name)
            guard abs(value) <= GLBSafetyLimits.transformMagnitude,
                  Float(value).isFinite else {
                throw MeshScene.LoadError.unreadable("GLB \(name) is outside the supported range.")
            }
            return value
        }
    }

    private func unitArray(
        _ raw: Any?, named name: String, counts: ClosedRange<Int>
    ) throws -> [Double] {
        guard let values = raw as? [Any], counts.contains(values.count) else {
            throw MeshScene.LoadError.unreadable("Invalid GLB \(name).")
        }
        return try values.map { try unitNumber($0, named: name) }
    }

    private func quaternion(_ raw: Any?) throws -> [Double] {
        let values = try numericArray(raw, named: "node rotation", count: 4)
        let squaredLength = values.reduce(0) { $0 + $1 * $1 }
        guard squaredLength.isFinite, (0.5...1.5).contains(squaredLength) else {
            throw MeshScene.LoadError.unreadable("GLB node rotation is not a unit quaternion.")
        }
        return values
    }

    private func unitNumber(_ raw: Any?, named name: String) throws -> Double {
        let value = try number(raw, named: name)
        guard (0...1).contains(value) else {
            throw MeshScene.LoadError.unreadable("GLB \(name) must be between zero and one.")
        }
        return value
    }

    private func textureIndex(_ raw: Any?, named name: String) throws -> Int? {
        guard raw != nil else { return nil }
        guard let texture = raw as? [String: Any] else {
            throw MeshScene.LoadError.unreadable("Invalid GLB \(name).")
        }
        return try optionalInteger(texture["index"], named: name)
    }

    private func number(_ raw: Any?, named name: String) throws -> Double {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            throw MeshScene.LoadError.unreadable("Invalid GLB \(name).")
        }
        return number.doubleValue
    }

    private func integer(_ raw: Any?, named name: String, default fallback: Int? = nil) throws -> Int {
        if raw == nil, let fallback { return fallback }
        return try integer(raw, named: name)
    }

    private func integer(_ raw: Any?, named name: String) throws -> Int {
        guard let value = Self.integerValue(raw) else {
            throw MeshScene.LoadError.unreadable("Invalid GLB \(name).")
        }
        return value
    }

    private func optionalInteger(_ raw: Any?, named name: String) throws -> Int? {
        guard raw != nil else { return nil }
        return try integer(raw, named: name)
    }

    private func integerArray(
        _ raw: Any?, named name: String, maximum: Int
    ) throws -> [Int] {
        guard raw != nil else { return [] }
        guard let values = raw as? [Any], values.count <= maximum else {
            throw MeshScene.LoadError.unreadable("Invalid or oversized GLB \(name).")
        }
        return try values.map { try integer($0, named: name) }
    }

    private static func table(
        _ root: [String: Any], named name: String, maximum: Int
    ) throws -> [[String: Any]] {
        guard root[name] != nil else { return [] }
        return try dictionaryArray(root[name], named: name, maximum: maximum)
    }

    private static func dictionaryArray(
        _ raw: Any?, named name: String, maximum: Int
    ) throws -> [[String: Any]] {
        guard let values = raw as? [Any], values.count <= maximum else {
            throw MeshScene.LoadError.unreadable("Invalid or oversized GLB \(name) table.")
        }
        return try values.map {
            guard let dictionary = $0 as? [String: Any] else {
                throw MeshScene.LoadError.unreadable("Invalid GLB \(name) entry.")
            }
            return dictionary
        }
    }

    private static func integerValue(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return raw as? Int
    }

    private static func componentBytes(_ componentType: Int) -> Int? {
        switch componentType {
        case 5120, 5121: return 1
        case 5122, 5123: return 2
        case 5125, 5126: return 4
        default: return nil
        }
    }

    private static func componentCount(_ type: String) -> Int? {
        switch type {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4", "MAT2": return 4
        case "MAT3": return 9
        case "MAT4": return 16
        default: return nil
        }
    }

    private static func elementBytes(
        type: String, componentBytes: Int, componentCount: Int
    ) -> Int? {
        // Matrix columns whose raw width is not 4-byte aligned include column padding in glTF.
        if type == "MAT2" || type == "MAT3" || type == "MAT4" {
            let columns = type == "MAT2" ? 2 : (type == "MAT3" ? 3 : 4)
            let rows = columns
            guard let columnBytes = MeshScene.checkedMultiply(rows, componentBytes) else { return nil }
            let alignedColumnBytes = (columnBytes + 3) & ~3
            return MeshScene.checkedMultiply(columns, alignedColumnBytes)
        }
        return MeshScene.checkedMultiply(componentBytes, componentCount)
    }
}

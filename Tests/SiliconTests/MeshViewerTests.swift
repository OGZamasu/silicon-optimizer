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

    private func triangleFixture() -> (root: [String: Any], bin: Data) {
        var bin = Data()
        for value: Float in [
            0, 0, 0,
            1, 0, 0,
            0, 1, 0,
        ] {
            appendUInt32(value.bitPattern, to: &bin)
        }
        for value: UInt16 in [0, 1, 2] {
            appendUInt16(value, to: &bin)
        }

        let root: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 36],
                ["buffer": 0, "byteOffset": 36, "byteLength": 6],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"],
                ["bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"],
            ],
            "meshes": [[
                "primitives": [["attributes": ["POSITION": 0], "indices": 1]],
            ]],
            "nodes": [["mesh": 0]],
            "scenes": [["nodes": [0]]],
            "scene": 0,
        ]
        return (root, bin)
    }

    private func parse(_ root: [String: Any], bin: Data) throws -> SCNScene {
        try MeshScene.loadGLB(data: makeGLB(root: root, bin: bin))
    }

    @Test func loadsASyntheticTriangleGLB() throws {
        let fixture = triangleFixture()
        let scene = try parse(fixture.root, bin: fixture.bin)
        #expect(geometryCount(scene.rootNode) == 1)
    }

    @Test func acceptsBoundedInterleavedVertexData() throws {
        var bin = Data()
        for vector: [Float] in [[0, 0, 0], [1, 0, 0], [0, 1, 0]] {
            for value in vector { appendUInt32(value.bitPattern, to: &bin) }
            appendUInt32(0xA5A5_A5A5, to: &bin) // an ignored four-byte interleave field
        }
        for value: UInt16 in [0, 1, 2] { appendUInt16(value, to: &bin) }

        var fixture = triangleFixture()
        fixture.bin = bin
        var views = fixture.root["bufferViews"] as! [[String: Any]]
        views[0] = ["buffer": 0, "byteOffset": 0, "byteLength": 48, "byteStride": 16]
        views[1] = ["buffer": 0, "byteOffset": 48, "byteLength": 6]
        fixture.root["bufferViews"] = views
        fixture.root["buffers"] = [["byteLength": bin.count]]

        let scene = try parse(fixture.root, bin: fixture.bin)
        #expect(geometryCount(scene.rootNode) == 1)
    }

    @Test func preservesMeshInstancingAndHierarchyWithoutASceneTable() throws {
        let fixture = triangleFixture()
        var instancedRoot = fixture.root
        instancedRoot["nodes"] = [
            ["mesh": 0, "rotation": [0.0, 0.0, 0.0, 1.0]],
            ["mesh": 0],
        ]
        instancedRoot["scenes"] = [["nodes": [0, 1]]]
        let instanced = try parse(instancedRoot, bin: fixture.bin)
        #expect(geometryCount(instanced.rootNode) == 2)

        var hierarchyRoot = fixture.root
        hierarchyRoot["nodes"] = [["children": [1]], ["mesh": 0]]
        hierarchyRoot.removeValue(forKey: "scenes")
        hierarchyRoot.removeValue(forKey: "scene")
        let hierarchy = try parse(hierarchyRoot, bin: fixture.bin)
        #expect(geometryCount(hierarchy.rootNode) == 1)
    }

    @Test func loadsABoundedEmbeddedTexture() throws {
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        var fixture = triangleFixture()
        while fixture.bin.count % 4 != 0 { fixture.bin.append(0) }
        let imageOffset = fixture.bin.count
        fixture.bin.append(png)

        var views = fixture.root["bufferViews"] as! [[String: Any]]
        views.append(["buffer": 0, "byteOffset": imageOffset, "byteLength": png.count])
        fixture.root["bufferViews"] = views
        fixture.root["buffers"] = [["byteLength": fixture.bin.count]]
        fixture.root["images"] = [["bufferView": 2, "mimeType": "image/png"]]
        fixture.root["textures"] = [["source": 0]]
        fixture.root["materials"] = [[
            "pbrMetallicRoughness": ["baseColorTexture": ["index": 0]],
        ]]
        var meshes = fixture.root["meshes"] as! [[String: Any]]
        meshes[0] = [
            "primitives": [["attributes": ["POSITION": 0], "indices": 1, "material": 0]],
        ]
        fixture.root["meshes"] = meshes

        let scene = try parse(fixture.root, bin: fixture.bin)
        #expect(geometryCount(scene.rootNode) == 1)
    }

    @Test func rejectsNegativeAndOverflowingBufferRanges() throws {
        let fixture = triangleFixture()
        var negativeRoot = fixture.root
        var negativeViews = negativeRoot["bufferViews"] as! [[String: Any]]
        negativeViews[0]["byteOffset"] = -1
        negativeRoot["bufferViews"] = negativeViews
        #expect(throws: MeshScene.LoadError.self) {
            _ = try parse(negativeRoot, bin: fixture.bin)
        }

        var overflowRoot = fixture.root
        var overflowViews = overflowRoot["bufferViews"] as! [[String: Any]]
        overflowViews[0]["byteOffset"] = Int.max
        overflowViews[0]["byteLength"] = Int.max
        overflowRoot["bufferViews"] = overflowViews
        #expect(throws: MeshScene.LoadError.self) {
            _ = try parse(overflowRoot, bin: fixture.bin)
        }
    }

    @Test func rejectsOversizedAndInconsistentAccessorCounts() throws {
        let fixture = triangleFixture()
        var oversizedRoot = fixture.root
        var oversizedAccessors = oversizedRoot["accessors"] as! [[String: Any]]
        oversizedAccessors[0]["count"] = GLBSafetyLimits.accessorElements + 1
        oversizedRoot["accessors"] = oversizedAccessors
        #expect(throws: MeshScene.LoadError.self) {
            _ = try parse(oversizedRoot, bin: fixture.bin)
        }

        var truncatedRoot = fixture.root
        var truncatedAccessors = truncatedRoot["accessors"] as! [[String: Any]]
        truncatedAccessors[1]["count"] = 6
        truncatedRoot["accessors"] = truncatedAccessors
        #expect(throws: MeshScene.LoadError.self) {
            _ = try parse(truncatedRoot, bin: fixture.bin)
        }
    }

    @Test func rejectsInvalidStrideAndBooleanNumericMetadata() throws {
        let fixture = triangleFixture()
        var strideRoot = fixture.root
        var views = strideRoot["bufferViews"] as! [[String: Any]]
        views[0]["byteStride"] = Int.max
        strideRoot["bufferViews"] = views
        #expect(throws: MeshScene.LoadError.self) {
            _ = try parse(strideRoot, bin: fixture.bin)
        }

        var booleanRoot = fixture.root
        var accessors = booleanRoot["accessors"] as! [[String: Any]]
        accessors[0]["count"] = true
        booleanRoot["accessors"] = accessors
        #expect(throws: MeshScene.LoadError.self) {
            _ = try parse(booleanRoot, bin: fixture.bin)
        }
    }

    @Test func rejectsNonFiniteVerticesAndExtremeTransforms() throws {
        var nonFinite = triangleFixture()
        var infinity = Float.infinity.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &infinity) { bytes in
            nonFinite.bin.replaceSubrange(0..<4, with: bytes)
        }
        #expect(throws: MeshScene.LoadError.self) {
            _ = try parse(nonFinite.root, bin: nonFinite.bin)
        }

        let fixture = triangleFixture()
        var transformedRoot = fixture.root
        var nodes = transformedRoot["nodes"] as! [[String: Any]]
        nodes[0]["translation"] = [1.0e300, 0.0, 0.0]
        transformedRoot["nodes"] = nodes
        #expect(throws: MeshScene.LoadError.self) {
            _ = try parse(transformedRoot, bin: fixture.bin)
        }

        var invalidRotationRoot = fixture.root
        var rotatedNodes = invalidRotationRoot["nodes"] as! [[String: Any]]
        rotatedNodes[0]["rotation"] = [0.0, 0.0, 0.0, 0.0]
        invalidRotationRoot["nodes"] = rotatedNodes
        #expect(throws: MeshScene.LoadError.self) {
            _ = try parse(invalidRotationRoot, bin: fixture.bin)
        }

        var materialRoot = fixture.root
        materialRoot["materials"] = [[
            "pbrMetallicRoughness": ["baseColorFactor": [1.0e300, 0.0, 0.0, 1.0]],
        ]]
        var meshes = materialRoot["meshes"] as! [[String: Any]]
        meshes[0] = [
            "primitives": [["attributes": ["POSITION": 0], "indices": 1, "material": 0]],
        ]
        materialRoot["meshes"] = meshes
        #expect(throws: MeshScene.LoadError.self) {
            _ = try parse(materialRoot, bin: fixture.bin)
        }
    }

    @Test func rejectsOutOfRangeIndicesBeforeSceneKitConstruction() throws {
        var fixture = triangleFixture()
        var invalidIndex = UInt16(3).littleEndian
        Swift.withUnsafeBytes(of: &invalidIndex) { bytes in
            fixture.bin.replaceSubrange(40..<42, with: bytes)
        }
        #expect(throws: MeshScene.LoadError.self) {
            _ = try parse(fixture.root, bin: fixture.bin)
        }
    }

    @Test func rejectsCyclicAndRepeatedNodeGraphs() throws {
        let fixture = triangleFixture()
        var cyclicRoot = fixture.root
        cyclicRoot["nodes"] = [
            ["children": [1]],
            ["children": [0]],
        ]
        cyclicRoot["scenes"] = [["nodes": [0]]]
        #expect(throws: MeshScene.LoadError.self) {
            _ = try parse(cyclicRoot, bin: fixture.bin)
        }

        var repeatedRoot = fixture.root
        repeatedRoot["nodes"] = [
            ["children": [2]],
            ["children": [2]],
            ["mesh": 0],
        ]
        repeatedRoot["scenes"] = [["nodes": [0, 1]]]
        #expect(throws: MeshScene.LoadError.self) {
            _ = try parse(repeatedRoot, bin: fixture.bin)
        }
    }

    @Test func rejectsExcessiveGraphDepthAndNodeTables() throws {
        let fixture = triangleFixture()
        var deepRoot = fixture.root
        var nodes: [[String: Any]] = (0...GLBSafetyLimits.nodeDepth).map { index in
            index == GLBSafetyLimits.nodeDepth ? [:] : ["children": [index + 1]]
        }
        nodes[GLBSafetyLimits.nodeDepth]["mesh"] = 0
        deepRoot["nodes"] = nodes
        deepRoot["scenes"] = [["nodes": [0]]]
        #expect(throws: MeshScene.LoadError.self) {
            _ = try parse(deepRoot, bin: fixture.bin)
        }

        var wideRoot = fixture.root
        wideRoot["nodes"] = Array(
            repeating: [String: Any](), count: GLBSafetyLimits.nodes + 1
        )
        wideRoot["scenes"] = [["nodes": []]]
        #expect(throws: MeshScene.LoadError.self) {
            _ = try parse(wideRoot, bin: fixture.bin)
        }
    }

    @Test func rejectsExcessiveChunkCountsAndJSONDepth() throws {
        let fixture = triangleFixture()
        let chunks = Array(
            repeating: (UInt32(0x1234_5678), Data()), count: GLBSafetyLimits.chunks
        )
        let chunkHeavy = try makeGLB(root: fixture.root, bin: fixture.bin, extraChunks: chunks)
        #expect(throws: MeshScene.LoadError.self) {
            _ = try MeshScene.loadGLB(data: chunkHeavy)
        }

        let depth = GLBSafetyLimits.jsonDepth + 1
        let nestedJSON = Data(
            (String(repeating: "[", count: depth) + "0" +
             String(repeating: "]", count: depth)).utf8
        )
        let deeplyNested = makeGLB(json: nestedJSON, bin: Data())
        #expect(throws: MeshScene.LoadError.self) {
            _ = try MeshScene.loadGLB(data: deeplyNested)
        }
    }

    @Test func rejectsSparseFileBeyondTheByteBudgetWithoutReadingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mesh-viewer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("oversized.glb")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(GLBSafetyLimits.fileBytes) + 1)
        try handle.close()

        #expect(throws: MeshScene.LoadError.self) {
            _ = try MeshScene.load(url)
        }
    }

    /// A TRELLIS.2 output: textured, PBR, trimesh-exported.
    @Test func loadsATrellisGLB() throws {
        let url = ProcessInfo.processInfo.environment["SILICON_TEST_GLB"].map {
            URL(fileURLWithPath: $0)
        } ?? URL(fileURLWithPath: "/Volumes/T9/trellis2/test_shoe.glb")
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

    /// The non-GLB path remains delegated to Model I/O and receives the fallback material.
    @Test func loadsAnOBJWithAFallbackMaterial() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mesh-viewer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("triangle.obj")
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8).write(to: url)

        let scene = try MeshScene.load(url)
        #expect(geometryCount(scene.rootNode) > 0)
    }
}

private func appendUInt16(_ value: UInt16, to data: inout Data) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

private func appendChunk(type: UInt32, payload: Data, padding: UInt8, to body: inout Data) {
    var padded = payload
    while padded.count % 4 != 0 { padded.append(padding) }
    appendUInt32(UInt32(padded.count), to: &body)
    appendUInt32(type, to: &body)
    body.append(padded)
}

private func makeGLB(
    root: [String: Any], bin: Data,
    extraChunks: [(UInt32, Data)] = []
) throws -> Data {
    makeGLB(
        json: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
        bin: bin, extraChunks: extraChunks
    )
}

private func makeGLB(
    json: Data, bin: Data, extraChunks: [(UInt32, Data)] = []
) -> Data {
    var body = Data()
    appendChunk(type: 0x4E4F_534A, payload: json, padding: 0x20, to: &body)
    for chunk in extraChunks {
        appendChunk(type: chunk.0, payload: chunk.1, padding: 0, to: &body)
    }
    if !bin.isEmpty {
        appendChunk(type: 0x004E_4942, payload: bin, padding: 0, to: &body)
    }

    var result = Data()
    appendUInt32(0x4654_6C67, to: &result)
    appendUInt32(2, to: &result)
    appendUInt32(UInt32(12 + body.count), to: &result)
    result.append(body)
    return result
}

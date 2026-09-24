import Foundation
import Testing
@testable import SiliconMCP

/// Tool arguments arrive as JSON numbers, which are doubles, and most tools read them as
/// integers. A number past `Int`'s range used to trap in the conversion and take the whole
/// MCP bridge down with exit 133, whichever tool it was sent to.
@Suite("MCP integer arguments")
struct JSONValueIntegerTests {

    @Test func aNumberNoIntCanHoldIsNoNumber() throws {
        for value in [18_446_744_073_709_551_615.0, 1e20, -1e20, 9.3e18, -9.3e18,
                      .infinity, -.infinity, .nan] {
            #expect(JSONValue.number(value).intValue == nil, "\(value)")
        }
        // Inside the range nothing changes, fractions included.
        #expect(JSONValue.number(42).intValue == 42)
        #expect(JSONValue.number(3.9).intValue == 3)
        #expect(JSONValue.number(-2.5).intValue == -2)
        #expect(JSONValue.number(4_294_967_295).intValue == 4_294_967_295)
        #expect(JSONValue.string("7").intValue == 7)
    }

    /// The same arguments as they come off the wire, through the tools that read them.
    @Test func hugeRenderArgumentsReachTheToolsAsAbsent() throws {
        let line = #"{"seed":18446744073709551615,"steps":1e20,"width":-1e300,"#
            + #""texture_size":1024,"vertex_budget":1e19,"octree":256}"#
        let arguments = try JSONDecoder().decode(
            [String: JSONValue].self, from: Data(line.utf8)
        )

        let mesh = Tools.meshRequest(arguments)
        #expect(mesh.seed == nil)
        #expect(mesh.steps == nil)
        #expect(mesh.vertexBudget == nil)
        #expect(mesh.textureSize == 1024)
        #expect(mesh.octree == 256)

        let image = Tools.imageRequest(arguments)
        #expect(image.seed == nil)
        #expect(image.width == nil)
    }
}

import Foundation
import Testing
@testable import SiliconMCP

/// `list_models` filters by category in a query string, and category names are prose.
@Suite("MCP list_models query")
struct ListModelsQueryTests {

    /// Read back the way the control server reads it: `URLComponents` over the target,
    /// last value per name.
    static func query(_ path: String) throws -> [String: String] {
        let components = try #require(URLComponents(string: "http://localhost\(path)"))
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value }
        #expect(components.path == "/catalog")
        return query
    }

    /// "Small & Fast" is a real category. Escaped for a whole query string, its `&` split
    /// it in two and the Mac answered with the unfiltered catalog.
    @Test func aCategoryWithAnAmpersandArrivesWhole() throws {
        let path = Tools.catalogPath(["category": .string("Small & Fast")])
        #expect(try Self.query(path) == ["onlyRunnable": "true", "category": "Small & Fast"])
    }

    @Test func queryPunctuationInACategoryCannotAddOrReplaceParameters() throws {
        let category = "C++ = fast?#&onlyRunnable=false"
        let path = Tools.catalogPath([
            "category": .string(category), "only_runnable": .bool(true),
        ])
        #expect(try Self.query(path) == ["onlyRunnable": "true", "category": category])
        #expect(try Self.query(Tools.catalogPath(["only_runnable": .bool(false)]))
            == ["onlyRunnable": "false"])
    }
}

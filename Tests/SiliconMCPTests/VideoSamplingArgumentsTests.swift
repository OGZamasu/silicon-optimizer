import Testing
@testable import SiliconMCP

@Suite("MCP video sampling arguments")
struct VideoSamplingArgumentsTests {
    @Test func bothToolsAdvertiseTheSameBoundedOverrideAndSeed() throws {
        for name in ["generate_video", "queue_videos"] {
            let tool = try #require(Tools.all.first { $0.name == name })
            #expect(tool.properties["h3_steps"] == Tools.h3StepsProperty)
            #expect(tool.properties["seed"] != nil && tool.properties["h3_turbo"] != nil)
            #expect(!tool.required.contains("h3_steps"))
        }
    }

    @Test func omittedAndNullStepsAreAuto() throws {
        #expect(try Tools.videoSamplingArguments([:]).steps == nil)
        #expect(try Tools.videoSamplingArguments(["h3_steps": .null]).steps == nil)
        #expect(try Tools.videoSamplingArguments(["h3_turbo": .bool(true)]).turbo == true)
    }

    @Test func fullSamplingAcceptsExactlyIntegralCountsInRange() throws {
        for steps in [4, 9, 20, 30] {
            let result = try Tools.videoSamplingArguments(["h3_steps": .number(Double(steps)), "h3_turbo": .bool(false)])
            #expect(result.steps == steps && result.turbo == false)
        }
        let invalid: [JSONValue] = [.number(0), .number(3), .number(31), .number(20.5),
                                    .number(.infinity), .number(.nan), .number(1e30),
                                    .bool(true), .string("20"), .array([])]
        for value in invalid {
            #expect(throws: (any Error).self) {
                try Tools.videoSamplingArguments(["h3_steps": value, "h3_turbo": .bool(false)])
            }
        }
    }

    @Test func explicitStepsCannotInheritOrEnableTurbo() {
        #expect(throws: (any Error).self) { try Tools.videoSamplingArguments(["h3_steps": .number(30)]) }
        for value: JSONValue in [.bool(true), .number(0), .string("false"), .null] {
            #expect(throws: (any Error).self) {
                try Tools.videoSamplingArguments(["h3_steps": .number(30), "h3_turbo": value])
            }
        }
    }

    @Test func fixedSeedsForComparisonsAreNotCoerced() throws {
        #expect(try Tools.videoSeedArgument([:]) == nil)
        #expect(try Tools.videoSeedArgument(["seed": .number(42)]) == 42)
        #expect(try Tools.videoSeedArgument(["seed": .number(4294967295)]) == UInt32.max)
        for value: JSONValue in [.number(-1), .number(4294967296), .number(1.5), .string("42"), .bool(true)] {
            #expect(throws: (any Error).self) { try Tools.videoSeedArgument(["seed": value]) }
        }
    }
}

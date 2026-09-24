import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconMCP

/// `POST /mesh/plan` prices a model, a pipeline and a vertex budget — never the picture —
/// and `plan_3d` has no image argument at all. When the route started resolving a subject
/// the way a render does, every MCP plan became a 400.
@Suite("Planning a mesh")
struct MeshPlanRouteTests {

    @Test func aPlanNeedsNoPictureWhileARenderStillDoes() async throws {
        try await BuddyMediaFixture.withServer { fixture in
            // Byte for byte what the MCP bridge sends for `plan_3d` naming only a model.
            let planToolBody = String(
                decoding: try JSONEncoder().encode(
                    Tools.meshRequest(["model_id": .string("lato-2")])
                ),
                as: UTF8.self
            )
            #expect(try await fixture.local.status(
                "POST", "/mesh/plan", token: fixture.local.token, body: planToolBody
            ) == 200)
            #expect(await fixture.host.modelsAsked.last == "lato-2")
            // The empty path the bridge sends for "none" reaches the planner as none.
            #expect(await fixture.host.lastMeshImagePath == nil)

            // A paired device may ask for a plan too, with no subject to name.
            let paired = try await fixture.pair()
            #expect(try await fixture.phone.status(
                "POST", "/mesh/plan", token: paired.token, body: #"{"modelID":"trellis2-4b"}"#
            ) == 200)
            #expect(await fixture.host.modelsAsked.last == "trellis2-4b")

            // A render without a subject is still a 400, from either caller.
            #expect(try await fixture.local.status(
                "POST", "/mesh/generate", token: fixture.local.token, body: planToolBody
            ) == 400)
            #expect(try await fixture.phone.status(
                "POST", "/mesh/generate", token: paired.token, body: #"{"modelID":"trellis2-4b"}"#
            ) == 400)
            // And a device naming a path is refused on the plan route as before — a plan
            // that answered differently for a path would say whether the file exists.
            #expect(try await fixture.phone.status(
                "POST", "/mesh/plan", token: paired.token,
                body: #"{"modelID":"trellis2-4b","imagePath":"/etc/passwd"}"#
            ) == 400)
        }
    }
}

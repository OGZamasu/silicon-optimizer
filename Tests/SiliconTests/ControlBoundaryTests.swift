import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconUI

@Suite("Control API numeric boundaries")
@MainActor
struct ControlBoundaryTests {

    @Test func localOnlyImageRequestsCannotSelectAPairedNode() {
        #expect(!AppModel.shouldRouteImageRemotely(localOnly: true, hasCandidate: true))
        #expect(AppModel.shouldRouteImageRemotely(localOnly: false, hasCandidate: true))
        #expect(!AppModel.shouldRouteImageRemotely(localOnly: nil, hasCandidate: false))
    }

    @Test func languagePlanRejectsInvalidContextAndExpertDomains() async throws {
        let app = AppModel()
        let entry = try #require(ModelCatalog.all.first)
        for context in [0, -1, entry.maxContext + 1, Int.max] {
            await #expect(throws: ControlHostError.self) {
                _ = try await app.plan(.init(modelID: entry.id, contextLength: context))
            }
        }
        await #expect(throws: ControlHostError.self) {
            _ = try await app.plan(.init(modelID: entry.id, expertSlots: Int.max))
        }
    }

    @Test func imagePlanRejectsInvalidGeometryAndSteps() async {
        let app = AppModel()
        let invalid: [(Int?, Int?, Int?)] = [
            (0, 512, 4), (-1, 512, 4), (Int.max, 1, 4),
            (8192, 8192, 4), (512, 512, 0), (512, 512, Int.max),
        ]
        for (width, height, steps) in invalid {
            await #expect(throws: ControlHostError.self) {
                _ = try await app.planImage(.init(
                    prompt: "test", width: width, height: height, steps: steps
                ))
            }
        }
    }
}

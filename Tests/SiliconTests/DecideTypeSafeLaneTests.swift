import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

// MARK: - The plain typesafe lane, and the line it is billed to

/// `decide(provider: "typesafe")`, end to end against a loopback TypeSafe.
///
/// Driven through `AppModel.decideViaTypeSafe`, the function `decide` hands the request to,
/// with a real `JevService` pointed at a private store and a fake server. `decide` itself
/// cannot be driven here: `runtimeState` and `loadedModel` are settable only from
/// `AppModel.swift`, and the lane reads `JevService.shared`, which a suite running in
/// parallel cannot repoint. What is left in `decide` is one `await` and one call.
///
/// This exists because of a near miss. A mutation that billed this lane to `.calibration`
/// survived the suite during PR #41's review: the cascade's billing test could reach
/// `escalate`, and the `typesafe` lane's call was a separate copy that nothing pinned.
@Suite("Decide: the typesafe lane")
struct DecideTypeSafeLaneTests {

    private static let asked = ControlAPI.DecideRequest(
        state: .string("A customer was charged twice."),
        questions: jevQuestions,
        // An alias on purpose. The lane must send the pinned version, not what a tool call
        // asked for.
        model: "jev-latest",
        provider: "typesafe"
    )

    /// One request, on the pinned model, answered as a `DecideResponse`, and one call on the
    /// decide tool's ledger line and no other.
    @Test func oneRequestOnThePinnedModelBilledToTheDecideTool() async throws {
        let typeSafe = try CapturingServer { _ in jevAnswer }
        defer { typeSafe.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        await harness.configure(
            baseURL: URL(string: "http://127.0.0.1:\(typeSafe.port)")!, session: session
        )
        try await harness.enable()

        let response = try await AppModel.decideViaTypeSafe(Self.asked, using: harness.service)

        // The request: exactly one, to the decide route, carrying the pinned model rather
        // than the alias the caller named, with the state and the questions as given.
        #expect(typeSafe.requests.count == 1)
        let sent = try #require(
            try JSONSerialization.jsonObject(with: typeSafe.requests[0].body) as? [String: Any]
        )
        #expect(typeSafe.requests[0].path == "/v1/systemone")
        #expect(sent["model"] as? String == JevService.pinnedModel)
        #expect(sent["state"] as? String == "A customer was charged twice.")
        #expect(Set(((sent["questions"] as? [String: Any]) ?? [:]).keys) == ["refund"])

        // The answer, as the caller of `decide` receives it.
        #expect(response.model == JevService.pinnedModel)
        #expect(try response.noul("refund") == 0.93)
        #expect(response.usage.inputTokens == 1000)
        #expect(response.usage.outputTokens == 4)
        #expect(response.answers.count == 1)
        #expect(response.latencyMS != nil)
        #expect(response.sources == nil, "one lane answered, so there is nothing to attribute")

        // The ledger: one call, under the decide tool, and no other line touched — not
        // calibration's, which is the one the surviving mutation moved it to.
        let month = await harness.service.ledger().month()
        #expect(month.total.calls == 1)
        #expect(month.features["decideTool"]?.calls == 1)
        #expect(month.features["decideTool"]?.inputTokens == 1000)
        #expect(month.features["calibration"] == nil)
        #expect(Set(month.features.keys) == ["decideTool"])
        #expect(month.models == [JevService.pinnedModel: 1])

        // And it reached the file, which is what the budget reads on the next launch.
        let saved = JevLedger.load(from: harness.ledgerURL).month()
        #expect(saved.features["decideTool"]?.calls == 1)
    }

    /// With the decide tool off nothing is sent, nothing is billed, and the caller is told
    /// which switch is off — whatever the neighbouring switches say, and whatever the
    /// master switch says.
    @Test func withTheDecideToolOffNothingIsSent() async throws {
        let typeSafe = try untouchedServer("the decide tool is off")
        defer { typeSafe.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        await harness.configure(
            baseURL: URL(string: "http://127.0.0.1:\(typeSafe.port)")!, session: session
        )

        // Master switch on, the decide tool off. Calibration on, to show that a feature
        // being on for something else does not let this lane spend.
        try await harness.service.update { settings in
            settings.enabled = true
            settings.features[.decideTool] = false
            settings.features[.calibration] = true
        }
        await #expect(throws: JevError.disabled(.decideTool)) {
            try await AppModel.decideViaTypeSafe(Self.asked, using: harness.service)
        }

        // Master switch off, the decide tool on.
        try await harness.service.update { settings in
            settings.enabled = false
            settings.features[.decideTool] = true
        }
        await #expect(throws: JevError.disabled(.decideTool)) {
            try await AppModel.decideViaTypeSafe(Self.asked, using: harness.service)
        }

        #expect(typeSafe.requests.isEmpty)
        let month = await harness.service.ledger().month()
        #expect(month.total.calls == 0)
        #expect(month.features.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.ledgerURL.path), "a refusal wrote a ledger")
    }
}

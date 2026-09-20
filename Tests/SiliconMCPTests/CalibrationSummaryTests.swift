import Foundation
import SiliconControl
import Testing
@testable import SiliconMCP

/// What `get_status` and `calibrate_decisions` tell an agent about the cascade.
///
/// These lines are the only place an agent learns where the local lane stops being trusted,
/// so the thing that matters most is what they say when the stored floors are *not* the ones
/// running — which is the ordinary state of a Mac that has loaded a different model since.
@Suite("MCP calibration summary")
struct CalibrationSummaryTests {

    static func calibration(
        applies: Bool?, floors: ControlAPI.JevCalibration.Floors? = nil,
        inEffect: ControlAPI.JevCalibration.Floors? = nil,
        loaded: String? = nil, measured: Bool = true
    ) -> ControlAPI.JevCalibration {
        .init(
            modelID: "qwen-30b", modelName: "Qwen3-Coder 30B", jevModel: "jev-1.13.0",
            date: "2026-09-18T09:41:00Z",
            cases: 40, builtInCases: 40, userCases: 0, comparisons: 80,
            agreement: [.init(kind: "choice", compared: 30, agreed: 27, rate: 0.9)],
            overallAgreementRate: 0.85,
            floors: floors ?? .init(
                choiceConfidence: 0.72, scoreConfidence: 0.81, noulLow: 0.29, noulHigh: 0.71
            ),
            escalationRate: 0.18,
            choiceFloorMeasured: measured, scoreFloorMeasured: measured,
            noulBandMeasured: measured,
            bins: [], inputTokens: 31_204, estimatedUSD: 0.0013,
            appliesToLoadedModel: applies, floorsInEffect: inEffect, loadedModelName: loaded
        )
    }

    @Test func itLeadsWithTheFloorsThatAreRunning() {
        let line = Tools.cascadeLine(Self.calibration(applies: true))
        #expect(line.contains("choices under 0.72"))
        #expect(line.contains("scores under 0.81"))
        #expect(line.contains("nouls between 0.29 and 0.71"))
        #expect(line.contains("85% agreement"))
        // The number that says what the floors cost to run, not just how good they look.
        #expect(line.contains("18% of answers escalated"))
        #expect(!line.contains("NOT in effect"))
    }

    /// The case this line exists for. A calibration measured on a model nobody has loaded
    /// since describes nothing that is happening, so it must not be quoted as though it did.
    @Test func itRefusesToQuoteFloorsThatAreNotInEffect() {
        let line = Tools.cascadeLine(Self.calibration(
            applies: false,
            inEffect: .init(confidence: 0.6, noulLow: 0.25, noulHigh: 0.75),
            loaded: "Llama 4B"
        ))
        // The floors it prints are the ones actually running, not the stored ones.
        #expect(line.contains("choices under 0.60"))
        #expect(line.contains("scores under 0.60"))
        #expect(line.contains("nouls between 0.25 and 0.75"))
        #expect(!line.contains("0.72"))
        #expect(!line.contains("0.29"))
        // And it says so, names both models, and says how to fix it.
        #expect(line.contains("NOT in effect"))
        #expect(line.contains("Qwen3-Coder 30B"))
        #expect(line.contains("Llama 4B"))
        #expect(line.contains("calibrate_decisions"))
        // No agreement rate: quoting one beside floors that are not running would be the
        // same lie in a different sentence.
        #expect(!line.contains("85%"))
    }

    @Test func aFallbackFloorIsAdmittedRatherThanPresentedAsMeasured() {
        let line = Tools.cascadeLine(Self.calibration(applies: true, measured: false))
        #expect(line.contains("Some floors fell back to the defaults"))
    }

    /// The full report an agent gets back from a run.
    @Test func theRunReportCarriesTheCaveatAndTheCost() {
        let page = Tools.describe(Self.calibration(applies: true))
        #expect(page.contains("Qwen3-Coder 30B"))
        #expect(page.contains("jev-1.13.0"))
        #expect(page.contains("18% of this set would have gone to Jev"))
        #expect(page.contains("choice: 27 of 30 (90%)"))
        #expect(page.contains("$0.0013"))
        // The caveat is in the answer, not only in the README.
        #expect(page.contains("reference, not ground truth"))
    }

    /// The tool an agent reads before spending: it has to say that it spends.
    @Test func theToolWarnsThatItCostsMoney() throws {
        let tool = try #require(Tools.all.first { $0.name == "calibrate_decisions" })
        #expect(tool.description.contains("COSTS MONEY"))
        #expect(tool.description.contains(
            "\(ControlAPI.JevCalibration.estimatedCents()) cent"
        ))
        #expect(tool.description.contains("ask the user"))
        #expect(tool.description.contains("reference here, not ground truth"))
        #expect(tool.required.isEmpty)
    }

    /// `decide` is the tool that actually runs the cascade, so its description is where an
    /// agent learns that `auto` is two lanes and how to tell which answered.
    @Test func theDecideToolExplainsTheCascadeAndTheSourcesMap() throws {
        let tool = try #require(Tools.all.first { $0.name == "decide" })
        #expect(tool.description.contains("local+typesafe"))
        #expect(tool.description.contains("`sources`"))
        #expect(tool.description.contains("calibrate_decisions"))
    }

    /// The handler accepts "laya" and "node" as a `provider` — `AppModel.decide` switches
    /// on exactly those two spellings, beside "auto", "local" and "typesafe" — so the
    /// property an agent reads before choosing one has to name them too.
    @Test func theDecideToolsProviderPropertyNamesEveryLaneTheHandlerAccepts() throws {
        let tool = try #require(Tools.all.first { $0.name == "decide" })
        let provider = try #require(tool.properties["provider"])
        guard case .object(let fields) = provider,
              case .string(let description) = fields["description"] ?? .null
        else {
            Issue.record("provider has no description")
            return
        }
        for word in ["auto", "local", "laya", "node", "typesafe"] {
            #expect(description.contains(word), "provider's description omits \"\(word)\"")
        }
    }

    /// The handler now calibrates whichever lane it is told to, not only the loaded model
    /// — so the tool needs a `lane` argument, and its description has to say what the
    /// lane words are and that Jev is never one of them.
    @Test func calibrateDecisionsTakesALaneArgumentNamingEveryCalibratableLane() throws {
        let tool = try #require(Tools.all.first { $0.name == "calibrate_decisions" })
        #expect(tool.properties["lane"] != nil, "no way to name which lane to calibrate")
        #expect(tool.description.contains("\"laya\""))
        #expect(tool.description.contains("\"node\""))
        #expect(tool.description.contains("\"typesafe\""), "must say Jev cannot be calibrated")
        // Still optional: the old, lane-less call is still the same route, unchanged.
        #expect(tool.required.isEmpty)
    }
}

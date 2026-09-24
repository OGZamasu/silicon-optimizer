import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

/// Finding a node's decision lane in the `/v1/node` advertisement it already sends.
///
/// The fixture is the shape silicon-node's own `/v1/node` returns — its `decisions` object,
/// field for field — rather than one written to suit this Mac: the lane was never found
/// because this Mac looked for a shape the node does not send.
@Suite("Node decision lane discovery")
struct NodeDecisionDiscoveryTests {

    private func advertisement(decisions: String) throws -> [String: Any] {
        let body = """
            {"name":"silicon-node","platform":"windows-wsl2-cuda",
             "capabilities":[{"id":"llm-qwen3.8-27b","kind":"llm","ready":true}],
             "decisions":\(decisions)}
            """
        return try #require(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
    }

    private func peer(_ json: [String: Any], reachable: Bool = true) -> AppModel.PeerStatus {
        var status = AppModel.PeerStatus(
            name: "studio", baseURL: "http://100.64.0.9:8790", reachable: reachable
        )
        AppModel.parseNode(json, into: &status)
        return status
    }

    @Test func theNodesDecisionsObjectIsFound() throws {
        let json = try advertisement(decisions: """
            {"engine":"laya","available":true,"loaded":true,"device":"cuda",
             "preload":false,"max_loaded":3,"idle_unload_s":900,
             "models":["laya","laya-multilingual","laya-typed-decisions"],
             "checkpoints":{"english":{"repo":"convaiinnovations/laya",
               "revision":"1c5edc17a7acd8701df6fc341c0d179f1c62c982",
               "encoder":"ModernBERT-large 421M","context":"512"}},
             "question_types":["choice","score","noul"],
             "limits":{"max_questions":32,"max_options":32,"max_state_chars":20000,
               "max_body_bytes":262144},
             "vram_mib":4600,"load_seconds":8.2,
             "latency_ms":{"noul":31.4,"choice":33,"batch":58.1},
             "served":12,"uptime_s":120,"error":null}
            """)
        let status = peer(json)
        #expect(status.decisions?.loaded == true)

        let candidate = try #require(AppModel.decisionCandidate(for: status))
        #expect(candidate.name == "studio")
        #expect(candidate.ready)
        #expect(candidate.checkpoints == ["laya", "laya-multilingual", "laya-typed-decisions"])
        // A one-question request's latency, not the batch's.
        #expect(candidate.perQuestionMS == 31.4)
        #expect(candidate.detail == nil)
    }

    /// Lazy by default on the node: available but not yet loaded, nothing measured. It can
    /// answer — the first question pays the load — so it is ready, with no speed to rank on.
    @Test func aColdLaneIsReadyWithNoSpeedYet() throws {
        let status = peer(try advertisement(decisions: """
            {"engine":"laya","available":true,"loaded":false,
             "models":["laya"],"latency_ms":null,"error":null}
            """))
        let candidate = try #require(AppModel.decisionCandidate(for: status))
        #expect(candidate.ready)
        #expect(candidate.perQuestionMS == nil)
    }

    /// The node reports the object even when the lane is off or its package is missing —
    /// `available: false`, sometimes with an error. That node offers no lane.
    @Test func aNodeWhoseLaneIsNotAvailableOffersNone() throws {
        let status = peer(try advertisement(decisions: """
            {"engine":"laya","available":false,"error":"RuntimeError"}
            """))
        #expect(status.decisions?.available == false)
        #expect(AppModel.decisionCandidate(for: status) == nil)
    }

    /// The shape this Mac first documented — a capability of kind `decision` — still works
    /// for a node that advertises its lane that way.
    @Test func aDecisionCapabilityIsStillAccepted() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: Data("""
            {"capabilities":[{"id":"laya","kind":"decision","ready":true,
              "typical_seconds":0.02}]}
            """.utf8)) as? [String: Any])
        let candidate = try #require(AppModel.decisionCandidate(for: peer(json)))
        #expect(candidate.ready)
        #expect(candidate.checkpoints == ["laya"])
        #expect(candidate.perQuestionMS == 20)
    }

    @Test func aNodeWithNoDecisionLaneOffersNone() {
        #expect(AppModel.decisionCandidate(for: peer(["capabilities": [[String: Any]]()])) == nil)
    }
}

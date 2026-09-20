import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime

/// `NodeDecisionLane` is nearly free to build — it is `SystemOneClient` pointed at a swarm
/// peer instead of TypeSafe, since the node serves the same `/v1/systemone` shape — but the
/// seams that are its own code had no tests: the checkpoint-name remapping, the peer-name
/// rewrite on the way back, and what happens with no peer at all.
///
/// `CapturingServer` — the same loopback double `SystemOneTests` uses for TypeSafe itself —
/// stands in for the node here. It is a real local TCP listener on `127.0.0.1`, so this
/// exercises the actual `URLSession` path end to end without ever reaching a real node.
@Suite("The node decision lane")
struct NodeDecisionLaneTests {

    private func peer(port: UInt16, token: String? = "swarm-token") -> NodeDecisionLane.Peer {
        .init(
            name: "studio", baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            token: token, checkpoints: ["laya"], perQuestionMS: 12
        )
    }

    @Test func isReadyReflectsWhetherAPeerIsThereRightNow() async {
        let current = CurrentPeer()
        let lane = NodeDecisionLane(peer: { current.value })
        #expect(await lane.isReady() == false)
        current.value = peer(port: 1)
        #expect(await lane.isReady())
    }

    /// A plain mutable box, not an actor: `peer()` is a synchronous, non-isolated closure —
    /// `NodeDecisionLane` calls it from `isReady()`, which must stay cheap — so what it
    /// closes over has to be readable without `await`.
    private final class CurrentPeer: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: NodeDecisionLane.Peer?
        var value: NodeDecisionLane.Peer? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// The node calls the default checkpoint "laya" — the upstream PyTorch repository's
    /// name, not the MLX port's — because it serves the upstream weights. A silent rename
    /// on either side would send the Mac's default checkpoint to a node that has never
    /// heard of it, which is exactly the kind of wire drift this suite exists to catch.
    @Test func nodeModelNamesAreTheUpstreamNamesNotTheMLXPortsRepositories() {
        #expect(NodeDecisionLane.nodeModelName(for: .english) == "laya")
        #expect(NodeDecisionLane.nodeModelName(for: .multilingual) == "laya-multilingual")
        #expect(NodeDecisionLane.nodeModelName(for: .typedDecisions) == "laya-typed-decisions")
    }

    @Test func noPeerMeansNoNodeToAsk() async {
        let lane = NodeDecisionLane(peer: { nil })
        await #expect(throws: DecisionLaneError.nodeUnreachable) {
            _ = try await lane.decide(.fixture())
        }
    }

    /// With no model named, the request that reaches the node carries the default
    /// checkpoint's node name — not the Mac's own repository spelling, which the node has
    /// never heard of — and the swarm credential goes over as a bearer token, the same as
    /// every other route on that node.
    @Test func decideDefaultsTheModelToTheDefaultCheckpointsNodeName() async throws {
        let server = try CapturingServer { _, _ in
            .init(body: #"""
                {"model":"laya","usage":{"input_tokens":10,"output_tokens":0},
                 "answers":{"q":{"type":"noul","noul":0.6}}}
                """#)
        }
        defer { server.stop() }
        let lane = NodeDecisionLane(peer: { self.peer(port: server.port) })

        let response = try await lane.decide(.fixture())

        let request = try #require(server.requests.first)
        #expect(request.path == "/v1/systemone")
        #expect(request.headers["authorization"] == "Bearer swarm-token")
        let body = try #require(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        #expect(body["model"] as? String == "laya", "the default checkpoint's node name")
        #expect(response.answers["q"] == .noul(0.6))
    }

    /// A caller that names a model explicitly — the test bench, or a calibration run
    /// pinned to one checkpoint — is not overridden by the default remapping.
    @Test func decidePassesThroughAnExplicitModelWithoutRemappingIt() async throws {
        let server = try CapturingServer { _, _ in
            .init(body: #"""
                {"model":"laya-multilingual","usage":{"input_tokens":10,"output_tokens":0},
                 "answers":{"q":{"type":"noul","noul":0.6}}}
                """#)
        }
        defer { server.stop() }
        let lane = NodeDecisionLane(peer: { self.peer(port: server.port) })

        var request = ControlAPI.DecideRequest.fixture()
        request.model = "laya-multilingual"
        _ = try await lane.decide(request)

        let sent = try #require(server.requests.first)
        let body = try #require(
            try JSONSerialization.jsonObject(with: sent.body) as? [String: Any]
        )
        #expect(body["model"] as? String == "laya-multilingual", "an explicit model is not remapped")
    }

    /// Whatever the node's own answer says `provider` was, the lane's rewrite wins: the
    /// point of the field is to say *which peer* answered, in a shape
    /// `DecisionLaneID.named` can still parse as the node lane.
    @Test func theResponsesProviderIsAlwaysRewrittenToTheLaneAndThePeersName() async throws {
        let server = try CapturingServer { _, _ in
            .init(body: #"""
                {"model":"laya","provider":"whatever-the-node-felt-like",
                 "usage":{"input_tokens":1,"output_tokens":0},
                 "answers":{"q":{"type":"noul","noul":0.1}}}
                """#)
        }
        defer { server.stop() }
        let lane = NodeDecisionLane(peer: { self.peer(port: server.port) })

        let response = try await lane.decide(.fixture())
        #expect(response.provider == "node:studio")
        #expect(DecisionLaneID.named(response.provider ?? "") == .node)
    }
}

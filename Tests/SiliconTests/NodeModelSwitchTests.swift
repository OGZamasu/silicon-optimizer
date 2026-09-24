import Foundation
import Testing
@testable import SiliconUI

/// A node lists its chat models as files and takes them back by model id. Sending a file
/// name to `POST /v1/llm/start` stopped the model the node was serving and then looked for
/// a file that does not exist — the node's chat down for the whole swarm, from one click.
@Suite("Switching a node's chat model", .serialized, .redirectedConversationStore,
       .redirectedSwarmConfig)
@MainActor
struct NodeModelSwitchTests {

    /// A two-model node serving the first, in the shapes `GET /v1/llm` and
    /// `GET /v1/llm/models` really use: files in the list, the served id as the model.
    static let twoModelNode = AppModel.PeerLLM(
        installed: true, running: true, healthy: true, model: "qwen3.8-27b",
        availableModels: ["gemma4_31b.ninfer", "qwen3_8_27b.ninfer"]
    )

    /// The node's own rule for the `model` field of `POST /v1/llm/start`, copied from its
    /// handler: dots and dashes become underscores and `.ninfer` is appended.
    static func fileTheNodeLooksFor(_ model: String) -> String {
        model.replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_") + ".ninfer"
    }

    @Test func everyModelOfferedNamesAFileTheNodeHas() {
        let offered = Self.twoModelNode.switchableModels
        #expect(offered == ["qwen3.8-27b", "gemma4_31b"])
        #expect(Set(offered.map(Self.fileTheNodeLooksFor))
            == Set(Self.twoModelNode.availableModels))
    }

    /// The menu bar used to show this node a two-entry menu — its id and its own file —
    /// and the file entry was the one that took it down.
    @Test func aOneModelNodeOffersOneModel() {
        let node = AppModel.PeerLLM(
            installed: true, running: false, healthy: false, model: "qwen3.8-27b",
            availableModels: ["qwen3_8_27b.ninfer"]
        )
        #expect(node.switchableModels == ["qwen3.8-27b"])
    }

    /// Through the real request: every spelling a menu or a gateway id can hand over goes
    /// out as the id, and the node's rule turns each into a file it has.
    @Test func theStartRequestCarriesTheModelIdNeverTheFileName() async throws {
        let server = try CapturingServer(status: 409) { _ in #"{"detail":"queue busy"}"# }
        defer { server.stop() }
        let app = AppModel(settings: .init())
        let peer = AppModel.PeerStatus(
            name: "Rig", baseURL: "http://127.0.0.1:\(server.port)", reachable: true,
            llm: Self.twoModelNode
        )

        let asked = ["gemma4_31b.ninfer", "qwen3_8_27b.ninfer", "gemma4_31b", "qwen3.8-27b"]
        for model in asked {
            await app.setPeerLLM(peer, running: true, model: model)
        }

        let sent = try server.requests.map { request in
            #expect(request.path == "/v1/llm/start")
            let body = try #require(
                try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            )
            return try #require(body["model"] as? String)
        }
        #expect(sent == ["gemma4_31b", "qwen3.8-27b", "gemma4_31b", "qwen3.8-27b"])
        for model in sent {
            #expect(Self.twoModelNode.availableModels.contains(Self.fileTheNodeLooksFor(model)))
        }
    }
}

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

    /// Through the real request: every spelling a menu, a gateway id or the context menu
    /// can hand over goes out as the id, with the exact listed file beside it as
    /// `model_file` — which every node reads before it munges `model`. The hand-placed
    /// file with dots and dashes in its name is the one the munge alone could never find.
    @Test func theStartRequestCarriesTheModelIdAndTheListedFile() async throws {
        let server = try CapturingServer(status: 409) { _ in #"{"detail":"queue busy"}"# }
        defer { server.stop() }
        let app = AppModel(settings: .init())
        var node = Self.twoModelNode
        node.availableModels.append("llama-3.1-8b.ninfer")
        let peer = AppModel.PeerStatus(
            name: "Rig", baseURL: "http://127.0.0.1:\(server.port)", reachable: true, llm: node
        )

        let asked: [(asked: String, id: String, file: String)] = [
            ("gemma4_31b.ninfer", "gemma4_31b", "gemma4_31b.ninfer"),
            ("qwen3_8_27b.ninfer", "qwen3.8-27b", "qwen3_8_27b.ninfer"),
            ("gemma4_31b", "gemma4_31b", "gemma4_31b.ninfer"),
            ("qwen3.8-27b", "qwen3.8-27b", "qwen3_8_27b.ninfer"),
            ("llama-3.1-8b.ninfer", "llama-3.1-8b", "llama-3.1-8b.ninfer"),
            ("llama-3.1-8b", "llama-3.1-8b", "llama-3.1-8b.ninfer"),
        ]
        for entry in asked {
            await app.setPeerLLM(peer, running: true, model: entry.asked)
        }
        // The context menu's restart sends the loaded model again, with a size.
        await app.setPeerLLM(peer, running: true, model: node.model, contextLength: 32_768)

        let sent = try server.requests.map { request in
            #expect(request.path == "/v1/llm/start")
            return try #require(
                try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            )
        }
        #expect(sent.count == asked.count + 1)
        for (body, entry) in zip(sent, asked + [("qwen3.8-27b", "qwen3.8-27b", "qwen3_8_27b.ninfer")]) {
            #expect(body["model"] as? String == entry.id, "\(entry.asked)")
            #expect(body["model_file"] as? String == entry.file, "\(entry.asked)")
            #expect(node.availableModels.contains(body["model_file"] as? String ?? ""))
        }
        #expect(sent.last?["context_length"] as? Int == 32_768)
        // Every id is still one an older node's munge alone resolves, where it can.
        for body in sent.prefix(4) {
            let id = try #require(body["model"] as? String)
            #expect(node.availableModels.contains(Self.fileTheNodeLooksFor(id)))
        }
    }

    /// A file that differs from the served id only in case: the munge names a file that
    /// is not there on a case-sensitive models folder, the listed name is.
    @Test func theListedFileKeepsItsOwnCase() {
        let node = AppModel.PeerLLM(
            installed: true, running: true, healthy: true, model: "qwen3.8-27b",
            availableModels: ["Qwen3_8_27B.ninfer"]
        )
        #expect(node.listedFile(for: "qwen3.8-27b") == "Qwen3_8_27B.ninfer")
        // A node with no list is asked by id alone, as before.
        let unlisted = AppModel.PeerLLM(
            installed: true, running: true, healthy: true, model: "qwen3.8-27b"
        )
        #expect(unlisted.listedFile(for: "qwen3.8-27b") == nil)
    }
}

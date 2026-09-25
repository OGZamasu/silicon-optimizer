import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
import SiliconCore
import SiliconPlanner
@testable import SiliconRuntime
@testable import SiliconUI

/// Where Qwen-Image 2.1 reaches beyond the Images tab: the control API the phones and MCP
/// read, and the swarm — a paired node that advertises the same model id gets the job with
/// that id. The node side is checked against the shape silicon-node already sends (its
/// `text-to-image` capability lists installed lanes in `settings.models`), parsed by the same
/// code that parses a real `/v1/node`.
///
/// Hermetic: an app model with injected settings and a scratch hub; no network, no node.
@Suite("Qwen-Image 2.1 reach", .redirectedConversationStore)
@MainActor
struct QwenImage21ReachTests {

    static let pruna = DiffusionCatalog.qwenImage21Pruna

    /// A node's `/v1/node`, as silicon-node writes it, with `models` listing its image lanes.
    static func node(name: String, models: String?, enabled: Bool = true) -> AppModel.PeerStatus {
        var settings: [String: Any] = ["default_model": "qwen-image", "qwen_steps": 30]
        if let models { settings["models"] = models }
        let json: [String: Any] = [
            "platform": "windows-wsl2-cuda",
            "profile": ["gpu": "NVIDIA GeForce RTX 3090 Ti", "vram_mb": 24564],
            "capabilities": [[
                "id": "text-to-image", "name": "Text → image", "kind": "image",
                "ready": true, "enabled": enabled, "peak_vram_gb": NSNull(),
                "typical_seconds": NSNull(), "settings": settings,
                "detail": "POST /v1/text-to-image {prompt, width, height, steps?, seed?, negative_prompt?, model?}",
            ] as [String: Any]],
        ]
        var status = AppModel.PeerStatus(name: name, baseURL: "http://100.64.0.9:8790", reachable: true)
        AppModel.parseNode(json, into: &status)
        return status
    }

    @Test func theNodesModelListIsReadFromItsCapabilitySettings() throws {
        let peer = Self.node(name: "box", models: "qwen-image, sana,qwen-image-2.1-pruna,")
        let capability = try #require(peer.capabilities.first)
        #expect(AppModel.isImageCapability(capability))
        #expect(AppModel.advertisedImageModels(capability) == ["qwen-image", "sana", "qwen-image-2.1-pruna"])
        // Numbers in settings still parse as before.
        #expect(capability.settings["qwen_steps"] == "30")
        let silent = try #require(Self.node(name: "old", models: nil).capabilities.first)
        #expect(AppModel.advertisedImageModels(silent).isEmpty)
    }

    /// A node that has the model beats one that does not; with none that has it, the first
    /// image node still takes the job, as every node job did before nodes named models.
    @Test func aJobGoesToTheNodeThatHasItsModel() {
        let plain = Self.node(name: "a-plain", models: "qwen-image,sana")
        let having = Self.node(name: "b-having", models: "qwen-image,qwen-image-2.1,qwen-image-2.1-pruna")
        let peers = [plain, having]
        #expect(AppModel.imageNode(for: Self.pruna.id, among: peers)?.name == "b-having")
        #expect(AppModel.imageNode(for: "qwen-image-2.1", among: peers)?.name == "b-having")
        #expect(AppModel.imageNode(for: "flux2-klein-4b", among: peers)?.name == "a-plain")
        #expect(AppModel.imageNode(for: nil, among: peers)?.name == "a-plain")

        // A switched-off capability attracts nothing, whatever it lists.
        let off = Self.node(name: "c-off", models: Self.pruna.id, enabled: false)
        #expect(AppModel.imageNode(for: Self.pruna.id, among: [off]) == nil)
        var unreachable = having
        unreachable.reachable = false
        #expect(AppModel.imageNode(for: Self.pruna.id, among: [plain, unreachable])?.name == "a-plain")
    }

    /// The id travels only to a node that advertises it; the body is the node's own
    /// `/v1/text-to-image` contract.
    @Test func theSameIDIsSentOnlyToANodeThatHasIt() {
        let having = Self.node(name: "b", models: "qwen-image-2.1-pruna")
        let plain = Self.node(name: "a", models: "qwen-image")
        #expect(AppModel.nodeImageModel(for: Self.pruna.id, on: having) == Self.pruna.id)
        #expect(AppModel.nodeImageModel(for: Self.pruna.id, on: plain) == nil)

        let body = NodeImageRuntime.submissionBody(for: NodeImageRequest(
            prompt: "a lighthouse", width: 1024, height: 1024,
            steps: Self.pruna.normalizedSteps(20), seed: 42,
            model: AppModel.nodeImageModel(for: Self.pruna.id, on: having),
            outputDirectory: FileManager.default.temporaryDirectory
        ))
        #expect(body["model"] as? String == "qwen-image-2.1-pruna")
        #expect(body["steps"] as? Int == 8)
        #expect(body["negative_prompt"] == nil)
    }

    private func scratchModel() -> AppModel {
        AppModel(
            videoQueue: VideoBatchQueue(storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("scratch-video-queue-\(UUID().uuidString).json")),
            settings: .init()
        )
    }

    /// `GET /image/models` — what the phones and `list_image_models` read — carries both
    /// entries, their licence, and the adapter's default of 8 steps, with no change to the
    /// wire type.
    @Test func theControlAPIListsBothWithTheirLicence() async throws {
        let model = scratchModel()
        try requireTemporaryDirectory(model.fallbackHuggingFaceHub)
        defer { removeTemporaryDirectory(model.fallbackHuggingFaceHub) }
        let listed = await model.imageModels()
        let base = listed.first { $0.id == "qwen-image-2.1" }
        let pruna = listed.first { $0.id == "qwen-image-2.1-pruna" }
        #expect(base?.defaultSteps == 40)
        #expect(pruna?.defaultSteps == 8)
        for entry in [base, pruna] {
            #expect(entry?.license.contains("non-commercial") == true)
            #expect(entry?.isGated == false)
            #expect(entry?.recommendation != nil)
        }
    }

    /// An agent's blank prompt is refused before anything is queued, as the video route
    /// refuses one — not half an hour of reading weights later. Planning takes no prompt.
    @Test func aBlankPromptIsRefusedBeforeAnythingRuns() async throws {
        let model = scratchModel()
        try requireTemporaryDirectory(model.fallbackHuggingFaceHub)
        defer { removeTemporaryDirectory(model.fallbackHuggingFaceHub) }
        var ran = false
        model.makeImageRuntime = { _ in ran = true; return MFluxRuntime() }
        for blank in ["", "   ", "\n\t"] {
            do {
                _ = try await model.generateImage(.init(prompt: blank, modelID: Self.pruna.id, localOnly: true))
                Issue.record("a blank prompt was accepted")
            } catch ControlHostError.badRequest(let message) {
                #expect(message == "The prompt is empty.")
            }
        }
        #expect(!ran)
        #expect(model.imageQueue.isEmpty && model.currentImageJob == nil)
        let plan = try await model.planImage(.init(prompt: "", modelID: Self.pruna.id))
        #expect(plan.steps == 8)
    }

    /// A phone or agent asking the adapter for another step count gets its nearest schedule.
    @Test func thePlanRouteSnapsTheAdaptersSteps() async throws {
        let model = scratchModel()
        try requireTemporaryDirectory(model.fallbackHuggingFaceHub)
        defer { removeTemporaryDirectory(model.fallbackHuggingFaceHub) }
        let eight = try await model.planImage(.init(prompt: "p", modelID: Self.pruna.id, steps: 30))
        #expect(eight.steps == 8)
        let five = try await model.planImage(.init(prompt: "p", modelID: Self.pruna.id, steps: 4))
        #expect(five.steps == 5)
        let base = try await model.planImage(.init(prompt: "p", modelID: "qwen-image-2.1", steps: 30))
        #expect(base.steps == 30)
    }
}

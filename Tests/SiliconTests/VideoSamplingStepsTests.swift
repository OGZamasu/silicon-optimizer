import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

@Suite("Per-clip H3 denoising depth") @MainActor
struct VideoSamplingStepsTests {
    private func fixture() -> (URL, VideoBatchQueue, VideoRequest) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("h3-steps-test-\(UUID())")
        return (folder, VideoBatchQueue(storeURL: folder.appendingPathComponent("queue.json")),
                VideoRequest(entryID: "hailuo-h3", prompt: "Silver-striped honey badger", seconds: 15,
                             resolution: "720p", outputDirectory: folder, seed: 42, h3Turbo: false,
                             h3Steps: 30))
    }

    @Test(arguments: [4, 9, 12, 16, 20, 30]) func controlAndNodeWireKeepStepsWithoutChangingCanvas(steps: Int) throws {
        let request = ControlAPI.VideoGenerateRequest(prompt: "A badger", modelID: "hailuo-h3", seconds: 15,
                                                      resolution: "720p", seed: 42, h3Turbo: false, h3Steps: steps)
        let data = try JSONEncoder().encode(request)
        let wire = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(wire["h3_steps"] as? Int == steps && wire["h3Steps"] == nil)
        let decoded = try JSONDecoder().decode(ControlAPI.VideoGenerateRequest.self, from: data)
        var (_, _, node) = fixture()
        node.h3Steps = decoded.h3Steps
        let body = try #require(JSONSerialization.jsonObject(with: node.nodeBody()) as? [String: Any])
        #expect(body["h3_steps"] as? Int == steps)
        #expect(body["h3_turbo"] as? Bool == false)
        #expect(body["seconds"] as? Int == 15 && body["resolution"] as? String == "720p")
        let batch = ControlAPI.VideoQueueRequest(prompts: ["one"], h3Turbo: false, h3Steps: steps)
        let batchData = try JSONEncoder().encode(batch)
        #expect(try JSONDecoder().decode(ControlAPI.VideoQueueRequest.self, from: batchData).h3Steps == steps)
        #expect(String(decoding: batchData, as: UTF8.self).contains("h3_steps"))
    }

    @Test func oldRequestsDecodeAndAutoIsOmitted() throws {
        let single = try JSONDecoder().decode(ControlAPI.VideoGenerateRequest.self, from: Data(#"{"prompt":"one"}"#.utf8))
        let batch = try JSONDecoder().decode(ControlAPI.VideoQueueRequest.self, from: Data(#"{"prompts":["one"]}"#.utf8))
        #expect(single.h3Steps == nil && batch.h3Steps == nil)
        var (_, _, template) = fixture()
        template.h3Steps = nil
        let data = try JSONEncoder().encode(template)
        #expect(try JSONDecoder().decode(VideoRequest.self, from: data).h3Steps == nil)
        #expect(!String(decoding: try template.nodeBody(), as: UTF8.self).contains("h3_steps"))
    }

    @Test func invalidValuesAndTurboCannotQueueAnyWork() throws {
        let (folder, queue, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        for steps in [-1, 0, 1, 3, 31, Int.max] {
            var bad = template; bad.h3Steps = steps
            #expect(throws: (any Error).self) { try queue.enqueueSingle(bad) }
        }
        for turbo: Bool? in [nil, true] {
            var bad = template; bad.h3Turbo = turbo
            #expect(throws: (any Error).self) { try queue.enqueueSingle(bad) }
        }
        var wrongModel = template; wrongModel.entryID = "ltx2-distilled"; wrongModel.h3Turbo = nil
        #expect(throws: (any Error).self) { try queue.enqueueSingle(wrongModel) }
        for value in ["true", "20.5", "\"20\"", "[]"] {
            let json = Data("{\"prompts\":[\"one\"],\"h3_steps\":\(value)}".utf8)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(ControlAPI.VideoQueueRequest.self, from: json) }
        }
        #expect(queue.items.isEmpty)
    }

    @Test func snapshotsPersistRecoverExportAndRemainVisibleThroughControlAPI() async throws {
        var (folder, queue, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try queue.setPaused(true)
        let batch = try queue.enqueue(prompts: ["one", "two"], variations: 2, title: "Steps", template: template)
        template.h3Steps = 20
        let single = try queue.enqueueSingle(template)
        #expect(queue.items.prefix(4).allSatisfy { $0.request.h3Steps == 30 })
        let restored = VideoBatchQueue(storeURL: queue.storeURL)
        #expect(restored.items.map(\.request.h3Steps) == [30, 30, 30, 30, 20])
        #expect(restored.isPaused && restored.items.last?.id == single.id)
        try restored.exportManifest(batchID: batch)
        let manifest = try Data(contentsOf: queue.items[0].request.outputDirectory.appendingPathComponent("manifest.json"))
        #expect(String(decoding: manifest, as: UTF8.self).contains("\"h3Steps\" : 30"))
        let model = AppModel(videoQueue: restored, settings: .init())
        let view = await model.videoQueue()
        #expect(view.items.map(\.h3Steps) == [30, 30, 30, 30, 20])
    }

    @Test func unsupportedNodeKeepsExplicitOverridePendingInsteadOfDroppingIt() async throws {
        let (folder, queue, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try queue.enqueueSingle(template)
        let model = AppModel(videoQueue: queue, settings: .init())
        let peer = AppModel.PeerStatus(name: "legacy", baseURL: "http://127.0.0.1:1", reachable: true,
                                      capabilities: [.init(id: "hailuo-h3", kind: "video", ready: true,
                                                           supportedParameters: ["h3_turbo"])])
        await model.processNextQueuedVideo(peers: [peer])
        #expect(queue.items[0].status == .pending && queue.items[0].nodeJob == nil)
        #expect(queue.items[0].request.h3Steps == 30)
        #expect(model.videoQueueMessage?.contains("does not advertise denoising steps") == true)
    }

    @Test func bothComposersSnapshotTheSameStepsAndLeaveExistingJobsAlone() async throws {
        let (folder, queue, _) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try queue.setPaused(true)
        var settings = Settings(); settings.videoOutputDirectory = folder.path
        let model = AppModel(videoQueue: queue, settings: settings)
        defer { model.videoQueueTask?.cancel() }
        model.selectedVideoModel = "hailuo-h3"
        model.videoSampling = .full
        model.videoSeconds = 15
        model.videoH3Steps = 30
        model.videoPrompt = "First clip"
        model.generateVideo()
        #expect(queue.items.count == 1 && queue.items[0].request.h3Steps == 30)
        model.videoH3Steps = 20
        model.videoBatchPrompts = "Second clip\n\nThird clip"
        model.enqueueVideoComposer()
        for _ in 0..<100 where model.isEnqueuingVideoBatch { try await Task.sleep(for: .milliseconds(10)) }
        #expect(queue.items.map(\.request.h3Steps) == [30, 20, 20])
        #expect(queue.isPaused && model.videoBatchPrompts.isEmpty)
        model.videoSampling = .turbo
        model.videoPrompt = "Invalid override"
        model.generateVideo()
        #expect(queue.items.count == 3 && model.videoPrompt == "Invalid override")
        #expect(model.videoError?.contains("requires h3_turbo") == true)
    }
}

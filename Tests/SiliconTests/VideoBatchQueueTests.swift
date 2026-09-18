import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime

@Suite("Persistent video batches") @MainActor
struct VideoBatchQueueTests {
    private func fixture() -> (VideoBatchQueue, URL, VideoRequest) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("video-queue-test-\(UUID())")
        return (VideoBatchQueue(storeURL: folder.appendingPathComponent("queue.json")), folder,
                VideoRequest(entryID: "hailuo-h3", prompt: "template", seconds: 10,
                             resolution: "480p", outputDirectory: folder.appendingPathComponent("clips")))
    }

    @Test func paragraphsKeepTheirInternalNewlines() {
        #expect(VideoBatchQueue.parsePrompts(" first\r\nsecond line\r\n \r\n next shot \n\n")
                == ["first\nsecond line", "next shot"])
        #expect(VideoBatchQueue.parsePrompts(" \n\t\n").isEmpty)
    }

    @Test func singlesJoinBatchesInFIFOOrderAndKeepWholePromptsAndSettings() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try queue.enqueue(prompts: ["batch one", "batch two"], variations: 1, title: "Movie", template: template)
        var request = template
        request.prompt = " first paragraph\n\nsecond paragraph "
        request.h3ChainPrompts = ["window one", "window two"]
        request.h3Turbo = false
        request.seed = 42
        let single = try queue.enqueueSingle(request)
        request.prompt = "changed draft"
        request.seconds = 15
        request.h3Turbo = true
        #expect(queue.items.count == 3)
        #expect(queue.next?.request.prompt == "batch one")
        #expect(single.request.prompt == "first paragraph\n\nsecond paragraph")
        #expect(single.request.seed == 42 && single.request.seconds == 10 && single.request.h3Turbo == false)
        #expect(single.request.h3ChainPrompts == ["window one", "window two"])
        #expect(single.request.clientID?.hasPrefix("vq-") == true)
        let restored = VideoBatchQueue(storeURL: queue.storeURL)
        #expect(restored.items.last?.id == single.id)
        #expect(restored.items.last?.request.h3ChainPrompts == single.request.h3ChainPrompts)
        try queue.setPaused(true)
        try queue.enqueueSingle(template)
        #expect(queue.isPaused && queue.next == nil)
    }

    @Test func singleReferenceImagesArePrivateSnapshotsNotMutableSourcePaths() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("reference.png")
        let original = Data("image fixture".utf8)
        try original.write(to: source)
        var request = template
        request.image = source
        let single = try queue.enqueueSingle(request)
        let snapshot = try #require(single.request.image)
        #expect(snapshot != source)
        #expect(snapshot.deletingLastPathComponent().lastPathComponent == "inputs")
        try Data("edited source".utf8).write(to: source)
        #expect(try Data(contentsOf: snapshot) == original)
        try FileManager.default.removeItem(at: source)
        let restored = VideoBatchQueue(storeURL: queue.storeURL)
        #expect(try Data(contentsOf: #require(restored.items.first?.request.image)) == original)
        #expect(try FileManager.default.attributesOfItem(atPath: snapshot.path)[.posixPermissions] as? Int == 0o600)
        let body = try #require(JSONSerialization.jsonObject(with: single.request.nodeBody()) as? [String: Any])
        #expect(body["image_b64"] as? String == original.base64EncodedString())
    }

    @Test func singleValidationDoesNotBypassCapsOrAcceptMissingImages() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var request = template
        request.h3ChainPrompts = ["missing second window"]
        #expect(throws: (any Error).self) { try queue.enqueueSingle(request) }
        request = template
        request.image = folder.appendingPathComponent("missing.png")
        #expect(throws: (any Error).self) { try queue.enqueueSingle(request) }
        #expect(queue.items.isEmpty)
        try queue.enqueue(prompts: Array(repeating: "shot", count: 10), variations: 20,
                          title: "Full", template: template)
        #expect(throws: (any Error).self) { try queue.enqueueSingle(template) }
        #expect(queue.items.count == 200)
    }

    @Test func displayOrderKeepsActiveAndWaitingClipsAboveNewestFirstHistory() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try queue.enqueue(prompts: ["old done", "new done", "failed", "active", "next", "last"],
                          variations: 1, title: "Order", template: template)
        let original = queue.items.map(\.id)
        for index in [0, 1] {
            try queue.complete(original[index], result: .init(file: folder.appendingPathComponent("\(index).mp4"),
                                                              modelName: "H3", prompt: "done", elapsed: 1))
        }
        try queue.fail(original[2], message: "failed", terminalNodeFailure: true)
        try queue.begin(original[3], nodeName: "fixture", nodeURL: URL(string: "http://queue.test")!)
        #expect(queue.displayItems.map(\.id) == [3, 4, 5, 2, 1, 0].map { original[$0] })
        #expect(queue.items.map(\.id) == original)
    }

    @Test func variationsAreDistinctOrderedAndFrozenOnDisk() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try queue.enqueue(prompts: [" shot one ", "shot two"], variations: 3, title: "Movie", template: template, baseSeed: .max)
        #expect(queue.items.count == 6)
        #expect(queue.items.map(\.scene) == [1, 1, 1, 2, 2, 2])
        #expect(queue.items.map(\.variation) == [1, 2, 3, 1, 2, 3])
        #expect(queue.items.map(\.request.seed) == [.max, 0, 1, 2, 3, 4])
        #expect(Set(queue.items.map(\.request.clientID)).count == 6)
        let restored = VideoBatchQueue(storeURL: queue.storeURL)
        #expect(restored.storageError == nil)
        #expect(restored.items.map(\.id) == queue.items.map(\.id))
        #expect(restored.next?.request.prompt == "shot one")
        #expect(restored.items.allSatisfy { $0.request.seconds == 10 && $0.request.resolution == "480p" })
        let permissions = try FileManager.default.attributesOfItem(atPath: queue.storeURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func mixedFinishedHistoryUsesCompletionTimeIncludingRetriedOldClips() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try queue.enqueue(prompts: ["old failure", "later success", "waiting"], variations: 1,
                          title: "Order", template: template, now: Date(timeIntervalSince1970: 1))
        let ids = queue.items.map(\.id)
        try queue.begin(ids[0], nodeName: "fixture", nodeURL: URL(string: "http://queue.test")!)
        try queue.accepted(ids[0], job: .init(id: "failed-job"))
        try queue.fail(ids[0], message: "failed", terminalNodeFailure: true, now: Date(timeIntervalSince1970: 10))
        let result = VideoResult(file: folder.appendingPathComponent("test.mp4"), modelName: "H3", prompt: "done", elapsed: 1)
        try queue.complete(ids[1], result: result, now: Date(timeIntervalSince1970: 20))
        #expect(queue.displayItems.map(\.id) == [ids[2], ids[1], ids[0]])
        #expect(VideoBatchQueue(storeURL: queue.storeURL).displayItems.map(\.id) == queue.displayItems.map(\.id))
        try queue.retry(ids[0])
        #expect(queue.items[0].finishedAt == nil)
        #expect(queue.displayItems.map(\.id) == [ids[0], ids[2], ids[1]])
        try queue.complete(ids[0], result: result, now: Date(timeIntervalSince1970: 30))
        #expect(queue.displayItems.map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(queue.items.map(\.id) == ids)
    }

    @Test func legacyFinishedHistoryHasStableMixedStatusOrdering() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try queue.enqueue(prompts: ["failed", "done"], variations: 1, title: "Legacy", template: template)
        var items = queue.items
        items[0].status = .failed
        items[1].status = .completed
        try JSONEncoder().encode(VideoBatchQueue.Document(items: items)).write(to: queue.storeURL)
        let restored = VideoBatchQueue(storeURL: queue.storeURL)
        #expect(restored.storageError == nil)
        #expect(restored.displayItems.map(\.id) == items.reversed().map(\.id))
    }

    @Test func clearedResultsLiveOnlyUntilAllRegisteredWaitersReleaseTheirReceipts() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try queue.enqueueSingle(template)
        queue.retainReceipt(item.id)
        queue.retainReceipt(item.id)
        let result = VideoResult(file: folder.appendingPathComponent("test.mp4"), modelName: "H3", prompt: "done", elapsed: 1)
        try queue.complete(item.id, result: result)
        try queue.clearFinished()
        #expect(queue.items.isEmpty && queue.displayItems.isEmpty)
        #expect(VideoBatchQueue(storeURL: queue.storeURL).items.isEmpty)
        #expect(queue.receipt(item.id)?.file == result.file)
        queue.releaseReceipt(item.id)
        #expect(queue.receipt(item.id)?.file == result.file)
        queue.releaseReceipt(item.id)
        #expect(queue.receipt(item.id) == nil)
    }

    @Test func wholeBatchValidationDoesNotPartiallyEnqueue() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (prompts, variations) in [([], 1), (["valid", " "], 1), (["shot"], 0), (["shot"], 21),
                                      (Array(repeating: "shot", count: 11), 20), ([String(repeating: "x", count: 12001)], 1)] {
            #expect(throws: (any Error).self) {
                try queue.enqueue(prompts: prompts, variations: variations, title: "", template: template)
            }
        }
        #expect(queue.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: queue.storeURL.path))
        var invalid = template
        invalid.seconds = 8
        #expect(throws: (any Error).self) { try queue.enqueue(prompts: ["shot"], variations: 1, title: "", template: invalid) }
        invalid = template; invalid.resolution = "4k"
        #expect(throws: (any Error).self) { try queue.enqueue(prompts: ["shot"], variations: 1, title: "", template: invalid) }
    }

    @Test func manyClipsHaveNoDeadlineUntilActuallySubmitted() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try queue.enqueue(prompts: Array(repeating: "shot", count: 10), variations: 20,
                          title: "Overnight", template: template, now: .distantPast)
        #expect(queue.pendingCount == 200)
        #expect(queue.next != nil)
        #expect(queue.items.allSatisfy { $0.nodeJob == nil })
        #expect(throws: (any Error).self) { try queue.enqueue(prompts: ["one too many"], variations: 1, title: "", template: template) }
    }

    @Test func pauseSurvivesRelaunchButKeepsFollowingTheAcceptedJob() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try queue.enqueue(prompts: ["one", "two"], variations: 1, title: "", template: template)
        let first = try #require(queue.next)
        try queue.begin(first.id, nodeName: "local", nodeURL: URL(string: "http://127.0.0.1:8790")!)
        try queue.accepted(first.id, job: .init(id: "saved-remote-job"))
        try queue.setPaused(true)
        let restored = VideoBatchQueue(storeURL: queue.storeURL)
        #expect(restored.isPaused)
        #expect(restored.next?.nodeJob?.id == "saved-remote-job")
        try restored.complete(first.id, result: .init(file: folder.appendingPathComponent("clip.mp4"), modelName: "H3", prompt: "one", elapsed: 30))
        #expect(restored.next == nil)
        try restored.setPaused(false)
        #expect(restored.next?.request.prompt == "two")
    }

    @Test func interruptedSubmissionNeverAutomaticallyCreatesAnotherRender() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try queue.enqueue(prompts: ["one", "two"], variations: 1, title: "", template: template)
        let first = try #require(queue.next)
        try queue.begin(first.id, nodeName: "local", nodeURL: URL(string: "http://127.0.0.1:8790")!)
        let restored = VideoBatchQueue(storeURL: queue.storeURL)
        #expect(restored.next == nil)
        #expect(restored.items[0].uncertainSubmission)
        #expect(throws: (any Error).self) { try restored.retry(first.id) }
        try restored.retry(first.id, confirmNewRender: true)
        #expect(restored.items[0].request.clientID != first.request.clientID)
        #expect(restored.items[0].attempt == 2)
        #expect(restored.next == nil) // User must also resume future dispatch.
    }

    @Test func failedTransferReusesTheSameNodeReceipt() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try queue.enqueue(prompts: ["one", "two"], variations: 1, title: "", template: template)
        let first = try #require(queue.next)
        try queue.begin(first.id, nodeName: "local", nodeURL: URL(string: "http://127.0.0.1:8790")!)
        try queue.accepted(first.id, job: .init(id: "original"))
        try queue.fail(first.id, message: "Network lost")
        #expect(queue.isPaused)
        try queue.retry(first.id)
        #expect(queue.next?.nodeJob?.id == "original")
        #expect(queue.next?.request.clientID == first.request.clientID)
        #expect(queue.next?.attempt == 1)
    }

    @Test func confirmedFailedRenderCanBeRetriedWithoutBlockingOtherClips() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try queue.enqueue(prompts: ["one", "two"], variations: 1, title: "", template: template)
        let first = try #require(queue.next)
        try queue.begin(first.id, nodeName: "local", nodeURL: URL(string: "http://127.0.0.1:8790")!)
        try queue.accepted(first.id, job: .init(id: "failed-remote"))
        try queue.fail(first.id, message: "Renderer out of memory", terminalNodeFailure: true)
        #expect(!queue.isPaused)
        #expect(queue.next?.request.prompt == "two")
        try queue.retry(first.id)
        #expect(queue.next?.nodeJob == nil)
        #expect(queue.next?.previousNodeJobs == ["failed-remote"])
        #expect(queue.next?.request.clientID != first.request.clientID)
        #expect(queue.next?.request.seed == first.request.seed)
    }

    @Test func corruptHistoryIsPreservedAndCannotBeOverwritten() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let broken = Data("{ broken history".utf8)
        try broken.write(to: queue.storeURL)
        let restored = VideoBatchQueue(storeURL: queue.storeURL)
        #expect(restored.storageError != nil)
        #expect(throws: (any Error).self) { try restored.enqueue(prompts: ["shot"], variations: 1, title: "", template: template) }
        #expect(try Data(contentsOf: queue.storeURL) == broken)
    }

    @Test func failedPersistenceCannotDispatchUnsavedWork() throws {
        let (_, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = VideoBatchQueue(storeURL: folder.appendingPathComponent("queue.json")) { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }
        #expect(throws: (any Error).self) { try queue.enqueue(prompts: ["shot"], variations: 1, title: "", template: template) }
        #expect(queue.items.isEmpty)
        #expect(queue.next == nil)
        #expect(queue.storageError != nil)
    }

    @Test func manifestAndMediaSurviveClearingFinishedHistory() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let batch = try queue.enqueue(prompts: ["shot"], variations: 1, title: "My Movie", template: template, baseSeed: 42)
        let item = try #require(queue.next)
        try queue.exportManifest(batchID: batch)
        let file = item.request.outputDirectory.appendingPathComponent(item.filename)
        try Data("test media".utf8).write(to: file)
        try queue.complete(item.id, result: .init(file: file, modelName: "H3", prompt: "shot", elapsed: 10))
        try queue.exportManifest(batchID: batch)
        try queue.clearFinished()
        #expect(queue.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let manifest = try String(contentsOf: item.request.outputDirectory.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(manifest.contains("My Movie"))
        #expect(manifest.contains("completed"))
        #expect(!manifest.contains("Bearer"))
    }

    @Test func seedAndSamplingSurviveTheWireWithoutChangingCanvas() throws {
        let (_, _, template) = fixture()
        var request = template
        request.seed = 42; request.h3Turbo = false; request.clientID = "queue-test"
        let body = try #require(JSONSerialization.jsonObject(with: request.nodeBody()) as? [String: Any])
        #expect(body["seed"] as? Int == 42)
        #expect(body["h3_turbo"] as? Bool == false)
        #expect(body["resolution"] as? String == "480p")
        #expect(body["entry_id"] as? String == "queue-test")
        request.entryID = "ltx2-distilled"
        #expect(throws: (any Error).self) { try request.nodeBody() }
        let old = try JSONDecoder().decode(ControlAPI.VideoQueueRequest.self, from: Data(#"{"prompts":["shot"]}"#.utf8))
        #expect(old.variations == nil && old.seed == nil && old.h3Turbo == nil)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ControlAPI.VideoQueueRequest.self, from: Data(#"{"prompts":["shot"],"seed":-1}"#.utf8))
        }
    }

    @Test func finishingLaterClipsDoesNotEraseClearedEditingReceipts() throws {
        let (queue, folder, template) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let batch = try queue.enqueue(prompts: ["one", "two", "removed"], variations: 1, title: "", template: template)
        let first = queue.items[0]
        try queue.complete(first.id, result: .init(file: folder.appendingPathComponent("one.mp4"), modelName: "H3", prompt: "one", elapsed: 1))
        try queue.exportManifest(batchID: batch)
        try queue.clearFinished()
        try queue.removePending(queue.items[1].id)
        let second = try #require(queue.next)
        try queue.complete(second.id, result: .init(file: folder.appendingPathComponent("two.mp4"), modelName: "H3", prompt: "two", elapsed: 1))
        try queue.exportManifest(batchID: batch)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode([VideoQueueItem].self, from: Data(contentsOf: first.request.outputDirectory.appendingPathComponent("manifest.json")))
        #expect(exported.map(\.request.prompt) == ["one", "two"])
        #expect(exported.allSatisfy { $0.status == .completed })
    }
}

import Foundation
import Testing
@testable import SiliconRuntime

@Suite("Removed video reference cleanup") @MainActor
struct VideoQueueCleanupTests {
    @MainActor private struct Fixture {
        let root: URL
        let source: URL
        let queue: VideoBatchQueue
        let item: VideoQueueItem
        let snapshot: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("video-cleanup-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            source = root.appendingPathComponent("reference.png")
            try Data("original image".utf8).write(to: source)
            queue = VideoBatchQueue(storeURL: root.appendingPathComponent("queue.json"))
            var request = VideoRequest(entryID: "hailuo-h3", prompt: "fixture", seconds: 10,
                                       resolution: "480p", outputDirectory: root.appendingPathComponent("clips"))
            request.image = source
            item = try queue.enqueueSingle(request)
            snapshot = try #require(item.request.image)
        }

        func restored(items: [VideoQueueItem]) throws -> VideoBatchQueue {
            try JSONEncoder().encode(VideoBatchQueue.Document(items: items)).write(to: queue.storeURL)
            return VideoBatchQueue(storeURL: queue.storeURL)
        }
    }

    @Test func removalDisposesOnlyTheUnusedCopyAndEmptyOwnedFolder() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.queue.removePending(fixture.item.id)
        #expect(fixture.queue.items.isEmpty)
        #expect(VideoBatchQueue(storeURL: fixture.queue.storeURL).items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.item.request.outputDirectory.path))
        #expect(try String(contentsOf: fixture.source, encoding: .utf8) == "original image")
    }

    @Test func failedPersistenceLeavesTheQueuedItemAndImageIntact() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let queue = VideoBatchQueue(storeURL: fixture.queue.storeURL) { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }
        #expect(throws: (any Error).self) { try queue.removePending(fixture.item.id) }
        #expect(queue.items.map(\.id) == [fixture.item.id])
        #expect(VideoBatchQueue(storeURL: queue.storeURL).items.map(\.id) == [fixture.item.id])
        #expect(try Data(contentsOf: fixture.snapshot) == Data(contentsOf: fixture.source))
    }

    @Test(arguments: ["pending", "completed image", "completed file"])
    func sharedReferencesSurviveIncludingClearedManifestHistory(_ reference: String) throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var other = fixture.item
        other.id = UUID().uuidString
        other.request.clientID = "vq-\(other.id)"
        if reference != "pending" { other.status = .completed }
        if reference == "completed file" {
            other.request.image = nil
            other.file = fixture.snapshot
        }
        let queue = try fixture.restored(items: [fixture.item, other])
        try queue.exportManifest(batchID: fixture.item.batchID)
        try queue.clearFinished()
        try queue.removePending(fixture.item.id)
        #expect(try Data(contentsOf: fixture.snapshot) == Data(contentsOf: fixture.source))
        let manifest = try String(contentsOf: fixture.item.request.outputDirectory.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(manifest.contains(other.id))
    }

    @Test func unrelatedMediaAndSiblingInputsAreNeverRecursivelyDeleted() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let media = fixture.item.request.outputDirectory.appendingPathComponent("keep.mp4")
        let sibling = fixture.snapshot.deletingLastPathComponent().appendingPathComponent("keep.png")
        try Data("media".utf8).write(to: media)
        try Data("other reference".utf8).write(to: sibling)
        try fixture.queue.removePending(fixture.item.id)
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
        #expect(try String(contentsOf: media, encoding: .utf8) == "media")
        #expect(try String(contentsOf: sibling, encoding: .utf8) == "other reference")
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    @Test(arguments: ["image", "inputs", "job"])
    func cleanupDoesNotFollowReplacedSymlinks(_ component: String) throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let replaced: URL
        switch component {
        case "image": replaced = fixture.snapshot
        case "inputs": replaced = fixture.snapshot.deletingLastPathComponent()
        default: replaced = fixture.item.request.outputDirectory
        }
        let preserved = fixture.root.appendingPathComponent("preserved-\(component)")
        try FileManager.default.moveItem(at: replaced, to: preserved)
        try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: preserved)
        try fixture.queue.removePending(fixture.item.id)
        #expect(try Data(contentsOf: fixture.snapshot) == Data(contentsOf: fixture.source))
        #expect(try replaced.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    @Test func externalReferencesAreNotConsideredQueueOwned() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var item = fixture.item
        item.request.image = fixture.source
        let queue = try fixture.restored(items: [item])
        try queue.removePending(item.id)
        #expect(try String(contentsOf: fixture.source, encoding: .utf8) == "original image")
        #expect(FileManager.default.fileExists(atPath: fixture.snapshot.path))
    }

    @Test func removedRetryKeepsTheImageUsedByItsPreviousAttempt() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let queue = fixture.queue
        try queue.begin(fixture.item.id, nodeName: "fixture", nodeURL: URL(string: "http://queue.test")!)
        try queue.accepted(fixture.item.id, job: .init(id: "old-job"))
        try queue.fail(fixture.item.id, message: "renderer failed", terminalNodeFailure: true)
        try queue.retry(fixture.item.id, confirmNewRender: true)
        #expect(queue.items[0].attempt == 2)
        try queue.removePending(fixture.item.id)
        #expect(try Data(contentsOf: fixture.snapshot) == Data(contentsOf: fixture.source))
    }

    @Test func alreadyMissingCopyDoesNotPreventRemoval() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.snapshot)
        try fixture.queue.removePending(fixture.item.id)
        #expect(fixture.queue.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.item.request.outputDirectory.path))
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    }
}

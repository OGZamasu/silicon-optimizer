import Foundation
import Testing
@testable import SiliconRuntime

@Suite("Recent video discovery")
struct RecentVideoFilesTests {
    private func fixture() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("video-recents-\(UUID())")
    }
    @discardableResult
    private func media(_ relative: String, in root: URL, date: TimeInterval = 100) throws -> URL {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("media fixture".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: file.path)
        return file.resolvingSymlinksInPath()
    }

    @Test @MainActor func singlesAndBatchesRemainDiscoverableAfterClearingAndRelaunch() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("clips")
        let queue = VideoBatchQueue(storeURL: root.appendingPathComponent("queue.json"))
        let request = VideoRequest(entryID: "hailuo-h3", prompt: "single", seconds: 10,
                                   resolution: "480p", outputDirectory: output)
        try queue.enqueueSingle(request)
        try queue.enqueue(prompts: ["batch one", "batch two"], variations: 1, title: "Movie", template: request)
        var files = [try media("legacy.mov", in: output)]
        for item in queue.items {
            let file = try media(item.filename, in: item.request.outputDirectory)
            files.append(file)
            try queue.complete(item.id, result: .init(file: file, modelName: "H3", prompt: item.request.prompt, elapsed: 1))
            try queue.exportManifest(batchID: item.batchID)
        }
        try queue.clearFinished()
        let restored = VideoBatchQueue(storeURL: queue.storeURL)
        #expect(restored.items.isEmpty)
        #expect(Set(RecentVideoFiles.scan(in: output, queuedFiles: restored.items.compactMap(\.file))) == Set(files))
    }

    @Test func scanIsShallowAndDoesNotFollowSymlinksOrTreatFoldersAsMedia() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("clips")
        let flat = try media("legacy.MP4", in: output)
        let nested = try media("Batches/job/render.webm", in: output)
        try media("Batches/job/inputs/not-a-result.mp4", in: output)
        try media("Batches/job/deeper/hidden.mp4", in: output)
        try media("unrelated/hidden.mp4", in: output)
        try media("Batches/job/.hidden.mp4", in: output)
        let outside = try media("outside/movie.mp4", in: root)
        try FileManager.default.createDirectory(at: output.appendingPathComponent("directory.mp4"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("linked.mp4"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("Batches/linked-job"),
                                                 withDestinationURL: outside.deletingLastPathComponent())
        #expect(Set(RecentVideoFiles.scan(in: output)) == Set([flat, nested]))
        // A replaced Batches directory must not turn discovery into a walk elsewhere.
        try FileManager.default.moveItem(at: output.appendingPathComponent("Batches"), to: root.appendingPathComponent("saved-batches"))
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("Batches"),
                                                 withDestinationURL: outside.deletingLastPathComponent())
        #expect(RecentVideoFiles.scan(in: output) == [flat])
    }

    @Test func newestResultsAreLimitedDeduplicatedAndMayIncludeAnOlderOutputDestination() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("clips")
        let old = try media("old.mp4", in: output, date: 100)
        let newer = try media("Batches/job/new.mov", in: output, date: 200)
        let newest = try media("previous-output/newest.webm", in: root, date: 300)
        let missing = root.appendingPathComponent("missing.mp4")
        #expect(RecentVideoFiles.scan(in: output, queuedFiles: [old, newer, newer, newest, missing], limit: 2) == [newest, newer])
        #expect(RecentVideoFiles.scan(in: output, limit: 0).isEmpty)
        #expect(RecentVideoFiles.scan(in: root.appendingPathComponent("missing")).isEmpty)
    }

    @Test func folderAndEntryBudgetsBoundDiscovery() throws {
        let root = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try media("Batches/old/movie.mp4", in: root)
        let newer = try media("Batches/new/movie.mp4", in: root)
        for (file, time) in [(old, 100.0), (newer, 200.0)] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)],
                                                 ofItemAtPath: file.deletingLastPathComponent().path)
        }
        #expect(RecentVideoFiles.scan(in: root, maximumFolders: 1) == [newer])
        #expect(RecentVideoFiles.scan(in: root, maximumFolders: 0).isEmpty)
        #expect(RecentVideoFiles.scan(in: root, maximumEntries: 0).isEmpty)
        #expect(RecentVideoFiles.scan(in: root, maximumEntries: 1).isEmpty)
        // Queue receipts are independently capped and still usable when disk discovery is disabled.
        #expect(RecentVideoFiles.scan(in: root, queuedFiles: [old], maximumEntries: 0) == [old])
    }
}

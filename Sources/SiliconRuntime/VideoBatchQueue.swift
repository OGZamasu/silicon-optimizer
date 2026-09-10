import Foundation
import Observation
import SiliconCatalog
import Darwin

public enum VideoSampling: String, CaseIterable, Codable, Sendable {
    case nodeDefault, turbo, full
    public var label: String {
        switch self {
        case .nodeDefault: "Renderer default"
        case .turbo: "Turbo — faster"
        case .full: "Full sampling — slower"
        }
    }
    public var h3Turbo: Bool? {
        switch self { case .nodeDefault: nil; case .turbo: true; case .full: false }
    }
}

public enum VideoQueueStatus: String, Codable, Sendable {
    case pending, submitting, rendering, completed, failed
}

public struct VideoQueueItem: Identifiable, Codable, Sendable {
    public var id: String
    public var batchID: String
    public var batchName: String
    public var scene: Int
    public var variation: Int
    public var attempt = 1
    public var createdAt: Date
    public var request: VideoRequest
    public var status: VideoQueueStatus = .pending
    public var nodeName: String?
    public var nodeURL: URL?
    public var nodeJob: VideoNodeJob?
    public var previousNodeJobs: [String] = []
    public var file: URL?
    public var elapsed: TimeInterval?
    public var error: String?
    public var uncertainSubmission = false
    public var nodeFailed = false

    public var label: String { "Scene \(scene) · variation \(variation)" }
    public var canReconnect: Bool { status == .failed && nodeJob != nil && !nodeFailed }
    public var filename: String {
        String(format: "scene-%03d_take-%02d", scene, variation)
            + "_seed-\(request.seed ?? 0)_\(id.prefix(8))-a\(attempt).mp4"
    }
}

/// The durable queue is intentionally separate from the GPU runner. Only one
/// request is dispatched at a time, so a large overnight batch does not consume
/// all of a node's accepted-job deadlines while waiting in line.
@MainActor @Observable
public final class VideoBatchQueue {
    public static let maximumPending = 200
    public static let maximumVariations = 20
    public static let maximumHistory = 2000

    struct Document: Codable {
        var version = 1
        var paused = false
        var items: [VideoQueueItem] = []
    }

    public private(set) var items: [VideoQueueItem] = []
    public private(set) var isPaused = false
    public private(set) var storageError: String?
    public let storeURL: URL
    @ObservationIgnored private let persist: (Data, URL) throws -> Void

    public init(
        storeURL: URL,
        persist: @escaping (Data, URL) throws -> Void = VideoBatchQueue.writePrivate
    ) {
        self.storeURL = storeURL
        self.persist = persist
        do {
            let data: Data
            do { data = try Data(contentsOf: storeURL) }
            catch CocoaError.fileReadNoSuchFile { return }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1,
                  Set(document.items.map(\.id)).count == document.items.count,
                  document.items.count <= Self.maximumHistory,
                  document.items.allSatisfy({ item in
                      UUID(uuidString: item.id) != nil
                          && item.request.outputDirectory.isFileURL
                          && (item.status != .rendering || (item.nodeJob != nil && item.nodeURL != nil))
                  }) else {
                throw VideoRuntimeError.failed("Unsupported or invalid video queue document.")
            }
            items = document.items.map { original in
                var item = original
                if item.status == .submitting {
                    item.status = .failed
                    item.uncertainSubmission = true
                    item.error = "The app closed before the node receipt was saved. Check the node before rendering again; the original may still be running. Client ID: \(item.request.clientID ?? item.id)."
                }
                return item
            }
            isPaused = document.paused || items.contains(where: \.uncertainSubmission)
        } catch {
            // Never replace an unreadable history with an empty queue.
            storageError = "Could not load the video queue. The original file was preserved: \(error.localizedDescription)"
            isPaused = true
        }
    }

    public var pendingCount: Int {
        items.filter { [.pending, .submitting, .rendering].contains($0.status) }.count
    }
    /// Active work and FIFO waiting clips stay visible above finished history.
    /// Presentation order never changes dispatch order or the persisted document.
    public var displayItems: [VideoQueueItem] {
        items.filter { $0.status == .rendering || $0.status == .submitting }
            + items.filter { $0.status == .pending }
            + items.reversed().filter { $0.status == .failed }
            + items.reversed().filter { $0.status == .completed }
    }
    public var next: VideoQueueItem? {
        guard storageError == nil else { return nil }
        // Following an already accepted job is safe even when future dispatch is paused.
        if let active = items.first(where: { $0.status == .rendering }) { return active }
        return isPaused ? nil : items.first { $0.status == .pending }
    }

    /// Blank lines delimit shots, while line breaks within one paragraph stay in its prompt.
    public nonisolated static func parsePrompts(_ text: String) -> [String] {
        var prompts: [String] = []
        var paragraph: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !paragraph.isEmpty { prompts.append(paragraph.joined(separator: "\n")); paragraph = [] }
            } else { paragraph.append(trimmed) }
        }
        if !paragraph.isEmpty { prompts.append(paragraph.joined(separator: "\n")) }
        return prompts
    }

    @discardableResult
    public func enqueue(
        prompts: [String], variations: Int, title: String, template: VideoRequest,
        baseSeed: UInt32? = nil, now: Date = Date()
    ) throws -> String {
        try append(prompts: prompts, variations: variations, title: title, template: template,
                   baseSeed: baseSeed, now: now, singleClip: false)[0].batchID
    }

    /// Single clips use the same persistence and serial dispatcher as batches.
    /// A multiline prompt is one clip; reference images are snapshotted privately
    /// so editing or deleting the source while waiting cannot change the render.
    @discardableResult
    public func enqueueSingle(_ request: VideoRequest, now: Date = Date()) throws -> VideoQueueItem {
        try append(prompts: [request.prompt], variations: 1, title: "Single clip", template: request,
                   baseSeed: request.seed, now: now, singleClip: true)[0]
    }

    private func append(
        prompts: [String], variations: Int, title: String, template: VideoRequest,
        baseSeed: UInt32?, now: Date, singleClip: Bool
    ) throws -> [VideoQueueItem] {
        guard storageError == nil else { throw VideoRuntimeError.failed(storageError!) }
        let prompts = prompts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !prompts.isEmpty, prompts.count <= Self.maximumPending,
              prompts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.count <= 12000 }),
              (1...Self.maximumVariations).contains(variations),
              prompts.count * variations + pendingCount <= Self.maximumPending,
              prompts.count * variations + items.count <= Self.maximumHistory else {
            throw VideoRuntimeError.failed("Use nonempty prompts of at most 12,000 characters, 1–20 variations, and at most 200 unfinished clips. Clear finished history if the 2,000-item history is full.")
        }
        guard let entry = VideoCatalog.entry(id: template.entryID),
              entry.supportedSeconds.contains(template.seconds),
              ["480p", "720p", "1080p"].contains(template.resolution),
              template.outputDirectory.isFileURL,
              singleClip || (template.image == nil && template.h3ChainPrompts == nil) else {
            throw VideoRuntimeError.failed("Choose a supported model, duration, and size. Batch prompts are text-only; use Make a clip for an image or per-window prompts.")
        }
        guard template.image == nil || entry.supportsImageInput else {
            throw VideoRuntimeError.failed("This video model does not support reference images.")
        }
        // Validate the metadata without reading an unbounded image into a JSON body.
        var validated = template
        validated.image = nil
        _ = try validated.nodeBody()
        let batchID = UUID().uuidString
        let name = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let batchName = name.isEmpty ? "Video batch" : name
        let timestamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let folder = template.outputDirectory.appendingPathComponent("Batches", isDirectory: true)
            .appendingPathComponent("\(timestamp)-\(batchID.prefix(8))", isDirectory: true)
        let imageSnapshot: URL?
        if let image = template.image {
            guard image.isFileURL,
                  try image.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw VideoRuntimeError.failed("Choose a local image file.")
            }
            let handle = try FileHandle(forReadingFrom: image)
            defer { try? handle.close() }
            let limit = 20 * 1024 * 1024
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard !data.isEmpty, data.count <= limit else {
                throw VideoRuntimeError.failed("Reference images must be nonempty and at most 20 MiB.")
            }
            let destination = folder.appendingPathComponent("inputs", isDirectory: true)
                .appendingPathComponent(image.lastPathComponent)
            try Self.writePrivate(data, destination)
            imageSnapshot = destination
        } else { imageSnapshot = nil }
        let seed = baseSeed ?? UInt32.random(in: .min ... .max)
        var added: [VideoQueueItem] = []
        for (sceneIndex, prompt) in prompts.enumerated() {
            for variation in 1...variations {
                let id = UUID().uuidString
                var request = template
                request.prompt = prompt
                request.seed = seed &+ UInt32(added.count)
                request.clientID = "vq-\(id)"
                request.outputDirectory = folder
                request.image = imageSnapshot
                added.append(VideoQueueItem(
                    id: id, batchID: batchID, batchName: batchName, scene: sceneIndex + 1,
                    variation: variation, createdAt: now, request: request
                ))
            }
        }
        do { try commit(items + added, paused: isPaused) }
        catch {
            // Only remove the newly created snapshot, never the user's source.
            if let imageSnapshot { try? FileManager.default.removeItem(at: imageSnapshot) }
            throw error
        }
        return added
    }

    public func setPaused(_ paused: Bool) throws { try commit(items, paused: paused) }

    public func begin(_ id: String, nodeName: String, nodeURL: URL) throws {
        try update(id) { item in
            guard item.status == .pending else { throw VideoRuntimeError.failed("The clip is not waiting to start.") }
            item.status = .submitting
            item.nodeName = nodeName
            item.nodeURL = nodeURL
            item.error = nil
        }
    }

    public func accepted(_ id: String, job: VideoNodeJob) throws {
        try update(id) { item in
            item.nodeJob = job
            item.status = .rendering
            item.uncertainSubmission = false
        }
    }

    public func complete(_ id: String, result: VideoResult) throws {
        try update(id) { item in
            item.status = .completed
            item.file = result.file
            item.elapsed = result.elapsed
            item.error = nil
        }
    }

    public func fail(_ id: String, message: String, terminalNodeFailure: Bool = false) throws {
        var updated = items
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[index].status = .failed
        updated[index].nodeFailed = terminalNodeFailure
        updated[index].uncertainSubmission = updated[index].nodeJob == nil
        updated[index].error = message
        // A lost connection may still be consuming the GPU. Do not blindly add
        // further work until the user reconnects or checks an uncertain submission.
        try commit(updated, paused: isPaused || !terminalNodeFailure)
    }

    public func retry(_ id: String, confirmNewRender: Bool = false) throws {
        guard pendingCount < Self.maximumPending else {
            throw VideoRuntimeError.failed("The queue already has 200 unfinished clips; retry after one finishes or is removed.")
        }
        try update(id) { item in
            guard item.status == .failed else { throw VideoRuntimeError.failed("Only failed clips can be retried.") }
            if item.canReconnect && !confirmNewRender {
                item.status = .rendering
            } else {
                guard (!item.uncertainSubmission && !item.canReconnect) || confirmNewRender else {
                    throw VideoRuntimeError.failed("Check the node first. Retrying an uncertain submission can create a duplicate; explicitly confirm a new render.")
                }
                if let old = item.nodeJob { item.previousNodeJobs.append(old.id) }
                item.nodeJob = nil
                item.request.clientID = "vq-\(UUID().uuidString)"
                item.attempt += 1
                item.status = .pending
            }
            item.uncertainSubmission = false
            item.nodeFailed = false
            item.error = nil
        }
    }

    public func removePending(_ id: String) throws {
        guard let item = items.first(where: { $0.id == id }), item.status == .pending else {
            throw VideoRuntimeError.failed("Only clips that have not been submitted can be removed.")
        }
        try commit(items.filter { $0.id != id }, paused: isPaused)
        do {
            let retained = try exportManifest(batchID: item.batchID, directory: item.request.outputDirectory)
            try removeUnusedSnapshot(of: item, retained: retained)
        } catch {
            throw VideoRuntimeError.failed("Clip removed from the queue, but its folder could not be fully cleaned up: \(error.localizedDescription)")
        }
    }

    /// Only a never-submitted clip's queue-owned copy is disposable. Use
    /// descriptor-relative unlink and empty-directory removal, never recursive
    /// deletion: source images, shared references, media and symlink targets stay.
    private func removeUnusedSnapshot(of item: VideoQueueItem, retained: [VideoQueueItem]) throws {
        guard item.attempt == 1, item.nodeJob == nil, item.nodeURL == nil,
              item.previousNodeJobs.isEmpty, !item.uncertainSubmission,
              let image = item.request.image?.standardizedFileURL, image.isFileURL,
              UUID(uuidString: item.batchID) != nil else { return }
        let folder = item.request.outputDirectory.standardizedFileURL
        let timestamp = ISO8601DateFormatter().string(from: item.createdAt).replacingOccurrences(of: ":", with: "-")
        guard folder.isFileURL, folder.deletingLastPathComponent().lastPathComponent == "Batches",
              folder.lastPathComponent == "\(timestamp)-\(item.batchID.prefix(8))",
              image.deletingLastPathComponent() == folder.appendingPathComponent("inputs", isDirectory: true),
              !image.lastPathComponent.isEmpty else { return }
        let canonicalImage = image.resolvingSymlinksInPath()
        guard !(items + retained).contains(where: {
            $0.request.image?.resolvingSymlinksInPath() == canonicalImage
                || $0.file?.resolvingSymlinksInPath() == canonicalImage
        }) else { return }

        let directory = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            if [ENOENT, ELOOP, ENOTDIR].contains(errno) { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(directory) }
        let inputs = openat(directory, "inputs", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if inputs >= 0 {
            defer { close(inputs) }
            var metadata = stat()
            if fstatat(inputs, image.lastPathComponent, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFREG else { return }
                guard unlinkat(inputs, image.lastPathComponent, 0) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } else if errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // AT_REMOVEDIR refuses nonempty directories, even if another file
            // appears between the snapshot unlink and this operation.
            if unlinkat(directory, "inputs", AT_REMOVEDIR) != 0,
               ![ENOENT, ENOTEMPTY, EEXIST].contains(errno) {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else if errno != ENOENT {
            if [ELOOP, ENOTDIR].contains(errno) { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let otherFolderUsers = items.contains {
            $0.request.outputDirectory.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath()
        }
        if retained.isEmpty && !otherFolderUsers {
            // This is the empty manifest just exported after the durable removal.
            if unlinkat(directory, "manifest.json", 0) != 0, errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if rmdir(folder.path) != 0, ![ENOENT, ENOTEMPTY, EEXIST, ENOTDIR].contains(errno) {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    public func clearFinished() throws {
        // Completed media and exported manifests stay on disk. Failed jobs are
        // retained, especially those whose remote outcome is still unknown.
        try commit(items.filter { $0.status != .completed }, paused: isPaused)
    }

    /// A portable editing receipt lives beside each batch's clips. It contains
    /// prompts, seeds, variations, remote IDs and output paths, never credentials.
    @discardableResult
    public func exportManifest(batchID: String, directory: URL? = nil) throws -> [VideoQueueItem] {
        let batch = items.filter { $0.batchID == batchID }
        guard let directory = directory ?? batch.first?.request.outputDirectory else { return [] }
        let destination = directory.appendingPathComponent("manifest.json")
        // Clearing app history must not erase receipts for clips already in an
        // editor's folder when another member of that same batch finishes later.
        let previous: [VideoQueueItem]
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            previous = try decoder.decode([VideoQueueItem].self, from: Data(contentsOf: destination))
        } catch CocoaError.fileReadNoSuchFile { previous = [] }
        let currentIDs = Set(batch.map(\.id))
        let retained = previous.filter { $0.batchID == batchID && $0.status == .completed && !currentIDs.contains($0.id) }
        let exported = (retained + batch).sorted {
            $0.scene == $1.scene ? $0.variation < $1.variation : $0.scene < $1.scene
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try Self.writePrivate(encoder.encode(exported), destination)
        return exported
    }

    private func update(_ id: String, _ edit: (inout VideoQueueItem) throws -> Void) throws {
        var updated = items
        guard let index = updated.firstIndex(where: { $0.id == id }) else {
            throw VideoRuntimeError.failed("That queue item no longer exists.")
        }
        try edit(&updated[index])
        try commit(updated, paused: isPaused)
    }

    private func commit(_ updated: [VideoQueueItem], paused: Bool) throws {
        guard storageError == nil else { throw VideoRuntimeError.failed(storageError!) }
        do {
            try persist(JSONEncoder().encode(Document(paused: paused, items: updated)), storeURL)
        } catch {
            storageError = "Could not save the video queue; no further clips will be submitted. \(error.localizedDescription)"
            throw error
        }
        items = updated
        isPaused = paused
    }

    public nonisolated static func writePrivate(_ data: Data, _ url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// A confirmed terminal node error is different from losing the connection:
/// retrying the former may create a new render; the latter must reuse its receipt.
public struct VideoNodeFailed: LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

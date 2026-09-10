import Foundation
import SiliconCatalog
import SiliconControl
import SiliconRuntime

extension AppModel {
    public var supportsH3Sampling: Bool {
        guard let entry = VideoCatalog.entry(id: selectedVideoModel),
              let peer = videoCapableNode(for: entry) else { return false }
        return videoCapability(for: entry, on: peer)?.supportedParameters.contains("h3_turbo") == true
    }

    public func enqueueVideoComposer() {
        guard !isEnqueuingVideoBatch else { return }
        let seedText = videoBatchSeed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard seedText.isEmpty || UInt32(seedText) != nil else {
            videoQueueMessage = "Base seed must be an integer from 0 through 4,294,967,295, or blank for random."
            return
        }
        let submittedPrompts = videoBatchPrompts
        let request = ControlAPI.VideoQueueRequest(
            prompts: VideoBatchQueue.parsePrompts(submittedPrompts), title: videoBatchTitle,
            variations: videoBatchVariations, modelID: selectedVideoModel,
            seconds: videoSeconds, resolution: videoResolution, seed: UInt32(seedText),
            h3Turbo: selectedVideoModel == "hailuo-h3" ? videoSampling.h3Turbo : nil
        )
        isEnqueuingVideoBatch = true
        Task {
            defer { isEnqueuingVideoBatch = false }
            do {
                _ = try await enqueueVideos(request)
                if videoBatchPrompts == submittedPrompts { videoBatchPrompts = "" }
            } catch { videoQueueMessage = error.localizedDescription }
        }
    }

    @discardableResult
    func enqueueSingleVideo(_ request: VideoRequest) throws -> VideoQueueItem {
        let item = try videoBatchQueue.enqueueSingle(request)
        videoQueueMessage = nil
        do { try videoBatchQueue.exportManifest(batchID: item.batchID) }
        catch { videoQueueMessage = "Clip queued, but its editing manifest could not be written: \(error.localizedDescription)" }
        revealVideoPanel(.queue)
        noteActivity()
        startVideoQueueWorker()
        return item
    }

    /// Preserve the synchronous control API's file response without owning the
    /// renderer. A caller going away must not cancel or resubmit a durable job.
    func waitForQueuedVideo(
        _ id: String, timeout: TimeInterval = TimeInterval(VideoGenerationBudget.controlSeconds - 30)
    ) async throws -> ControlAPI.VideoResponse {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        let receipt = "Queue item \(id). Inspect the video queue before submitting again."
        while true {
            guard let item = videoBatchQueue.items.first(where: { $0.id == id }) else {
                throw ControlHostError.badRequest("The clip was removed from queue history. \(receipt)")
            }
            if item.status == .completed, let file = item.file {
                return .init(file: file.path, node: item.nodeName ?? "Video node",
                             model: item.request.entryID, elapsedSeconds: item.elapsed ?? 0)
            }
            if item.status == .failed {
                throw ControlHostError.badRequest("\(item.error ?? "The render failed.") \(receipt)")
            }
            if let error = videoBatchQueue.storageError {
                throw ControlHostError.badRequest("\(error) \(receipt)")
            }
            if videoBatchQueue.isPaused && item.status == .pending {
                throw ControlHostError.badRequest("The clip is saved in the paused queue; resume it in Video. \(receipt)")
            }
            guard ContinuousClock.now < deadline, !Task.isCancelled else {
                throw ControlHostError.badRequest("Stopped waiting, but the saved clip may still be queued or rendering. \(receipt)")
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch {
                throw ControlHostError.badRequest("Stopped waiting; the saved clip has not been cancelled. \(receipt)")
            }
        }
    }

    public func videoQueueAction(_ action: String, id: String? = nil, confirmNewRender: Bool = false) {
        Task {
            do {
                _ = try await controlVideoQueue(.init(action: action, id: id, confirmNewRender: confirmNewRender))
            } catch { videoQueueMessage = error.localizedDescription }
        }
    }

    public func videoQueue() async -> ControlAPI.VideoQueueView {
        .init(paused: videoBatchQueue.isPaused, activeID: activeVideoQueueID,
              message: videoBatchQueue.storageError ?? videoQueueMessage,
              items: videoBatchQueue.items.map { item in
            .init(id: item.id, batchID: item.batchID, title: item.batchName,
                  prompt: item.request.prompt, scene: item.scene, variation: item.variation,
                  seed: item.request.seed, modelID: item.request.entryID, seconds: item.request.seconds,
                  resolution: item.request.resolution, h3Turbo: item.request.h3Turbo,
                  status: item.status.rawValue, nodeJobID: item.nodeJob?.id, file: item.file?.path,
                  outputDirectory: item.request.outputDirectory.path, error: item.error,
                  uncertainSubmission: item.uncertainSubmission)
        })
    }

    public func enqueueVideos(_ request: ControlAPI.VideoQueueRequest) async throws -> ControlAPI.VideoQueueView {
        // Model/duration defaults are snapshotted now, not read when a later job starts.
        guard let entry = VideoCatalog.entry(id: request.modelID ?? selectedVideoModel) else {
            throw ControlHostError.badRequest("Unknown video model.")
        }
        let template = VideoRequest(
            entryID: entry.id, prompt: "Batch template",
            seconds: request.seconds ?? entry.normalizedSeconds(videoSeconds),
            resolution: request.resolution ?? videoResolution,
            outputDirectory: settings.resolvedVideoOutputDirectory,
            h3Turbo: request.h3Turbo
        )
        do {
            let batch = try videoBatchQueue.enqueue(
                prompts: request.prompts, variations: request.variations ?? 1,
                title: request.title ?? "Video batch", template: template, baseSeed: request.seed
            )
            do { try videoBatchQueue.exportManifest(batchID: batch) }
            catch { videoQueueMessage = "Queue saved, but its editing manifest could not be written: \(error.localizedDescription)" }
        } catch { throw ControlHostError.badRequest(error.localizedDescription) }
        revealVideoPanel(.queue)
        noteActivity()
        startVideoQueueWorker()
        return await videoQueue()
    }

    public func controlVideoQueue(_ request: ControlAPI.VideoQueueControl) async throws -> ControlAPI.VideoQueueView {
        do {
            switch request.action {
            case "pause": try videoBatchQueue.setPaused(true)
            case "resume": try videoBatchQueue.setPaused(false)
            case "retry":
                guard let id = request.id else { throw ControlHostError.badRequest("An item ID is required.") }
                try videoBatchQueue.retry(id, confirmNewRender: request.confirmNewRender ?? false)
            case "remove":
                guard let id = request.id else { throw ControlHostError.badRequest("An item ID is required.") }
                try videoBatchQueue.removePending(id)
            case "clear_finished":
                for batchID in Set(videoBatchQueue.items.map(\.batchID)) {
                    try videoBatchQueue.exportManifest(batchID: batchID)
                }
                try videoBatchQueue.clearFinished()
            default: throw ControlHostError.badRequest("Use pause, resume, retry, remove, or clear_finished.")
            }
        } catch { throw ControlHostError.badRequest(error.localizedDescription) }
        videoQueueMessage = nil
        startVideoQueueWorker()
        return await videoQueue()
    }

    func startVideoQueueWorker() {
        guard videoQueueTask == nil else { return }
        videoQueueTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.processNextQueuedVideo()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func processNextQueuedVideo(peers: [PeerStatus]? = nil) async {
        guard !isGeneratingVideo, let queued = videoBatchQueue.next,
              let entry = VideoCatalog.entry(id: queued.request.entryID) else { return }
        let node: PeerStatus?
        if let pinnedURL = queued.nodeURL, queued.nodeJob != nil {
            // Reconnect only to the original configured peer. A changed peer name
            // must never send its bearer to a different URL saved in a receipt.
            node = (peers ?? swarmPeers).first { peer in
                peer.reachable && peer.name == queued.nodeName
                    && URL(string: peer.baseURL.trimmingCharacters(in: .whitespaces)) == pinnedURL
            }
        } else {
            node = Self.videoCapableNode(for: entry, among: peers ?? swarmPeers)
        }
        guard let node, let base = URL(string: node.baseURL.trimmingCharacters(in: .whitespaces)) else {
            videoQueueMessage = "Waiting for \(queued.nodeName ?? entry.name). The queue is saved; no job has been resubmitted."
            return
        }
        if queued.nodeJob == nil, queued.request.h3Turbo != nil,
           videoCapability(for: entry, on: node)?.supportedParameters.contains("h3_turbo") != true {
            videoQueueMessage = "This H3 node does not advertise per-clip sampling controls. Update its video-node adapter, or use Renderer default for a new batch."
            return
        }
        do {
            // Fail before spending GPU time if the editing destination is not
            // writable. Keep the unsubmitted job pending, not "uncertain".
            try videoBatchQueue.exportManifest(batchID: queued.batchID)
        } catch {
            videoQueueMessage = "Cannot write the batch folder; fix the video destination and resume. \(error.localizedDescription)"
            try? videoBatchQueue.setPaused(true)
            return
        }
        isGeneratingVideo = true
        activeVideoQueueID = queued.id
        videoStage = queued.label
        videoProgress = nil
        videoQueueMessage = nil
        noteActivity()
        defer {
            isGeneratingVideo = false
            activeVideoQueueID = nil
            videoStage = nil
            videoProgress = nil
        }
        do {
            if queued.nodeJob == nil { try videoBatchQueue.begin(queued.id, nodeName: node.name, nodeURL: base) }
            let token = swarmConfig?.bearer(forPeer: node.name)
            var result = try await videoRuntime.generate(
                queued.request, node: base, token: token, resuming: queued.nodeJob,
                onSubmitted: { [weak self] receipt in
                    try await MainActor.run { try self?.videoBatchQueue.accepted(queued.id, job: receipt) }
                },
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        guard self?.activeVideoQueueID == queued.id else { return }
                        self?.videoStage = progress.line(fallback: "Rendering")
                        self?.videoProgress = progress.fraction
                    }
                }
            )
            var destination = queued.request.outputDirectory.appendingPathComponent(queued.filename)
            // Never overwrite a file left between download and receipt persistence.
            // Reconnecting downloads again, but does not generate a second clip.
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = destination.deletingPathExtension()
                    .appendingPathExtension("\(UUID().uuidString.prefix(8)).mp4")
            }
            try FileManager.default.moveItem(at: result.file, to: destination)
            result.file = destination
            try videoBatchQueue.complete(queued.id, result: result)
            videoResults.insert(result, at: 0)
            revealVideoPanel(.queue)
            do { try videoBatchQueue.exportManifest(batchID: queued.batchID) }
            catch { videoQueueMessage = "Clip saved; could not update its manifest: \(error.localizedDescription)" }
        } catch {
            videoQueueMessage = error.localizedDescription
            do {
                try videoBatchQueue.fail(queued.id, message: error.localizedDescription,
                                        terminalNodeFailure: error is VideoNodeFailed)
                try videoBatchQueue.exportManifest(batchID: queued.batchID)
            } catch { videoQueueMessage = error.localizedDescription }
        }
    }
}

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

    public var supportsH3Steps: Bool {
        guard let entry = VideoCatalog.entry(id: selectedVideoModel),
              let peer = videoCapableNode(for: entry) else { return false }
        return videoCapability(for: entry, on: peer)?.supportedParameters.contains("h3_steps") == true
    }

    /// Auto omits the override, preserving old nodes and persisted requests.
    var composerH3Steps: Int? {
        selectedVideoModel == "hailuo-h3" && videoH3Steps != 0 ? videoH3Steps : nil
    }

    public func enqueueVideoComposer() {
        guard !isEnqueuingVideoBatch else { return }
        let seedText = videoBatchSeed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard seedText.isEmpty || UInt32(seedText) != nil else {
            videoQueueMessage = "Base seed must be an integer from 0 through 4,294,967,295, or blank for random."
            return
        }
        let submittedPrompts = videoBatchPrompts
        isEnqueuingVideoBatch = true
        Task {
            defer { isEnqueuingVideoBatch = false }
            do {
                _ = try await enqueueVideos(composerRequest(prompts: submittedPrompts,
                                                            seed: UInt32(seedText)))
                if videoBatchPrompts == submittedPrompts { videoBatchPrompts = "" }
            } catch { videoQueueMessage = error.localizedDescription }
        }
    }

    /// The batch the composer's controls describe.
    ///
    /// "Let Jev pick" is a stored preference, so it outlives the thing that makes it work:
    /// turning Jev off, running out of budget or removing the key must put this composer
    /// back to exactly what it did before, sampling controls and all. So the stored answer
    /// is ANDed with whether routing can actually happen, here, at the moment of queueing —
    /// not where the toggle was drawn, which may have been an hour ago.
    func composerRequest(prompts: String, seed: UInt32?) async -> ControlAPI.VideoQueueRequest {
        let wanted = await mediaRoutingSettings.composerAutoRoute
        let available = await mediaRoutingIsAvailable
        let autoRoute = wanted && available
        return ControlAPI.VideoQueueRequest(
            prompts: VideoBatchQueue.parsePrompts(prompts), title: videoBatchTitle,
            variations: videoBatchVariations,
            modelID: autoRoute ? MediaRoutingQuestions.autoModelID : selectedVideoModel,
            // The picker only offers supported lengths, but a stale selection must not
            // turn into a refused batch; snap it to the model's nearest length.
            seconds: autoRoute
                ? nil
                : VideoCatalog.entry(id: selectedVideoModel)?.normalizedSeconds(videoSeconds)
                    ?? videoSeconds,
            resolution: videoResolution, seed: seed,
            h3Turbo: autoRoute || selectedVideoModel != "hailuo-h3" ? nil : videoSampling.h3Turbo,
            h3Steps: autoRoute ? nil : composerH3Steps
        )
    }

    /// The composer's "Add to queue" button.
    ///
    /// With "Let Jev pick" off — and whenever Jev cannot answer — this is `generateVideo()`
    /// and nothing else: same model, same length, same sampling, same draft handling. With
    /// it on, the prompt chooses the lane and the length first, and the clip carries the one
    /// line saying why.
    public func enqueueVideoClip() {
        guard !isEnqueuingVideoBatch else { return }
        let prompt = videoPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isEnqueuingVideoBatch = true
        Task {
            defer { isEnqueuingVideoBatch = false }
            do {
                // Same rule as the batch composer: the stored preference only counts while
                // routing can actually happen.
                guard await mediaRoutingSettings.composerAutoRoute else {
                    return generateVideo()
                }
                guard let routed = try await mediaRoutedVideo(
                    prompt: prompt, explicitModelID: nil, seconds: nil
                ), let entry = VideoCatalog.entry(id: routed.modelID) else {
                    return generateVideo()
                }
                let request = VideoRequest(
                    entryID: entry.id,
                    prompt: prompt,
                    image: entry.supportsImageInput ? videoImage : nil,
                    seconds: routed.seconds ?? entry.normalizedSeconds(videoSeconds),
                    resolution: videoResolution,
                    outputDirectory: settings.resolvedVideoOutputDirectory,
                    h3Turbo: routed.h3Turbo, h3Steps: routed.h3Steps
                )
                videoError = nil
                _ = try enqueueSingleVideo(request, detail: routed.reason)
                // Only clear the draft once the queue has durably accepted it.
                videoPrompt = ""
                videoImage = nil
            } catch {
                videoError = error.localizedDescription
            }
        }
    }

    @discardableResult
    func enqueueSingleVideo(_ request: VideoRequest, detail: String? = nil) throws -> VideoQueueItem {
        let item = try videoBatchQueue.enqueueSingle(request, detail: detail)
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
        videoBatchQueue.retainReceipt(id)
        defer { videoBatchQueue.releaseReceipt(id) }
        while true {
            try Task.checkCancellation()
            guard let item = videoBatchQueue.receipt(id) else {
                throw ControlHostError.badRequest("The clip was removed from queue history. \(receipt)")
            }
            if item.status == .completed, let file = item.file {
                return .init(file: file.path, node: item.nodeName ?? "Video node",
                             model: item.request.entryID, elapsedSeconds: item.elapsed ?? 0,
                             detail: item.detail)
            }
            if item.status == .failed {
                throw ControlHostError.badRequest("\(item.error ?? "The render failed.") \(receipt)")
            }
            if let error = videoBatchQueue.storageError {
                throw ControlHostError.badRequest("\(error) \(receipt)")
            }
            // A pause (including another clip's transient failure) changes
            // dispatch, not this already-accepted caller's outcome. Keep waiting
            // for resume, a terminal result, disconnect or the original deadline.
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
                  uncertainSubmission: item.uncertainSubmission, h3Steps: item.request.h3Steps,
                  detail: item.detail, negativePrompt: item.request.negativePrompt)
        })
    }

    public func enqueueVideos(_ request: ControlAPI.VideoQueueRequest) async throws -> ControlAPI.VideoQueueView {
        // Bound untrusted counts before routing or multiplying them. The queue repeats
        // these checks at persistence time, but that is after this method builds its detail.
        let variations = request.variations ?? 1
        guard (1...VideoBatchQueue.maximumVariations).contains(variations),
              !request.prompts.isEmpty,
              request.prompts.count <= VideoBatchQueue.maximumPending else {
            throw ControlHostError.badRequest("Use 1–20 variations and between 1 and 200 prompts.")
        }
        // An omitted or "auto" model is the router's cue. It answers nil when Jev is off, no
        // key is stored, the budget is gone or the call failed — and the lines below then do
        // exactly what they did before this feature existed.
        let routed = try await mediaRoutedVideo(
            prompt: Self.routingPrompt(for: request.prompts),
            explicitModelID: request.modelID, seconds: request.seconds
        )
        // "auto" is a routing instruction, never a model id: with nothing to route it back
        // to the app's own selection, which is what an omitted model has always meant.
        let namedID = MediaRoutingQuestions.isAuto(request.modelID) ? nil : request.modelID
        // Model/duration defaults are snapshotted now, not read when a later job starts.
        guard let entry = VideoCatalog.entry(
            id: routed?.modelID ?? namedID ?? selectedVideoModel
        ) else {
            throw ControlHostError.badRequest("Unknown video model.")
        }
        let template = VideoRequest(
            entryID: entry.id, prompt: "Batch template",
            seconds: request.seconds ?? routed?.seconds ?? entry.normalizedSeconds(videoSeconds),
            resolution: request.resolution ?? videoResolution,
            outputDirectory: settings.resolvedVideoOutputDirectory,
            h3Turbo: routed?.h3Turbo ?? request.h3Turbo,
            h3Steps: routed?.h3Steps ?? request.h3Steps,
            // One line for the whole batch, and only where the chosen lane reads it: the
            // batch picks one model for every clip, so what to keep out of frame is a
            // property of the batch rather than of a shot.
            negativePrompt: entry.supportsNegativePrompt
                ? request.negativePrompt?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
                : nil
        )
        // Every clip in a batch carries the same line, because one model and one length
        // were chosen for all of them — from the prompts together, not from this clip's.
        // Saying so stops the line reading like a judgment of the shot it sits under.
        let clipCount = request.prompts.count * variations
        let detail = routed.map { routed in
            clipCount > 1 ? "\(routed.reason) — chosen for the batch" : routed.reason
        }
        do {
            let batch = try videoBatchQueue.enqueue(
                prompts: request.prompts, variations: variations,
                title: request.title ?? "Video batch", template: template, baseSeed: request.seed,
                detail: detail
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
            case "stop_following":
                guard let id = request.id, activeVideoQueueID == id,
                      let render = videoQueueRenderTask else {
                    throw ControlHostError.badRequest("That clip is not currently being followed by the app.")
                }
                // Save the pause before interrupting transport. Never advertise
                // a remote GPU cancellation: the node may still finish this job.
                try videoBatchQueue.setPaused(true)
                render.cancel()
            case "clear_finished":
                for batchID in Set(videoBatchQueue.items.map(\.batchID)) {
                    try videoBatchQueue.exportManifest(batchID: batchID)
                }
                try videoBatchQueue.clearFinished()
            default: throw ControlHostError.badRequest(ControlServer.unknownQueueAction)
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
        guard !isGeneratingVideo, videoBatchQueue.next != nil else { return }
        // The saved peer list is only as fresh as the last poll, and nothing else polls
        // while the app sits on this tab overnight. Ask again (at most every twenty
        // seconds) before choosing a node, so a node that went away and came back is
        // used instead of the queue waiting on a stale "unreachable" or failing on a
        // stale "reachable". Tests hand in peers directly and skip the network.
        if peers == nil { await refreshSwarmIfStale() }
        // Re-read after the await: the user may have removed or paused meanwhile.
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
        if queued.nodeJob == nil, queued.request.h3Steps != nil,
           videoCapability(for: entry, on: node)?.supportedParameters.contains("h3_steps") != true {
            videoQueueMessage = "This H3 node does not advertise denoising steps. Update its adapter and Phosphene, or choose Auto for a new clip. The saved override has not been dropped."
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
            videoQueueRenderTask = nil
        }
        do {
            if queued.nodeJob == nil { try videoBatchQueue.begin(queued.id, nodeName: node.name, nodeURL: base) }
            let token = swarmConfig?.bearer(forPeer: node.name)
            let render = Task { try await videoRuntime.generate(
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
            ) }
            videoQueueRenderTask = render
            var result = try await withTaskCancellationHandler {
                try await render.value
            } onCancel: { render.cancel() }
            videoQueueRenderTask = nil
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
            let message = videoQueueRenderTask?.isCancelled == true && !(error is VideoNodeFailed)
                ? "Stopped following. The node may still be rendering; use Reconnect / download to retrieve the same job, or check the node before rendering again."
                : error.localizedDescription
            videoQueueMessage = message
            do {
                try videoBatchQueue.fail(queued.id, message: message,
                                        terminalNodeFailure: error is VideoNodeFailed)
                try videoBatchQueue.exportManifest(batchID: queued.batchID)
            } catch { videoQueueMessage = error.localizedDescription }
        }
    }
}

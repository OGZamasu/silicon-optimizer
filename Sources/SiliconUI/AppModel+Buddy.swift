import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SiliconCatalog
import SiliconControl
import SiliconCore
import SiliconRuntime

/// The Mac half of Silicon Buddy: the streaming and conversation routes the phone apps use,
/// and the Settings section that lets a phone in.
///
/// Nothing here is reachable until the owner turns the toggle on. With it off the control
/// server is what it always was — loopback, one token, nothing on the tailnet.
extension AppModel {

    // MARK: - Streaming chat

    public func chatStream(
        _ request: ControlAPI.ChatRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        guard let runtime = activeRuntime, runtimeState.isRunning else {
            throw ControlHostError.noModelLoaded
        }
        if let refusal = BuddyLimits.refusal(
            forImages: request.messages.flatMap(\.images)
        ) {
            throw ControlHostError.badRequest(refusal)
        }
        let chatRequest = ChatRequest(
            messages: request.messages.map {
                ChatMessage(
                    role: ChatMessage.Role(rawValue: $0.role) ?? .user,
                    content: $0.content, images: $0.images
                )
            },
            temperature: request.temperature ?? settings.temperature,
            topP: settings.topP,
            maxTokens: request.maxTokens ?? (settings.maxTokens > 0 ? settings.maxTokens : nil),
            reasoningEffort: settings.reasoningEffort.isEmpty ? nil : settings.reasoningEffort
        )
        let budget = chatRequest.maxTokens
        return streamed { [weak self] emit in
            guard let self else { return }
            var answer = ""
            var finished = GenerationMetrics()
            // Like `chat`, this path has no `generationTask`, so without `whileGenerating`
            // a long answer reads as idleness — and the idle timer unloads the model, or
            // the Mac sleeps, halfway through writing it.
            try await self.whileGenerating {
                for try await event in try await runtime.chat(chatRequest) {
                    switch event {
                    case .token(let token):
                        answer += token
                        emit(.token(token))
                    case .reasoningToken(let token): emit(.reasoning(token))
                    case .finished(let metrics):
                        self.lastGeneration = metrics
                        finished = metrics
                        emit(.finished(Self.metrics(metrics)))
                    }
                }
            }
            // `POST /chat/stream` has no transcript, so a verdict that misses the stream
            // has nowhere to go: no message to hang it on, no id to key an `/events` frame
            // to. It is bounded like the conversation path and simply dropped if it is
            // late — which is why the stateful route is the one to use if you want the
            // verdict guaranteed.
            let work = Task { @MainActor [weak self] in
                guard let self else { return nil as ControlAPI.ChatVerdict? }
                return await self.whileGenerating {
                    await self.streamVerdict(
                        prompt: VerificationPrompt(messages: request.messages),
                        reply: answer, metrics: finished, budget: budget
                    )
                }
            }
            if let verdict = await VerdictRelay.result(of: work, within: Self.verdictGrace) {
                emit(.verdict(verdict))
            }
        }
    }

    /// How long a stream will hold itself open waiting for Jev before closing without the
    /// verdict.
    ///
    /// Jev answers in about 100 ms, so this is not a budget, it is a backstop: a TypeSafe
    /// hiccup must not turn into a chat that appears to hang after its last token. The
    /// conversation path loses nothing when it trips — the verdict still lands on the
    /// message and on `/events` a moment later.
    static let verdictGrace: Duration = .seconds(3)

    /// The `verdict` frame, or nil when verification is off or found nothing worth saying.
    ///
    /// Deliberately after the whole answer and deliberately without escalating. Jev reads a
    /// finished reply, and the reply is not finished until the last token — and by then the
    /// reader has it. See `JevVerifier.streamSuggestion` for why a stream suggests rather
    /// than substitutes; `POST /chat`, which has shown nothing, does escalate.
    func streamVerdict(
        prompt: VerificationPrompt, reply: String, metrics: GenerationMetrics, budget: Int?,
        conversationID: String? = nil, messageID: String? = nil,
        using override: JevVerifier? = nil
    ) async -> ControlAPI.ChatVerdict? {
        guard !reply.isEmpty else { return nil }
        guard let (verdict, target) = await verifyWithoutEscalating(
            prompt: prompt, reply: reply,
            truncated: metrics.wasTruncated(budget: budget), using: override
        ) else { return nil }
        // Nothing fired. A frame saying so is noise on a phone; silence is the accept.
        guard verdict != .accept else { return nil }
        return ControlAPI.ChatVerdict(
            verdict: verdict.name,
            reasons: verdict.reasons,
            escalatedTo: nil,
            suggestion: {
                if case .escalate = verdict { return JevVerifier.streamSuggestion(target: target) }
                return nil
            }(),
            conversationID: conversationID,
            messageID: messageID
        )
    }

    // MARK: - Conversations

    public func conversationList() async -> [ControlAPI.ConversationSummary] {
        conversations.map(Self.summarize)
    }

    public func createConversation(title: String?) async -> ControlAPI.ConversationSummary {
        var conversation = Conversation()
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { conversation.title = String(trimmed.prefix(60)) }
        // At the top of the sidebar, but not selected. A phone starting a thread must not
        // move the cursor out from under whoever is typing at the Mac.
        conversations.insert(conversation, at: 0)
        if selectedConversationID == nil { selectedConversationID = conversation.id }
        return Self.summarize(conversation)
    }

    public func conversation(id: String) async throws -> ControlAPI.ConversationDetail {
        guard let conversation = conversations.first(where: { $0.id.uuidString == id }) else {
            throw BuddyHostError.noSuchConversation(id)
        }
        return ControlAPI.ConversationDetail(
            id: conversation.id.uuidString,
            title: conversation.title,
            updatedAt: ControlAPI.timestamp(Self.updatedAt(conversation)),
            isGenerating: isAnswering(conversation.id),
            messages: conversation.messages.map {
                .init(
                    role: $0.role.rawValue, content: $0.content,
                    createdAt: ControlAPI.timestamp($0.createdAt),
                    id: $0.id.uuidString, verification: $0.verification
                )
            }
        )
    }

    public func replyInConversation(
        id: String, to message: ControlAPI.NewMessageRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        // Most specific first: which conversation, then whether it is free, then whether
        // anything can answer at all. A busy thread is a 409 whatever the runtime is doing,
        // and it could not be busy without a model loaded anyway.
        guard let index = conversations.firstIndex(where: { $0.id.uuidString == id }) else {
            throw BuddyHostError.noSuchConversation(id)
        }
        // Two answers being written into one transcript interleave, and the second request
        // would carry the first one's half-finished reply as context. Refuse instead.
        guard !isAnswering(conversations[index].id) else {
            throw BuddyHostError.conversationBusy(id)
        }
        guard let runtime = activeRuntime, runtimeState.isRunning else {
            throw ControlHostError.noModelLoaded
        }
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ControlHostError.badRequest("A message needs something in it.")
        }
        if let refusal = BuddyLimits.refusal(forImages: message.images) {
            throw ControlHostError.badRequest(refusal)
        }
        noteActivity()

        conversations[index].messages.append(
            ChatMessage(role: .user, content: message.content, images: message.images)
        )
        let reply = ChatMessage(role: .assistant, content: "")
        conversations[index].messages.append(reply)
        let replyID = reply.id
        if conversations[index].title == Conversation.untitled {
            conversations[index].title = String(text.prefix(60))
        }

        let conversationID = conversations[index].id
        BuddyGenerations.shared.begin(conversationID)
        let chatRequest = ChatRequest(
            messages: conversations[index].messages.dropLast().map { $0 },
            temperature: message.temperature ?? settings.temperature,
            topP: settings.topP,
            maxTokens: message.maxTokens ?? (settings.maxTokens > 0 ? settings.maxTokens : nil),
            reasoningEffort: settings.reasoningEffort.isEmpty ? nil : settings.reasoningEffort
        )

        let budget = chatRequest.maxTokens
        let asked = chatRequest.messages
        return streamed { [weak self] emit in
            guard let self else { return }
            defer { BuddyGenerations.shared.end(conversationID) }
            var answer = ""
            var finished = GenerationMetrics()
            do {
                try await self.whileGenerating {
                    for try await event in try await runtime.chat(chatRequest) {
                        switch event {
                        case .token(let token):
                            answer += token
                            self.append(token, to: replyID, in: conversationID, reasoning: false)
                            emit(.token(token))
                        case .reasoningToken(let token):
                            self.append(token, to: replyID, in: conversationID, reasoning: true)
                            emit(.reasoning(token))
                        case .finished(let metrics):
                            self.lastGeneration = metrics
                            finished = metrics
                            emit(.finished(Self.metrics(metrics)))
                        }
                    }
                }
            } catch {
                // The half-written answer is already in the transcript both screens read.
                // Saying so there is the difference between "the model stopped" and "the
                // Mac lost the thread", which is what a blank bubble looks like.
                self.append(
                    "\n\n_Generation failed: \(error.localizedDescription)_",
                    to: replyID, in: conversationID, reasoning: false
                )
                throw error
            }
            // The verdict outlives this stream. It is written onto the message and posted
            // to `/events`, keyed by the two ids, so a phone that has already closed the
            // stream — or was not listening at all — still gets it, from the transcript if
            // not from the wire.
            let work = Task { @MainActor [weak self] in
                guard let self else { return nil as ControlAPI.ChatVerdict? }
                let verdict = await self.whileGenerating {
                    await self.streamVerdict(
                        prompt: VerificationPrompt(
                            messages: asked.map {
                                .init(
                                    role: $0.role.rawValue, content: $0.content,
                                    images: $0.images
                                )
                            }
                        ),
                        reply: answer, metrics: finished, budget: budget,
                        conversationID: conversationID.uuidString,
                        messageID: replyID.uuidString
                    )
                }
                guard let verdict else { return nil }
                self.attach(verdict, to: replyID, in: conversationID)
                await BuddyEventHub.shared.post(.verdict(verdict))
                return verdict
            }
            // …and the stream still closes at `finished` if Jev is slow, rather than
            // leaving a phone watching a socket that has nothing left to say.
            if let verdict = await VerdictRelay.result(of: work, within: Self.verdictGrace) {
                emit(.verdict(verdict))
            }
        }
    }

    /// Writes a verdict onto the message it is about, so `GET /conversations/{id}` carries
    /// it for as long as the thread exists.
    private func attach(
        _ verdict: ControlAPI.ChatVerdict, to messageID: UUID, in conversationID: Conversation.ID
    ) {
        guard let conversation = conversations.firstIndex(where: { $0.id == conversationID }),
              let message = conversations[conversation].messages.firstIndex(
                  where: { $0.id == messageID }
              )
        else { return }
        conversations[conversation].messages[message].verification = verdict
    }

    /// Appends into a named conversation rather than the selected one: a phone can be
    /// talking in a thread the Mac is not looking at.
    private func append(
        _ token: String, to messageID: UUID, in conversationID: Conversation.ID, reasoning: Bool
    ) {
        guard let conversation = conversations.firstIndex(where: { $0.id == conversationID }),
              let message = conversations[conversation].messages.firstIndex(
                  where: { $0.id == messageID }
              )
        else { return }
        if reasoning {
            let existing = conversations[conversation].messages[message].reasoning ?? ""
            conversations[conversation].messages[message].reasoning = existing + token
        } else {
            conversations[conversation].messages[message].content += token
        }
    }

    /// Whether an answer is still being written into this conversation — by a phone or by
    /// the Mac's own chat window, both of which register here.
    ///
    /// Keyed on the conversation, never on which one happens to be selected: the Mac can be
    /// answering in one thread while the sidebar shows another, and asking about selection
    /// would both miss that and falsely refuse the thread that is merely on screen.
    func isAnswering(_ id: Conversation.ID) -> Bool {
        BuddyGenerations.shared.isBusy(id)
    }

    // MARK: - The /events side channel

    public func beginEventUpdates(postingTo hub: BuddyEventHub) async {
        BuddyEventPump.shared.start(watching: self, hub: hub)
        // Its own watcher rather than another field on this one: the agent sessions are
        // sampled ten times a second so streamed prose arrives promptly, and the status
        // and download frames have no use for that rate. Started only for a subscriber
        // allowed to see them — a chat-only phone or the swarm on `/events` is sent no
        // agent frames, so reading transcripts on its behalf would be work for nothing.
        if await hub.agentAudienceCount > 0 {
            AgentEventPump.shared.start(watching: self, hub: hub)
        }
    }

    /// What a subscriber would want to know right now. Built whole and diffed, rather than
    /// posted from the places state changes: those places are in `AppModel.swift`, which
    /// this milestone does not touch, and a watcher that samples cannot miss an update by
    /// forgetting to announce one.
    ///
    /// - Parameter registry: The table finished files are published from. The shared one,
    ///   except in a test that must not add entries to the owner's.
    func buddyEventSnapshot(
        registry: MediaRegistry = .shared
    ) async -> BuddyEventPump.Snapshot {
        var jobs: [String: ControlAPI.JobEvent] = [:]
        let queue = await videoQueue()
        let roots = await controlMediaRoots()
        for item in queue.items {
            let active = item.id == activeVideoQueueID
            // Registered against the shared table the control server publishes from, so the
            // id on the frame that says "done" is the id `GET /video/queue` was already
            // handing out — one fetch, not a second poll to find out what to fetch.
            var mediaID: String?
            if let file = item.file {
                mediaID = await registry.register(path: file, within: roots)
            }
            jobs[item.id] = Self.jobEvent(
                for: item, active: active,
                fraction: active ? videoProgress : nil,
                stage: active ? videoStage : nil,
                mediaID: mediaID
            )
        }
        if let image = currentImageJob {
            jobs["image"] = ControlAPI.JobEvent(
                id: "image", kind: "image", status: "running", title: image.modelName,
                fraction: imageProgress.map { $0.total > 0 ? Double($0.step) / Double($0.total) : nil } ?? nil,
                stage: imageState.stageLine
            )
        } else if let ending = lastImageEnding {
            var mediaID: String?
            if let file = ending.file {
                mediaID = await registry.register(path: file.path, within: roots)
            }
            jobs["image"] = Self.jobEvent(
                id: "image", kind: "image", ending: ending, mediaID: mediaID
            )
        }
        if let mesh = currentMeshJob {
            jobs["mesh"] = ControlAPI.JobEvent(
                id: "mesh", kind: "mesh", status: "running", title: mesh.modelName,
                fraction: meshProgress,
                stage: meshState.stageLine
            )
        } else if let ending = lastMeshEnding {
            var mediaID: String?
            if let file = ending.file {
                mediaID = await registry.register(path: file.path, within: roots)
            }
            jobs["mesh"] = Self.jobEvent(
                id: "mesh", kind: "mesh", ending: ending, mediaID: mediaID
            )
        }
        await registry.persist()

        var downloads: [String: ControlAPI.DownloadEvent] = [:]
        for transfer in activeTransfers {
            downloads[transfer.id] = ControlAPI.DownloadEvent(
                id: transfer.id, name: transfer.name,
                fraction: transfer.progress?.fraction ?? 0,
                bytesReceived: transfer.progress?.bytesReceived.rawValue ?? 0,
                bytesExpected: transfer.progress?.bytesExpected.rawValue ?? 0,
                bytesPerSecond: transfer.progress?.bytesPerSecond ?? 0,
                error: transfer.error
            )
        }
        return BuddyEventPump.Snapshot(
            status: await status(), downloads: downloads, jobs: jobs
        )
    }

    /// One queue item as a `job` frame.
    ///
    /// Its own function, and pure, because two of its three optional fields are rules
    /// rather than copies and a rule that only exists inside a snapshot builder is a rule
    /// nothing can check.
    ///
    /// `stage` belongs to the clip the app is actually following: one waiting its turn has
    /// a status, and inventing a stage for it would be a sentence the renderer never said.
    /// `reason` belongs to a clip the Mac has *given up on* — a transient failure that is
    /// waiting to be retried carries an `error` too, and a phone announcing that beside a
    /// pending status would be reporting a failure that has not happened.
    nonisolated static func jobEvent(
        for item: ControlAPI.VideoQueueView.Item, active: Bool,
        fraction: Double?, stage: String?, mediaID: String?
    ) -> ControlAPI.JobEvent {
        ControlAPI.JobEvent(
            id: item.id, kind: "video", status: item.status, title: item.title,
            fraction: active ? fraction : nil,
            stage: active ? stage : nil,
            reason: item.status == VideoQueueStatus.failed.rawValue ? item.error
                : item.status == VideoQueueStatus.cancelled.rawValue ? item.cancelDetail : nil,
            mediaID: mediaID
        )
    }

    /// The last frame of an image or mesh job that has left its queue: the same three
    /// endings a clip has, and the file to fetch when there is one.
    nonisolated static func jobEvent(
        id: String, kind: String, ending: RenderEnding, mediaID: String?
    ) -> ControlAPI.JobEvent {
        ControlAPI.JobEvent(
            id: id, kind: kind, status: ending.status.rawValue, title: ending.title,
            reason: ending.reason, mediaID: ending.status == .completed ? mediaID : nil
        )
    }

    /// A download that has left the transfer list, as its last frame: arrived when what it
    /// was fetching is installed now, stopped when it is not. Both end with nothing moving,
    /// so a phone's "Happening now" lets go of it either way.
    func settledDownload(_ last: ControlAPI.DownloadEvent) -> ControlAPI.DownloadEvent {
        hasInstalled(downloadID: last.id)
            ? BuddyEventPump.arrived(last) : BuddyEventPump.stopped(last)
    }

    /// Whether the thing a transfer with this id was fetching is on this Mac now. The ids
    /// are the ones `activeTransfers` hands out: `<entry>@<quantization>` for a language
    /// model, which is also its library id, and the catalog entry's own id for an image or
    /// 3D model.
    func hasInstalled(downloadID id: String) -> Bool {
        if installedModels.contains(where: { $0.id == id }) { return true }
        if let entry = DiffusionCatalog.entry(id: id) { return isImageModelInstalled(entry) }
        if let entry = MeshCatalog.entry(id: id) { return meshInstallation(for: entry).isInstalled }
        return false
    }

    // MARK: - Shapes

    static func summarize(_ conversation: Conversation) -> ControlAPI.ConversationSummary {
        ControlAPI.ConversationSummary(
            id: conversation.id.uuidString,
            title: conversation.title,
            updatedAt: ControlAPI.timestamp(updatedAt(conversation)),
            messageCount: conversation.messages.count
        )
    }

    /// A conversation has no modification date of its own; its last message is the closest
    /// honest answer, and an empty one falls back to when it was started.
    static func updatedAt(_ conversation: Conversation) -> Date {
        conversation.messages.last?.createdAt ?? conversation.createdAt
    }

    static func metrics(_ metrics: GenerationMetrics) -> ControlAPI.ChatMetrics {
        ControlAPI.ChatMetrics(
            promptTokens: metrics.promptTokens,
            generatedTokens: metrics.generatedTokens,
            tokensPerSecond: metrics.generationTokensPerSecond,
            timeToFirstToken: metrics.timeToFirstToken
        )
    }

    /// Wraps a main-actor generator in a stream the control server can consume, and wires
    /// the consumer's disappearance to the generator's cancellation — which is what stops
    /// the model when a phone locks its screen mid-answer.
    private func streamed(
        _ body: @escaping @MainActor @Sendable (
            @escaping @MainActor (ControlAPI.ChatStreamEvent) -> Void
        ) async throws -> Void
    ) -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task { @MainActor in
                do {
                    try await body { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

// MARK: - Waiting a little, but not indefinitely

/// Takes a task's result if it arrives inside a deadline, and otherwise gives up on
/// *waiting* — never on the task, which keeps running and finishes what it started.
///
/// That asymmetry is the whole point here. The verdict has two jobs: catching the stream
/// that is still open, and landing on the message for everyone who reads it later. Only the
/// first has a deadline. Cancelling the work when the deadline passed would throw away the
/// second, which is the one that always matters.
enum VerdictRelay {

    static func result<Value: Sendable>(
        of work: Task<Value?, Never>, within duration: Duration
    ) async -> Value? {
        let slot = Slot<Value>()
        // `await work.value` is not cancellable for a non-throwing task, so the wait cannot
        // be raced inside a task group — the group would sit on it anyway. A mailbox the
        // timer can also post to is what makes the deadline real.
        let forward = Task { await slot.deliver(work.value) }
        let timer = Task {
            try? await Task.sleep(for: duration)
            await slot.giveUp()
        }
        defer { forward.cancel(); timer.cancel() }
        return await slot.take()
    }

    private actor Slot<Value: Sendable> {
        private var waiting: CheckedContinuation<Value?, Never>?
        private var settled = false
        private var value: Value?

        func deliver(_ value: Value?) { finish(value) }
        func giveUp() { finish(nil) }

        /// First writer wins, so a verdict that beat the timer is not overwritten by it.
        private func finish(_ value: Value?) {
            guard !settled else { return }
            settled = true
            self.value = value
            waiting?.resume(returning: value)
            waiting = nil
        }

        /// Kept rather than dropped when it arrives before anyone asks: on a warm cache
        /// the verdict can be ready before the caller reaches this line.
        func take() async -> Value? {
            if settled { return value }
            return await withCheckedContinuation { continuation in
                waiting = continuation
            }
        }
    }
}

// MARK: - How a render ended

/// How the last job in the Images or 3D queue ended, kept for `/events`.
///
/// Those queues are reported as one frame each, `image` and `mesh`, for the job running now.
/// When it finishes there is no job running, and a frame that simply stopped being sent left
/// a phone showing the render as running for ever — and with no file to fetch. So the frame
/// stays, saying how the render ended in the video queue's words, until the next one starts.
struct RenderEnding: Sendable, Equatable {
    var status: VideoQueueStatus
    var title: String
    var reason: String?
    /// What it made, when it made something.
    var file: URL?

    /// From a job's outcome: done with its file, stopped or taken out of the queue at the
    /// Mac, or failed with the renderer's own sentence.
    init(title: String, outcome: Result<URL?, any Error>) {
        self.title = title
        switch outcome {
        case .success(let file):
            status = .completed
            self.file = file
        case .failure(let error as QueuedRenderError):
            status = .cancelled
            reason = error.localizedDescription
        case .failure(let error):
            status = .failed
            reason = error.localizedDescription
        }
    }
}

// MARK: - Watching the Mac for subscribers

/// Samples the app's state while at least one `/events` stream is open, and posts what
/// changed.
///
/// A singleton for the same reason `BuddyCenter` is one: `AppModel` is `@Observable` and an
/// extension cannot add a stored property to hold the task. Sampling at a second's cadence
/// is deliberate — the alternative is a `didSet` on half a dozen properties in the file this
/// milestone is not allowed to touch, and a phone does not need per-token status updates.
@MainActor
public final class BuddyEventPump {

    public static let shared = BuddyEventPump()

    /// Everything a subscriber is told about, as one reading.
    public struct Snapshot: Sendable {
        public var status: ControlAPI.Status
        public var downloads: [String: ControlAPI.DownloadEvent]
        public var jobs: [String: ControlAPI.JobEvent]

        public init(
            status: ControlAPI.Status,
            downloads: [String: ControlAPI.DownloadEvent],
            jobs: [String: ControlAPI.JobEvent]
        ) {
            self.status = status
            self.downloads = downloads
            self.jobs = jobs
        }
    }

    private var task: Task<Void, Never>?
    /// Bumped on every stop, so a task that is winding down can tell whether the handle it
    /// is about to clear is still its own.
    private var generation = UUID()
    /// Which model and which hub the running loop is watching.
    ///
    /// One of each exists in the app, so this never changes there. It changes constantly
    /// under a test suite, and the singleton was answering "already running" to a start
    /// against a *different* hub — leaving the loop feeding a hub nobody reads while the
    /// one with a subscriber on it got nothing but heartbeats.
    private var watching: WatchTarget?
    /// Incremented on every start request. A task that reads "no subscribers" and then sees
    /// this move knows a phone arrived during that await, and keeps going — otherwise the
    /// new subscriber would find a pump that had just decided to stop and a handle that was
    /// not yet free, and get nothing but heartbeats for the rest of the session.
    private var startRequests = 0
    /// What the running loop last read of `PaidLanes.allowed`. Read by the test that proves
    /// the request that happened to start the loop does not decide it for the loop's life.
    private(set) var paidLanesOpenInLoop: Bool?

    public init() {}

    public var isRunning: Bool { task != nil }

    func start(
        watching model: AppModel, hub: BuddyEventHub = .shared,
        interval: Duration = .seconds(1)
    ) {
        startRequests += 1
        let target = WatchTarget(model: model, hub: hub)
        // Already doing exactly this: nothing to do, and starting a second loop would
        // double every frame.
        if task != nil, watching == target { return }
        // Running against something else. Whatever it was watching, this is the reader
        // that is actually here, so the loop is re-pointed rather than turned away.
        if task != nil { stop() }
        watching = target
        let mine = UUID()
        generation = mine
        // Whoever subscribes first starts this loop, and the swarm may be first: see
        // `PaidLanes.forTheApp`.
        task = PaidLanes.forTheApp {
            Task { [weak self, weak model] in
                var previous: Snapshot?
                while !Task.isCancelled {
                    guard let self, let model else { break }
                    self.paidLanesOpenInLoop = PaidLanes.allowed
                    let requestsBefore = self.startRequests
                    let subscribers = await hub.subscriberCount
                    if self.shouldStop(subscribers: subscribers, requestsAtCheck: requestsBefore) {
                        // No await between the decision and the handle, so a `start` racing
                        // this either bumped the counter above or is yet to run at all.
                        if self.generation == mine { self.task = nil }
                        return
                    }
                    let current = await model.buddyEventSnapshot()
                    for event in Self.changes(
                        from: previous, to: current, settling: model.settledDownload
                    ) {
                        await hub.post(event)
                    }
                    previous = current
                    guard (try? await Task.sleep(for: interval)) != nil else { break }
                }
                if self?.generation == mine { self?.task = nil }
            }
        }
    }

    public func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        watching = nil
    }

    /// Whether the loop should give up: nobody is reading, and nobody asked it to keep
    /// going while it was finding that out.
    ///
    /// The second half is the whole point. Reading `subscriberCount` is an await, and a
    /// phone connecting during it calls `start`, which sees a handle that is not yet free
    /// and returns — leaving nothing running and a subscriber getting heartbeats for the
    /// rest of the session. Comparing the counter is how the loop notices that happened.
    func shouldStop(subscribers: Int, requestsAtCheck: Int) -> Bool {
        subscribers == 0 && startRequests == requestsAtCheck
    }

    /// How many starts have been asked for. Read by the test that pins the rule above.
    var startRequestCount: Int { startRequests }

    /// The first reading is entirely news — a phone that has just connected knows nothing,
    /// so it gets the current state rather than waiting for something to move.
    ///
    /// Something that leaves the reading is news too. A phone holds on to every download
    /// and render it has been told about until a frame says it is over, so one that simply
    /// stops being mentioned stays "happening now" on the phone for ever. A download is
    /// announced once more as `settle` says it ended; a render taken out of a queue, as
    /// cancelled. Anything whose last frame already said it was over is left alone.
    static func changes(
        from previous: Snapshot?, to current: Snapshot,
        settling settle: (ControlAPI.DownloadEvent) -> ControlAPI.DownloadEvent = BuddyEventPump.stopped
    ) -> [BuddyEvent] {
        var events: [BuddyEvent] = []
        if previous.map({ !matches($0.status, current.status) }) ?? true {
            events.append(.status(current.status))
        }
        for (id, download) in current.downloads.sorted(by: { $0.key < $1.key })
        where previous?.downloads[id] != download {
            events.append(.download(download))
        }
        for (id, last) in (previous?.downloads ?? [:]).sorted(by: { $0.key < $1.key })
        where current.downloads[id] == nil && !isOver(last) {
            events.append(.download(settle(last)))
        }
        for (id, job) in current.jobs.sorted(by: { $0.key < $1.key })
        where previous?.jobs[id] != job {
            events.append(.job(job))
        }
        for (id, last) in (previous?.jobs ?? [:]).sorted(by: { $0.key < $1.key })
        where current.jobs[id] == nil && !isOver(last) {
            events.append(.job(removed(last)))
        }
        return events
    }

    /// The words a job's status is over in — the video queue's, which the image and mesh
    /// frames share.
    nonisolated static let finishedStatuses: Set<String> = [
        VideoQueueStatus.completed.rawValue, VideoQueueStatus.failed.rawValue,
        VideoQueueStatus.cancelled.rawValue,
    ]

    nonisolated static func isOver(_ job: ControlAPI.JobEvent) -> Bool {
        finishedStatuses.contains(job.status)
    }

    /// Done is `fraction: 1`; failed or stopped carries an `error`. The same two endings
    /// `PhoneModelService` gives the downloads it runs for a phone.
    nonisolated static func isOver(_ download: ControlAPI.DownloadEvent) -> Bool {
        download.fraction >= 1 || download.error != nil
    }

    /// Why a job went from a reading without saying it was over: somebody at the Mac took
    /// it out of the queue, and it will not run now.
    nonisolated static let removedFromQueue = "Removed from the queue on the Mac before it finished."

    /// Why a download went from a reading without arriving.
    nonisolated static let downloadStopped = "Stopped on the Mac before it finished."

    nonisolated static func removed(_ job: ControlAPI.JobEvent) -> ControlAPI.JobEvent {
        ControlAPI.JobEvent(
            id: job.id, kind: job.kind, status: VideoQueueStatus.cancelled.rawValue,
            title: job.title, reason: removedFromQueue
        )
    }

    nonisolated static func arrived(
        _ download: ControlAPI.DownloadEvent
    ) -> ControlAPI.DownloadEvent {
        var done = download
        done.fraction = 1
        done.bytesReceived = max(download.bytesReceived, download.bytesExpected)
        done.bytesPerSecond = 0
        done.error = nil
        done.stage = nil
        return done
    }

    nonisolated static func stopped(
        _ download: ControlAPI.DownloadEvent
    ) -> ControlAPI.DownloadEvent {
        var stopped = download
        stopped.bytesPerSecond = 0
        stopped.error = downloadStopped
        stopped.stage = nil
        return stopped
    }

    /// `ControlAPI.Status` is part of a frozen wire contract and deliberately not
    /// `Equatable`; comparing the bytes it would send is the comparison that matters here.
    private static func matches(_ left: ControlAPI.Status, _ right: ControlAPI.Status) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(left)) == (try? encoder.encode(right))
    }
}

/// Which conversations have an answer in flight, for the same reason `BuddyEventPump` is a
/// singleton: `AppModel` is `@Observable` and an extension cannot add a stored property.
///
/// Both halves of the app register here — the Chat tab in `AppModel.send` and a phone in
/// `replyInConversation` — so "is this thread busy?" has one answer rather than two that
/// disagree.
@MainActor
public final class BuddyGenerations {

    public static let shared = BuddyGenerations()

    private var active: Set<Conversation.ID> = []

    public init() {}

    public func isBusy(_ id: Conversation.ID) -> Bool { active.contains(id) }
    public func begin(_ id: Conversation.ID) { active.insert(id) }
    public func end(_ id: Conversation.ID) { active.remove(id) }
}

// MARK: - Settings state

/// The Silicon Buddy section's own state.
///
/// `AppModel` is `@Observable` and an extension cannot add stored properties to it, so the
/// buddy screen keeps its state here instead. `BuddyRegistry` remains the source of truth
/// on disk; this is the copy the window draws from.
@MainActor
@Observable
public final class BuddyCenter {

    public static let shared = BuddyCenter()

    public private(set) var allowsTailnetDevices = false
    public private(set) var devices: [ControlAPI.BuddyDeviceSummary] = []
    public private(set) var invitation: BuddyInvitation?
    /// What the next pairing grants. Full control is the default: the owner is standing
    /// over the device, approving it by hand, and remote parity is the point.
    public var nextScope: BuddyScope = .full
    /// Where the QR says to dial, once the listener is actually up.
    public private(set) var reachAddress: String?
    public private(set) var problem: String?
    public private(set) var isBusy = false

    private let registry: BuddyRegistry
    private var expiryTask: Task<Void, Never>?

    public init(registry: BuddyRegistry = .shared) {
        self.registry = registry
    }

    public func refresh(server: ControlServer?) async {
        allowsTailnetDevices = await registry.allowsTailnetDevices
        devices = await registry.devices()
        adopt(await registry.openInvitation())
        reachAddress = await server?.tailnetListenerAddress
        problem = await server?.tailnetError
    }

    public func setAllowsTailnetDevices(_ allowed: Bool, server: ControlServer?) async {
        isBusy = true
        defer { isBusy = false }
        await registry.setAllowsTailnetDevices(allowed)
        if !allowed { await cancelInvitation() }
        await server?.refreshTailnetAccess()
        await refresh(server: server)
    }

    /// Opens a pairing code. Refuses rather than drawing a QR nobody can reach: a code
    /// pointing at a listener that is not up is a minute of someone's life.
    public func pairDevice(server: ControlServer?, scope: BuddyScope? = nil) async {
        isBusy = true
        defer { isBusy = false }
        await refresh(server: server)
        guard allowsTailnetDevices else {
            problem = "Turn Silicon Buddy on first — pairing rides on the tailnet listener."
            return
        }
        // The tailnet listener's port, never loopback's: loopback takes a fresh ephemeral
        // port every launch, and a QR pointing at yesterday's is a QR that stops working.
        guard let host = reachAddress, let port = await server?.tailnetListenerPort, port > 0
        else {
            problem = problem ?? "The tailnet listener is not up yet. Try again in a moment."
            return
        }
        problem = nil
        let granting = scope ?? nextScope
        nextScope = granting
        adopt(await registry.invite(host: host, port: port, scope: granting))
    }

    /// Called while the sheet is open. A code that has just been spent should turn into the
    /// new device's row, not sit there looking live.
    public func followPairing(server: ControlServer?) async -> Bool {
        let stillOpen = await registry.openInvitation()
        guard stillOpen == nil, invitation != nil else {
            adopt(stillOpen)
            return false
        }
        adopt(nil)
        await refresh(server: server)
        return true
    }

    public func cancelInvitation() async {
        cancelExpiry()
        await registry.cancelInvitation()
        invitation = nil
    }

    public func revoke(_ id: String) async {
        await registry.revoke(deviceID: id)
        devices = await registry.devices()
    }

    /// Takes up whatever invitation is open now, re-arming the expiry whenever the code
    /// on screen is a different one.
    ///
    /// The code is the identity, and this has to notice a swap rather than merely an
    /// arrival. `POST /buddy/invitations` can mint underneath an open pairing sheet, and
    /// the sheet's poll adopts what it finds — which leaves the expiry armed for the code
    /// that was replaced still counting down towards a credential that is live. Firing it
    /// would blank a code the owner is halfway through typing into a phone.
    private func adopt(_ fresh: BuddyInvitation?) {
        let superseded = fresh?.code != invitation?.code
            || fresh?.expiresAt != invitation?.expiresAt
        invitation = fresh
        guard superseded else { return }
        if let fresh {
            scheduleExpiry(of: fresh)
        } else {
            cancelExpiry()
        }
    }

    /// Clears the code from the screen when it stops working, so the window never shows a
    /// QR that the server would now refuse.
    private func scheduleExpiry(of invitation: BuddyInvitation) {
        cancelExpiry()
        let wait = invitation.expiresAt.timeIntervalSinceNow
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(wait, 0)))
            guard !Task.isCancelled else { return }
            // Belt and braces with `adopt`: a timer that has outlived the code it was
            // armed for must never take the live one down with it.
            guard self?.invitation?.code == invitation.code else { return }
            self?.invitation = nil
        }
    }

    private func cancelExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
    }

    /// The QR the phone camera reads. Scaled up from the generator's tiny native output,
    /// with nearest-neighbour interpolation — a smoothed QR is a QR that will not scan.
    public static func qrCode(for text: String, scale: CGFloat = 10) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

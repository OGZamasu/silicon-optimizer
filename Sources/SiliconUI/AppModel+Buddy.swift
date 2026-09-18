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
        return streamed { [weak self] emit in
            guard let self else { return }
            // Like `chat`, this path has no `generationTask`, so without `whileGenerating`
            // a long answer reads as idleness — and the idle timer unloads the model, or
            // the Mac sleeps, halfway through writing it.
            try await self.whileGenerating {
                for try await event in try await runtime.chat(chatRequest) {
                    switch event {
                    case .token(let token): emit(.token(token))
                    case .reasoningToken(let token): emit(.reasoning(token))
                    case .finished(let metrics):
                        self.lastGeneration = metrics
                        emit(.finished(Self.metrics(metrics)))
                    }
                }
            }
        }
    }

    // MARK: - Conversations

    public func conversationList() async -> [ControlAPI.ConversationSummary] {
        conversations.map(Self.summarize)
    }

    public func createConversation(title: String?) async -> ControlAPI.ConversationSummary {
        var conversation = Conversation()
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { conversation.title = String(trimmed.prefix(60)) }
        // At the top and selected, exactly as `newConversation` does it: a conversation
        // started from a phone should be the one on screen when the owner looks over.
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
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
            messages: conversation.messages.map {
                .init(
                    role: $0.role.rawValue, content: $0.content,
                    createdAt: ControlAPI.timestamp($0.createdAt)
                )
            }
        )
    }

    public func replyInConversation(
        id: String, to message: ControlAPI.NewMessageRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        guard let runtime = activeRuntime, runtimeState.isRunning else {
            throw ControlHostError.noModelLoaded
        }
        guard let index = conversations.firstIndex(where: { $0.id.uuidString == id }) else {
            throw BuddyHostError.noSuchConversation(id)
        }
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ControlHostError.badRequest("A message needs something in it.")
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
        let chatRequest = ChatRequest(
            messages: conversations[index].messages.dropLast().map { $0 },
            temperature: message.temperature ?? settings.temperature,
            topP: settings.topP,
            maxTokens: message.maxTokens ?? (settings.maxTokens > 0 ? settings.maxTokens : nil),
            reasoningEffort: settings.reasoningEffort.isEmpty ? nil : settings.reasoningEffort
        )

        return streamed { [weak self] emit in
            guard let self else { return }
            do {
                try await self.whileGenerating {
                    for try await event in try await runtime.chat(chatRequest) {
                        switch event {
                        case .token(let token):
                            self.append(token, to: replyID, in: conversationID, reasoning: false)
                            emit(.token(token))
                        case .reasoningToken(let token):
                            self.append(token, to: replyID, in: conversationID, reasoning: true)
                            emit(.reasoning(token))
                        case .finished(let metrics):
                            self.lastGeneration = metrics
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
        }
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

    // MARK: - The /events side channel

    public func beginEventUpdates() async {
        BuddyEventPump.shared.start(watching: self)
    }

    /// What a subscriber would want to know right now. Built whole and diffed, rather than
    /// posted from the places state changes: those places are in `AppModel.swift`, which
    /// this milestone does not touch, and a watcher that samples cannot miss an update by
    /// forgetting to announce one.
    func buddyEventSnapshot() async -> BuddyEventPump.Snapshot {
        var jobs: [String: ControlAPI.JobEvent] = [:]
        let queue = await videoQueue()
        for item in queue.items {
            jobs[item.id] = ControlAPI.JobEvent(
                id: item.id, kind: "video", status: item.status,
                title: item.title,
                fraction: item.id == activeVideoQueueID ? videoProgress : nil
            )
        }
        if let image = currentImageJob {
            jobs["image"] = ControlAPI.JobEvent(
                id: "image", kind: "image", status: "running", title: image.modelName,
                fraction: imageProgress.map { $0.total > 0 ? Double($0.step) / Double($0.total) : nil } ?? nil
            )
        }
        if let mesh = currentMeshJob {
            jobs["mesh"] = ControlAPI.JobEvent(
                id: "mesh", kind: "mesh", status: "running", title: mesh.modelName,
                fraction: meshProgress
            )
        }

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

    public init() {}

    public var isRunning: Bool { task != nil }

    func start(
        watching model: AppModel, hub: BuddyEventHub = .shared,
        interval: Duration = .seconds(1)
    ) {
        guard task == nil else { return }
        task = Task { [weak self, weak model] in
            var previous: Snapshot?
            while !Task.isCancelled {
                guard let model, await hub.subscriberCount > 0 else { break }
                let current = await model.buddyEventSnapshot()
                for event in Self.changes(from: previous, to: current) { await hub.post(event) }
                previous = current
                guard (try? await Task.sleep(for: interval)) != nil else { break }
            }
            self?.task = nil
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// The first reading is entirely news — a phone that has just connected knows nothing,
    /// so it gets the current state rather than waiting for something to move.
    static func changes(from previous: Snapshot?, to current: Snapshot) -> [BuddyEvent] {
        var events: [BuddyEvent] = []
        if previous.map({ !matches($0.status, current.status) }) ?? true {
            events.append(.status(current.status))
        }
        for (id, download) in current.downloads.sorted(by: { $0.key < $1.key })
        where previous?.downloads[id] != download {
            events.append(.download(download))
        }
        for (id, job) in current.jobs.sorted(by: { $0.key < $1.key })
        where previous?.jobs[id] != job {
            events.append(.job(job))
        }
        return events
    }

    /// `ControlAPI.Status` is part of a frozen wire contract and deliberately not
    /// `Equatable`; comparing the bytes it would send is the comparison that matters here.
    private static func matches(_ left: ControlAPI.Status, _ right: ControlAPI.Status) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(left)) == (try? encoder.encode(right))
    }
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
        invitation = await registry.openInvitation()
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
    public func pairDevice(server: ControlServer?) async {
        isBusy = true
        defer { isBusy = false }
        await refresh(server: server)
        guard allowsTailnetDevices else {
            problem = "Turn Silicon Buddy on first — pairing rides on the tailnet listener."
            return
        }
        guard let host = reachAddress, let port = await server?.listeningPort, port > 0 else {
            problem = problem ?? "The tailnet listener is not up yet. Try again in a moment."
            return
        }
        problem = nil
        let fresh = await registry.invite(host: host, port: port)
        invitation = fresh
        scheduleExpiry(of: fresh)
    }

    public func cancelInvitation() async {
        expiryTask?.cancel()
        expiryTask = nil
        await registry.cancelInvitation()
        invitation = nil
    }

    public func revoke(_ id: String) async {
        await registry.revoke(deviceID: id)
        devices = await registry.devices()
    }

    /// Clears the code from the screen when it stops working, so the window never shows a
    /// QR that the server would now refuse.
    private func scheduleExpiry(of invitation: BuddyInvitation) {
        expiryTask?.cancel()
        let wait = invitation.expiresAt.timeIntervalSinceNow
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(wait, 0)))
            guard !Task.isCancelled else { return }
            self?.invitation = nil
        }
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

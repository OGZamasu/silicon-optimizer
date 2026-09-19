import Foundation
import SiliconCatalog
import SiliconControl

/// The Mac's side of the phone's fallback model, as the control server and the Settings
/// window both see it: the pinned catalogue, the state of this Mac's copy of each model,
/// and progress on `/events` while one is being fetched.
///
/// It owns no files itself — `PhoneModelStore` does — and it never loads anything: these
/// models are fetched here only to be passed along to a phone. It keeps no location either:
/// every call is handed the model library folder as the owner's settings have it at that
/// moment, and the store works out `Phone Models/` from it.
public actor PhoneModelService {

    public nonisolated let store: PhoneModelStore
    private let hub: BuddyEventHub
    private let watchInterval: Duration
    /// One per model while a fetch is being followed. Tokened, so a watcher that has
    /// decided to stop cannot clear the row of the one that replaced it.
    private var watchers: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    /// - Parameter watchInterval: how often a fetch in flight is sampled for `/events`.
    ///   A second, like the rest of the Mac's status frames; a test shortens it.
    public init(
        store: PhoneModelStore, hub: BuddyEventHub = .shared,
        watchInterval: Duration = .seconds(1)
    ) {
        self.store = store
        self.hub = hub
        self.watchInterval = watchInterval
    }

    // MARK: - What the routes and the Settings row ask

    public func phoneModels(library: URL?) async -> ControlAPI.PhoneModelList {
        var models: [ControlAPI.PhoneModel] = []
        for entry in store.catalog {
            let state = await store.state(of: entry.id, library: library) ?? .absent
            models.append(Self.wire(entry, state: state))
        }
        return ControlAPI.PhoneModelList(models: models)
    }

    /// - Parameter library: asked again every time the progress watcher samples, so a
    ///   library moved mid-download is followed there.
    public func prepare(
        id: String, verify: Bool = false, library: @escaping @Sendable () async -> URL?
    ) async throws -> ControlAPI.PhoneModelPreparation {
        guard let entry = store.entry(id: id) else { throw PhoneModelError.unknownModel(id) }
        let folder = await library()
        let outcome: PhoneModelStore.PrepareOutcome
        do {
            outcome = try await store.prepare(id: id, library: folder, verify: verify)
        } catch let error as PhoneModelStore.StoreError {
            throw Self.routeError(error, id: id)
        }
        if outcome != .alreadyReady { watch(entry, library: library) }
        return ControlAPI.PhoneModelPreparation(
            model: Self.wire(entry, state: await store.state(of: id, library: folder) ?? .absent),
            wasReady: outcome == .alreadyReady
        )
    }

    public func file(id: String, library: URL?) async throws -> ControlAPI.PhoneModelFile {
        guard let entry = store.entry(id: id) else { throw PhoneModelError.unknownModel(id) }
        let file: PhoneModelStore.VerifiedFile
        do {
            file = try await store.verifiedFile(id: id, library: library)
        } catch let error as PhoneModelStore.StoreError {
            throw Self.routeError(error, id: id)
        }
        return ControlAPI.PhoneModelFile(
            url: file.url, sizeBytes: file.sizeBytes, sha256: file.sha256, fileName: entry.file
        )
    }

    public func remove(id: String, library: URL?) async throws -> ControlAPI.PhoneModel {
        guard let entry = store.entry(id: id) else { throw PhoneModelError.unknownModel(id) }
        do {
            try await store.remove(id: id, library: library)
        } catch let error as PhoneModelStore.StoreError {
            throw Self.routeError(error, id: id)
        }
        return Self.wire(entry, state: await store.state(of: id, library: library) ?? .absent)
    }

    /// Stops a download and keeps what arrived. The Settings row's Stop; not a route.
    public func cancel(id: String, library: URL?) async -> ControlAPI.PhoneModel? {
        guard let entry = store.entry(id: id) else { return nil }
        await store.cancel(id: id)
        return Self.wire(entry, state: await store.state(of: id, library: library) ?? .absent)
    }

    /// Folders the library has left behind with phone models still in them. For the Mac's
    /// own Settings row; a phone is never told this Mac's paths.
    public func notices(library: URL?) async -> [PhoneModelStore.Notice] {
        await store.notices(library: library)
    }

    /// Tries every move that could not finish once more — the Settings page's Try Again.
    public func retryMoves(library: URL?) async {
        await store.retryMoves(library: library)
    }

    static func routeError(_ error: PhoneModelStore.StoreError, id: String) -> PhoneModelError {
        switch error {
        case .unknownModel: .unknownModel(id)
        case .noSpace(let failure): .noSpace(failure.reason)
        case .driveMissing(let sentence): .driveMissing(sentence)
        case .notReady: .notReady(id)
        }
    }

    /// Returns once every progress watcher has posted its last frame. For a test that must
    /// not leave one polling after it has cleaned up.
    public func waitForWatchers() async {
        while let (_, watcher) = watchers.first {
            await watcher.task.value
        }
    }

    // MARK: - Progress on /events

    /// What a `download` frame says when a fetch ends because the Mac's copy was removed.
    public static let removedWhileDownloading =
        "Removed from the Mac before it finished."

    /// Follows one fetch until it settles, posting a `download` frame whenever what it
    /// would say changes — and always the last one, so a phone watching the stream sees
    /// the fetch end as `fraction: 1` with no stage, as a failure's reason, or as a removal.
    private func watch(_ entry: PhoneModelEntry, library: @escaping @Sendable () async -> URL?) {
        guard watchers[entry.id] == nil else { return }
        let store = self.store, hub = self.hub, interval = watchInterval
        let token = UUID()
        let task = Task {
            var last: ControlAPI.DownloadEvent?
            while !Task.isCancelled {
                let state = await store.state(of: entry.id, library: await library()) ?? .absent
                let frame = Self.downloadEvent(entry, state: state)
                if frame != last {
                    await hub.post(.download(frame))
                    last = frame
                }
                guard case .downloading = state else { break }
                try? await Task.sleep(for: interval)
            }
            await self.watcherEnded(entry, token: token, library: library)
        }
        watchers[entry.id] = (token, task)
    }

    private func watcherEnded(
        _ entry: PhoneModelEntry, token: UUID, library: @escaping @Sendable () async -> URL?
    ) async {
        guard watchers[entry.id]?.token == token else { return }
        watchers[entry.id] = nil
        // A prepare that arrived while this watcher was deciding to stop found it still
        // here and started no other. If that fetch is running, it needs one.
        if case .downloading = await store.state(of: entry.id, library: await library()) {
            watch(entry, library: library)
        }
    }

    // MARK: - Shapes

    /// One catalogue entry and the state of the Mac's copy, as a phone reads it.
    public static func wire(
        _ entry: PhoneModelEntry, state: PhoneModelStore.State
    ) -> ControlAPI.PhoneModel {
        ControlAPI.PhoneModel(
            id: entry.id, label: entry.label, isDefault: entry.isDefault,
            sizeBytes: entry.sizeBytes, sha256: entry.sha256, licence: entry.licence,
            source: .init(repo: entry.repository, commit: entry.commit, file: entry.file),
            onMac: onMac(state, size: entry.sizeBytes),
            recommended: .init(
                threadsPrompt: entry.recommended.threadsPrompt,
                threadsGenerate: entry.recommended.threadsGenerate,
                contextLength: entry.recommended.contextLength,
                minFreeMemoryBytes: entry.recommended.minFreeMemoryBytes,
                thinking: entry.recommended.thinking
            ),
            measured: entry.measured.map {
                .init(
                    device: $0.device, runtime: $0.runtime, conditions: $0.conditions,
                    tokensPerSecond: $0.tokensPerSecond,
                    threadSweep: $0.threadSweep.map {
                        .init(threads: $0.threads, tokensPerSecond: $0.tokensPerSecond)
                    },
                    promptTokensPerSecond: $0.promptTokensPerSecond,
                    secondsToFirstWord300: $0.secondsToFirstWord300,
                    firstWordEstimated: true,
                    sustainedTokensPerSecond: $0.sustainedTokensPerSecond,
                    sustainedMeasured: $0.sustainedTokensPerSecond != nil,
                    peakMemoryBytes: $0.peakMemoryBytes,
                    peakMemoryContextTokens: $0.peakMemoryContextTokens
                )
            },
            slowerOnPhone: entry.slowerOnPhone
        )
    }

    static func onMac(
        _ state: PhoneModelStore.State, size: Int64
    ) -> ControlAPI.PhoneModel.OnMac {
        switch state {
        case .absent:
            return .init(state: "absent")
        case .downloading(let received, _, let stage):
            return .init(
                state: "downloading", stage: stage.rawValue, fraction: fraction(received, of: size)
            )
        case .ready:
            return .init(state: "ready")
        case .failed(let failure):
            return .init(
                state: "failed",
                fraction: failure.bytesOnDisk > 0 ? fraction(failure.bytesOnDisk, of: size) : nil,
                reason: failure.reason, failure: failure.kind.rawValue
            )
        }
    }

    /// The `download` frame for one model in one state. The id is `ondevice:` and the
    /// model's id, so a phone can tell these from the Mac's own model downloads. Done is
    /// `fraction: 1` with no `stage` and no `error`.
    public static func downloadEvent(
        _ entry: PhoneModelEntry, state: PhoneModelStore.State
    ) -> ControlAPI.DownloadEvent {
        let id = ControlAPI.PhoneModel.downloadEventPrefix + entry.id
        let name = "\(entry.label) for your phone"
        let total = entry.sizeBytes
        switch state {
        case .downloading(let received, let rate, let stage):
            return .init(
                id: id, name: name, fraction: fraction(received, of: total),
                bytesReceived: received, bytesExpected: total, bytesPerSecond: rate,
                stage: stage.rawValue
            )
        case .ready:
            return .init(
                id: id, name: name, fraction: 1, bytesReceived: total, bytesExpected: total,
                bytesPerSecond: 0
            )
        case .failed(let failure):
            return .init(
                id: id, name: name, fraction: fraction(failure.bytesOnDisk, of: total),
                bytesReceived: failure.bytesOnDisk, bytesExpected: total, bytesPerSecond: 0,
                error: failure.reason
            )
        case .absent:
            return .init(
                id: id, name: name, fraction: 0, bytesReceived: 0, bytesExpected: total,
                bytesPerSecond: 0, error: removedWhileDownloading
            )
        }
    }

    static func fraction(_ part: Int64, of whole: Int64) -> Double {
        guard whole > 0 else { return 0 }
        return min(1, max(0, Double(part) / Double(whole)))
    }
}

/// The phone models as one library folder sees them: the service, and where the owner's
/// settings put the model library at the moment each call is made.
///
/// What the control server and the Settings row are handed. It carries no location of its
/// own, so there is nothing to go stale: move the library in Settings and the very next
/// call is answered from — and moves the files to — the new one.
public struct PhoneModelsAtLibrary: PhoneModelProvider {
    public let service: PhoneModelService
    public let library: @Sendable () async -> URL?

    public init(service: PhoneModelService, library: @escaping @Sendable () async -> URL?) {
        self.service = service
        self.library = library
    }

    public func phoneModels() async -> ControlAPI.PhoneModelList {
        await service.phoneModels(library: await library())
    }

    public func preparePhoneModel(
        id: String, verify: Bool
    ) async throws -> ControlAPI.PhoneModelPreparation {
        try await service.prepare(id: id, verify: verify, library: library)
    }

    public func phoneModelFile(id: String) async throws -> ControlAPI.PhoneModelFile {
        try await service.file(id: id, library: await library())
    }

    public func removePhoneModel(id: String) async throws -> ControlAPI.PhoneModel {
        try await service.remove(id: id, library: await library())
    }

    public func cancel(id: String) async -> ControlAPI.PhoneModel? {
        await service.cancel(id: id, library: await library())
    }

    public func notices() async -> [PhoneModelStore.Notice] {
        await service.notices(library: await library())
    }

    public func retryMoves() async {
        await service.retryMoves(library: await library())
    }

    /// Where the models are kept right now, or the drive that is missing.
    public func place() async -> PhoneModelPlace {
        service.store.place(forLibrary: await library())
    }
}

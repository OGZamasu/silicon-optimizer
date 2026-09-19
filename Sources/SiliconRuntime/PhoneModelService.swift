import Foundation
import SiliconCatalog
import SiliconControl

/// The Mac's side of the phone's fallback model, as the control server and the Settings
/// window both see it: the pinned catalogue, the state of this Mac's copy of each model,
/// and progress on `/events` while one is being fetched.
///
/// It owns no files itself — `PhoneModelStore` does — and it never loads anything: these
/// models are fetched here only to be passed along to a phone.
public actor PhoneModelService: PhoneModelProvider {

    /// The app's own: files under `PhoneModels/` in the app's support directory, fetched
    /// from huggingface.co, frames to the hub the control server streams from.
    public static let shared = PhoneModelService()

    public nonisolated let store: PhoneModelStore
    private let hub: BuddyEventHub
    private let watchInterval: Duration
    /// One per model while a fetch is being followed. Tokened, so a watcher that has
    /// decided to stop cannot clear the row of the one that replaced it.
    private var watchers: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    /// - Parameter watchInterval: how often a fetch in flight is sampled for `/events`.
    ///   A second, like the rest of the Mac's status frames; a test shortens it.
    public init(
        store: PhoneModelStore = PhoneModelStore(), hub: BuddyEventHub = .shared,
        watchInterval: Duration = .seconds(1)
    ) {
        self.store = store
        self.hub = hub
        self.watchInterval = watchInterval
    }

    /// Where the Mac keeps them — for the Settings row and the README, never for a phone.
    public nonisolated var folder: URL { store.root }

    // MARK: - PhoneModelProvider

    public func phoneModels() async -> ControlAPI.PhoneModelList {
        var models: [ControlAPI.PhoneModel] = []
        for entry in store.catalog {
            models.append(Self.wire(entry, state: await store.state(of: entry.id) ?? .absent))
        }
        return ControlAPI.PhoneModelList(models: models)
    }

    public func preparePhoneModel(id: String) async throws -> ControlAPI.PhoneModelPreparation {
        guard let entry = store.entry(id: id) else { throw PhoneModelError.unknownModel(id) }
        let outcome: PhoneModelStore.PrepareOutcome
        do {
            outcome = try await store.prepare(id: id)
        } catch PhoneModelStore.StoreError.noSpace(let failure) {
            throw PhoneModelError.noSpace(failure.reason)
        } catch PhoneModelStore.StoreError.unknownModel {
            throw PhoneModelError.unknownModel(id)
        }
        if outcome != .alreadyReady { watch(entry) }
        return ControlAPI.PhoneModelPreparation(
            model: Self.wire(entry, state: await store.state(of: id) ?? .absent),
            wasReady: outcome == .alreadyReady
        )
    }

    public func phoneModelFile(id: String) async throws -> ControlAPI.PhoneModelFile {
        guard let entry = store.entry(id: id) else { throw PhoneModelError.unknownModel(id) }
        guard let file = await store.verifiedFile(id: id) else {
            throw PhoneModelError.notReady(id)
        }
        return ControlAPI.PhoneModelFile(
            url: file.url, sizeBytes: file.sizeBytes, sha256: file.sha256, fileName: entry.file
        )
    }

    public func removePhoneModel(id: String) async throws -> ControlAPI.PhoneModel {
        guard let entry = store.entry(id: id) else { throw PhoneModelError.unknownModel(id) }
        do {
            try await store.remove(id: id)
        } catch PhoneModelStore.StoreError.unknownModel {
            throw PhoneModelError.unknownModel(id)
        }
        return Self.wire(entry, state: await store.state(of: id) ?? .absent)
    }

    // MARK: - Progress on /events

    /// What a `download` frame says when a fetch ends because the Mac's copy was removed.
    public static let removedWhileDownloading =
        "Removed from the Mac before it finished."

    /// Follows one fetch until it settles, posting a `download` frame whenever what it
    /// would say changes — and always the last one, so a phone watching the stream sees
    /// the fetch end as `fraction: 1`, as a failure's reason, or as a removal.
    private func watch(_ entry: PhoneModelEntry) {
        guard watchers[entry.id] == nil else { return }
        let store = self.store, hub = self.hub, interval = watchInterval
        let token = UUID()
        let task = Task {
            var last: ControlAPI.DownloadEvent?
            while !Task.isCancelled {
                let state = await store.state(of: entry.id) ?? .absent
                let frame = Self.downloadEvent(entry, state: state)
                if frame != last {
                    await hub.post(.download(frame))
                    last = frame
                }
                guard case .downloading = state else { break }
                try? await Task.sleep(for: interval)
            }
            await self.watcherEnded(entry, token: token)
        }
        watchers[entry.id] = (token, task)
    }

    private func watcherEnded(_ entry: PhoneModelEntry, token: UUID) async {
        guard watchers[entry.id]?.token == token else { return }
        watchers[entry.id] = nil
        // A prepare that arrived while this watcher was deciding to stop found it still
        // here and started no other. If that fetch is running, it needs one.
        if case .downloading = await store.state(of: entry.id) { watch(entry) }
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
                    secondsToFirstWord300: $0.secondsToFirstWord300,
                    tokensPerSecond: $0.tokensPerSecond,
                    tokensPerSecondMax: $0.tokensPerSecondMax,
                    sustainedTokensPerSecond: $0.sustainedTokensPerSecond
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
        case .downloading(let received, _):
            return .init(state: "downloading", fraction: fraction(received, of: size))
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
    /// model's id, so a phone can tell these from the Mac's own model downloads.
    public static func downloadEvent(
        _ entry: PhoneModelEntry, state: PhoneModelStore.State
    ) -> ControlAPI.DownloadEvent {
        let id = ControlAPI.PhoneModel.downloadEventPrefix + entry.id
        let name = "\(entry.label) for your phone"
        let total = entry.sizeBytes
        switch state {
        case .downloading(let received, let rate):
            return .init(
                id: id, name: name, fraction: fraction(received, of: total),
                bytesReceived: received, bytesExpected: total, bytesPerSecond: rate
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

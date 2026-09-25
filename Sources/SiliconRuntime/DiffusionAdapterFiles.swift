import Foundation
import SiliconCatalog
import SiliconControl
import SiliconCore

/// Puts a diffusion adapter's file in the hub cache, checked against its reviewed digest.
///
/// The same rule the voice models live by (`VoiceRuntime.preparePinnedModels`): the file comes
/// from the adapter's pinned revision, it is kept only if its SHA-256 is the one in
/// `Resources/pinned-installs/models` — written by `Scripts/pin-hub-models.sh` from the Hub's
/// own record — and it lands where Hugging Face would put it, so a copy fetched by anything
/// else is found and reused rather than fetched twice. Only the one variant asked for is
/// fetched: installing the entry costs one 336 MB file, not every schedule's.
public struct DiffusionAdapterFiles: Sendable {

    public enum Failure: Error, LocalizedError, Equatable {
        /// The app has no reviewed record of the file, or one for another revision.
        case unreviewed(String)
        case fetchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unreviewed(let detail): detail
            case .fetchFailed(let detail): detail
            }
        }
    }

    public let locks: URL
    public let hub: URL
    /// Where the files are fetched from; only tests point this anywhere but the Hub.
    let server: URL
    /// curl's `--proto`; only tests widen it beyond https.
    let protocols: String

    public init(
        locks: URL = PinnedInstall.defaultLockRoot(), hub: URL,
        server: URL = URL(string: "https://huggingface.co")!, protocols: String = "=https"
    ) {
        self.locks = locks
        self.hub = hub
        self.server = server
        self.protocols = protocols
    }

    /// The reviewed record of one variant's file: the manifest, narrowed to that file. Refused
    /// when the manifest is missing, is for another revision than the catalogue names, or does
    /// not list the file — any of which means the file on the Hub is not the one reviewed.
    public func pinned(
        _ variant: DiffusionAdapter.Variant, of adapter: DiffusionAdapter
    ) throws -> PinnedInstall.HubModel {
        guard var model = try? PinnedInstall.HubModel.load(adapter.repository, from: locks) else {
            throw Failure.unreviewed(
                "The reviewed file list for \(adapter.repository) is missing from the app, so "
                    + "nothing was fetched. Reinstalling the app puts it back."
            )
        }
        guard model.revision == adapter.revision else {
            throw Failure.unreviewed(
                "The reviewed file list for \(adapter.repository) is for revision "
                    + "\(model.revision.prefix(7)), not \(adapter.revision.prefix(7)), so "
                    + "nothing was fetched."
            )
        }
        model.files = model.files.filter { $0.path == variant.file }
        guard model.files.count == 1 else {
            throw Failure.unreviewed(
                "\(variant.file) is not in the reviewed file list for \(adapter.repository)."
            )
        }
        return model
    }

    /// The reviewed SHA-256 the runner checks the file against before merging it.
    public func sha256(
        _ variant: DiffusionAdapter.Variant, of adapter: DiffusionAdapter
    ) throws -> String {
        try pinned(variant, of: adapter).files[0].sha256
    }

    public func file(_ variant: DiffusionAdapter.Variant, of adapter: DiffusionAdapter) -> URL {
        DiffusionInstaller.adapterFile(variant, of: adapter, hub: hub)
    }

    public func isInPlace(_ variant: DiffusionAdapter.Variant, of adapter: DiffusionAdapter) -> Bool {
        DiffusionInstaller.isAdapterInPlace(variant, of: adapter, hub: hub)
    }

    /// The fetch, as commands: one, which leaves a right file alone, reuses a right blob, and
    /// otherwise downloads by commit and keeps the bytes only if their digest matches.
    public func fetchCommands(
        _ variant: DiffusionAdapter.Variant, of adapter: DiffusionAdapter
    ) throws -> [PinnedInstall.Command] {
        try pinned(variant, of: adapter).fetchCommands(
            hub: hub, server: server, protocols: protocols
        )
    }

    /// Fetches the variant's file unless it is already in place, reporting bytes as the
    /// download grows.
    public func prepare(
        _ variant: DiffusionAdapter.Variant, of adapter: DiffusionAdapter,
        onProgress: @escaping @Sendable (_ received: Bytes, _ expected: Bytes) -> Void = { _, _ in }
    ) async throws {
        let model = try pinned(variant, of: adapter)
        if isInPlace(variant, of: adapter) { return }
        let record = model.files[0]
        let part = model.cacheDirectory(hub: hub)
            .appendingPathComponent("blobs/\(record.sha256).part")
        let expected = Bytes(record.size)

        let watcher = Task {
            while !Task.isCancelled {
                let size = (try? FileManager.default.attributesOfItem(atPath: part.path))?[.size]
                    as? NSNumber
                onProgress(Bytes(size?.int64Value ?? 0), expected)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { watcher.cancel() }

        for command in model.fetchCommands(hub: hub, server: server, protocols: protocols) {
            try await Self.run(command)
        }
        onProgress(expected, expected)
        guard isInPlace(variant, of: adapter) else {
            throw Failure.fetchFailed("\(variant.file) was fetched but is not where it belongs.")
        }
    }

    /// Runs one command to the end and fails with what it said, stopping it if the caller is
    /// cancelled.
    static func run(_ command: PinnedInstall.Command) async throws {
        let process = ServerProcess()
        try await process.start(
            executable: command.executable, arguments: command.arguments,
            currentDirectory: command.workingDirectory
        )
        while await process.isRunning {
            if Task.isCancelled {
                await process.terminate()
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard await process.terminationStatus == 0 else {
            let tail = await process.log.split(separator: "\n").suffix(2)
                .joined(separator: " ")
            throw Failure.fetchFailed(tail.isEmpty ? "\(command.label) failed." : tail)
        }
    }
}

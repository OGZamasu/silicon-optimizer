import CArtifactHTTP
import CFNetwork
import Foundation

/// GMI audio artifacts are provider-supplied URLs. URLSession exposes the peer IP only after
/// sending the request, so this one path uses a direct libcurl connection with pre-connect
/// and pre-request address vetoes. The rest of the application's transfers stay on URLSession.
public enum PublicHTTPSArtifactTransfer {
    private static let maximumRedirects = 20
    private static let proxyVariables = [
        "http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY",
    ]

    static func proxyEnvironmentConfigured(_ environment: [String: String]) -> Bool {
        proxyVariables.contains { !(environment[$0] ?? "").isEmpty }
    }

    static func directOnly(_ entries: [[String: Any]]) -> Bool {
        entries.count == 1
            && (entries[0][kCFProxyTypeKey as String] as? String) == (kCFProxyTypeNone as String)
    }

    static func autoProxyConfigured(_ settings: [String: Any]) -> Bool {
        let automaticKeys = [
            kCFNetworkProxiesProxyAutoConfigEnable as String,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String,
        ]
        if automaticKeys.contains(where: { ((settings[$0] as? NSNumber)?.intValue ?? 0) != 0 }) {
            return true
        }
        // macOS can keep per-interface proxy settings under a nested dictionary. A PAC/WPAD
        // configuration there is not proof that this direct libcurl hop matches the system route.
        return settings.values.contains {
            guard let nested = $0 as? [String: Any] else { return false }
            return autoProxyConfigured(nested)
        }
    }

    static func enforceDirect(
        environment: [String: String], proxyEntries: [[String: Any]],
        systemSettings: [String: Any]
    ) throws {
        guard !proxyEnvironmentConfigured(environment), !autoProxyConfigured(systemSettings),
              directOnly(proxyEntries)
        else { throw RemoteTransferError.unverifiableProxy }
    }

    static func redirectTarget(_ location: String, from current: URL, count: Int) throws -> URL {
        guard count < maximumRedirects else { throw RemoteTransferError.tooManyRedirects }
        guard let next = RemoteURLPolicy.publicHTTPS.resolve(location, relativeTo: current)
        else { throw RemoteTransferError.redirectRejected }
        return next
    }

    /// Throws `unverifiableProxy` when a proxy or PAC would carry traffic to `url`. The
    /// transfer asks on every hop; `CloudAudioRuntime` asks before it submits a job, so a
    /// proxied Mac is told before GMI does, and bills for, work that could not be fetched.
    static func requireDirectConnection(to url: URL) throws {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let entries = CFNetworkCopyProxiesForURL(url as CFURL, settings)
                .takeRetainedValue() as? [[String: Any]]
        else { throw RemoteTransferError.unverifiableProxy }
        guard let settingsDictionary = settings as NSDictionary as? [String: Any]
        else { throw RemoteTransferError.unverifiableProxy }
        try enforceDirect(
            environment: ProcessInfo.processInfo.environment, proxyEntries: entries,
            systemSettings: settingsDictionary
        )
    }

    @discardableResult
    public static func download(
        from remote: URL, to destination: URL, maximumBytes: Int64,
        budget: RemoteByteBudget, timeout: TimeInterval
    ) async throws -> URL {
        try await download(
            from: remote, to: destination, maximumBytes: maximumBytes,
            budget: budget, timeout: timeout,
            proxyCheck: requireDirectConnection, onNetworkAttempt: {}
        )
    }

    /// Builds the C job for one hop from its URL, descriptor, byte limit, timeout, disk
    /// reserve and budget callback. Production always uses `silicon_artifact_job_create`,
    /// which has no way to override DNS or trust; tests substitute fixture resolution per
    /// hop so the redirect loop itself can be driven against a local server.
    typealias JobFactory = @Sendable (
        String, Int32, Int64, Int64, Int64, SiliconArtifactConsume, UnsafeMutableRawPointer
    ) -> OpaquePointer?

    static func productionJob(
        _ url: String, _ descriptor: Int32, _ limit: Int64, _ timeout: Int64, _ reserve: Int64,
        _ consume: SiliconArtifactConsume, _ context: UnsafeMutableRawPointer
    ) -> OpaquePointer? {
        url.withCString { address in
            silicon_artifact_job_create(
                address, descriptor, limit, timeout, reserve, consume, context
            )
        }
    }

    static func download(
        from remote: URL, to destination: URL, maximumBytes: Int64,
        budget: RemoteByteBudget, timeout: TimeInterval,
        proxyCheck: @escaping @Sendable (URL) throws -> Void,
        onNetworkAttempt: @escaping @Sendable () -> Void,
        makeJob: @escaping JobFactory = productionJob
    ) async throws -> URL {
        guard RemoteURLPolicy.publicHTTPS.permits(remote)
        else { throw RemoteTransferError.disallowedURL }
        guard maximumBytes > 0, timeout.isFinite, timeout > 0, timeout <= 86_400
        else { throw RemoteTransferError.networkFailure }

        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try RemoteArtifactTransfer.requireDiskCapacity(
            at: directory,
            bytes: min(maximumBytes, 8 * 1_024 * 1_024) + RemoteArtifactTransfer.diskReserveBytes
        )

        let partial = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).partial"
        )
        guard manager.createFile(
            atPath: partial.path, contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
        var published = false
        defer { if !published { try? manager.removeItem(at: partial) } }

        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        let deadline = Date().addingTimeInterval(timeout)
        var current = remote
        var redirects = 0
        while true {
            try Task.checkCancellation()
            guard RemoteURLPolicy.publicHTTPS.permits(current)
            else { throw RemoteTransferError.redirectRejected }
            try proxyCheck(current)
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw RemoteTransferError.networkFailure }
            let available = min(maximumBytes, budget.remaining)
            guard available > 0 else {
                throw RemoteTransferError.aggregateLimitExceeded(budget.limit)
            }
            let milliseconds = Int64(min(remaining * 1000, Double(Int64.max)))
            onNetworkAttempt()
            guard let job = CurlArtifactJob(
                url: current, fileDescriptor: handle.fileDescriptor,
                maximumBytes: maximumBytes, timeoutMilliseconds: max(1, milliseconds),
                reserveBytes: RemoteArtifactTransfer.diskReserveBytes, budget: budget,
                make: makeJob
            ) else { throw RemoteTransferError.networkFailure }
            let result = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(returning: job.perform())
                    }
                }
            } onCancel: {
                job.cancel()
            }
            try Task.checkCancellation()

            switch result.outcome {
            case SILICON_ARTIFACT_REDIRECT:
                guard result.bytes == 0 else { throw RemoteTransferError.redirectRejected }
                let next = try redirectTarget(result.location, from: current, count: redirects)
                redirects += 1
                current = next
            case SILICON_ARTIFACT_SUCCESS:
                try handle.synchronize()
                try handle.close()
                try RemoteArtifactTransfer.requireDiskCapacity(
                    at: directory, bytes: RemoteArtifactTransfer.diskReserveBytes
                )
                if manager.fileExists(atPath: destination.path) {
                    _ = try manager.replaceItemAt(destination, withItemAt: partial)
                } else {
                    try manager.moveItem(at: partial, to: destination)
                }
                published = true
                return destination
            case SILICON_ARTIFACT_PRIVATE_ADDRESS:
                throw RemoteTransferError.disallowedResolvedAddress
            case SILICON_ARTIFACT_TOO_LARGE:
                throw RemoteTransferError.responseTooLarge(maximumBytes)
            case SILICON_ARTIFACT_AGGREGATE_LIMIT:
                throw RemoteTransferError.aggregateLimitExceeded(budget.limit)
            case SILICON_ARTIFACT_CONTENT_TYPE:
                throw RemoteTransferError.unexpectedContentType("non-audio")
            case SILICON_ARTIFACT_DISK:
                throw RemoteTransferError.insufficientDiskSpace
            case SILICON_ARTIFACT_HTTP_STATUS:
                throw RemoteTransferError.unexpectedStatus(Int(result.status))
            case SILICON_ARTIFACT_EMPTY:
                throw RemoteTransferError.emptyArtifact
            case SILICON_ARTIFACT_CANCELLED:
                throw CancellationError()
            default:
                throw RemoteTransferError.networkFailure
            }
        }
    }
}

private struct CurlHop: Sendable {
    let outcome: SiliconArtifactOutcome
    let status: Int
    let bytes: Int64
    let location: String
}

/// Cancellation and completion can race on different queues. The lock keeps the C allocation
/// alive while `silicon_artifact_job_cancel` touches its atomic flag.
private final class CurlArtifactJob: @unchecked Sendable {
    private let lock = NSLock()
    private var pointer: OpaquePointer?
    private let budget: RemoteByteBudget

    private static let consumeBytes: SiliconArtifactConsume = { context, count in
        guard let context else { return 0 }
        let budget = Unmanaged<RemoteByteBudget>.fromOpaque(context).takeUnretainedValue()
        do {
            try budget.consume(count)
            return 1
        } catch {
            return 0
        }
    }

    init?(url: URL, fileDescriptor: Int32, maximumBytes: Int64,
          timeoutMilliseconds: Int64, reserveBytes: Int64, budget: RemoteByteBudget,
          make: PublicHTTPSArtifactTransfer.JobFactory) {
        self.budget = budget
        pointer = make(
            url.absoluteString, fileDescriptor, maximumBytes, timeoutMilliseconds, reserveBytes,
            Self.consumeBytes, Unmanaged.passUnretained(budget).toOpaque()
        )
        if pointer == nil { return nil }
    }

    func perform() -> CurlHop {
        lock.lock()
        guard let pointer else {
            lock.unlock()
            return CurlHop(outcome: SILICON_ARTIFACT_NETWORK, status: 0, bytes: 0, location: "")
        }
        lock.unlock()
        let outcome = silicon_artifact_job_perform(pointer)
        lock.lock()
        let result = CurlHop(
            outcome: outcome,
            status: Int(silicon_artifact_job_status(pointer)),
            bytes: silicon_artifact_job_bytes(pointer),
            location: String(cString: silicon_artifact_job_location(pointer))
        )
        silicon_artifact_job_destroy(pointer)
        self.pointer = nil
        lock.unlock()
        return result
    }

    func cancel() {
        lock.lock()
        if let pointer { silicon_artifact_job_cancel(pointer) }
        lock.unlock()
    }

    deinit {
        if let pointer { silicon_artifact_job_destroy(pointer) }
    }
}

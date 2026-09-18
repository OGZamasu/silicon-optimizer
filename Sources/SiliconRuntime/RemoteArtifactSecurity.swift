import Foundation
import Network

/// Network authority granted to a remote job endpoint.
public enum RemoteURLPolicy: Sendable {
    /// A fixed service control endpoint may not change scheme, host, or effective port.
    case sameOrigin(URL)
    /// A user-configured peer may publish a second port on the same host. The scheme and
    /// host stay fixed; credentials remain stricter and are still bound to one origin.
    case peerHost(URL)
    /// Provider artifacts may live on an undocumented CDN, but never on a local/private address
    /// or over HTTP. This screens literal/special-use hosts; a provider-owned allowlist is still
    /// needed to eliminate malicious public DNS and rebinding entirely.
    case publicHTTPS

    public func resolve(_ value: String, relativeTo base: URL) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let candidate = URL(string: value, relativeTo: base)?.absoluteURL,
              permits(candidate)
        else { return nil }
        return candidate
    }

    public func permits(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil,
              let scheme = url.scheme?.lowercased(),
              let host = Self.normalizedHost(url.host),
              scheme == "http" || scheme == "https"
        else { return false }

        switch self {
        case .sameOrigin(let base):
            return Self.sameOrigin(base, url)
        case .peerHost(let base):
            guard let baseScheme = base.scheme?.lowercased(),
                  let baseHost = Self.normalizedHost(base.host)
            else { return false }
            return scheme == baseScheme && host == baseHost
        case .publicHTTPS:
            return scheme == "https" && Self.isPublicHost(host)
        }
    }

    /// Rejects a redirect outside the policy and removes a bearer credential whenever the
    /// destination's normalized origin differs from the endpoint that issued it.
    public func sanitized(
        _ request: URLRequest, credentialOrigin: URL?
    ) -> URLRequest? {
        guard let url = request.url, permits(url) else { return nil }
        var result = request
        if let credentialOrigin, !Self.sameOrigin(credentialOrigin, url) {
            result.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return result
    }

    public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = normalizedHost(lhs.host),
              let rhsHost = normalizedHost(rhs.host)
        else { return false }
        return lhsScheme == rhsScheme
            && lhsHost == rhsHost
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func normalizedHost(_ host: String?) -> String? {
        guard var host, !host.isEmpty else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        return host.lowercased()
    }

    private static func isPublicHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let looksNumeric = labels.allSatisfy { label in
            let lowered = label.lowercased()
            return !lowered.isEmpty && (
                lowered.allSatisfy(\.isNumber)
                    || lowered.hasPrefix("0x")
                        && lowered.dropFirst(2).allSatisfy { $0.isHexDigit }
            )
        }
        if looksNumeric {
            // Only canonical four-part decimal IPv4 is handed to the strict parser below.
            // This excludes resolver-dependent forms such as 127.1, 0177.0.0.1 and hex.
            guard labels.count == 4, labels.allSatisfy({ label in
                label.allSatisfy(\.isNumber)
                    && (label == "0" || !label.hasPrefix("0"))
                    && (Int(label) ?? 256) <= 255
            }) else { return false }
        }
        if let address = IPv4Address(host) {
            return isPublicIPv4(Array(address.rawValue))
        }
        if let address = IPv6Address(host) {
            let bytes = Array(address.rawValue)
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return isPublicIPv4(Array(bytes.suffix(4)))
            }
            // Only globally routable unicast, excluding the documentation prefix.
            guard bytes.count == 16, bytes[0] & 0xe0 == 0x20 else { return false }
            if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 {
                return false
            }
            return true
        }

        guard host.contains(".") else { return false }
        let localSuffixes = [
            ".localhost", ".local", ".internal", ".home", ".lan", ".invalid",
            ".test", ".example",
        ]
        return host != "localhost" && !localSuffixes.contains(where: host.hasSuffix)
    }

    private static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let a = bytes[0], b = bytes[1], c = bytes[2]
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100, (64...127).contains(b) { return false }
        if a == 169, b == 254 { return false }
        if a == 172, (16...31).contains(b) { return false }
        if a == 192, b == 168 { return false }
        if a == 192, b == 0, c == 0 || a == 192, b == 0, c == 2 { return false }
        if a == 198, b == 18 || a == 198, b == 19 || a == 198, b == 51, c == 100 {
            return false
        }
        if a == 203, b == 0, c == 113 { return false }
        return true
    }
}

/// Converts an opaque identifier from a remote response into exactly one URL path component.
/// `URL.appendingPathComponent` preserves literal `/` and `..`, so accepting those values from
/// a peer or provider can retarget a credentialed poll/cancel request to a different endpoint.
public enum RemotePathIdentifier {
    public static let maximumBytes = 256

    public static func appending(_ value: String, to base: URL) -> URL? {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"), !value.contains("%"),
              value.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return base.appendingPathComponent(value)
    }
}

public enum RemoteTransferError: LocalizedError {
    case disallowedURL
    case redirectRejected
    case responseTooLarge(Int64)
    case aggregateLimitExceeded(Int64)
    case insufficientDiskSpace
    case unexpectedStatus(Int)
    case unexpectedContentType(String)
    case emptyArtifact

    public var errorDescription: String? {
        switch self {
        case .disallowedURL: "The remote service returned a URL outside its allowed network scope."
        case .redirectRejected: "The remote service redirected outside its allowed network scope."
        case .responseTooLarge(let limit): "The remote response exceeded its \(limit)-byte limit."
        case .aggregateLimitExceeded(let limit):
            "The remote job exceeded its \(limit)-byte aggregate download limit."
        case .insufficientDiskSpace: "There is not enough free disk space to safely download this artifact."
        case .unexpectedStatus(let status): "The artifact server answered HTTP \(status)."
        case .unexpectedContentType(let type): "The artifact server returned \(type), not the expected media type."
        case .emptyArtifact: "The artifact server returned an empty file."
        }
    }
}

/// Thread-safe shared budget for all artifacts returned by one job.
public final class RemoteByteBudget: @unchecked Sendable {
    public let limit: Int64
    private let lock = NSLock()
    private var used: Int64 = 0

    public init(limit: Int64) { self.limit = max(0, limit) }

    public var remaining: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return max(0, limit - used)
    }

    func consume(_ count: Int64) throws {
        guard count >= 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard count <= limit - used else {
            throw RemoteTransferError.aggregateLimitExceeded(limit)
        }
        used += count
    }
}

private final class RemoteRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let policy: RemoteURLPolicy
    let credentialOrigin: URL?

    init(policy: RemoteURLPolicy, credentialOrigin: URL?) {
        self.policy = policy
        self.credentialOrigin = credentialOrigin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(policy.sanitized(request, credentialOrigin: credentialOrigin))
    }
}

/// Bounded JSON/control-plane responses. Redirects are checked before any redirected body is read.
public enum RemoteHTTP {
    public static let controlResponseLimit = 1 * 1_024 * 1_024
    public static let errorResponseLimit = 64 * 1_024

    public static func data(
        for request: URLRequest,
        session: URLSession = .shared,
        policy: RemoteURLPolicy,
        credentialOrigin: URL? = nil,
        successLimit: Int = controlResponseLimit,
        errorLimit: Int = errorResponseLimit
    ) async throws -> (Data, URLResponse) {
        guard let safeRequest = policy.sanitized(request, credentialOrigin: credentialOrigin)
        else { throw RemoteTransferError.disallowedURL }
        let delegate = RemoteRedirectDelegate(policy: policy, credentialOrigin: credentialOrigin)
        let (bytes, response) = try await session.bytes(for: safeRequest, delegate: delegate)
        guard let finalURL = response.url, policy.permits(finalURL) else {
            throw RemoteTransferError.redirectRejected
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
        let limit = (200..<300).contains(status) ? max(0, successLimit) : max(0, errorLimit)
        if response.expectedContentLength > Int64(limit) {
            throw RemoteTransferError.responseTooLarge(Int64(limit))
        }
        var body = Data()
        if response.expectedContentLength > 0 {
            body.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            guard body.count < limit else {
                throw RemoteTransferError.responseTooLarge(Int64(limit))
            }
            body.append(byte)
        }
        return (body, response)
    }
}

/// Streams an artifact directly into a same-directory temporary file and atomically publishes it.
public enum RemoteArtifactTransfer {
    public static let diskReserveBytes: Int64 = 256 * 1_024 * 1_024

    @discardableResult
    public static func download(
        from remote: URL,
        policy: RemoteURLPolicy,
        credentialOrigin: URL? = nil,
        bearerToken: String? = nil,
        to destination: URL,
        maximumBytes: Int64,
        budget: RemoteByteBudget,
        timeout: TimeInterval,
        allowedContentTypes: [String],
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) async throws -> URL {
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try requireDiskCapacity(
            at: directory,
            bytes: min(maximumBytes, 8 * 1_024 * 1_024) + diskReserveBytes
        )

        var request = URLRequest(url: remote)
        request.timeoutInterval = timeout
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        guard let safeRequest = policy.sanitized(request, credentialOrigin: credentialOrigin)
        else { throw RemoteTransferError.disallowedURL }

        let partial = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).partial"
        )
        guard manager.createFile(
            atPath: partial.path, contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
        var published = false
        defer {
            if !published { try? manager.removeItem(at: partial) }
        }

        let handle = try FileHandle(forWritingTo: partial)
        let receiver = BoundedFileReceiver(
            handle: handle,
            directory: directory,
            policy: policy,
            credentialOrigin: credentialOrigin,
            maximumBytes: maximumBytes,
            budget: budget,
            allowedContentTypes: allowedContentTypes,
            configuration: sessionConfiguration
        )
        try await receiver.run(safeRequest)
        try requireDiskCapacity(at: directory, bytes: diskReserveBytes)

        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: partial)
        } else {
            try manager.moveItem(at: partial, to: destination)
        }
        published = true
        return destination
    }

    fileprivate static func requireDiskCapacity(at directory: URL, bytes: Int64) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        if let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value, free < bytes {
            throw RemoteTransferError.insufficientDiskSpace
        }
    }
}

private final class BoundedFileReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let directory: URL
    private let policy: RemoteURLPolicy
    private let credentialOrigin: URL?
    private let maximumBytes: Int64
    private let budget: RemoteByteBudget
    private let allowedContentTypes: [String]
    private let configuration: URLSessionConfiguration
    private let lifecycleLock = NSLock()
    private var task: URLSessionDataTask?
    private var cancellationRequested = false
    private var received: Int64 = 0
    private var nextDiskCheck: Int64 = 8 * 1_024 * 1_024
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private var client: URLSession?

    init(
        handle: FileHandle,
        directory: URL,
        policy: RemoteURLPolicy,
        credentialOrigin: URL?,
        maximumBytes: Int64,
        budget: RemoteByteBudget,
        allowedContentTypes: [String],
        configuration: URLSessionConfiguration
    ) {
        self.handle = handle
        self.directory = directory
        self.policy = policy
        self.credentialOrigin = credentialOrigin
        self.maximumBytes = maximumBytes
        self.budget = budget
        self.allowedContentTypes = allowedContentTypes
        self.configuration = configuration
    }

    func run(_ request: URLRequest) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = request.timeoutInterval
                configuration.timeoutIntervalForResource = request.timeoutInterval
                let client = URLSession(
                    configuration: configuration, delegate: self, delegateQueue: queue
                )
                self.client = client
                let task = client.dataTask(with: request)
                lifecycleLock.lock()
                self.task = task
                let shouldCancel = cancellationRequested
                lifecycleLock.unlock()
                task.resume()
                if shouldCancel { task.cancel() }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        lifecycleLock.lock()
        cancellationRequested = true
        let task = self.task
        lifecycleLock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(policy.sanitized(request, credentialOrigin: credentialOrigin))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              let url = http.url, policy.permits(url)
        else {
            failure = RemoteTransferError.redirectRejected
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            failure = RemoteTransferError.unexpectedStatus(http.statusCode)
            completionHandler(.cancel)
            return
        }
        if http.expectedContentLength > maximumBytes {
            failure = RemoteTransferError.responseTooLarge(maximumBytes)
            completionHandler(.cancel)
            return
        }
        if http.expectedContentLength > budget.remaining {
            failure = RemoteTransferError.aggregateLimitExceeded(budget.limit)
            completionHandler(.cancel)
            return
        }
        if http.expectedContentLength > 0 {
            do {
                try RemoteArtifactTransfer.requireDiskCapacity(
                    at: directory,
                    bytes: http.expectedContentLength + RemoteArtifactTransfer.diskReserveBytes
                )
            } catch {
                failure = error
                completionHandler(.cancel)
                return
            }
        }
        if let type = http.mimeType?.lowercased(),
           !allowedContentTypes.isEmpty,
           !allowedContentTypes.contains(where: { allowed in
               allowed.hasSuffix("/*")
                   ? type.hasPrefix(String(allowed.dropLast()))
                   : type == allowed
           })
        {
            failure = RemoteTransferError.unexpectedContentType(type)
            completionHandler(.cancel)
            return
        }
        self.response = http
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        let count = Int64(data.count)
        guard count <= maximumBytes - received else {
            failure = RemoteTransferError.responseTooLarge(maximumBytes)
            dataTask.cancel()
            return
        }
        do {
            try budget.consume(count)
            try handle.write(contentsOf: data)
            received += count
            if received >= nextDiskCheck {
                try RemoteArtifactTransfer.requireDiskCapacity(
                    at: directory, bytes: RemoteArtifactTransfer.diskReserveBytes
                )
                nextDiskCheck = received + 8 * 1_024 * 1_024
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        var completionError = failure ?? error
        do { try handle.synchronize() } catch {
            if completionError == nil { completionError = error }
        }
        do { try handle.close() } catch {
            if completionError == nil { completionError = error }
        }
        let resultError = completionError
        if resultError == nil, response == nil {
            failure = RemoteTransferError.redirectRejected
        } else if resultError == nil, received == 0 {
            failure = RemoteTransferError.emptyArtifact
        }
        let continuation = self.continuation
        self.continuation = nil
        client?.finishTasksAndInvalidate()
        client = nil
        lifecycleLock.lock()
        self.task = nil
        lifecycleLock.unlock()
        if let error = failure ?? completionError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

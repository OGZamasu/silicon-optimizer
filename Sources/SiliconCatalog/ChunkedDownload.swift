import Foundation

/// Streams an HTTP response body as `Data` chunks.
///
/// `URLSession.bytes(for:)` vends one byte at a time, which caps throughput far below what an
/// Apple SSD and a fast connection can sustain — unacceptable when a single model file is 40 GB.
/// This delegate hands us the same buffers the loading system already assembled, so a download
/// runs at line rate.
enum DownloadEvent: Sendable {
    case response(HTTPURLResponse)
    case chunk(Data)
}

/// A redirect the download's policy would not follow. The transfer ends here, before a byte
/// of the other host's answer is read.
public struct RedirectRefused: Error, LocalizedError, Equatable {
    public var host: String

    public init(host: String) { self.host = host }

    public var errorDescription: String? {
        "The download was redirected somewhere this Mac does not fetch from (\(host))."
    }
}

final class ChunkedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<DownloadEvent, any Error>.Continuation?
    private var task: URLSessionDataTask?
    /// Which redirects may be followed. Nil follows any, which is what the catalogue's own
    /// downloads have always done.
    private let redirects: (@Sendable (URL) -> Bool)?

    init(redirects: (@Sendable (URL) -> Bool)? = nil) {
        self.redirects = redirects
    }

    /// Starts `request` on its own session and returns the event stream. The first event is
    /// always the response; body chunks follow.
    func start(_ request: URLRequest, configuration: URLSessionConfiguration)
        -> AsyncThrowingStream<DownloadEvent, any Error>
    {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }

            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: request)
            lock.withLock { self.task = task }

            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.cancel() }
                // The session holds a strong reference to its delegate until invalidated.
                session.finishTasksAndInvalidate()
            }
            task.resume()
        }
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirects else { return completionHandler(request) }
        guard let url = request.url, redirects(url) else {
            // Ended with a reason rather than handed back as a 3xx: a download that stopped
            // because of where it was sent should say so, not report a status code.
            let host = request.url?.host ?? "an address with no host"
            lock.withLock { continuation }?.finish(throwing: RedirectRefused(host: host))
            task.cancel()
            return completionHandler(nil)
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        if let http = response as? HTTPURLResponse {
            lock.withLock { continuation }?.yield(.response(http))
        }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { continuation }?.yield(.chunk(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let continuation = lock.withLock { self.continuation }
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}

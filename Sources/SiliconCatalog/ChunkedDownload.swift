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

final class ChunkedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<DownloadEvent, any Error>.Continuation?
    private var task: URLSessionDataTask?

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

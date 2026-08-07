import Foundation
import SiliconCore

/// Reads a GGUF header over HTTP, without downloading the model.
///
/// This is what lets the app give a full memory plan — layers, attention geometry, expert
/// counts — for a model it has never seen, before committing to a 30 GB transfer. GGUF puts all
/// its metadata at the front of the file, so a range request for the first few megabytes is
/// enough. Hugging Face serves `Range` on its CDN, so this costs a few hundred kilobytes.
public struct RemoteGGUFReader: Sendable {

    public enum ReadError: Error, LocalizedError {
        case rangeNotSupported
        case headerTooLarge

        public var errorDescription: String? {
            switch self {
            case .rangeNotSupported:
                "This host does not support partial downloads, so the model's architecture "
                    + "cannot be inspected before downloading it."
            case .headerTooLarge:
                "The model's metadata is unusually large and could not be read remotely."
            }
        }
    }

    /// Doubling window. Most headers fit in the first chunk; a large tokenizer vocabulary is what
    /// pushes past it, and the ceiling stops a malformed file from pulling the whole model.
    static let initialChunk = 2 * 1_048_576
    static let maximumChunk = 32 * 1_048_576

    private let session: URLSession
    private let token: String?

    public init(token: String? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration)
        self.token = token
    }

    public func readHeader(repository: String, file: String) async throws -> GGUFReader.Metadata {
        var length = Self.initialChunk

        while length <= Self.maximumChunk {
            let data = try await fetch(repository: repository, file: file, length: length)
            do {
                return try GGUFReader().read(data: data)
            } catch GGUFReader.ReadError.truncated {
                // The metadata runs past what was fetched; ask for twice as much.
                length *= 2
                continue
            }
        }
        throw ReadError.headerTooLarge
    }

    /// Reads the shape, falling back to nil rather than throwing — a browser listing should not
    /// fail because one model's header could not be read.
    public func readShape(repository: String, file: String) async -> ModelShape? {
        guard let metadata = try? await readHeader(repository: repository, file: file)
        else { return nil }
        return GGUFReader().shape(from: metadata)
    }

    private func fetch(repository: String, file: String, length: Int) async throws -> Data {
        var request = URLRequest(
            url: HuggingFaceClient.downloadURL(repository: repository, file: file)
        )
        request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HuggingFaceClient.ClientError.badResponse(0)
        }
        // 206 means the range was honoured. A 200 means the whole file is coming, which for a
        // model is exactly what this class exists to avoid.
        guard http.statusCode == 206 else {
            throw http.statusCode == 200
                ? ReadError.rangeNotSupported
                : HuggingFaceClient.ClientError.badResponse(http.statusCode)
        }
        return data
    }
}

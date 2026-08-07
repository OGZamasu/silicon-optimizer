import Foundation
import SiliconCore

/// Minimal Hugging Face Hub client — repository listing, file metadata and search.
public struct HuggingFaceClient: Sendable {

    public struct RepoFile: Sendable, Hashable {
        public var path: String
        public var size: Bytes
        /// SHA-256 from the Git LFS pointer, when the file is LFS-tracked (all GGUF files are).
        public var sha256: String?
    }

    public struct SearchResult: Sendable, Hashable, Identifiable {
        public var id: String            // "unsloth/Qwen3-8B-GGUF"
        public var downloads: Int
        public var likes: Int
        public var updated: Date?
        public var tags: [String]

        public var author: String { id.split(separator: "/").first.map(String.init) ?? "" }
        public var name: String { id.split(separator: "/").last.map(String.init) ?? id }
    }

    public enum ClientError: Error, LocalizedError {
        case badResponse(Int)
        case fileNotFound(repository: String, quantization: String)
        case rateLimited

        public var errorDescription: String? {
            switch self {
            case .badResponse(let code): "Hugging Face returned HTTP \(code)."
            case .fileNotFound(let repository, let quantization):
                "No \(quantization) file found in \(repository). It may have been renamed or removed."
            case .rateLimited:
                "Hugging Face is rate limiting this machine. Add an access token in Settings to raise the limit."
            }
        }
    }

    private let session: URLSession
    private let token: String?

    public init(session: URLSession = .shared, token: String? = nil) {
        self.session = session
        self.token = token
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        // An access token is optional for public repos but raises the anonymous rate limit and
        // is required for gated models such as Llama.
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: request(url))
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse(0) }
        if http.statusCode == 429 { throw ClientError.rateLimited }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.badResponse(http.statusCode)
        }
        return data
    }

    // MARK: - Repository contents

    /// Lists every file in a repository, including LFS checksums.
    public func files(in repository: String, revision: String = "main") async throws -> [RepoFile] {
        var components = URLComponents(
            string: "https://huggingface.co/api/models/\(repository)/tree/\(revision)"
        )!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]

        let payload = try await data(from: components.url!)
        let entries = try JSONDecoder().decode([TreeEntry].self, from: payload)
        return entries.compactMap { entry in
            guard entry.type == "file" else { return nil }
            return RepoFile(
                path: entry.path,
                size: Bytes(entry.lfs?.size ?? entry.size ?? 0),
                sha256: entry.lfs?.oid
            )
        }
    }

    // MARK: - Search

    public func search(query: String, format: ModelFormat = .gguf, limit: Int = 40) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "filter", value: format == .gguf ? "gguf" : "mlx"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]

        let payload = try await data(from: components.url!)
        let models = try JSONDecoder().decode([SearchModel].self, from: payload)
        let formatter = ISO8601DateFormatter()
        return models.map {
            SearchResult(
                id: $0.id, downloads: $0.downloads ?? 0, likes: $0.likes ?? 0,
                updated: $0.lastModified.flatMap(formatter.date(from:)),
                tags: $0.tags ?? []
            )
        }
    }

    // MARK: - URLs

    public static func downloadURL(repository: String, file: String, revision: String = "main") -> URL {
        let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(encoded)?download=true")!
    }

    public static func pageURL(repository: String) -> URL {
        URL(string: "https://huggingface.co/\(repository)")!
    }

    // MARK: - Wire types

    private struct TreeEntry: Decodable {
        var type: String
        var path: String
        var size: Int64?
        var lfs: LFS?

        struct LFS: Decodable {
            var oid: String
            var size: Int64
        }
    }

    private struct SearchModel: Decodable {
        var id: String
        var downloads: Int?
        var likes: Int?
        var lastModified: String?
        var tags: [String]?
    }
}

import CryptoKit
import Foundation
import Network
import SiliconCore
import Testing
@testable import SiliconCatalog

/// The multi-file download path, exercised for real (hub issue #5: "split-file
/// downloads unexercised"). A local HTTP server stands in for huggingface.co, so
/// sharded transfers, skip-if-valid, resume-from-part and checksum verification all
/// run against genuine sockets without moving gigabytes.
@Suite("Model downloads, sharded")
struct ModelDownloadTests {

    // MARK: - A tiny HTTP file server

    /// Serves GET over loopback from an in-memory file table. Understands Range
    /// (bytes=N-) unless told to ignore it, which is exactly the server behaviour the
    /// downloader's restart path exists for. Records every request it saw.
    private final class FileServer: @unchecked Sendable {
        private let listener: NWListener
        private let lock = NSLock()
        private var files: [String: Data] = [:]
        private(set) var requests: [(path: String, range: Int64?)] = []
        var honorsRange = true
        /// Real Hub/CDN behaviour: a Range starting at or past the end is 416.
        var rangePastEndIs416 = false
        /// A server that answers every Range with 416.
        var rejectsRanges = false
        private(set) var port: UInt16 = 0

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            listener = try NWListener(using: parameters, on: .any)

            // Handlers capture self, so they attach only once everything is initialized.
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: DispatchQueue(label: "file-server"))
            ready.wait()
            port = listener.port?.rawValue ?? 0
        }

        func stop() { listener.cancel() }

        func set(_ path: String, _ data: Data) {
            lock.lock(); files[path] = data; lock.unlock()
        }

        func sawRequest(for path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return requests.contains { $0.path.hasSuffix(path) }
        }

        func range(for path: String) -> Int64? {
            lock.lock(); defer { lock.unlock() }
            return requests.last { $0.path.hasSuffix(path) }?.range
        }

        private func serve(_ connection: NWConnection) {
            connection.start(queue: DispatchQueue(label: "file-server-conn"))
            var head = Data()
            func readMore() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                    [weak self] data, _, _, error in
                    guard let self, error == nil, let data else {
                        connection.cancel(); return
                    }
                    head.append(data)
                    if let headerEnd = head.range(of: Data("\r\n\r\n".utf8)) {
                        self.respond(connection, head: head.subdata(in: 0..<headerEnd.lowerBound))
                    } else {
                        readMore()
                    }
                }
            }
            readMore()
        }

        private func respond(_ connection: NWConnection, head: Data) {
            let text = String(decoding: head, as: UTF8.self)
            let lines = text.components(separatedBy: "\r\n")
            let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            // The query (`?download=true`, which every Hub URL carries) is not part of the file.
            let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
            var from: Int64?
            for line in lines where line.lowercased().hasPrefix("range:") {
                let value = line.split(separator: "=").last ?? ""
                from = Int64(value.split(separator: "-").first ?? "")
            }
            lock.lock()
            requests.append((path, from))
            let stored = files.first { path.hasSuffix($0.key) }?.value
            let honor = honorsRange
            lock.unlock()

            guard let stored else {
                send(connection, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", Data())
                return
            }
            if let from, honor, rejectsRanges || (rangePastEndIs416 && from >= Int64(stored.count)) {
                send(connection,
                     "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(stored.count)\r\n"
                     + "Content-Length: 0\r\nConnection: close\r\n\r\n", Data())
                return
            }
            if let from, honor, from > 0, from < Int64(stored.count) {
                let slice = stored.subdata(in: Int(from)..<stored.count)
                send(connection,
                     "HTTP/1.1 206 Partial Content\r\nContent-Length: \(slice.count)\r\n"
                     + "Content-Range: bytes \(from)-\(stored.count - 1)/\(stored.count)\r\n"
                     + "Connection: close\r\n\r\n",
                     slice)
            } else {
                send(connection,
                     "HTTP/1.1 200 OK\r\nContent-Length: \(stored.count)\r\nConnection: close\r\n\r\n",
                     stored)
            }
        }

        private func send(_ connection: NWConnection, _ header: String, _ body: Data) {
            var payload = Data(header.utf8)
            payload.append(body)
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    // MARK: - Helpers

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("model-dl-\(UUID().uuidString)", isDirectory: true)
    }

    /// A terabyte free, whatever the Mac running the suite has. These files are a few
    /// hundred kilobytes; whether they fit beside the 10 GiB reserve is not what is being
    /// tested here, and on a nearly full startup disk the live answer is "no".
    private static let roomToSpare: @Sendable (URL) -> Int64? = { _ in 1 << 40 }

    // MARK: - The reserve

    /// The reserve is asked of the free space the downloader was given, before a byte moves:
    /// exactly the file plus the reserve is not enough, one byte more is.
    @Test func theReserveIsKeptOfTheFreeSpaceTheDownloaderIsGiven() async throws {
        let server = try FileServer()
        defer { server.stop() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let whole = randomData(100_000)
        server.set("weights.safetensors", whole)
        let resolution = ModelResolver.Resolution(
            repository: "test/reserve",
            files: [.init(path: "weights.safetensors",
                          size: Bytes(Int64(whole.count)), sha256: sha(whole))],
            projector: nil
        )
        let exactly = Int64(whole.count) + ModelDownloader.diskReserve.rawValue
        let asked = LockedPaths()
        func downloader(free: Int64) -> ModelDownloader {
            ModelDownloader(
                baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
                availableCapacity: { url in
                    asked.append(url.standardizedFileURL.path)
                    return free
                }
            )
        }

        await #expect(throws: ModelDownloader.DownloadError.self) {
            _ = try await downloader(free: exactly).download(resolution, to: directory) { _ in }
        }
        #expect(server.requests.isEmpty)
        #expect(Set(asked.paths) == [directory.standardizedFileURL.path])

        let written = try await downloader(free: exactly + 1)
            .download(resolution, to: directory) { _ in }
        #expect(try Data(contentsOf: written[0]) == whole)
    }

    private final class LockedPaths: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var paths: [String] { lock.withLock { stored } }
        func append(_ path: String) { lock.withLock { stored.append(path) } }
    }

    // MARK: - The sharded transfer

    @Test func aShardedModelArrivesWholeAndAlreadyValidFilesAreNotRefetched() async throws {
        let server = try FileServer()
        defer { server.stop() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let shard1 = randomData(300_000)
        let shard2 = randomData(200_000)
        let config = Data(#"{"model_type":"qwen3"}"#.utf8)
        server.set("model-00001-of-00002.safetensors", shard1)
        server.set("model-00002-of-00002.safetensors", shard2)
        server.set("config.json", config)

        // The head shard is already on disk and valid; only the rest should transfer.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try shard1.write(to: directory.appendingPathComponent("model-00001-of-00002.safetensors"))

        let resolution = ModelResolver.Resolution(
            repository: "test/sharded",
            files: [
                .init(path: "model-00001-of-00002.safetensors",
                      size: Bytes(Int64(shard1.count)), sha256: sha(shard1)),
                .init(path: "model-00002-of-00002.safetensors",
                      size: Bytes(Int64(shard2.count)), sha256: sha(shard2)),
                .init(path: "config.json", size: Bytes(Int64(config.count)), sha256: nil),
            ],
            projector: nil
        )
        #expect(resolution.isSharded)

        final class ProgressBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: ModelDownloader.Progress?
            var last: ModelDownloader.Progress? {
                get { lock.lock(); defer { lock.unlock() }; return value }
                set { lock.lock(); value = newValue; lock.unlock() }
            }
        }
        let progress = ProgressBox()
        let downloader = ModelDownloader(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            availableCapacity: Self.roomToSpare
        )
        let written = try await downloader.download(resolution, to: directory) {
            progress.last = $0
        }

        #expect(written.count == 3)
        #expect(written[0].lastPathComponent == "model-00001-of-00002.safetensors")
        #expect(try Data(contentsOf: written[1]) == shard2)
        #expect(try Data(contentsOf: written[2]) == config)
        #expect(server.sawRequest(for: "model-00001-of-00002.safetensors") == false)
        #expect(progress.last?.fileCount == 3)
    }

    @Test func aSameSizeFileWithTheWrongDigestIsRefetched() async throws {
        let server = try FileServer()
        defer { server.stop() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expected = Data("reviewed model bytes".utf8)
        let substituted = Data(repeating: 0x41, count: expected.count)
        server.set("weights.gguf", expected)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try substituted.write(to: directory.appendingPathComponent("weights.gguf"))
        let resolution = ModelResolver.Resolution(
            repository: "test/curated",
            files: [.init(path: "weights.gguf", size: Bytes(Int64(expected.count)), sha256: sha(expected))],
            projector: nil
        )
        let downloader = ModelDownloader(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let written = try await downloader.download(resolution, to: directory) { _ in }

        #expect(try Data(contentsOf: written[0]) == expected)
        #expect(server.sawRequest(for: "weights.gguf"))
    }

    @Test func aSameSizeFileWithoutADigestIsRefetched() async throws {
        let server = try FileServer()
        defer { server.stop() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expected = Data("fresh config".utf8)
        let substituted = Data("other config".utf8)
        #expect(substituted.count == expected.count)
        server.set("config.json", expected)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try substituted.write(to: directory.appendingPathComponent("config.json"))
        let resolution = ModelResolver.Resolution(
            repository: "test/curated",
            files: [.init(path: "config.json", size: Bytes(Int64(expected.count)), sha256: nil)],
            projector: nil
        )
        let downloader = ModelDownloader(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let written = try await downloader.download(resolution, to: directory) { _ in }

        #expect(try Data(contentsOf: written[0]) == expected)
        #expect(server.sawRequest(for: "config.json"))
    }

    @Test func anUnverifiedPartialCannotBeCombinedWithARangedResponse() async throws {
        let server = try FileServer()
        defer { server.stop() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expected = Data("trusted configuration".utf8)
        server.set("config.json", expected)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("UNSAFE!".utf8).write(to: directory.appendingPathComponent("config.json.part"))
        let resolution = ModelResolver.Resolution(
            repository: "test/curated",
            files: [.init(path: "config.json", size: Bytes(Int64(expected.count)), sha256: nil)],
            projector: nil
        )
        let downloader = ModelDownloader(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let written = try await downloader.download(resolution, to: directory) { _ in }

        #expect(try Data(contentsOf: written[0]) == expected)
        #expect(server.range(for: "config.json") == nil)
    }

    /// A cancel during the post-transfer checksum keeps the whole partial. The next attempt
    /// must not ask the Hub for `bytes=<size>-`, which a real Hub answers with 416 on every
    /// try: the partial is checked and moved into place. (Regression test from the critic.)
    @Test func aCompletePartialLeftByACancelledChecksumIsNotRangeRequestedAgain() async throws {
        let server = try FileServer()
        defer { server.stop() }
        server.rangePastEndIs416 = true
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bytes = randomData(64 * 1024)
        server.set("weights.gguf", bytes)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent("weights.gguf.part"))
        let resolution = ModelResolver.Resolution(
            repository: "test/curated",
            files: [.init(path: "weights.gguf", size: Bytes(Int64(bytes.count)), sha256: sha(bytes))],
            projector: nil
        )
        let downloader = ModelDownloader(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let written = try await downloader.download(resolution, to: directory) { _ in }
        #expect(try Data(contentsOf: written[0]) == bytes)
        #expect(!server.sawRequest(for: "weights.gguf"), "a right partial needs no network")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("weights.gguf.part").path))
    }

    /// A partial as long as the file but with the wrong bytes, or longer than the file, is
    /// fetched afresh — whole, never ranged.
    @Test func aFullOrOverlongPartialWithTheWrongBytesIsFetchedWhole() async throws {
        for extra in [0, 7] {
            let server = try FileServer()
            defer { server.stop() }
            server.rangePastEndIs416 = true
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let bytes = randomData(64 * 1024)
            server.set("weights.gguf", bytes)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes.count + extra)
                .write(to: directory.appendingPathComponent("weights.gguf.part"))
            let resolution = ModelResolver.Resolution(
                repository: "test/curated",
                files: [.init(path: "weights.gguf", size: Bytes(Int64(bytes.count)), sha256: sha(bytes))],
                projector: nil
            )
            let downloader = ModelDownloader(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
            let written = try await downloader.download(resolution, to: directory) { _ in }
            #expect(try Data(contentsOf: written[0]) == bytes)
            #expect(server.sawRequest(for: "weights.gguf"))
            #expect(server.range(for: "weights.gguf") == nil, "extra \(extra)")
        }
    }

    /// A 416 to a ranged request means the partial is no prefix the server recognises: the
    /// file is fetched again from the start instead of failing on every attempt.
    @Test func aRangeTheServerRefusesRestartsTheFile() async throws {
        let server = try FileServer()
        defer { server.stop() }
        server.rejectsRanges = true
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bytes = randomData(64 * 1024)
        server.set("weights.gguf", bytes)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.prefix(1000).write(to: directory.appendingPathComponent("weights.gguf.part"))
        let resolution = ModelResolver.Resolution(
            repository: "test/curated",
            files: [.init(path: "weights.gguf", size: Bytes(Int64(bytes.count)), sha256: sha(bytes))],
            projector: nil
        )
        let downloader = ModelDownloader(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let written = try await downloader.download(resolution, to: directory) { _ in }
        #expect(try Data(contentsOf: written[0]) == bytes)
        #expect(server.range(for: "weights.gguf") == nil, "the retry asks for the whole file")
    }

    /// Reusing a local file now means hashing it, and a cancel must not wait behind that:
    /// the check stops, nothing is fetched, and nothing comes back as verified.
    @Test func aCancelledDownloadStopsCheckingLocalBytes() async throws {
        let server = try FileServer()
        defer { server.stop() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bytes = randomData(64 * 1024)
        server.set("weights.gguf", bytes)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent("weights.gguf"))
        let resolution = ModelResolver.Resolution(
            repository: "test/curated",
            files: [.init(path: "weights.gguf", size: Bytes(Int64(bytes.count)), sha256: sha(bytes))],
            projector: nil
        )
        let downloader = ModelDownloader(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let attempt = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await downloader.download(resolution, to: directory) { _ in }
        }
        await #expect(throws: CancellationError.self) { _ = try await attempt.value }
        #expect(!server.sawRequest(for: "weights.gguf"))
    }

    /// The checksum after a transfer, and the one before a reuse, stop at the next chunk
    /// once their task is cancelled — Stop and Remove wait for a phone model's attempt,
    /// and that attempt hashes gigabytes.
    @Test func aCancelledChecksumStopsReading() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("weights.gguf")
        try randomData(64 * 1024).write(to: file)
        let downloader = ModelDownloader()

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try downloader.sha256(of: file, checkingCancellation: true)
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        // The same read in a live task still finishes.
        #expect(try downloader.sha256(of: file, checkingCancellation: true) == sha(try Data(contentsOf: file)))
    }

    @Test func aPartialFileResumesWhereItStopped() async throws {
        let server = try FileServer()
        defer { server.stop() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let whole = randomData(400_000)
        server.set("weights.safetensors", whole)

        // A previous attempt got half the file.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try whole.prefix(150_000).write(
            to: directory.appendingPathComponent("weights.safetensors.part")
        )

        let resolution = ModelResolver.Resolution(
            repository: "test/resume",
            files: [.init(path: "weights.safetensors",
                          size: Bytes(Int64(whole.count)), sha256: sha(whole))],
            projector: nil
        )
        let downloader = ModelDownloader(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            availableCapacity: Self.roomToSpare
        )
        let written = try await downloader.download(resolution, to: directory) { _ in }

        #expect(server.range(for: "weights.safetensors") == 150_000)
        #expect(try Data(contentsOf: written[0]) == whole)
    }

    /// A server that answers a Range request with 200 sent the whole byte stream; the
    /// partial on disk is then a prefix of nothing and must be thrown away, not prepended.
    @Test func aServerThatIgnoresRangeRestartsTheFileCleanly() async throws {
        let server = try FileServer()
        server.honorsRange = false
        defer { server.stop() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let whole = randomData(250_000)
        server.set("weights.safetensors", whole)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Garbage that is NOT a prefix of the real stream.
        try randomData(80_000).write(
            to: directory.appendingPathComponent("weights.safetensors.part")
        )

        let resolution = ModelResolver.Resolution(
            repository: "test/restart",
            files: [.init(path: "weights.safetensors",
                          size: Bytes(Int64(whole.count)), sha256: sha(whole))],
            projector: nil
        )
        let downloader = ModelDownloader(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            availableCapacity: Self.roomToSpare
        )
        let written = try await downloader.download(resolution, to: directory) { _ in }
        #expect(try Data(contentsOf: written[0]) == whole)
    }
}

/// The MLX side of hub issue #5: an MLX model is a directory, and the resolver must
/// bring the whole directory — weights first, documentation left behind.
@Suite("MLX resolution")
struct MLXResolutionTests {

    private func listing(_ names: [String]) -> [HuggingFaceClient.RepoFile] {
        names.map { .init(path: $0, size: Bytes(1), sha256: nil) }
    }

    @Test func picksWeightsConfigAndTokenizerAndSkipsDocs() {
        // The real file list of mlx-community/Qwen3-4B-Instruct-2507-4bit, docs included.
        let files = ModelResolver.mlxModelFiles(in: listing([
            ".gitattributes", "README.md", "added_tokens.json", "chat_template.jinja",
            "config.json", "generation_config.json", "merges.txt", "model.safetensors",
            "model.safetensors.index.json", "special_tokens_map.json", "tokenizer.json",
            "tokenizer_config.json", "vocab.json",
        ]))
        let names = files.map(\.path)
        #expect(names.first == "model.safetensors")
        #expect(!names.contains("README.md"))
        #expect(!names.contains(".gitattributes"))
        #expect(names.contains("model.safetensors.index.json"))
        #expect(names.contains("tokenizer.json"))
        #expect(names.contains("chat_template.jinja"))
        #expect(names.contains("merges.txt"))
    }

    @Test func shardedWeightsLeadTheList() {
        let files = ModelResolver.mlxModelFiles(in: listing([
            "config.json", "model-00002-of-00003.safetensors", "tokenizer.json",
            "model-00001-of-00003.safetensors", "model-00003-of-00003.safetensors",
        ]))
        #expect(files.prefix(3).allSatisfy { $0.path.hasSuffix(".safetensors") })
        #expect(files.first?.path == "model-00001-of-00003.safetensors")
    }

    @Test func theMLXCatalogEntriesResolveAgainstTheirTwinsShapes() {
        let flagship = ModelCatalog.entry(id: "qwen3.8-27b-mlx")
        #expect(flagship?.format == .mlx)
        #expect(flagship?.variants.first?.quantization == .mlx4)
        #expect(flagship?.shape.totalParameters
                == ModelCatalog.entry(id: "qwen3.8-27b")?.shape.totalParameters)

        let small = ModelCatalog.entry(id: "qwen3-4b-mlx")
        #expect(small?.format == .mlx)
        #expect(small?.shape.totalParameters
                == ModelCatalog.entry(id: "qwen3-4b")?.shape.totalParameters)
    }
}

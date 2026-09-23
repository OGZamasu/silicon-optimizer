import CryptoKit
import Foundation
import Network
import Security
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconCore
@testable import SiliconRuntime
@testable import SiliconUI

// The fixtures behind `BuddyPhoneModelsTests`: a phone-model store over a temporary model
// library, a loopback stand-in for Hugging Face, and a control server that answers
// `/ondevice/models` from them.

// MARK: - Waiting without sleeping blind

/// Polls until `condition` holds. The timeout is only how long a failure takes to report:
/// a passing run returns in milliseconds, and a Mac busy with someone else's build must not
/// turn a slow poll into a red test.
func until(
    _ timeout: Duration = .seconds(60), _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// A value a test changes while the code under test reads it from another task.
final class SharedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A one-way gate a test opens: whoever waits on it is held until then.
actor PauseGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

// MARK: - A store over a temporary library

extension PhoneModelStore.Volumes {
    /// The live drives with a terabyte free on each, for a store a test builds by hand:
    /// what fits is then the test's business rather than the build machine's.
    static let roomToSpare = PhoneModelStore.Volumes(
        missingDrive: { PhoneModelStore.missingDrive(for: $0) },
        availableCapacity: { _ in PhoneModelFixture.roomToSpare },
        volumeID: { PhoneModelStore.volumeID(of: $0) }
    )
}

/// A phone-model store and service over a temporary model library, fed by a loopback
/// stand-in for Hugging Face that serves random bytes under the real pinned paths. The
/// catalogue is the real one with each file shrunk to a few hundred kilobytes — same ids,
/// repositories, commits and file names, so every request the store makes is the one it
/// would make for real.
struct PhoneModelFixture: Sendable {
    var directory = URL(fileURLWithPath: "/nonexistent")
    var huggingFace: FakeHuggingFace!
    var qwenBytes = Data()
    var gemmaBytes = Data()
    var qwen = PhoneModelCatalog.qwen35_2B
    var gemma = PhoneModelCatalog.gemma4E2B
    var store: PhoneModelStore!
    var service: PhoneModelService!
    var provider: PhoneModelsAtLibrary!
    var hub = BuddyEventHub()
    /// The model library folder, as Settings would have it. A test moves it by setting this.
    var libraryBox = SharedBox<URL?>(nil)
    /// Folders whose drive the test has "unplugged".
    var unplugged = SharedBox<[String]>([])
    /// Every folder the room check was asked about.
    var roomAsked = SharedBox<[URL]>([])
    /// When set, every check of a file waits here first.
    var checkGate = SharedBox<PauseGate?>(nil)
    /// Folders the test has put on a drive of their own, by path prefix.
    var volumeOf = SharedBox<[String: Int64]>([:])
    /// Free bytes on every drive, as the store and its downloader read them. A terabyte
    /// unless a test says otherwise: the files here are a few hundred kilobytes, and
    /// whether they fit beside the 10 GiB reserve must not depend on how full the disk of
    /// the Mac running the suite happens to be.
    var room = SharedBox<Int64?>(PhoneModelFixture.roomToSpare)

    static let roomToSpare: Int64 = 1 << 40

    var library: URL? {
        get { libraryBox.value }
        nonmutating set { libraryBox.value = newValue }
    }

    /// `<library>/Phone Models`, where the store should be putting things now.
    var root: URL {
        (library ?? directory.appendingPathComponent("Fallback"))
            .standardizedFileURL.appendingPathComponent(PhoneModelStore.folderName)
    }

    var stateFile: URL { directory.appendingPathComponent("phone-models.json") }

    static func pinnedPath(_ entry: PhoneModelEntry) -> String {
        "/\(entry.repository)/resolve/\(entry.commit)/\(entry.file)"
    }

    /// The whole request target the Hub is asked for, query and all.
    static func pinnedTarget(_ entry: PhoneModelEntry) -> String {
        pinnedPath(entry) + "?download=true"
    }

    func fileURL(_ entry: PhoneModelEntry, in folder: URL? = nil) -> URL {
        (folder ?? root).appendingPathComponent(entry.file)
    }

    func partialURL(_ entry: PhoneModelEntry, in folder: URL? = nil) -> URL {
        fileURL(entry, in: folder).appendingPathExtension("part")
    }

    func size(of url: URL) -> Int64? { Self.size(of: url) }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { ($0[.size] as? NSNumber)?.int64Value }
    }

    /// Whatever is left in a phone-models folder, hidden files included.
    func leftovers(in folder: URL? = nil) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: (folder ?? root).path)) ?? []
    }

    // The store's calls, at the library the test has set.

    func state(_ entry: PhoneModelEntry) async -> PhoneModelStore.State? {
        await store.state(of: entry.id, library: library)
    }

    @discardableResult
    func prepare(
        _ entry: PhoneModelEntry, verify: Bool = false
    ) async throws -> PhoneModelStore.PrepareOutcome {
        try await store.prepare(id: entry.id, library: library, verify: verify)
    }

    func verified(_ entry: PhoneModelEntry) async -> PhoneModelStore.VerifiedFile? {
        try? await store.verifiedFile(id: entry.id, library: library)
    }

    func remove(_ entry: PhoneModelEntry) async throws {
        try await store.remove(id: entry.id, library: library)
    }

    func settle(_ entry: PhoneModelEntry) async {
        await store.waitUntilSettled(id: entry.id)
    }

    /// Prepares and waits for it to finish, however it finishes.
    func fetch(_ entry: PhoneModelEntry) async throws {
        try await prepare(entry)
        await settle(entry)
    }

    /// Cuts the next transfer of `entry` off after exactly `bytes` — and only once the
    /// store has those bytes on disk, so what a resume starts from is known rather than
    /// raced against how quickly the socket was read before it closed.
    func interrupt(_ entry: PhoneModelEntry, after bytes: Int) async throws {
        huggingFace.hold(after: bytes)
        try await prepare(entry)
        let partial = partialURL(entry)
        try await until { Self.size(of: partial) == Int64(bytes) }
        huggingFace.drop()
        await settle(entry)
    }

    static func with(
        spaceCheck: PhoneModelStore.SpaceCheck? = nil,
        qwenSize: Int = 300_000, gemmaSize: Int = 200_000,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (PhoneModelFixture) async throws -> Void
    ) async throws {
        var fixture = PhoneModelFixture()
        fixture.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-phone-models-\(UUID())")
        let library = fixture.directory.appendingPathComponent("Local Models")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let huggingFace = try FakeHuggingFace()
        defer { huggingFace.stop() }

        fixture.huggingFace = huggingFace
        fixture.qwenBytes = randomBytes(qwenSize)
        fixture.gemmaBytes = randomBytes(gemmaSize)
        fixture.qwen = shrunk(PhoneModelCatalog.qwen35_2B, to: fixture.qwenBytes)
        fixture.gemma = shrunk(PhoneModelCatalog.gemma4E2B, to: fixture.gemmaBytes)
        huggingFace.serve(fixture.qwenBytes, at: pinnedPath(fixture.qwen))
        huggingFace.serve(fixture.gemmaBytes, at: pinnedPath(fixture.gemma))
        fixture.library = library

        let stateFile = fixture.stateFile
        let base = huggingFace.baseURL
        let unplugged = fixture.unplugged
        let asked = fixture.roomAsked
        let check = spaceCheck
        let volumeOf = fixture.volumeOf
        let room = fixture.room
        let gate = fixture.checkGate
        let hooks = PhoneModelStore.Hooks(beforeCheck: { _ in await gate.value?.wait() })
        fixture.store = PhoneModelStore(
            catalog: [fixture.qwen, fixture.gemma],
            fallback: fixture.directory.appendingPathComponent("Fallback")
                .appendingPathComponent(PhoneModelStore.folderName),
            stateFile: { stateFile },
            source: { base },
            spaceCheck: { needed, folder in
                asked.value.append(folder)
                try check?(needed, folder)
            },
            volumes: .init(
                missingDrive: { folder in
                    let path = folder.standardizedFileURL.path
                    if unplugged.value.contains(where: { path.hasPrefix($0) }) { return "Old Drive" }
                    return PhoneModelStore.missingDrive(for: folder)
                },
                availableCapacity: { _ in room.value },
                volumeID: { url in
                    let path = url.standardizedFileURL.path
                    if let own = volumeOf.value.first(where: { path.hasPrefix($0.key) }) {
                        return own.value
                    }
                    return PhoneModelStore.volumeID(of: url)
                }
            ),
            hooks: hooks
        )
        fixture.service = PhoneModelService(
            store: fixture.store, hub: fixture.hub, watchInterval: .milliseconds(20)
        )
        let libraryBox = fixture.libraryBox
        fixture.provider = PhoneModelsAtLibrary(service: fixture.service) { libraryBox.value }

        // Whatever happened, nothing may still be writing into the folder the defer above
        // is about to delete.
        let store: PhoneModelStore = fixture.store
        let ids = [fixture.qwen.id, fixture.gemma.id]
        func drain() async {
            await gate.value?.release()
            huggingFace.release()
            for id in ids {
                await store.cancel(id: id)
                await store.waitUntilSettled(id: id)
            }
        }
        do {
            try await body(fixture)
        } catch {
            await drain()
            throw error
        }
        await drain()
    }

    /// The real entry, with its size and digest swapped for a small file's.
    static func shrunk(_ real: PhoneModelEntry, to bytes: Data) -> PhoneModelEntry {
        var entry = real
        entry.sizeBytes = Int64(bytes.count)
        entry.sha256 = sha256(bytes)
        return entry
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        precondition(status == errSecSuccess)
        return data
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - A control server over a provider

/// A control server whose `/ondevice/models` answers from the provider handed in, with a
/// loopback listener for this Mac's own token and a second one standing in for the
/// tailnet, where paired devices — and, when the swarm is exposed, the swarm token — are
/// honoured.
struct PhoneRouteFixture {
    let server: ControlServer
    let local: TestClient
    let phone: TestClient
    let devices: BuddyRegistry

    func pair(
        name: String = "Galaxy S24 Ultra", scope: BuddyScope = .full
    ) async throws -> ControlAPI.BuddyPairResponse {
        let invitation = await devices.invite(host: "127.0.0.1", port: phone.port, scope: scope)
        let (status, body) = try await phone.call(
            "POST", "/buddy/pair", token: nil,
            body: #"{"code":"\#(invitation.code)","deviceName":"\#(name)","platform":"android"}"#
        )
        #expect(status == 200)
        return try JSONDecoder().decode(ControlAPI.BuddyPairResponse.self, from: body)
    }

    static func with(
        provider: (any PhoneModelProvider)?, hub: BuddyEventHub = BuddyEventHub(),
        swarmToken: String? = nil, swarmOnTailnet: Bool = false,
        writeDeadline: Duration = ControlServer.defaultEventWriteDeadline,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (PhoneRouteFixture) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-phone-routes-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let handshakeURL = directory.appendingPathComponent("control.json")
        let devices = BuddyRegistry(url: directory.appendingPathComponent("buddy.json"))
        let server = ControlServer(
            host: BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false),
            handshakeURL: handshakeURL, buddy: devices, events: hub,
            media: MediaRegistry(url: nil),
            uploadsRoot: directory.appendingPathComponent("uploads"),
            postersRoot: directory.appendingPathComponent("posters"),
            eventWriteDeadline: writeDeadline,
            // Never the real CLI: a test must not bind whatever tailnet this machine is on.
            discoverTailnetAddress: { nil },
            phoneModels: provider
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 64
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        try await server.start(swarmToken: swarmToken)
        defer { Task { await server.stop() } }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: handshakeURL.path) {
            guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
        let handshake = try JSONDecoder().decode(
            ControlAPI.Handshake.self, from: try Data(contentsOf: handshakeURL)
        )
        await devices.setAllowsTailnetDevices(true)
        let tailnetPort = try await BuddyControlTests.bindTailnetListener(
            on: server, avoiding: handshake.port
        )
        if swarmOnTailnet {
            // The owner has also let the swarm reach this Mac: the same socket, now with the
            // swarm secret honoured on it.
            try await server.setTailnetAccess(address: "127.0.0.1", port: tailnetPort, for: .swarm)
        }

        try await body(PhoneRouteFixture(
            server: server,
            local: TestClient(port: handshake.port, token: handshake.token, session: session),
            phone: TestClient(port: tailnetPort, token: handshake.token, session: session),
            devices: devices
        ))
        await server.stop()
    }
}

/// One file, ready, under one id — for the tests about how bytes go out rather than how
/// they arrived.
struct OneFile: PhoneModelProvider {
    let id: String
    let file: ControlAPI.PhoneModelFile

    func phoneModels() async -> ControlAPI.PhoneModelList { .init(models: []) }

    func preparePhoneModel(
        id: String, verify: Bool
    ) async throws -> ControlAPI.PhoneModelPreparation {
        throw PhoneModelError.unknownModel(id)
    }

    func phoneModelFile(id: String) async throws -> ControlAPI.PhoneModelFile {
        guard id == self.id else { throw PhoneModelError.unknownModel(id) }
        return file
    }

    func removePhoneModel(id: String) async throws -> ControlAPI.PhoneModel {
        throw PhoneModelError.unknownModel(id)
    }
}

extension TestClient {

    /// A GET whose headers matter as much as its body, with whatever conditional and range
    /// headers the test sends. Always to the wire: `URLSession` would otherwise answer a
    /// 304 from its own cache and call it a 200.
    func fetchFile(
        _ path: String, token: String?, headers: [String: String] = [:]
    ) async throws -> MediaAnswer {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (body, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        var lowered: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            lowered[key.lowercased()] = value
        }
        return MediaAnswer(status: http.statusCode, headers: lowered, body: body)
    }
}

/// Holds an `/events` stream open and keeps every frame it is sent.
final class EventFollower: @unchecked Sendable {
    private let task: Task<Void, any Error>
    private let log: Log

    private actor Log {
        var frames: [TestClient.Frame] = []
        func append(_ frame: TestClient.Frame) { frames.append(frame) }
    }

    private init(task: Task<Void, any Error>, log: Log) {
        self.task = task
        self.log = log
    }

    static func open(_ client: TestClient, token: String) async throws -> EventFollower {
        let log = Log()
        let ready = Ready()
        let task = Task {
            let (bytes, response) = try await client.session.bytes(
                for: client.request("GET", "/events", token: token, body: nil)
            )
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw BuddyTestError.unexpectedRoute
            }
            var name = ""
            for try await line in bytes.lines {
                if line.hasPrefix("event: ") {
                    name = String(line.dropFirst("event: ".count))
                } else if line.hasPrefix("data: ") {
                    await log.append(.init(name: name, data: String(line.dropFirst("data: ".count))))
                    await ready.signal()
                }
            }
        }
        do {
            try await ready.wait()
        } catch {
            task.cancel()
            throw error
        }
        return EventFollower(task: task, log: log)
    }

    /// The `download` frames for one id, in the order they arrived.
    func downloads(_ id: String) async -> [ControlAPI.DownloadEvent] {
        await log.frames.filter { $0.name == "download" }.compactMap {
            try? JSONDecoder().decode(ControlAPI.DownloadEvent.self, from: Data($0.data.utf8))
        }.filter { $0.id == id }
    }

    func stop() { task.cancel() }
}

// MARK: - Hugging Face, over loopback

/// Stands in for huggingface.co: serves a few files at exact paths, honours
/// `Range: bytes=N-`, records what it was asked and with which credentials, and can be told
/// to misbehave the ways the real one does — hold a transfer open partway, then either let
/// it finish or drop the connection, or answer with a redirect.
final class FakeHuggingFace: @unchecked Sendable {

    struct Request: Sendable, Equatable {
        /// The request target as sent, query included.
        var target: String
        var range: String?
        var authorization: String?
        var cookie: String?

        /// Without the query.
        var path: String { target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target }
    }

    /// What a held transfer sends before it waits, unless told otherwise.
    static let heldPrefix = 16_384

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-hugging-face")
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var redirects: [String: String] = [:]
    private var log: [Request] = []
    /// How much of a body goes out before a transfer waits, while transfers are held.
    private var holdingAfter: Int?
    private var held: [(connection: NWConnection, rest: Data)] = []
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw BuddyTestError.timeout
        }
        port = listener.port?.rawValue ?? 0
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    var requests: [Request] { lock.withLock { log } }

    func serve(_ data: Data, at path: String) { lock.withLock { files[path] = data } }
    func unserve(_ path: String) { _ = lock.withLock { files.removeValue(forKey: path) } }

    /// Answers `path` with a 302 to `location`.
    func redirect(_ path: String, to location: String) {
        lock.withLock { redirects[path] = location }
    }

    /// Transfers from now on declare their full length, send `bytes` of it, and wait for
    /// `release` or `drop`.
    func hold(after bytes: Int = FakeHuggingFace.heldPrefix) {
        lock.withLock { holdingAfter = bytes }
    }

    /// Lets every held transfer finish.
    func release() {
        for transfer in takeHeld() { send(transfer.connection, "", transfer.rest) }
    }

    /// Hangs up on every held transfer without sending the rest — which is what a dropped
    /// connection looks like from the client's side.
    func drop() {
        for transfer in takeHeld() { transfer.connection.cancel() }
    }

    private func takeHeld() -> [(connection: NWConnection, rest: Data)] {
        lock.withLock {
            holdingAfter = nil
            defer { held = [] }
            return held
        }
    }

    func stop() {
        listener.cancel()
        let open = lock.withLock { () -> [NWConnection] in
            held = []
            defer { connections = [] }
            return connections
        }
        for connection in open { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(
                    decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self
                ))
            } else if error == nil, !complete {
                self.receive(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(
            target: target, range: headers["range"], authorization: headers["authorization"],
            cookie: headers["cookie"]
        )
        let (stored, holdAfter, location) = lock.withLock {
            (files[request.path], holdingAfter, redirects[request.path])
        }
        if let location {
            send(connection, "HTTP/1.1 302 Found\r\nLocation: \(location)\r\n"
                + "Set-Cookie: session=fixture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            record(request)
            return
        }
        guard let stored else {
            send(connection, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            record(request)
            return
        }

        var status = "200 OK"
        var body = stored
        var extra = ""
        if let range = headers["range"], range.hasPrefix("bytes="),
           let from = Int(range.dropFirst("bytes=".count).split(separator: "-").first ?? "") {
            guard from < stored.count else {
                send(connection, "HTTP/1.1 416 Range Not Satisfiable\r\n"
                    + "Content-Range: bytes */\(stored.count)\r\nContent-Length: 0\r\n"
                    + "Connection: close\r\n\r\n")
                record(request)
                return
            }
            status = "206 Partial Content"
            body = stored.subdata(in: from..<stored.count)
            extra = "Content-Range: bytes \(from)-\(stored.count - 1)/\(stored.count)\r\n"
        }
        let header = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\n"
            + "Content-Type: application/octet-stream\r\n\(extra)Connection: close\r\n\r\n"

        if let holdAfter {
            send(connection, header, Data(body.prefix(holdAfter)), close: false)
            // Held, then logged, in one step and only after the prefix is queued: a test that
            // can see this request can release or drop it, and the rest of the body can only
            // ever follow the part already sent.
            let rest = Data(body.dropFirst(holdAfter))
            lock.withLock {
                held.append((connection, rest))
                log.append(request)
            }
        } else {
            send(connection, header, body)
            record(request)
        }
    }

    private func record(_ request: Request) { lock.withLock { log.append(request) } }

    private func send(
        _ connection: NWConnection, _ header: String, _ body: Data = Data(), close: Bool = true
    ) {
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }
}

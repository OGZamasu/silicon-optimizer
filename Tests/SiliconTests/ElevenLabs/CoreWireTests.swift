import Foundation
import Network
import Testing
@testable import SiliconElevenLabs

/// `URLSessionTransport` on a real socket — a loopback server on an ephemeral port, reached
/// through the debug-only loopback allowance — for what an in-memory transport cannot show:
/// multipart framing, chunked streaming, redirect refusal and cancellation as URLSession
/// actually does them. Nothing here leaves 127.0.0.1.
@Suite("ElevenLabs transport on the wire")
struct CoreWireTests {

    static let key = "sk_" + String(repeating: "wirefixture", count: 3)

    @Test func multipartBodiesArriveFramedAndWhole() async throws {
        let server = try LoopbackServer { _ in .whole(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8)) }
        defer { server.stop() }
        let transport = URLSessionTransport.loopbackForTesting(port: Int(server.port))
        let scratch = try Scratch()
        defer { scratch.remove() }

        // Two megabytes, so the copy from disk takes more than one read.
        let audio = Data((0..<(2 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let source = scratch.url("sample.mp3")
        try audio.write(to: source)
        let body = scratch.url("body.multipart")
        let contentType = try MultipartWriter.write([
            MultipartPart(name: "name", value: .text("Narrator")),
            MultipartPart(name: "files", value: .file(ElevenLabsFile(url: source), size: Int64(audio.count))),
        ], to: body)

        let response = try await transport.send(Self.request(
            server, "/v1/voices/add", method: "POST", headers: ["Content-Type": contentType], body: .file(body)
        ))
        #expect(response.status == 200)

        let received = try #require(server.requests.first)
        #expect(received.method == "POST")
        #expect(received.headers["content-type"] == contentType)
        #expect(received.headers["xi-api-key"] == Self.key)
        #expect(Int(received.headers["content-length"] ?? "") == received.body.count)
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let parts = MultipartMixed.split(received.body, boundary: boundary)
        #expect(parts.count == 2)
        #expect(String(decoding: parts[0].body, as: UTF8.self) == "Narrator")
        #expect(parts[1].body == audio)
        #expect(parts[1].headers["content-disposition"] == #"form-data; name="files"; filename="sample.mp3""#)
    }

    /// The server sends the first chunk and then holds the rest until the client says it has
    /// those bytes (or ten seconds pass). A transport that buffered the whole body would never
    /// say so, and the server would give up waiting — which is what this checks, rather than a
    /// timing a busy machine could miss.
    @Test func aChunkedAnswerStreamsAsItArrives() async throws {
        let chunks = (0..<4).map { Data(repeating: UInt8($0), count: 1_000) }
        let firstSeen = LoopbackServer.Gate()
        let server = try LoopbackServer { _ in
            .chunked(status: 200, headers: ["Content-Type": "audio/mpeg", "character-cost": "9"],
                     chunks: chunks, gap: .milliseconds(20), holdAfterFirst: firstSeen)
        }
        defer { server.stop() }
        let transport = URLSessionTransport.loopbackForTesting(port: Int(server.port))
        let response = try await transport.stream(Self.request(server, "/v1/text-to-speech/v/stream", method: "POST"))
        #expect(response.status == 200)
        #expect(response.headers["character-cost"] == "9")
        var received = Data()
        for try await chunk in response.body {
            received.append(chunk)
            if received.count >= chunks[0].count { firstSeen.open() }
        }
        #expect(received == chunks.reduce(Data(), +))
        #expect(!firstSeen.timedOut, "the first chunk did not reach the caller until the whole answer had")
    }

    @Test func redirectsAreAnsweredNotFollowed() async throws {
        let server = try LoopbackServer { request in
            request.target == "/v1/user"
                ? .whole(status: 302, headers: ["Location": "/elsewhere"], body: Data())
                : .whole(status: 200, headers: [:], body: Data("followed".utf8))
        }
        defer { server.stop() }
        let transport = URLSessionTransport.loopbackForTesting(port: Int(server.port))
        let response = try await transport.send(Self.request(server, "/v1/user"))
        #expect(response.status == 302)
        #expect(server.requests.map(\.target) == ["/v1/user"])

        // And through the client's error mapping, a redirect is an error that says so.
        let error = ElevenLabsClient.apiError(status: 302, headers: [:], body: Data(), key: Self.key,
                                              region: .global, retryAfter: nil)
        guard case .api(302, "redirect", let message, _) = error else { Issue.record("\(error)"); return }
        #expect(message.contains("does not follow"))
    }

    @Test func cancellingARequestClosesItsConnection() async throws {
        let server = try LoopbackServer { _ in .hang }
        defer { server.stop() }
        let transport = URLSessionTransport.loopbackForTesting(port: Int(server.port))
        let task = Task { try await transport.send(Self.request(server, "/v1/models")) }
        try await server.waitForRequests(1)
        task.cancel()
        let started = ContinuousClock.now
        await #expect(throws: ElevenLabsError.cancelled) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(3))
        try await server.waitForClosedConnections(1)
    }

    @Test func abandoningAStreamClosesItsConnection() async throws {
        let server = try LoopbackServer { _ in
            .chunked(status: 200, headers: ["Content-Type": "audio/mpeg"],
                     chunks: (0..<40).map { _ in Data(repeating: 1, count: 64) }, gap: .milliseconds(50))
        }
        defer { server.stop() }
        let transport = URLSessionTransport.loopbackForTesting(port: Int(server.port))
        let response = try await transport.stream(Self.request(server, "/v1/text-to-speech/v/stream", method: "POST"))
        for try await _ in response.body { break }
        try await server.waitForClosedConnections(1)
    }

    @Test func onlyTheElevenLabsHostsOverHTTPSAreEverContacted() async throws {
        let server = try LoopbackServer { _ in .whole(status: 200, headers: [:], body: Data()) }
        defer { server.stop() }
        let production = URLSessionTransport()
        let testing = URLSessionTransport.loopbackForTesting(port: Int(server.port))
        let refused = [
            "https://example.com/v1/user", "http://api.elevenlabs.io/v1/user",
            "https://api.elevenlabs.io:8443/v1/user", "https://api.elevenlabs.io.example.com/v1/user",
            "http://127.0.0.1:\(Int(server.port) + 1)/v1/user",
        ]
        for address in refused {
            var request = Self.request(server, "/v1/user")
            request.url = URL(string: address)!
            // Exactly `refusedHost`: any other error (a refused connection is `.network`) would
            // mean the request had been sent, and this test would pass for the wrong reason.
            let host = try #require(request.url.host)
            await #expect(throws: ElevenLabsError.refusedHost(host)) { try await testing.send(request) }
            await #expect(throws: ElevenLabsError.refusedHost(host)) { try await testing.stream(request) }
        }
        // The production transport has no loopback allowance at all.
        await #expect(throws: ElevenLabsError.refusedHost("127.0.0.1")) {
            try await production.send(Self.request(server, "/v1/user"))
        }
        #expect(server.requests.isEmpty)
    }

    @Test func answersAreBoundedAndDownloadsGoToDisk() async throws {
        let payload = Data((0..<100_000).map { UInt8($0 % 199) })
        let server = try LoopbackServer { _ in .whole(status: 200, headers: ["Content-Type": "audio/mpeg"], body: payload) }
        defer { server.stop() }
        let transport = URLSessionTransport.loopbackForTesting(port: Int(server.port))
        await #expect(throws: ElevenLabsError.self) {
            try await transport.send(Self.request(server, "/a", handling: .memory(limit: 1_000)))
        }
        let download = try await transport.send(Self.request(server, "/b", handling: .file(limit: 1 << 20)))
        guard case .file(let file) = download.body else { Issue.record("expected a file"); return }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(file.deletingLastPathComponent().resolvingSymlinksInPath().path
                == FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
        #expect(try Data(contentsOf: file) == payload)
    }

    @Test func cookiesAreNeitherKeptNorSent() async throws {
        let server = try LoopbackServer { _ in
            .whole(status: 200, headers: ["Set-Cookie": "session=abc; Path=/"], body: Data("{}".utf8))
        }
        defer { server.stop() }
        let transport = URLSessionTransport.loopbackForTesting(port: Int(server.port))
        _ = try await transport.send(Self.request(server, "/one"))
        _ = try await transport.send(Self.request(server, "/two"))
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { $0.headers["cookie"] == nil })
    }

    /// Across all five regions, through the client: the key goes to that region's host, in
    /// its header, and nowhere else.
    @Test func everyRegionSendsTheKeyOnlyToItsOwnHost() async throws {
        for region in ElevenLabsRegion.allCases {
            let transport = FakeElevenLabsTransport { _ in .json(["user_id": "u"]) }
            let sink = TemporaryFileSink()
            defer { sink.removeAll(); transport.removeTemporaryFiles() }
            let client = ElevenLabsClient(credentials: FakeCredentialSource(key: Self.key), region: region,
                                          transport: transport, sink: sink)
            _ = try await client.call("get_user_info")
            _ = try await client.call("text_to_speech_full", arguments: ["voice_id": "v", "text": "hi"])
            #expect(transport.hostViolations.isEmpty)
            for recorded in transport.recorded {
                #expect(recorded.request.url.scheme == "https")
                #expect(recorded.request.url.host == region.host)
                #expect(recorded.request.url.port == nil)
                #expect(recorded.request.header("xi-api-key") == Self.key)
                #expect(!recorded.request.url.absoluteString.contains(Self.key))
                #expect(!String(decoding: recorded.body, as: UTF8.self).contains(Self.key))
            }
        }
    }

    // MARK: - Helpers

    static func request(
        _ server: LoopbackServer, _ target: String, method: String = "GET",
        headers: [String: String] = [:], body: ElevenLabsRequest.Body = .none,
        handling: ElevenLabsRequest.ResponseHandling = .memory(limit: 1 << 20)
    ) -> ElevenLabsRequest {
        ElevenLabsRequest(
            operationID: "wire-test", method: method,
            url: URL(string: "http://127.0.0.1:\(server.port)\(target)")!,
            headers: headers.merging(["xi-api-key": key]) { $1 }, body: body, timeout: 10,
            responseHandling: handling
        )
    }

    struct Scratch {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-wire-\(UUID().uuidString)", isDirectory: true)
        init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func remove() { TemporaryFileSink.removeScratch(directory) }
    }
}

/// A loopback HTTP/1.1 server on an ephemeral port: records each request whole and answers
/// from a script — a whole body, a chunked one with gaps, or nothing at all.
final class LoopbackServer: @unchecked Sendable {
    struct Request {
        var method: String
        var target: String
        var headers: [String: String]
        var body: Data
    }

    enum Reply {
        case whole(status: Int, headers: [String: String], body: Data)
        /// `holdAfterFirst`: after the first chunk, wait for the gate to open (or ten seconds).
        case chunked(status: Int, headers: [String: String], chunks: [Data], gap: Duration,
                     holdAfterFirst: Gate? = nil)
        case hang
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "elevenlabs-loopback")
    private let lock = NSLock()
    private let handler: @Sendable (Request) -> Reply
    private var recorded: [Request] = []
    private var closed = 0
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    var requests: [Request] { lock.withLock { recorded } }
    var closedConnections: Int { lock.withLock { closed } }
    /// A one-way signal from the test to the server.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var gaveUp = false
        func open() { lock.withLock { isOpen = true } }
        var opened: Bool { lock.withLock { isOpen } }
        var timedOut: Bool { lock.withLock { gaveUp } }
        func giveUp() { lock.withLock { gaveUp = true } }
    }

    init(handler: @escaping @Sendable (Request) -> Reply) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        ready.wait()
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() } }
    }

    func waitForRequests(_ count: Int) async throws {
        try await waitUntil { self.requests.count >= count }
    }

    func waitForClosedConnections(_ count: Int) async throws {
        try await waitUntil { self.closedConnections >= count }
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting on the loopback server")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func serve(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.lock.withLock { self?.closed += 1 }
            default: break
            }
        }
        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data())
    }

    /// Reads until a whole request (head and Content-Length body) is in `buffer`, answers it,
    /// then keeps reading so a client that goes away is noticed.
    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || (complete && data == nil) {
                connection.cancel()
                return
            }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                self.readRequest(on: connection, buffer: buffer)
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard buffer.count - end.upperBound >= length else {
                self.readRequest(on: connection, buffer: buffer)
                return
            }
            let requestLine = lines.first?.split(separator: " ") ?? []
            let request = Request(
                method: requestLine.first.map(String.init) ?? "",
                target: requestLine.dropFirst().first.map(String.init) ?? "/",
                headers: headers,
                body: Data(buffer[end.upperBound..<(end.upperBound + length)])
            )
            self.lock.withLock { self.recorded.append(request) }
            self.reply(self.handler(request), on: connection)
            self.drain(connection)
        }
    }

    private func drain(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            if error != nil || complete || data == nil {
                connection.cancel()
                return
            }
            self?.drain(connection)
        }
    }

    private func reply(_ reply: Reply, on connection: NWConnection) {
        switch reply {
        case .hang:
            return
        case .whole(let status, let headers, let body):
            var head = "HTTP/1.1 \(status) Scripted\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
            for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
            var bytes = Data((head + "\r\n").utf8)
            bytes.append(body)
            connection.send(content: bytes, completion: .contentProcessed { _ in })
        case .chunked(let status, let headers, let chunks, let gap, let hold):
            var head = "HTTP/1.1 \(status) Scripted\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n"
            for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
            connection.send(content: Data((head + "\r\n").utf8), completion: .contentProcessed { _ in })
            let milliseconds = Int(gap.components.seconds * 1_000 + gap.components.attoseconds / 1_000_000_000_000_000)
            queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [weak self] in
                self?.sendChunk(0, of: chunks, gap: milliseconds, hold: hold, on: connection)
            }
        }
    }

    private func sendChunk(
        _ index: Int, of chunks: [Data], gap milliseconds: Int, hold: Gate?, on connection: NWConnection,
        waited: Int = 0
    ) {
        if index == 1, let hold, !hold.opened {
            guard waited < 10_000 else {
                hold.giveUp()
                return sendChunk(index, of: chunks, gap: milliseconds, hold: nil, on: connection)
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                self?.sendChunk(index, of: chunks, gap: milliseconds, hold: hold, on: connection, waited: waited + 10)
            }
            return
        }
        guard index < chunks.count else {
            connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            return
        }
        var frame = Data((String(chunks[index].count, radix: 16) + "\r\n").utf8)
        frame.append(chunks[index])
        frame.append(Data("\r\n".utf8))
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [weak self] in
                self?.sendChunk(index + 1, of: chunks, gap: milliseconds, hold: hold, on: connection)
            }
        })
    }
}

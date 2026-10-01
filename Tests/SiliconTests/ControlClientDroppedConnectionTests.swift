import Foundation
import Network
import Testing
@testable import SiliconControl

/// A connection that closes without an answer looks the same from the client whether the app
/// is busy or has just quit or crashed. Only the first may be told to try again: a paid call
/// the app was working on when it stopped may already have been done, and billed.
///
/// The app here is a loopback listener of the test's own that reads the request, changes the
/// handshake the way the app's state would, and closes the connection unanswered. The
/// handshake is in a temporary folder; nothing reaches the running app.
@Suite("Control client when a call's connection drops")
struct ControlClientDroppedConnectionTests {

    @Test func theSameAppStillUpIsBusyAndSaysAPaidCallMayHaveRun() async throws {
        let message = try await messageWhenTheConnectionDrops { _ in }
        #expect(message.contains("most likely busy"), "\(message)")
        #expect(message.contains("may still have run"), "\(message)")
    }

    @Test func anAppThatCrashedIsNotBusyAndWarnsBeforeAskingAgain() async throws {
        // A crash leaves the handshake behind, naming a process that is gone.
        let dead = try #require((90_000...99_000).reversed().first { kill(Int32($0), 0) != 0 && errno == ESRCH })
        let message = try await messageWhenTheConnectionDrops { handshake in
            var crashed = try read(handshake)
            crashed.pid = Int32(dead)
            try write(crashed, to: handshake)
        }
        expectStopped(message)
    }

    @Test func anAppThatQuitIsNotBusyAndWarnsBeforeAskingAgain() async throws {
        // Quitting removes the handshake.
        let message = try await messageWhenTheConnectionDrops { handshake in
            try FileManager.default.removeItem(at: handshake)
        }
        expectStopped(message)
    }

    @Test func anAppThatWasRelaunchedIsNotTheOneThatDroppedTheCall() async throws {
        // A new launch: this process is alive, but the token is new and so is the port.
        let message = try await messageWhenTheConnectionDrops { handshake in
            var relaunched = try read(handshake)
            relaunched.token = "second-launch-\(UUID().uuidString)"
            relaunched.port += 1
            try write(relaunched, to: handshake)
        }
        expectStopped(message)
    }

    // MARK: Helpers

    private func expectStopped(_ message: String) {
        #expect(message.contains("stopped (it quit or crashed) before answering"), "\(message)")
        #expect(message.contains("check before asking again"), "\(message)")
        #expect(!message.contains("busy"), "\(message)")
    }

    /// Posts what a paid ElevenLabs call posts, to a listener that reads it, calls
    /// `meanwhile` with the handshake, and closes the connection unanswered.
    private func messageWhenTheConnectionDrops(
        meanwhile: @escaping @Sendable (URL) throws -> Void
    ) async throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("control-drop-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let handshake = directory.appendingPathComponent("control.json")

        let app = try await DroppingListener.start { try? meanwhile(handshake) }
        defer { app.stop() }
        try write(
            ControlAPI.Handshake(
                port: app.port, pid: getpid(), token: "first-launch-\(UUID().uuidString)",
                app: .init(version: "0.0.0", build: "0")
            ),
            to: handshake
        )

        let client = ControlClient(handshakeURL: handshake)
        do {
            let _: [String: String] = try await client.post(
                "/elevenlabs/call", ["operation": "text_to_speech_full"]
            )
            Issue.record("The listener answered; it never should.")
            return ""
        } catch {
            #expect(app.requestsRead == 1)
            return error.localizedDescription
        }
    }

    private func read(_ url: URL) throws -> ControlAPI.Handshake {
        try JSONDecoder().decode(ControlAPI.Handshake.self, from: Data(contentsOf: url))
    }

    private func write(_ handshake: ControlAPI.Handshake, to url: URL) throws {
        try JSONEncoder().encode(handshake).write(to: url, options: .atomic)
    }
}

/// Accepts on an ephemeral loopback port, reads one whole request (headers and body), runs
/// `beforeClosing`, and closes the connection without a byte of answer.
private final class DroppingListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dropping-listener")
    private let lock = NSLock()
    private var read = 0
    private var started = false
    private(set) var port = 0

    var requestsRead: Int { lock.withLock { read } }

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start(beforeClosing: @escaping @Sendable () -> Void) async throws -> DroppingListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = DroppingListener(listener: try NWListener(using: parameters))
        server.listener.newConnectionHandler = { [server] connection in
            connection.start(queue: server.queue)
            server.readRequest(on: connection, buffered: Data()) {
                server.lock.withLock { server.read += 1 }
                beforeClosing()
                connection.cancel()
            }
        }
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            server.listener.stateUpdateHandler = { [server] state in
                let result: Result<Int, any Error>
                switch state {
                case .ready: result = .success(Int(server.listener.port?.rawValue ?? 0))
                case .failed(let error): result = .failure(error)
                default: return
                }
                // Ready once; a failure can only follow it after `stop`, when nobody waits.
                guard server.lock.withLock({ () -> Bool in
                    defer { server.started = true }
                    return !server.started
                }) else { return }
                continuation.resume(with: result)
            }
            server.listener.start(queue: server.queue)
        }
        server.port = port
        return server
    }

    func stop() { listener.cancel() }

    private func readRequest(on connection: NWConnection, buffered: Data, then done: @escaping @Sendable () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            var buffered = buffered
            if let data { buffered.append(data) }
            if let end = buffered.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: buffered[..<end.lowerBound], as: UTF8.self)
                let length = headers.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if buffered.count - end.upperBound >= length {
                    done()
                    return
                }
            }
            guard !complete, error == nil else { return }
            readRequest(on: connection, buffered: buffered, then: done)
        }
    }
}

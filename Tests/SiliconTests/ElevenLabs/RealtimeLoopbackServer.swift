import CryptoKit
import Foundation
import Network
import Testing
@testable import SiliconElevenLabs

/// A loopback WebSocket server on an ephemeral port, written out by hand (RFC 6455) so a test
/// sees exactly what `URLSessionWebSocketTask` puts on the wire — the upgrade's request line and
/// headers, every frame, the close code — and can answer however it likes: refuse the upgrade
/// with any status, redirect, send a message bigger than a megabyte, close with 4300.
///
/// It listens on the loopback interface only and is reached through the connector's debug-only
/// loopback allowance. Nothing here leaves 127.0.0.1.
final class RealtimeLoopbackServer: @unchecked Sendable {
    struct Upgrade: Sendable {
        var target: String
        var headers: [String: String]
    }

    enum Answer: Sendable {
        /// 101, then `script` plays the server's side of the conversation.
        case accept(@Sendable (RealtimeLoopbackConnection) async -> Void)
        /// Any other status (a refusal, a redirect), with headers, and the connection closed.
        case refuse(status: Int, headers: [String: String])
        /// Never answers the upgrade.
        case hang
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "elevenlabs-realtime-loopback")
    private let lock = NSLock()
    private let handler: @Sendable (Upgrade) -> Answer
    private var upgrades: [Upgrade] = []
    private var connections: [RealtimeLoopbackConnection] = []
    private(set) var port: UInt16 = 0

    var receivedUpgrades: [Upgrade] { lock.withLock { upgrades } }
    var openedConnections: [RealtimeLoopbackConnection] { lock.withLock { connections } }

    init(handler: @escaping @Sendable (Upgrade) -> Answer) throws {
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

    func url(_ target: String) -> URL {
        URL(string: "ws://127.0.0.1:\(port)\(target)")!
    }

    func waitForConnections(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if openedConnections.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readUpgrade(connection, buffer: Data())
    }

    private func readUpgrade(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || (complete && data == nil) { connection.cancel(); return }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                self.readUpgrade(connection, buffer: buffer)
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let upgrade = Upgrade(target: target, headers: headers)
            self.lock.withLock { self.upgrades.append(upgrade) }
            let leftover = Data(buffer[end.upperBound...])
            switch self.handler(upgrade) {
            case .hang:
                return
            case .refuse(let status, let extra):
                var response = "HTTP/1.1 \(status) Scripted\r\nContent-Length: 0\r\nConnection: close\r\n"
                for (name, value) in extra.sorted(by: { $0.key < $1.key }) { response += "\(name): \(value)\r\n" }
                connection.send(content: Data((response + "\r\n").utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            case .accept(let script):
                let key = headers["sec-websocket-key"] ?? ""
                let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
                    .base64EncodedString()
                let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
                let socket = RealtimeLoopbackConnection(connection: connection, queue: self.queue, buffer: leftover)
                self.lock.withLock { self.connections.append(socket) }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    socket.startReading()
                    Task { await script(socket) }
                })
            }
        }
    }
}

/// One accepted WebSocket connection, from the server's side.
final class RealtimeLoopbackConnection: @unchecked Sendable {
    enum Frame: Sendable, Equatable {
        case text(String)
        case binary(Data)
        case close(code: Int?, reason: String)
        case ping(Data)
        case pong(Data)
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var buffer: Data
    private var frames: [Frame] = []
    private var fragments = Data()
    private var fragmentOpcode: UInt8 = 0
    private var ended = false
    private var _endedBy = ""
    /// How the TCP connection ended, for diagnosis: "fin", or the error.
    var endedBy: String { lock.withLock { _endedBy } }

    init(connection: NWConnection, queue: DispatchQueue, buffer: Data) {
        self.connection = connection
        self.queue = queue
        self.buffer = buffer
    }

    /// Every frame the client sent, in order (pings answered, close answered, both recorded).
    var received: [Frame] { lock.withLock { frames } }
    var texts: [String] { received.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    var closeFrame: (code: Int?, reason: String)? {
        for frame in received { if case .close(let code, let reason) = frame { return (code, reason) } }
        return nil
    }
    var isEnded: Bool { lock.withLock { ended } }

    func startReading() {
        queue.async { self.parse() }
        read()
    }

    func cancel() { connection.cancel() }

    /// Waits for the client's `count`th text frame.
    func text(_ index: Int, timeout: Duration = .seconds(10)) async -> String? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let texts = texts
            if texts.count > index { return texts[index] }
            if isEnded { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func waitForClose(timeout: Duration = .seconds(10)) async -> (code: Int?, reason: String)? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let close = closeFrame { return close }
            if isEnded { return closeFrame }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func sendText(_ text: String) { send(opcode: 0x1, payload: Data(text.utf8)) }
    func sendJSON(_ json: JSONValue) { sendText(json.jsonString()) }
    func sendBinary(_ data: Data) { send(opcode: 0x2, payload: data) }

    /// A close frame with `code` and `reason`; the TCP connection is left for the client to end.
    func close(code: Int, reason: String) {
        var payload = Data([UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)])
        payload.append(Data(reason.utf8))
        send(opcode: 0x8, payload: payload)
    }

    /// The TCP connection cut with no close frame.
    func drop() { connection.cancel() }

    private func send(opcode: UInt8, payload: Data) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8 & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8(UInt64(payload.count) >> UInt64(shift) & 0xFF)) }
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data {
                self.lock.withLock { self.buffer.append(data) }
                self.parse()
            }
            if error != nil || (complete && data == nil) {
                self.lock.withLock {
                    self.ended = true
                    self._endedBy = error.map { "\($0)" } ?? "fin"
                }
                return
            }
            self.read()
        }
    }

    /// Takes every whole frame off the buffer.
    private func parse() {
        while true {
            let next: (opcode: UInt8, fin: Bool, payload: Data)? = lock.withLock {
                let bytes = [UInt8](buffer)
                guard bytes.count >= 2 else { return nil }
                let fin = bytes[0] & 0x80 != 0
                let opcode = bytes[0] & 0x0F
                let masked = bytes[1] & 0x80 != 0
                var length = Int(bytes[1] & 0x7F)
                var offset = 2
                if length == 126 {
                    guard bytes.count >= 4 else { return nil }
                    length = Int(bytes[2]) << 8 | Int(bytes[3])
                    offset = 4
                } else if length == 127 {
                    guard bytes.count >= 10 else { return nil }
                    length = (2..<10).reduce(0) { $0 << 8 | Int(bytes[$1]) }
                    offset = 10
                }
                let maskLength = masked ? 4 : 0
                guard bytes.count >= offset + maskLength + length else { return nil }
                let mask = masked ? Array(bytes[offset..<offset + 4]) : [0, 0, 0, 0]
                offset += maskLength
                var payload = [UInt8](bytes[offset..<offset + length])
                for index in payload.indices { payload[index] ^= mask[index % 4] }
                buffer = Data(bytes[(offset + length)...])
                return (opcode, fin, Data(payload))
            }
            guard let next else { return }
            handle(opcode: next.opcode, fin: next.fin, payload: next.payload)
        }
    }

    private func handle(opcode: UInt8, fin: Bool, payload: Data) {
        switch opcode {
        case 0x0, 0x1, 0x2:
            var whole: (UInt8, Data)?
            lock.withLock {
                if opcode != 0 { fragmentOpcode = opcode; fragments = Data() }
                fragments.append(payload)
                if fin { whole = (fragmentOpcode, fragments); fragments = Data() }
            }
            if let (kind, data) = whole {
                let frame: Frame = kind == 0x1 ? .text(String(decoding: data, as: UTF8.self)) : .binary(data)
                lock.withLock { frames.append(frame) }
            }
        case 0x8:
            let code = payload.count >= 2 ? Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1]) : nil
            let reason = payload.count > 2 ? String(decoding: payload.dropFirst(2), as: UTF8.self) : ""
            lock.withLock { frames.append(.close(code: code, reason: reason)) }
            send(opcode: 0x8, payload: payload.prefix(2))
        case 0x9:
            lock.withLock { frames.append(.ping(payload)) }
            send(opcode: 0xA, payload: payload)
        case 0xA:
            lock.withLock { frames.append(.pong(payload)) }
        default:
            break
        }
    }
}

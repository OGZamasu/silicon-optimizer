import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI
import class SiliconRuntime.VideoBatchQueue

// Shared by the voices-and-studio section tests. Nothing here reaches the network, the
// Keychain or the owner's files: the client runs over the in-memory transport with a fake
// key, answers are scripted per operation, written files land in scratch directories this
// file creates and removes.

/// Scripted answers by operation id, handed out in order.
final class VoicesStudioRoutes: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: [FakeElevenLabsTransport.Reply]]

    init(_ replies: [String: [FakeElevenLabsTransport.Reply]]) {
        self.replies = replies
    }

    func add(_ operationID: String, _ reply: FakeElevenLabsTransport.Reply) {
        lock.withLock { replies[operationID, default: []].append(reply) }
    }

    func next(_ operationID: String) -> FakeElevenLabsTransport.Reply {
        lock.withLock {
            guard var queue = replies[operationID], !queue.isEmpty else {
                return .jsonText(#"{"detail":"no scripted reply for \#(operationID)"}"#, status: 418)
            }
            let reply = queue.removeFirst()
            replies[operationID] = queue
            return reply
        }
    }
}

/// A client over the public fakes, and the section environment built on it.
@MainActor
struct VoicesStudioFixture {
    static let key = "fixture-" + String(repeating: "k", count: 12)

    let routes: VoicesStudioRoutes
    let transport: FakeElevenLabsTransport
    let credentials = FakeCredentialSource(key: VoicesStudioFixture.key)
    let sink = TemporaryFileSink()
    let client: ElevenLabsClient
    let voices: ElevenLabsVoiceDirectory

    init(_ replies: [String: [FakeElevenLabsTransport.Reply]] = [:]) {
        let routes = VoicesStudioRoutes(replies)
        self.routes = routes
        transport = FakeElevenLabsTransport { request in routes.next(request.operationID) }
        var limits = ElevenLabsClient.Limits()
        limits.retries = 0
        limits.firstBackoff = 0.01
        client = ElevenLabsClient(credentials: credentials, region: .global, transport: transport, sink: sink, limits: limits)
        let client = client
        voices = ElevenLabsVoiceDirectory(client: { client })
    }

    var context: ElevenLabsRunner.Context {
        let client = client
        let sink = sink
        return .init(client: { client }, sink: { sink })
    }

    var environment: VoicesStudioEnvironment {
        VoicesStudioEnvironment(context: context, voices: voices)
    }

    /// The requests sent for one operation, in order.
    func sent(_ operationID: String) -> [FakeElevenLabsTransport.Recorded] {
        transport.recorded.filter { $0.request.operationID == operationID }
    }

    /// The JSON body of the last request for an operation.
    func body(_ operationID: String) -> JSONValue? {
        sent(operationID).last.flatMap { try? JSONValue(data: $0.body) }
    }

    /// The query items of the last request for an operation, repeated names kept in order.
    func query(_ operationID: String) -> [(String, String)] {
        guard let url = sent(operationID).last?.request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [] }
        return items.map { ($0.name, $0.value ?? "") }
    }

    func path(_ operationID: String) -> String? {
        sent(operationID).last?.request.url.path
    }

    /// The multipart body of the last request for an operation, as text.
    func multipart(_ operationID: String) -> String {
        sent(operationID).last.map { String(decoding: $0.body, as: UTF8.self) } ?? ""
    }

    func clean() {
        transport.removeTemporaryFiles()
        sink.removeAll()
    }
}

/// A scratch directory under the system temporary directory, removed only if it is still one.
struct VoicesStudioScratch {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-voices-studio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A small file with the given name.
    func file(_ name: String, bytes: Int = 64) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    func remove() {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let target = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard target.deletingLastPathComponent().path == temporary.path,
              target.lastPathComponent.hasPrefix("elevenlabs-voices-studio-") else { return }
        try? FileManager.default.removeItem(at: target)
    }
}

/// Waits for a condition the main actor will make true, failing the test after a while.
@MainActor
func voicesStudioWait(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting")
}

/// Runs an action that asks for confirmation, answers it, and returns what was asked.
@MainActor
func voicesStudioConfirm(
    _ runner: @autoclosure () -> ElevenLabsRunner?, answer: Bool, during action: @escaping @MainActor () async -> Void
) async throws -> ElevenLabsConfirmationRequest? {
    let task = Task { await action() }
    try await voicesStudioWait { runner()?.phase == .awaitingConfirmation }
    let asked = runner()?.confirmation
    if answer { runner()?.confirm() } else { runner()?.decline() }
    await task.value
    return asked
}

// MARK: - Snapshots

/// Draws screens to PNG for a look: light and dark, narrow and wide. Written to
/// `$VOICES_STUDIO_SNAPSHOTS` when set (the builder points it at a folder on the external
/// disk), otherwise to a scratch directory that is removed again.
@MainActor
enum VoicesStudioSnapshots {
    static let sizes: [(name: String, width: CGFloat)] = [("narrow", 620), ("wide", 980)]

    static func directory() throws -> (url: URL, keep: Bool) {
        if let path = ProcessInfo.processInfo.environment["VOICES_STUDIO_SNAPSHOTS"], !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return (url, true)
        }
        let scratch = try VoicesStudioScratch()
        return (scratch.directory, false)
    }

    /// Renders `view` at every size in both appearances; returns the PNGs written.
    @discardableResult
    static func render<Content: View>(_ name: String, height: CGFloat, @ViewBuilder _ view: () -> Content) throws -> [URL] {
        let (directory, keep) = try directory()
        defer { if !keep { VoicesStudioScratch(unchecked: directory).remove() } }
        var written: [URL] = []
        let content = view()
        for size in sizes {
            for dark in [false, true] {
                let url = directory.appendingPathComponent("\(name)-\(size.name)-\(dark ? "dark" : "light").png")
                try png(content, width: size.width, height: height, dark: dark).write(to: url)
                written.append(url)
            }
        }
        return keep ? written : []
    }

    /// An app model for the environment — the shell's voice picker reads one even when it is
    /// handed a directory — built with injected settings (an inert ElevenLabs link) and a video
    /// queue in a scratch directory, so nothing of the owner's is read.
    static let app: AppModel = {
        let queue = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-voices-studio-app-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("video-queue.json")
        return AppModel(videoQueue: VideoBatchQueue(storeURL: queue), settings: .init())
    }()

    static func png<Content: View>(_ content: Content, width: CGFloat, height: CGFloat, dark: Bool) throws -> Data {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = content
            .environment(app)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: width, height: height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.appearance = appearance
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}

extension VoicesStudioScratch {
    init(unchecked directory: URL) {
        self.directory = directory
    }
}

// MARK: - Fake answers

enum VoicesStudioFakes {
    static func voice(
        _ id: String, _ name: String, category: String = "cloned", labels: [String: String] = [:],
        samples: [JSONValue] = [], fineTuning: JSONValue? = nil, settings: JSONValue? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "voice_id": .string(id), "name": .string(name), "category": .string(category),
            "labels": .object(labels.mapValues(JSONValue.string)), "samples": .array(samples),
            "available_for_tiers": [], "high_quality_base_model_ids": ["eleven_multilingual_v2"],
            "preview_url": .string("https://storage.example/\(id).mp3"),
            "description": .string("\(name), for tests."), "created_at_unix": 1_780_000_000,
        ]
        if let fineTuning { object["fine_tuning"] = fineTuning }
        if let settings { object["settings"] = settings }
        return .object(object)
    }

    static func sample(_ id: String, _ file: String, seconds: Double = 42) -> JSONValue {
        ["sample_id": .string(id), "file_name": .string(file), "mime_type": "audio/mpeg",
         "size_bytes": 812_345, "hash": "h", "duration_secs": .number(seconds)]
    }

    static let settings: JSONValue = [
        "stability": 0.4, "similarity_boost": 0.8, "style": 0.1, "speed": 1.05, "use_speaker_boost": true,
    ]

    /// A tiny MP3-shaped payload (not playable; the tests only move it around).
    static let audio = Data([0x49, 0x44, 0x33, 0x04, 0, 0, 0, 0, 0, 0x21] + Array(repeating: UInt8(0x55), count: 54))
}

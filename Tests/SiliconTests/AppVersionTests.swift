import Foundation
import Testing
@testable import SiliconControl

/// What the Mac says it is. A phone shows `/health`'s answer as "Silicon Optimizer <version>",
/// and for months that answer was a literal "0.1.0" whatever was installed (#81).
///
/// The version here is always a fixture handed to the server. Asserting the real release
/// number would fail on every release; asserting the fixture proves the server publishes
/// what it is given rather than something of its own.
@Suite("The app version the Mac advertises")
struct AppVersionTests {

    static let fixture = ControlAPI.AppVersion(version: "9.8.7", build: "654")

    @Test func healthCarriesTheVersionAndBuildItWasGiven() async throws {
        try await withServer { handshake, session in
            let (data, response) = try await session.data(
                from: URL(string: "http://127.0.0.1:\(handshake.port)/health")!
            )
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let health = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: String]
            )
            #expect(health["status"] == "ok")
            #expect(health["appVersion"] == "9.8.7")
            #expect(health["appBuild"] == "654")
            // The key every client written so far reads, now saying the same thing.
            #expect(health["version"] == "9.8.7")

            // And the shape a phone's contract fixture promises, no more and no less.
            let route = try #require(ContractExportTests.routes.first {
                $0.method == "GET" && $0.path == "/health"
            })
            let example = try #require(route.response)
            let promised = try #require(
                try JSONSerialization.jsonObject(with: try example.encode()) as? [String: Any]
            )
            #expect(Set(health.keys) == Set(promised.keys))
        }
    }

    @Test func theHandshakeCarriesTheSameVersionAndBuild() async throws {
        try await withServer { handshake, _ in
            #expect(handshake.version == "9.8.7")
            #expect(handshake.appVersion == "9.8.7")
            #expect(handshake.appBuild == "654")
        }
    }

    /// A handshake file written by an app from before these fields decodes; a client only
    /// has to fall back to `version`.
    @Test func anOlderHandshakeStillDecodes() throws {
        let older = #"{"port":8765,"pid":4242,"token":"t","version":"0.1.0"}"#
        let handshake = try JSONDecoder().decode(ControlAPI.Handshake.self, from: Data(older.utf8))
        #expect(handshake.version == "0.1.0")
        #expect(handshake.appVersion == nil && handshake.appBuild == nil)
    }

    @Test func theVersionIsReadFromTheBundlesInfoDictionary() {
        let read = ControlAPI.AppVersion(infoDictionary: [
            "CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "654",
        ])
        #expect(read == Self.fixture)
        // A binary with no Info.plist says so instead of inventing a number.
        #expect(ControlAPI.AppVersion(infoDictionary: nil)
            == ControlAPI.AppVersion(version: "dev", build: "dev"))
    }

    // MARK: - Fixture

    private func withServer(
        _ body: (ControlAPI.Handshake, URLSession) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-version-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let handshakeURL = directory.appendingPathComponent("control.json")
        let server = ControlServer(
            host: BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false),
            handshakeURL: handshakeURL,
            buddy: BuddyRegistry(url: directory.appendingPathComponent("buddy.json")),
            events: BuddyEventHub(),
            // Never the real CLI: a test must not bind whatever tailnet this machine is on.
            discoverTailnetAddress: { nil },
            appVersion: Self.fixture
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        try await server.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: handshakeURL.path) {
            guard ContinuousClock.now < deadline else {
                await server.stop()
                Issue.record("the handshake was never written")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let handshake = try JSONDecoder().decode(
            ControlAPI.Handshake.self, from: try Data(contentsOf: handshakeURL)
        )
        do {
            try await body(handshake, session)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }
}

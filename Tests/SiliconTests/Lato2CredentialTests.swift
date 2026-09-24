import Foundation
import Testing
import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

/// The LATO.2 service is a node route now, and a node refuses every off-box `/v1/` request
/// without a bearer. The lane sent none, while its probe asked the one open route and said
/// "answering" — so every 3D job to it failed, from the 3D tab and from MCP alike.
@Suite("LATO.2 lane credentials")
struct Lato2CredentialTests {

    static let token = "fixture-member-token"

    /// A node in miniature: `/health` open, every `/v1/` route behind the bearer, with the
    /// node's own refusal text.
    static func node() throws -> CapturingServer {
        try CapturingServer { request, _ in
            if request.path == "/health" { return .init(body: #"{"status":"ok"}"#) }
            guard request.headers["authorization"] == "Bearer \(token)" else {
                return .init(
                    status: 401, headers: ["Content-Type": "text/plain"],
                    body: "This Silicon node requires a bearer token. Send "
                        + "'Authorization: Bearer <token>'."
                )
            }
            switch request.path {
            case "/v1/image-to-mesh":
                return .init(body: #"{"job_id":"job-1"}"#)
            case "/v1/jobs/job-1":
                return .init(body: #"{"status":"done","progress":1.0,"result_urls":["/v1/files/job-1.glb"]}"#)
            case "/v1/files/job-1.glb":
                return .init(headers: ["Content-Type": "model/gltf-binary"], body: "glTF fixture")
            case "/v1/capabilities":
                return .init(body: "[]")
            default:
                return .init(status: 404, body: #"{"detail":"no such route"}"#)
            }
        }
    }

    static func request() throws -> MeshRequest {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lato2-credential-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("kettle.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: image)
        return MeshRequest(
            image: image, outputDirectory: directory.appendingPathComponent("out"),
            baseName: "kettle"
        )
    }

    @Test func aJobCarriesTheNodesCredentialOnEveryRequest() async throws {
        let server = try Self.node()
        defer { server.stop() }
        let request = try Self.request()
        defer { try? FileManager.default.removeItem(at: request.image.deletingLastPathComponent()) }

        let runtime = Lato2Runtime(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, token: Self.token
        )
        var result: MeshResult?
        for try await event in try await runtime.generate(request) {
            if case .finished(let finished) = event { result = finished }
        }

        let glb = try #require(result?.glb)
        #expect(try String(contentsOf: glb, encoding: .utf8) == "glTF fixture")
        let routes = server.requests.map(\.path)
        #expect(routes == ["/v1/image-to-mesh", "/v1/jobs/job-1", "/v1/files/job-1.glb"])
        for recorded in server.requests {
            #expect(recorded.headers["authorization"] == "Bearer \(Self.token)", "\(recorded.path)")
        }
    }

    /// No credential is still a refusal — but one that says where a credential comes from.
    @Test func withoutACredentialTheRefusalSaysWhereOneComesFrom() async throws {
        let server = try Self.node()
        defer { server.stop() }
        let request = try Self.request()
        defer { try? FileManager.default.removeItem(at: request.image.deletingLastPathComponent()) }

        let runtime = Lato2Runtime(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        do {
            for try await _ in try await runtime.generate(request) {}
            Issue.record("a node that wants a bearer took a job without one")
        } catch let MeshRuntimeError.generationFailed(message) {
            #expect(message.contains("requires a bearer token"))
            #expect(message.contains("No credential was sent"))
        }
    }

    /// The probe asks the question the lane depends on, not just whether the machine is up.
    @Test func theProbeTellsRefusedFromAnswering() async throws {
        let server = try Self.node()
        let base = URL(string: "http://127.0.0.1:\(server.port)")!

        #expect(await Lato2Runtime.probe(baseURL: base, token: Self.token) == .answering)
        guard case .refused(let reason) = await Lato2Runtime.probe(baseURL: base, token: nil)
        else {
            Issue.record("a node refusing every job was reported as answering")
            return
        }
        #expect(reason.contains("requires a bearer token"))
        guard case .refused = await Lato2Runtime.probe(baseURL: base, token: "wrong") else {
            Issue.record("a wrong token was reported as answering")
            return
        }

        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await Lato2Runtime.probe(baseURL: base, token: Self.token) == .unreachable)
    }

    /// The same credential the other node lanes send — the peer's own token, else the
    /// shared one — and only to an address that is one of the swarm's peers.
    @Test func theCredentialIsThePeersAndGoesOnlyToThePeer() throws {
        let config = SwarmConfig(swarmToken: "fixture-shared-token", peers: [
            SwarmPeer(name: "rig", baseURL: "http://100.64.0.9:8790", token: "fixture-rig-token"),
            SwarmPeer(name: "spare", baseURL: " http://spare.example.ts.net:8790/ "),
        ])
        func credential(_ url: String) -> String? {
            AppModel.lato2Credential(for: URL(string: url)!, in: config)
        }

        #expect(credential("http://100.64.0.9:8790") == "fixture-rig-token")
        #expect(credential("http://100.64.0.9:8790/") == "fixture-rig-token")
        #expect(credential("http://SPARE.example.ts.net:8790") == "fixture-shared-token")

        // Anything that is not exactly a peer's origin gets nothing.
        #expect(credential("http://100.64.0.10:8790") == nil)
        #expect(credential("http://100.64.0.9:8791") == nil)
        #expect(credential("https://100.64.0.9:8790") == nil)
        #expect(AppModel.lato2Credential(
            for: URL(string: "http://100.64.0.9:8790")!, in: nil
        ) == nil)
    }
}

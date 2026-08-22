import Foundation
import SiliconCatalog
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

extension Trait where Self == ConditionTrait {
    /// Live-node proofs are opt-in: `SILICON_LIVE_TESTS=1 swift test`. A default run
    /// must not have its duration or its verdict depend on another machine's queue
    /// (hub issue #10 — one of these once rode the node's backlog for five minutes).
    static var liveNodeOptIn: ConditionTrait {
        .enabled(
            if: ProcessInfo.processInfo.environment["SILICON_LIVE_TESTS"] == "1",
            "Set SILICON_LIVE_TESTS=1 to run the proofs against the configured node"
        )
    }
}

/// Integration proof that this Mac can see what a real node advertises.
///
/// Unit tests pinned the parser against payloads copied by hand; this asks the node
/// itself, because "the contract is implemented" and "our client sees it" are separate
/// claims and only one of them decides whether a button is enabled. Skips quietly when
/// no node is configured or reachable.
@Suite("Swarm, against the live node", .liveNodeOptIn)
struct SwarmLiveTests {

    private func liveNode() async -> AppModel.PeerStatus? {
        guard let config = SwarmConfig.load(), let peer = config.peers.first,
              let base = URL(string: peer.baseURL.trimmingCharacters(in: .whitespaces))
        else { return nil }

        var request = URLRequest(url: base.appendingPathComponent("v1/node"))
        request.timeoutInterval = 8
        if let token = config.effectiveToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var status = AppModel.PeerStatus(
            name: peer.name, baseURL: peer.baseURL, reachable: true
        )
        AppModel.parseNode(json, into: &status)
        return status
    }

    @Test func seesWhateverTheNodeAdvertises() async {
        guard let peer = await liveNode() else { return }   // no node here; nothing to prove
        #expect(!peer.capabilities.isEmpty)

        // Every filter in the app keys on `kind`, so an empty kind is a silent
        // capability the UI can never find.
        #expect(peer.capabilities.allSatisfy { !$0.kind.isEmpty })

        let kinds = Set(peer.capabilities.filter(\.ready).map(\.kind))
        print("live node ready kinds: \(kinds.sorted())")

        // The two the UI gates buttons on.
        if kinds.contains("video") {
            #expect(peer.capabilities.contains {
                $0.kind == "video" && $0.ready
            }, "a ready video capability must survive parsing")
        }
        if kinds.contains("portrait-animate") || kinds.contains("talking-head") {
            #expect(peer.capabilities.contains {
                ["portrait-animate", "talking-head"].contains($0.kind) && $0.ready
            })
        }
    }
}

/// A node that refuses a job explains why in the body. The app used to report only
/// the status code, which turned a fix-it instruction into a dead end.
@Suite("Node refusals are readable")
struct NodeRefusalTests {

    @Test func readsTheReasonOutOfWhateverShapeTheBodyTakes() {
        let plain = Data(#"{"error":"This node serves Wan 2.2 TI2V-5B; ltx2-distilled isn't installed yet."}"#.utf8)
        #expect(NodeVideoRuntime.reason(in: plain)?.contains("Wan 2.2") == true)

        let detail = Data(#"{"detail":"vertex budget must be between 200 and 5000"}"#.utf8)
        #expect(NodeVideoRuntime.reason(in: detail)?.contains("vertex budget") == true)

        // FastAPI's validation errors arrive as a list under `detail`.
        let validation = Data(#"{"detail":[{"loc":["body","seconds"],"msg":"input should be a valid integer"}]}"#.utf8)
        #expect(NodeVideoRuntime.reason(in: validation)?.contains("valid integer") == true)

        // A bare string body is still worth reading.
        #expect(NodeVideoRuntime.reason(in: Data("model not installed".utf8)) == "model not installed")

        // An HTML error page is noise, not an explanation.
        #expect(NodeVideoRuntime.reason(in: Data("<html><body>502</body></html>".utf8)) == nil)
        #expect(NodeVideoRuntime.reason(in: Data()) == nil)
    }

    /// End to end against the real node, using a request it is guaranteed to refuse:
    /// a deliberately wrong bearer token. The original version asked for a model the
    /// node didn't serve — then the node installed it, and every test run queued a
    /// real render and rode the GPU backlog for minutes (hub issue #10). A bad token
    /// is refused instantly, forever, through the same words-not-status-codes path.
    @Test(.liveNodeOptIn) func aRealRefusalArrivesAsWordsNotAStatusCode() async throws {
        guard let config = SwarmConfig.load(), let peer = config.peers.first,
              let base = URL(string: peer.baseURL.trimmingCharacters(in: .whitespaces))
        else { return }

        let runtime = NodeVideoRuntime()
        let request = VideoRequest(
            entryID: VideoCatalog.all.first?.id ?? "wan22-ti2v-5b",
            prompt: "a refusal, on purpose",
            seconds: 3,
            outputDirectory: FileManager.default.temporaryDirectory
        )
        do {
            _ = try await runtime.generate(
                request, node: base, token: "not-the-swarm-token-on-purpose"
            ) { _ in }
            Issue.record("the node accepted a bad token — that is a security bug, not a pass")
        } catch let error as VideoRuntimeError {
            let message = error.errorDescription ?? ""
            print("node refusal surfaced as: \(message)")
            #expect(!message.isEmpty)
            // The thing that was broken: a bare status code with no explanation.
            #expect(!message.contains("without saying why"))
        }
    }
}

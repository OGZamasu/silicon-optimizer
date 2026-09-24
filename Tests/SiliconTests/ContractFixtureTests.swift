import CryptoKit
import Foundation
import Testing
@testable import SiliconRuntime
@testable import SiliconUI

/// The Mac half of the wire contract with silicon-node.
///
/// `contract/` holds the real shapes silicon-node sends, byte-identical to the canonical copy
/// in that repository, where a Python suite asserts the live FastAPI responses still match
/// them. Here the same files go through the parsers the swarm page and every delegating tool
/// actually use, so a field the node renames fails on this side too — instead of showing up
/// as a blank tile on someone's Mac three weeks later.
///
/// `PeerParsingTests` keeps its hand-written dictionaries: those pin the *lenient* paths —
/// dialects, missing fields, older nodes. This suite pins today's node, exactly.
@Suite("Mac↔node wire contract")
struct ContractFixtureTests {

    /// The fixtures live at the repository root, shared with silicon-node, so they are read
    /// from disk rather than bundled as target resources — SPM only copies resources that sit
    /// inside the target's own directory, and a second copy would be one more thing to drift.
    private static let contractDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SiliconTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("contract")

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = Self.contractDirectory.appendingPathComponent("\(name).json")
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return try #require(object as? [String: Any])
    }

    private func within(_ value: Double?, of expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 0.01
    }

    /// The fixtures the contract's README lists in its Files table. The table travels with
    /// the fixtures from silicon-node, so it is the list of what the directory should hold —
    /// which a count typed in here was not, the day the node added two.
    private static func documentedFixtures() throws -> [String] {
        let readme = try String(
            contentsOf: contractDirectory.appendingPathComponent("README.md"), encoding: .utf8
        )
        let names = readme.split(separator: "\n").compactMap { line in
            line.firstMatch(of: /^\| `([^`\/]+\.json)` \|/).map { String($0.1) }
        }
        return Set(names).sorted()
    }

    /// Both repositories check this digest, so editing the fixtures on one side without
    /// copying the directory to the other fails a build rather than passing quietly.
    ///
    /// The digest covers whatever is on disk, so the set of files is checked against the
    /// README first: a fixture dropped or added with the digest recomputed would match it.
    @Test func theContractCopyMatchesTheCanonicalChecksum() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: Self.contractDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let documented = try Self.documentedFixtures()
        #expect(!documented.isEmpty)
        #expect(files.map(\.lastPathComponent) == documented)

        var digest = SHA256()
        for file in files {
            digest.update(data: Data(file.lastPathComponent.utf8))
            digest.update(data: try Data(contentsOf: file))
        }
        let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()

        let recorded = try String(
            contentsOf: Self.contractDirectory.appendingPathComponent("VERSION.sha256"),
            encoding: .utf8
        )
        #expect(hex == String(try #require(recorded.split(separator: " ").first)))
    }

    @Test func readsTheNodeAdvertisement() throws {
        var status = AppModel.PeerStatus(
            name: "silicon-node", baseURL: "http://node:8790", reachable: true
        )
        AppModel.parseNode(try fixture("node"), into: &status)

        #expect(status.platform == "windows-wsl2-cuda")
        #expect(status.hardware == "NVIDIA GeForce RTX 3090 Ti")
        #expect(within(status.totalGB, of: 24564.0 / 1024))
        #expect(within(status.usedGB, of: 21300.0 / 1024))
        // The one field the router ranks on: taken as advertised, never recomputed.
        #expect(within(status.headroomGB, of: 2.9))
        #expect(within(status.gpuUtil, of: 0.05))
        #expect(status.queueDepth == 0)
        #expect(status.gpuConsumer == "llm")
        #expect(status.readyCapabilities == ["image-to-mesh", "llm-qwen3.8-27b"])

        let mesh = try #require(status.capabilities.first)
        #expect(mesh.kind == "mesh")
        #expect(within(mesh.peakGB, of: 13.0))
        #expect(within(mesh.typicalSeconds, of: 323.7))
        #expect(mesh.enabled == true)
        #expect(mesh.settings["vert_num"] == "2000")
        // "no figure", not zero: a chat lane has no per-job VRAM peak.
        #expect(status.capabilities[1].peakGB == nil)

        let running = try #require(status.runningJob)
        #expect(running.kind == "text-to-video")
        #expect(running.running)
        #expect(running.progress == 0.42)
        #expect(running.submittedBy == "mac-studio")
        #expect(status.pendingJobs.map(\.kind) == ["image-to-mesh"])
        #expect(status.pendingJobs.allSatisfy { !$0.running })
    }

    @Test func readsHealthAsAVersionAndAQueueDepth() throws {
        let health = try fixture("health")
        let server = try #require(health["server"] as? [String: Any])
        #expect(server["name"] as? String == "silicon-node")
        // The node stamps this from its VERSION file; the Mac shows it in compatibility
        // messages, so an empty or missing string is a bug worth failing on.
        let version = try #require(server["version"] as? String)
        #expect(!version.isEmpty)
        #expect(health["queue_depth"] as? Int != nil)
    }

    /// A queued job has no progress to show. Rendering its absent 0% as a bar is how a
    /// five-minute wait for the card came to look like a stalled render.
    ///
    /// Note what this does *not* say: `isQueued` is false. The node reports a waiting job as
    /// `status: "running"`, so the flag — which keys off a literal "queued"/"pending" — never
    /// fires for silicon-node, and the absent `fraction` is the only signal. Pinned as the
    /// behaviour it is, rather than the behaviour the field name suggests.
    @Test func aQueuedJobReadsAsWaitingRatherThanStalled() throws {
        let progress = NodeJobProgress(from: try fixture("job-queued"))
        #expect(!progress.isQueued)
        #expect(progress.fraction == nil)
        #expect(progress.stage == nil)
        #expect(progress.queuePosition == nil)
    }

    @Test func aRunningJobReadsItsStageStepsAndETA() throws {
        let progress = NodeJobProgress(from: try fixture("job-running"))
        #expect(!progress.isQueued)
        #expect(progress.stage == "video-denoise")
        #expect(within(progress.fraction, of: 0.42))
        #expect(progress.step == 13)
        #expect(progress.stepsTotal == 30)
        #expect(within(progress.eta, of: 121))
        #expect(within(progress.elapsed, of: 88.4))
    }

    @Test func aFinishedJobReadsAsCompleteWithNodeRelativeFiles() throws {
        let json = try fixture("job-done")
        let progress = NodeJobProgress(from: json)
        #expect(!progress.isQueued)
        #expect(within(progress.fraction, of: 1.0))

        let urls = try #require(json["result_urls"] as? [String])
        // Node-relative on purpose: the caller resolves them against the peer's base URL,
        // so a node behind a tailnet name does not have to know what it is called.
        #expect(urls.allSatisfy { $0.hasPrefix("/v1/files/") })
    }

    @Test func aFailedJobCarriesASentenceWorthShowing() throws {
        let json = try fixture("job-failed")
        #expect(json["status"] as? String == "failed")
        let error = try #require(json["error"] as? String)
        #expect(error.count > 20 && error.hasSuffix("."))
        // Failure is not progress: nothing here should read as a live percentage.
        #expect(NodeJobProgress(from: json).fraction == nil)
    }

    /// Three statuses cross the wire, and the node collapses "queued" into "running" —
    /// so the Mac must never treat a missing `progress` as zero work done.
    @Test func onlyThreeStatusesEverArrive() throws {
        var statuses: Set<String> = []
        for name in ["job-queued", "job-running", "job-done", "job-failed"] {
            statuses.insert(try #require(try fixture(name)["status"] as? String))
        }
        #expect(statuses == ["running", "done", "failed"])
    }
}

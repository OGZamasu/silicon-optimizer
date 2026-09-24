import CryptoKit
import Foundation
import Testing
import SiliconCatalog
@testable import SiliconControl
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
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url(name)))
        return try #require(object as? [String: Any])
    }

    /// A fixture's exact bytes, for a stand-in node to answer with.
    private func fixtureText(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    private func url(_ name: String) -> URL {
        Self.contractDirectory.appendingPathComponent("\(name).json")
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
        #expect(status.readyCapabilities == ["image-to-mesh", "llm-qwen3.8-27b", "text-to-video"])

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

    /// Four statuses cross the wire. The node collapses "queued" into "running", so the Mac
    /// must never treat a missing `progress` as zero work done; and a cancelled job is its
    /// own terminal state, never a failure.
    @Test func fourStatusesArriveAndCancelledIsItsOwn() throws {
        var statuses: Set<String> = []
        for name in try Self.documentedFixtures() where name.hasPrefix("job-") {
            let status = try fixture(String(name.dropLast(".json".count)))["status"]
            statuses.insert(try #require(status as? String, "\(name)"))
        }
        #expect(statuses == ["running", "done", "failed", "cancelled"])
    }

    // MARK: - Cancellation and the decision lane (silicon-node 638b10e)

    /// The node's video lane says it can stop a job, and that advertisement is all the
    /// queue's Cancel keys on: the clip's own node offering `cancel` for the clip's lane.
    /// The fixture's lane is the generic `text-to-video`, which Wan 2.2 renders on.
    @MainActor
    @Test func theNodesVideoLaneOffersToCancelAClipItIsRendering() throws {
        let base = URL(string: "http://100.64.0.9:8790")!
        var status = AppModel.PeerStatus(
            name: "silicon-node", baseURL: base.absoluteString, reachable: true
        )
        AppModel.parseNode(try fixture("node"), into: &status)

        let video = try #require(status.capabilities.first { $0.kind == NodeVideoRuntime.capabilityKind })
        #expect(video.id == VideoCatalog.genericCapabilityID)
        #expect(video.supportedJobActions == ["cancel"])
        // Only the lane that says so: the mesh and chat lanes offer nothing to stop.
        #expect(status.capabilities.filter { !$0.supportedJobActions.isEmpty }.map(\.id)
                == ["text-to-video"])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("contract-cancel-offer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = VideoBatchQueue(storeURL: directory.appendingPathComponent("queue.json"))
        let item = try queue.enqueueSingle(VideoRequest(
            entryID: VideoCatalog.wan22.id, prompt: "A shot", outputDirectory: directory
        ))
        try queue.begin(item.id, nodeName: status.name, nodeURL: base)
        try queue.accepted(item.id, job: VideoNodeJob(id: "job-4f2c1a9b7d3e5f608a12"))
        let rendering = try #require(queue.items.first)
        #expect(AppModel.canCancelVideo(rendering, among: [status]))
    }

    /// A cancelled job ends the video poller as cancelled — the GPU is free and nothing will
    /// be published — never as a failure the queue might offer to render again. The node's
    /// `cancel.detail` is the sentence the clip keeps.
    @Test func aCancelledJobEndsTheVideoPollerAsCancelled() async throws {
        let body = try fixtureText("job-cancelled")
        let json = try fixture("job-cancelled")
        let jobID = try #require(json["job_id"] as? String)
        let server = try CapturingServer { _, _ in .init(body: body) }
        defer { server.stop() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("contract-cancelled-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = NodeVideoRuntime(pollInterval: .milliseconds(20))
        do {
            _ = try await runtime.generate(
                VideoRequest(entryID: VideoCatalog.wan22.id, prompt: "A shot",
                             outputDirectory: directory),
                node: URL(string: "http://127.0.0.1:\(server.port)")!, token: nil,
                resuming: VideoNodeJob(id: jobID), onProgress: { _ in }
            )
            Issue.record("A cancelled job has no clip to return")
        } catch let cancelled as VideoNodeCancelled {
            #expect(cancelled.detail == "Cancelled while running.")
        }
        #expect(server.requests.map(\.path) == ["/v1/jobs/\(jobID)"])
        // Stopped, not stalled: nothing in it reads as a live percentage or a wait.
        let progress = NodeJobProgress(from: json)
        #expect(progress.fraction == nil && !progress.isQueued)
    }

    /// `POST /v1/jobs/{id}/cancel` answers in its `cancel` field, and "cancelled" is the one
    /// answer that means the render is over for certain.
    @Test func theCancelAnswerReadsAsConfirmed() async throws {
        let body = try fixtureText("job-cancel")
        let jobID = try #require(try fixture("job-cancel")["job_id"] as? String)
        let server = try CapturingServer { _, _ in .init(body: body) }
        defer { server.stop() }

        let outcome = await NodeVideoRuntime().cancelJob(
            VideoNodeJob(id: jobID), node: URL(string: "http://127.0.0.1:\(server.port)")!,
            token: nil
        )
        #expect(outcome == .cancelled("The job is stopped and will not publish results."))
        #expect(server.requests.map(\.path) == ["/v1/jobs/\(jobID)/cancel"])
    }

    /// The decision lane is the top-level `decisions` object, not a capability. Read as the
    /// node sends it: available, cold (the first question pays the load), nothing measured.
    @Test func readsTheDecisionLaneFromItsOwnObject() throws {
        let json = try fixture("node")
        var status = AppModel.PeerStatus(
            name: "silicon-node", baseURL: "http://100.64.0.9:8790", reachable: true
        )
        AppModel.parseNode(json, into: &status)

        let lane = try #require(status.decisions)
        #expect(lane.available && !lane.loaded)
        #expect(lane.models == ["laya", "laya-multilingual", "laya-typed-decisions"])
        #expect(lane.perQuestionMS == nil)
        #expect(lane.error == nil)
        #expect(!status.capabilities.contains { $0.kind == NodeDecisionLane.capabilityKind })

        let candidate = try #require(AppModel.decisionCandidate(for: status))
        #expect(candidate.ready)
        #expect(candidate.checkpoints == ["laya", "laya-multilingual", "laya-typed-decisions"])

        // What this Mac would send has to be what the node says it accepts: every
        // checkpoint by the name the node lane uses, every kind of question.
        let decisions = try #require(json["decisions"] as? [String: Any])
        for checkpoint in LayaCheckpoint.allCases {
            #expect(lane.models.contains(NodeDecisionLane.nodeModelName(for: checkpoint)))
        }
        let accepted = Set(decisions["question_types"] as? [String] ?? [])
        #expect(ControlAPI.SystemOneQuestion.kinds.isSubset(of: accepted))
    }

    /// The node lane posts a decision where the advertisement says to.
    @Test func theNodeLanePostsWhereTheAdvertisementSays() async throws {
        let decisions = try #require(try fixture("node")["decisions"] as? [String: Any])
        let endpoint = try #require(decisions["endpoint"] as? String)
        let server = try CapturingServer { _, _ in
            .init(body: #"""
                {"model":"laya","usage":{"input_tokens":1,"output_tokens":0},
                 "answers":{"q":{"type":"noul","noul":0.5}}}
                """#)
        }
        defer { server.stop() }
        let lane = NodeDecisionLane(peer: {
            .init(name: "silicon-node", baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
                  token: "fixture-swarm-token")
        })
        _ = try await lane.decide(.fixture())
        #expect(server.requests.map(\.path) == [endpoint])
    }

    /// A mesh job the node cancelled — its owner's Cancel Queue, a cancel from the node's own
    /// page — is over. The LATO.2 lane read the status it did not know as "still running" and
    /// polled the finished job for thirty minutes before calling it a timeout.
    @Test func aMeshJobTheNodeCancelledEndsInsteadOfPollingOn() async throws {
        let body = try fixtureText("job-cancelled")
        let jobID = try #require(try fixture("job-cancelled")["job_id"] as? String)
        let server = try CapturingServer { request, _ in
            request.path == "/v1/image-to-mesh"
                ? .init(body: #"{"job_id":"\#(jobID)"}"#) : .init(body: body)
        }
        defer { server.stop() }
        let request = try Lato2CredentialTests.request()
        defer { try? FileManager.default.removeItem(at: request.image.deletingLastPathComponent()) }
        let runtime = Lato2Runtime(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)

        let ending = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    for try await _ in try await runtime.generate(request) {}
                    return "finished"
                } catch MeshRuntimeError.cancelledOnNode(let detail) {
                    return detail ?? "cancelled, with no sentence"
                } catch {
                    return "\(error)"
                }
            }
            // Far longer than one poll takes, far shorter than the 30-minute deadline.
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            await runtime.cancel()
            return first
        }
        let detail = try #require(ending, "still polling a cancelled job after 20 s")
        #expect(detail == "Cancelled while running.")
        #expect(server.requests.filter { $0.path == "/v1/jobs/\(jobID)" }.count == 1)
    }
}

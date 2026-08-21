import Foundation
import Testing
@testable import SiliconUI

/// The swarm dashboard is only as truthful as this parser, and the two platforms name
/// their fields differently — a CUDA node speaks VRAM, a Mac speaks unified memory.
/// Both real shapes are pinned here, copied from live `/v1/node` responses.
@Suite("Swarm peer parsing")
struct PeerParsingTests {

    private func within(_ value: Double?, of expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 0.01
    }

    @Test func readsACUDANodeAdvertisement() {
        let json: [String: Any] = [
            "name": "silicon-node",
            "platform": "windows-wsl2-cuda",
            "profile": [
                "gpu": "NVIDIA GeForce RTX 3090 Ti",
                "vram_mb": 24564,
                "driver": "610.88",
            ],
            "capabilities": [
                [
                    "id": "image-to-mesh", "kind": "mesh", "ready": true,
                    "peak_vram_gb": 13.0, "typical_seconds": 323.7,
                    "detail": "Route A: TRELLIS.2 densify then LATO.2 retopology.",
                ],
                [
                    "id": "llm-qwen3.8-27b", "kind": "llm", "ready": true,
                    "peak_vram_gb": NSNull(), "typical_seconds": NSNull(),
                    "detail": "Jobs preempt the LLM; it auto-restores.",
                ],
            ],
            "metrics": [
                "vram_used_mb": 21300, "vram_free_mb": 3010,
                "headroom_gb": 2.9, "gpu_util_pct": 5, "queue_depth": 0,
            ],
        ]

        var status = AppModel.PeerStatus(
            name: "silicon-node", baseURL: "http://node:8790", reachable: true
        )
        AppModel.parseNode(json, into: &status)

        #expect(status.platform == "windows-wsl2-cuda")
        #expect(status.hardware == "NVIDIA GeForce RTX 3090 Ti")
        #expect(within(status.totalGB, of: 24564.0 / 1024))
        #expect(within(status.usedGB, of: 21300.0 / 1024))
        #expect(within(status.headroomGB, of: 2.9))
        #expect(within(status.gpuUtil, of: 0.05))
        #expect(status.queueDepth == 0)

        #expect(status.capabilities.count == 2)
        let mesh = status.capabilities[0]
        #expect(mesh.ready)
        #expect(within(mesh.peakGB, of: 13.0))
        #expect(within(mesh.typicalSeconds, of: 323.7))
        // NSNull is "no figure", never a crash and never zero.
        #expect(status.capabilities[1].peakGB == nil)
        #expect(status.readyCapabilities == ["image-to-mesh", "llm-qwen3.8-27b"])
    }

    @Test func readsAMacAdvertisement() {
        let json: [String: Any] = [
            "name": "silicon-optimizer-mac",
            "platform": "macos-apple-silicon",
            "profile": [
                "chip": "Apple M4 Pro", "memory_gb": 48.0,
                "bandwidth_gbps": 273.0, "gpu_cores": 20,
            ],
            "capabilities": [
                ["id": "llm", "kind": "llm", "ready": true,
                 "peak_gb": 17.1, "detail": "Qwen3.8-27B loaded"],
            ],
            "metrics": [
                "queue_depth": 1, "headroom_gb": 12.5,
                "gpu_util_pct": 42, "memory_used_pct": 61,
            ],
        ]

        var status = AppModel.PeerStatus(
            name: "silicon-optimizer-mac", baseURL: "http://mac:8788", reachable: true
        )
        AppModel.parseNode(json, into: &status)

        #expect(status.hardware == "Apple M4 Pro")
        #expect(within(status.totalGB, of: 48))
        // Macs report a used percentage, not bytes; used is derived from the total.
        #expect(within(status.usedGB, of: 48 * 0.61))
        #expect(within(status.headroomGB, of: 12.5))
        #expect(within(status.gpuUtil, of: 0.42))
        #expect(status.queueDepth == 1)
        #expect(within(status.capabilities.first?.peakGB, of: 17.1))
    }

    /// The live `GET /v1/llm` payload from silicon-node, verbatim — including the URL
    /// annotated with " (tailnet)", which must not leak into the harness's baseURL.
    @Test func readsAPeerLLMStatus() {
        let json: [String: Any] = [
            "installed": true, "running": true, "healthy": true,
            "model": "qwen3.8-27b", "profile": "c1", "uptime_s": 4297,
            "api": [
                "openai": "http://100.118.191.121:8081/v1 (tailnet)",
                "anthropic": "http://100.118.191.121:8081 (tailnet, Messages API)",
            ],
        ]
        let llm = AppModel.parseLLM(json)
        #expect(llm.installed && llm.running && llm.healthy)
        #expect(llm.model == "qwen3.8-27b")
        #expect(within(llm.uptimeSeconds, of: 4297))
        #expect(llm.openAIBase == "http://100.118.191.121:8081/v1")
        #expect(llm.contextLength == nil)
    }

    /// A stopped LLM, as silicon-node reports it since the node started listing its
    /// installed models inline. `running: false` with the engine down is exactly the
    /// state behind "connection error" in chat — the parse must keep it distinct.
    @Test func readsAStoppedPeerLLMWithInstalledModels() {
        let json: [String: Any] = [
            "installed": true, "installed_models": ["qwen3_8_27b.ninfer"],
            "running": false, "healthy": false,
            "model": "qwen3.8-27b", "profile": NSNull(), "uptime_s": NSNull(),
            "api": ["openai": "http://100.118.191.121:8081/v1 (tailnet)"],
        ]
        let llm = AppModel.parseLLM(json)
        #expect(llm.installed && !llm.running && !llm.healthy)
        #expect(llm.model == "qwen3.8-27b")
        #expect(llm.availableModels == ["qwen3_8_27b.ninfer"])
        #expect(llm.uptimeSeconds == nil)
    }

    @Test func readsEveryModelListDialect() {
        #expect(AppModel.parseModelList(["models": ["a", "b"]]) == ["a", "b"])
        #expect(AppModel.parseModelList(["models": [["id": "a"], ["name": "b"]]]) == ["a", "b"])
        #expect(AppModel.parseModelList(["data": [["id": "qwen3.8-27b"]]]) == ["qwen3.8-27b"])
        #expect(AppModel.parseModelList(["unrelated": 1]).isEmpty)
    }

    @Test func degradesGracefullyWhenFieldsAreMissing() {
        var status = AppModel.PeerStatus(
            name: "mystery", baseURL: "http://x", reachable: true
        )
        AppModel.parseNode(["platform": "plan9"], into: &status)
        #expect(status.platform == "plan9")
        #expect(status.totalGB == nil)
        #expect(status.usedGB == nil)
        #expect(status.capabilities.isEmpty)
    }
}

@Suite("Swarm peer parsing — #128/#129 extensions")
struct PeerExtensionParsingTests {

    @Test func readsQueueJobsGPUConsumerAndAbilityConfig() {
        let json: [String: Any] = [
            "platform": "windows-wsl2-cuda",
            "metrics": [
                "gpu_util_pct": 100, "queue_depth": 2,
                "gpu_consumer": "job:portrait-animate",
            ],
            "queue": [
                "running": [
                    "id": "j-42", "kind": "portrait-animate",
                    "progress": 0.65, "started_at": 1_787_300_000,
                    "submitted_by": "chris-mac",
                ],
                "pending": [
                    ["id": "j-43", "kind": "text-to-video", "submitted_by": "sam-mac"],
                ],
            ],
            "capabilities": [
                [
                    "id": "text-to-video", "kind": "video", "ready": true,
                    "description": "WAN 2.2 image+text to 720p clips.",
                    "enabled": true,
                    "settings": ["resolution": "720p", "steps": 30],
                ],
            ],
        ]
        var status = AppModel.PeerStatus(
            name: "silicon-node", baseURL: "http://x", reachable: true
        )
        AppModel.parseNode(json, into: &status)

        #expect(status.gpuConsumer == "job:portrait-animate")
        #expect(status.runningJob?.id == "j-42")
        #expect(status.runningJob?.running == true)
        #expect(status.runningJob?.progress == 0.65)
        #expect(status.runningJob?.submittedBy == "chris-mac")
        #expect(status.pendingJobs.count == 1)
        #expect(status.pendingJobs.first?.kind == "text-to-video")
        #expect(status.pendingJobs.first?.running == false)

        let capability = status.capabilities.first
        #expect(capability?.description == "WAN 2.2 image+text to 720p clips.")
        #expect(capability?.enabled == true)
        #expect(capability?.settings["resolution"] == "720p")
        #expect(capability?.settings["steps"] == "30")
    }

    @Test func oldNodesWithoutTheNewFieldsStayClean() {
        let json: [String: Any] = [
            "metrics": ["gpu_util_pct": 5, "queue_depth": 1],
            "capabilities": [["id": "image-to-mesh", "kind": "mesh", "ready": true]],
        ]
        var status = AppModel.PeerStatus(
            name: "silicon-node", baseURL: "http://x", reachable: true
        )
        AppModel.parseNode(json, into: &status)
        #expect(status.gpuConsumer == nil)
        #expect(status.runningJob == nil)
        #expect(status.pendingJobs.isEmpty)
        #expect(status.capabilities.first?.enabled == nil)
        #expect(status.capabilities.first?.settings.isEmpty == true)
    }
}

/// The People panel reads /swarm/clients; today's nodes send names and timestamps,
/// and the #131 usage counters must slot in without a code change here.
@Suite("Swarm member parsing")
struct SwarmMemberParsingTests {

    @Test("today's shape parses, tomorrow's counters ride along")
    func parseClients() {
        let list: [[String: Any]] = [
            ["name": "Christopher’s MacBook Pro",
             "created": "2026-08-21 10:30:42",
             "last_seen": "2026-08-21 13:55:51"],
            ["name": "Tristan’s MacBook Pro",
             "created": "2026-08-21 13:46:43",
             "last_seen": "2026-08-21 13:55:48",
             "jobs_total": 7,
             "jobs_by_kind": ["text-to-video": 5, "image-to-mesh": 2],
             "llm_requests": 31],
            ["no_name": "dropped"],
        ]
        let parsed = AppModel.parsePeerClients(list)
        #expect(parsed.count == 2)
        #expect(parsed[0].jobsTotal == nil)
        #expect(parsed[1].jobsTotal == 7)
        #expect(parsed[1].jobsByKind?["text-to-video"] == 5)
        #expect(parsed[1].llmRequests == 31)
    }

    @Test("member ids stay unique across nodes sharing a person")
    func memberIDs() {
        let info = AppModel.PeerClientInfo(name: "Tristan’s MacBook Pro")
        let a = AppModel.SwarmMember(peerName: "silicon-node", info: info)
        let b = AppModel.SwarmMember(peerName: "attic-pc", info: info)
        #expect(a.id != b.id)
    }
}

/// #133: nodes gaining a second serving engine (FreeToken beside ninfer) say which
/// one backs the loaded model; single-engine nodes send nothing and nothing changes.
@Suite("Swarm peer parsing — engine field")
struct PeerEngineParsingTests {

    @Test func readsEngineWhenAdvertised() {
        let llm = AppModel.parseLLM([
            "running": true, "model": "deepseek-v4-flash",
            "context_length": 32768, "engine": "freetoken",
        ])
        #expect(llm.engine == "freetoken")
        #expect(llm.model == "deepseek-v4-flash")
    }

    @Test func absentEngineStaysNil() {
        let llm = AppModel.parseLLM(["running": true, "model": "qwen3.8-27b"])
        #expect(llm.engine == nil)
    }
}

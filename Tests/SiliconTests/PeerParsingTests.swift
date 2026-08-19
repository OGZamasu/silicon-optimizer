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

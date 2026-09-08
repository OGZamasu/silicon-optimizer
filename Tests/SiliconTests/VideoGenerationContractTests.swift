import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime

@Suite("Video generation wire and timeout contract")
struct VideoGenerationContractTests {
    @Test func olderSinglePromptRequestsStillDecodeAndOmitChainPrompts() throws {
        let request = try JSONDecoder().decode(
            ControlAPI.VideoGenerateRequest.self, from: Data(#"{"prompt":"waves"}"#.utf8)
        )
        #expect(request.h3ChainPrompts == nil)
        let encoded = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)
        ) as? [String: Any])
        #expect(encoded["h3_chain_prompts"] == nil)
        #expect(try ControlAPI.VideoGenerateRequest.validatedH3ChainPrompts(
            nil, modelID: "ltx2-distilled", seconds: 5
        ) == nil)
    }

    @Test(arguments: [10, 15]) func chainPromptsSurviveControlAndNodeSerialization(seconds: Int) throws {
        let prompts = (1...(seconds / 5)).map { " window \($0)\n" }
        let request = ControlAPI.VideoGenerateRequest(
            prompt: "A continuous shot", modelID: "hailuo-h3", seconds: seconds,
            h3ChainPrompts: prompts
        )
        let encoded = try JSONEncoder().encode(request)
        let wire = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(wire["h3_chain_prompts"] as? [String] == prompts)
        #expect(wire["h3ChainPrompts"] == nil)
        let decoded = try JSONDecoder().decode(ControlAPI.VideoGenerateRequest.self, from: encoded)
        let nodeRequest = VideoRequest(
            entryID: "hailuo-h3", prompt: decoded.prompt, seconds: seconds,
            h3ChainPrompts: decoded.h3ChainPrompts,
            outputDirectory: URL(fileURLWithPath: "/tmp/unused-video-output")
        )
        let node = try #require(JSONSerialization.jsonObject(with: nodeRequest.nodeBody()) as? [String: Any])
        #expect(node["model"] as? String == "hailuo-h3")
        #expect(node["seconds"] as? Int == seconds)
        #expect(node["h3_chain_prompts"] as? [String] == (1...(seconds / 5)).map { "window \($0)" })
    }

    @Test func rejectsWrongModelsLengthsCountsAndBlankOrOversizePrompts() throws {
        let invalid: [(String, Int, [String])] = [
            ("ltx2-distilled", 10, ["first", "second"]),
            ("hailuo-h3", 5, ["first", "second"]),
            ("hailuo-h3", 10, ["first"]),
            ("hailuo-h3", 15, ["first", "second"]),
            ("hailuo-h3", 10, ["first", " \n\t"]),
            ("hailuo-h3", 10, [String(repeating: "x", count: 4001), "second"]),
            // Count Unicode scalars consistently with Python, not grapheme clusters.
            ("hailuo-h3", 10, [String(repeating: "e\u{301}", count: 2001), "second"]),
        ]
        for (model, seconds, prompts) in invalid {
            let request = VideoRequest(
                entryID: model, prompt: "shot", seconds: seconds, h3ChainPrompts: prompts,
                outputDirectory: URL(fileURLWithPath: "/tmp/unused-video-output")
            )
            #expect(throws: ControlAPI.VideoGenerateRequest.ValidationError.self) { try request.nodeBody() }
        }
        #expect(try ControlAPI.VideoGenerateRequest.validatedH3ChainPrompts(
            [String(repeating: "x", count: 4000), " second "], modelID: "hailuo-h3", seconds: 10
        )?.last == "second")
    }

    @Test func timeoutLayersCoverTheAcceptedJobAndFiniteTransfers() {
        #expect(VideoGenerationBudget.nodeJobSeconds == 12 * 60 * 60)
        // Also pinned in the Python provider test so both clients share this contract.
        #expect(VideoGenerationBudget.controlSeconds == 45060)
        #expect(VideoGenerationBudget.toolSeconds > VideoGenerationBudget.controlSeconds)
        #expect(VideoGenerationBudget.toolMilliseconds == VideoGenerationBudget.toolSeconds * 1000)
        #expect(VideoGenerationBudget.controlSeconds > VideoGenerationBudget.nodeJobSeconds
            + 2 * VideoGenerationBudget.networkResourceSeconds + VideoGenerationBudget.downloadSeconds)
        let control = ControlClient.sessionConfiguration()
        #expect(control.timeoutIntervalForRequest == Double(VideoGenerationBudget.controlSeconds))
        #expect(control.timeoutIntervalForResource == Double(VideoGenerationBudget.controlSeconds))
        #expect(ControlClient.requestTimeout(for: "/video/generate") == control.timeoutIntervalForResource)
        #expect(ControlClient.requestTimeout(for: "/image/generate") == 1800)
        let node = NodeVideoRuntime.sessionConfiguration()
        #expect(node.timeoutIntervalForResource == 600)
        #expect(node.timeoutIntervalForResource == Double(VideoGenerationBudget.networkResourceSeconds))
    }

    @Test func aTimeoutDoesNotClaimTheAppQuit() {
        let error = ControlClient.transportError(URLError(.timedOut))
        guard case ControlClient.ClientError.transport(let message) = error else {
            Issue.record("A timeout must preserve its diagnosis, not report appNotRunning")
            return
        }
        #expect(message.contains("may still be working"))
        #expect(message.contains("before submitting again"))
        guard case ControlClient.ClientError.appNotRunning = ControlClient.transportError(
            URLError(.cannotConnectToHost)
        ) else {
            Issue.record("A refused connection should report appNotRunning")
            return
        }
    }
}

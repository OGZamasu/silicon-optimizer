import Foundation
import Testing
@testable import SiliconControl

@Suite("Gateway model ids")
struct GatewayModelIDTests {

    @Test func localAndNodeIDsRoundTrip() {
        let local = GatewayAPI.modelID(local: "qwen3.8-27b-Q4_K_M")
        #expect(local == "local/qwen3.8-27b-Q4_K_M")
        #expect(GatewayAPI.parseModelID(local) == .local(installID: "qwen3.8-27b-Q4_K_M"))

        let node = GatewayAPI.modelID(peerSlug: "silicon-node", model: "qwen3.8-27b")
        #expect(node == "node/silicon-node/qwen3.8-27b")
        #expect(GatewayAPI.parseModelID(node)
            == .node(peerSlug: "silicon-node", model: "qwen3.8-27b"))
    }

    /// Node model names may themselves carry slashes (HF-style "org/model"); only the
    /// first two separators structure the id.
    @Test func nodeModelNamesMayContainSlashes() {
        let id = GatewayAPI.modelID(peerSlug: "silicon-node", model: "org/some-model")
        #expect(GatewayAPI.parseModelID(id)
            == .node(peerSlug: "silicon-node", model: "org/some-model"))
    }

    @Test func malformedIDsParseAsNil() {
        #expect(GatewayAPI.parseModelID("gpt-4") == nil)
        #expect(GatewayAPI.parseModelID("local/") == nil)
        #expect(GatewayAPI.parseModelID("node/only-a-peer") == nil)
        #expect(GatewayAPI.parseModelID("node//model") == nil)
    }

    @Test func peerNamesBecomeSafeSlugs() {
        #expect(GatewayAPI.peerSlug("My PC #2") == "my-pc--2")
        #expect(GatewayAPI.peerSlug("silicon-node") == "silicon-node")
    }

    /// The wild pair this exists for: the node lists its model file as
    /// "qwen3_8_27b.ninfer" but serves it as "qwen3.8-27b". One model, one picker entry.
    @Test func fileAndServingSpellingsOfAModelMatch() {
        #expect(GatewayAPI.modelNamesMatch("qwen3_8_27b.ninfer", "qwen3.8-27b"))
        #expect(GatewayAPI.modelNamesMatch("Model.GGUF", "model"))
        #expect(!GatewayAPI.modelNamesMatch("qwen3.8-27b", "qwen3.5-7b"))
        #expect(GatewayAPI.normalizedModelName("Qwen3_8_27B.ninfer") == "qwen3827b")
    }

    @Test func modelListLeadsWithServingModels() throws {
        let data = GatewayAPI.modelsJSON([
            GatewayAPI.Model(
                id: "local/a", displayName: "A (Q4)", where_: "This Mac",
                contextWindow: 16384, serving: false, quantization: "Q4_K_M"
            ),
            GatewayAPI.Model(
                id: "node/n/m", displayName: "m — n", where_: "n", serving: true
            ),
        ])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = json?["data"] as? [[String: Any]]
        #expect(list?.first?["id"] as? String == "node/n/m")
        let silicon = list?.last?["silicon"] as? [String: Any]
        #expect(silicon?["contextWindow"] as? Int == 16384)
        #expect(silicon?["where"] as? String == "This Mac")
        #expect(silicon?["quantization"] as? String == "Q4_K_M")
    }
}

@Suite("Responses request translation")
struct GatewayResponsesRequestTests {

    /// The shape Codex actually sends: instructions, typed message items, a prior tool
    /// call round-trip, and flat function tools.
    private let codexRequest = """
    {
      "model": "local/qwen",
      "instructions": "You are Codex.",
      "input": [
        {"type": "message", "role": "user",
         "content": [{"type": "input_text", "text": "list the files"}]},
        {"type": "reasoning", "summary": [{"type": "summary_text", "text": "thinking"}]},
        {"type": "function_call", "name": "shell", "call_id": "call_7",
         "arguments": "{\\"command\\":[\\"ls\\"]}"},
        {"type": "function_call_output", "call_id": "call_7", "output": "README.md"},
        {"type": "message", "role": "assistant",
         "content": [{"type": "output_text", "text": "Here they are."}]}
      ],
      "tools": [
        {"type": "function", "name": "shell", "description": "Runs a command",
         "strict": false, "parameters": {"type": "object"}},
        {"type": "web_search"}
      ],
      "tool_choice": "auto",
      "stream": true,
      "store": false
    }
    """

    @Test func translatesItemsIntoChatMessages() throws {
        let (body, stream) = try GatewayAPI.chatRequestBody(
            fromResponsesRequest: Data(codexRequest.utf8), backendModel: "qwen"
        )
        #expect(stream)
        let chat = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(chat?["model"] as? String == "qwen")
        #expect(chat?["stream"] as? Bool == true)

        let messages = chat?["messages"] as? [[String: Any]] ?? []
        #expect(messages.first?["role"] as? String == "system")
        #expect(messages.first?["content"] as? String == "You are Codex.")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "list the files")

        // The reasoning item vanished; the tool round-trip became assistant + tool turns.
        let toolCall = messages[2]["tool_calls"] as? [[String: Any]]
        let function = toolCall?.first?["function"] as? [String: Any]
        #expect(function?["name"] as? String == "shell")
        #expect(toolCall?.first?["id"] as? String == "call_7")
        #expect(messages[3]["role"] as? String == "tool")
        #expect(messages[3]["tool_call_id"] as? String == "call_7")
        #expect(messages[3]["content"] as? String == "README.md")
        #expect(messages[4]["role"] as? String == "assistant")
    }

    @Test func flattensToolsAndDropsBuiltins() throws {
        let (body, _) = try GatewayAPI.chatRequestBody(
            fromResponsesRequest: Data(codexRequest.utf8), backendModel: "qwen"
        )
        let chat = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let tools = chat?["tools"] as? [[String: Any]] ?? []
        // web_search has no chat equivalent and is dropped.
        #expect(tools.count == 1)
        let function = tools.first?["function"] as? [String: Any]
        #expect(function?["name"] as? String == "shell")
        #expect(function?["description"] as? String == "Runs a command")
        #expect(chat?["tool_choice"] as? String == "auto")
    }

    @Test func developerRoleBecomesSystem() throws {
        let request = """
        {"model": "m", "stream": false, "input": [
          {"type": "message", "role": "developer",
           "content": [{"type": "input_text", "text": "be brief"}]}
        ]}
        """
        let (body, stream) = try GatewayAPI.chatRequestBody(
            fromResponsesRequest: Data(request.utf8), backendModel: "m"
        )
        #expect(!stream)
        let chat = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = chat?["messages"] as? [[String: Any]]
        #expect(messages?.first?["role"] as? String == "system")
    }

    @Test func modelFieldRewritesAndStreamFlagReads() {
        let body = Data("{\"model\": \"local/x\", \"stream\": true}".utf8)
        #expect(GatewayAPI.requestedModel(inBody: body) == "local/x")
        #expect(GatewayAPI.wantsStream(body: body))
        let rewritten = GatewayAPI.rewritingModel(inBody: body, to: "x")
        #expect(GatewayAPI.requestedModel(inBody: rewritten) == "x")
    }
}

@Suite("Responses stream translation")
struct GatewayResponsesStreamTests {

    /// Splits emitted SSE frames and returns each `data:` payload as parsed JSON.
    private func decode(_ frames: [Data]) -> [[String: Any]] {
        frames.flatMap { frame -> [[String: Any]] in
            String(decoding: frame, as: UTF8.self)
                .split(separator: "\n")
                .filter { $0.hasPrefix("data: ") }
                .compactMap { line in
                    let payload = String(line.dropFirst(6))
                    guard payload != "[DONE]" else { return nil }
                    let object = try? JSONSerialization.jsonObject(
                        with: Data(payload.utf8)
                    )
                    return object as? [String: Any]
                }
        }
    }

    private func chunk(_ json: String) -> String { json }

    @Test func plainTextBecomesMessageEvents() {
        let translator = GatewayResponsesTranslator(model: "local/qwen")
        var frames = [translator.opening()]
        frames += translator.translate(
            payload: #"{"choices":[{"delta":{"content":"Hel"}}]}"#
        )
        frames += translator.translate(
            payload: #"{"choices":[{"delta":{"content":"lo"}}]}"#
        )
        frames += translator.translate(
            payload: #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":2}}"#
        )
        frames += translator.translate(payload: "[DONE]")

        let events = decode(frames)
        let types = events.compactMap { $0["type"] as? String }
        #expect(types.first == "response.created")
        #expect(types.contains("response.output_item.added"))
        #expect(types.filter { $0 == "response.output_text.delta" }.count == 2)
        #expect(types.contains("response.output_item.done"))
        #expect(types.last == "response.completed")

        let completed = events.last?["response"] as? [String: Any]
        #expect(completed?["status"] as? String == "completed")
        let usage = completed?["usage"] as? [String: Any]
        #expect(usage?["input_tokens"] as? Int == 12)
        #expect(usage?["output_tokens"] as? Int == 2)
        let output = completed?["output"] as? [[String: Any]]
        let content = output?.first?["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == "Hello")

        // Codex reads the SSE terminator too.
        let all = frames.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(all.contains("data: [DONE]"))
    }

    @Test func toolCallsAccumulateAndCloseWhole() {
        let translator = GatewayResponsesTranslator(model: "m")
        var frames: [Data] = []
        frames += translator.translate(
            payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_9","function":{"name":"shell","arguments":"{\"com"}}]}}]}"#
        )
        frames += translator.translate(
            payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"mand\":[\"ls\"]}"}}]},"finish_reason":"tool_calls"}]}"#
        )
        frames += translator.translate(payload: "[DONE]")

        let events = decode(frames)
        let done = events.first {
            ($0["type"] as? String) == "response.output_item.done"
        }?["item"] as? [String: Any]
        #expect(done?["type"] as? String == "function_call")
        #expect(done?["call_id"] as? String == "call_9")
        #expect(done?["name"] as? String == "shell")
        #expect(done?["arguments"] as? String == #"{"command":["ls"]}"#)
    }

    @Test func missingCallIDsAreSynthesized() {
        let translator = GatewayResponsesTranslator(model: "m")
        var frames: [Data] = []
        frames += translator.translate(
            payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"shell","arguments":"{}"}}]}}]}"#
        )
        frames += translator.translate(payload: "[DONE]")
        let events = decode(frames)
        let done = events.first {
            ($0["type"] as? String) == "response.output_item.done"
        }?["item"] as? [String: Any]
        let callID = done?["call_id"] as? String ?? ""
        #expect(callID.hasPrefix("call_"))
        #expect(callID.count > 5)
    }

    @Test func reasoningStreamsAsSummaryDeltas() {
        let translator = GatewayResponsesTranslator(model: "m")
        var frames: [Data] = []
        frames += translator.translate(
            payload: #"{"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#
        )
        frames += translator.translate(
            payload: #"{"choices":[{"delta":{"content":"answer"}}]}"#
        )
        frames += translator.translate(payload: "[DONE]")

        let events = decode(frames)
        let types = events.compactMap { $0["type"] as? String }
        #expect(types.contains("response.reasoning_summary_part.added"))
        #expect(types.contains("response.reasoning_summary_text.delta"))
        // Reasoning and text are separate output items, reasoning first.
        let added = events.filter { ($0["type"] as? String) == "response.output_item.added" }
        #expect((added.first?["item"] as? [String: Any])?["type"] as? String == "reasoning")
        #expect((added.last?["item"] as? [String: Any])?["type"] as? String == "message")
    }

    @Test func failureEmitsResponseFailed() {
        let translator = GatewayResponsesTranslator(model: "m")
        _ = translator.opening()
        let frames = translator.failure(message: "the model never came up")
        let events = decode(frames)
        #expect(events.first?["type"] as? String == "response.failed")
        let response = events.first?["response"] as? [String: Any]
        let error = response?["error"] as? [String: Any]
        #expect(error?["message"] as? String == "the model never came up")
        // Terminal: nothing more after a failure, even [DONE] handling.
        #expect(translator.translate(payload: "[DONE]").isEmpty)
    }

    @Test func malformedChunksAreSkippedNotFatal() {
        let translator = GatewayResponsesTranslator(model: "m")
        #expect(translator.translate(payload: "not json").isEmpty)
        let frames = translator.translate(
            payload: #"{"choices":[{"delta":{"content":"ok"}}]}"#
        )
        #expect(!frames.isEmpty)
    }

    @Test func framePayloadExtractionSkipsCommentsAndEvents() {
        let frame = Data("event: response.created\n: keep-alive\ndata: {\"a\":1}".utf8)
        #expect(GatewayServer.dataPayloads(inFrame: frame) == ["{\"a\":1}"])
    }
}

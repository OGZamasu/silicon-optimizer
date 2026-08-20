import Foundation

/// Translates one backend chat-completions SSE stream into the Responses-API event stream
/// Codex expects, chunk by chunk.
///
/// The shape is deliberately the smallest event set Codex's client acts on: `response.created`
/// once, `response.output_item.added` when a message / reasoning / function-call item begins,
/// `response.output_text.delta` and `response.reasoning_summary_text.delta` while text flows,
/// `response.output_item.done` as each item closes, then exactly one of `response.completed`
/// or `response.failed`. Function-call arguments are not streamed as deltas — Codex only acts
/// on the finished call — so they accumulate and arrive whole in the item's `done` event.
///
/// One instance serves one request; feed it each SSE `data:` payload in order and write out
/// every frame it returns.
public final class GatewayResponsesTranslator {

    private let responseID: String
    private let model: String
    /// Whether backend reasoning becomes a reasoning item with summary deltas. Codex
    /// 0.148 stalls a turn whose response carried our reasoning items, so its route
    /// drops them; the thinking still happened, it just is not narrated.
    private let includeReasoning: Bool
    private var sequence = 0

    private enum OpenItem {
        case message(id: String, index: Int, text: String)
        case reasoning(id: String, index: Int, text: String)
        case functionCall(id: String, index: Int, callID: String, name: String, arguments: String)
    }

    /// Items in output order. Chat interleaves reasoning, text, and tool-call deltas; each
    /// kind opens once and closes at the end of the stream, which is also the order Codex
    /// renders them in.
    private var items: [OpenItem] = []
    /// Chat tool calls arrive keyed by their own index; map them onto our item list.
    private var toolItemsByChatIndex: [Int: Int] = [:]
    private var messageItemIndex: Int?
    private var reasoningItemIndex: Int?

    private var usage: [String: Any]?
    private var finishReason: String?
    private var finished = false
    private var callCounter = 0

    public init(model: String, includeReasoning: Bool = true) {
        self.model = model
        self.includeReasoning = includeReasoning
        self.responseID = "resp_\(UUID().uuidString.lowercased().prefix(24))"
    }

    // MARK: - Event assembly

    private func event(_ type: String, _ fields: [String: Any]) -> Data {
        var payload = fields
        payload["type"] = type
        payload["sequence_number"] = sequence
        sequence += 1
        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return GatewayAPI.sseData(json, event: type)
    }

    private func responseObject(status: String, error: [String: Any]? = nil) -> [String: Any] {
        var response: [String: Any] = [
            "id": responseID,
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "model": model,
            "status": status,
            "output": items.map(itemJSON),
        ]
        if let usage { response["usage"] = usage }
        if let error { response["error"] = error }
        return response
    }

    private func itemJSON(_ item: OpenItem) -> [String: Any] {
        switch item {
        case .message(let id, _, let text):
            return [
                "type": "message",
                "id": id,
                "status": "completed",
                "role": "assistant",
                "content": [["type": "output_text", "text": text, "annotations": []]],
            ]
        case .reasoning(let id, _, let text):
            return [
                "type": "reasoning",
                "id": id,
                "summary": [["type": "summary_text", "text": text]],
            ]
        case .functionCall(let id, _, let callID, let name, let arguments):
            return [
                "type": "function_call",
                "id": id,
                "call_id": callID,
                "name": name,
                "arguments": arguments,
                "status": "completed",
            ]
        }
    }

    /// The opening event, sent before any backend bytes exist so Codex sees the request
    /// accepted while a model is still loading.
    public func opening() -> Data {
        event("response.created", ["response": responseObject(status: "in_progress")])
    }

    // MARK: - Chunk translation

    /// Translates one backend SSE `data:` payload. `[DONE]` closes every open item and emits
    /// the terminal event; anything unparseable is skipped — a backend hiccup should cost a
    /// token, not the turn.
    public func translate(payload: String) -> [Data] {
        if payload == "[DONE]" { return close() }
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var out: [Data] = []

        for choice in chunk["choices"] as? [[String: Any]] ?? [] {
            let delta = choice["delta"] as? [String: Any] ?? [:]

            if includeReasoning,
               let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                out.append(contentsOf: appendReasoning(reasoning))
            }
            if let content = delta["content"] as? String, !content.isEmpty {
                out.append(contentsOf: appendText(content))
            }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                out.append(contentsOf: appendToolCall(call))
            }
            if let reason = choice["finish_reason"] as? String {
                finishReason = reason
            }
        }

        if let wireUsage = chunk["usage"] as? [String: Any] {
            let prompt = (wireUsage["prompt_tokens"] as? Int) ?? 0
            let completion = (wireUsage["completion_tokens"] as? Int) ?? 0
            usage = [
                "input_tokens": prompt,
                "input_tokens_details": ["cached_tokens": 0],
                "output_tokens": completion,
                "output_tokens_details": ["reasoning_tokens": 0],
                "total_tokens": prompt + completion,
            ]
        }
        return out
    }

    private func appendText(_ text: String) -> [Data] {
        var out: [Data] = []
        let index: Int
        if let existing = messageItemIndex {
            index = existing
        } else {
            index = items.count
            messageItemIndex = index
            let id = "msg_\(UUID().uuidString.lowercased().prefix(20))"
            items.append(.message(id: id, index: index, text: ""))
            out.append(event("response.output_item.added", [
                "output_index": index,
                "item": [
                    "type": "message", "id": id, "status": "in_progress",
                    "role": "assistant", "content": [],
                ],
            ]))
        }
        guard case .message(let id, _, let existingText) = items[index] else { return out }
        items[index] = .message(id: id, index: index, text: existingText + text)
        out.append(event("response.output_text.delta", [
            "item_id": id, "output_index": index, "content_index": 0, "delta": text,
        ]))
        return out
    }

    private func appendReasoning(_ text: String) -> [Data] {
        var out: [Data] = []
        let index: Int
        if let existing = reasoningItemIndex {
            index = existing
        } else {
            index = items.count
            reasoningItemIndex = index
            let id = "rs_\(UUID().uuidString.lowercased().prefix(20))"
            items.append(.reasoning(id: id, index: index, text: ""))
            out.append(event("response.output_item.added", [
                "output_index": index,
                "item": ["type": "reasoning", "id": id, "summary": []],
            ]))
            out.append(event("response.reasoning_summary_part.added", [
                "item_id": id, "output_index": index, "summary_index": 0,
                "part": ["type": "summary_text", "text": ""],
            ]))
        }
        guard case .reasoning(let id, _, let existingText) = items[index] else { return out }
        items[index] = .reasoning(id: id, index: index, text: existingText + text)
        out.append(event("response.reasoning_summary_text.delta", [
            "item_id": id, "output_index": index, "summary_index": 0, "delta": text,
        ]))
        return out
    }

    private func appendToolCall(_ call: [String: Any]) -> [Data] {
        var out: [Data] = []
        let chatIndex = call["index"] as? Int ?? 0
        let index: Int
        if let existing = toolItemsByChatIndex[chatIndex] {
            index = existing
        } else {
            index = items.count
            toolItemsByChatIndex[chatIndex] = index
            callCounter += 1
            let id = "fc_\(responseID.suffix(8))_\(callCounter)"
            items.append(.functionCall(id: id, index: index, callID: "", name: "", arguments: ""))
            out.append(event("response.output_item.added", [
                "output_index": index,
                "item": [
                    "type": "function_call", "id": id, "status": "in_progress",
                    "call_id": "", "name": "", "arguments": "",
                ],
            ]))
        }
        guard case .functionCall(let id, _, var callID, var name, var arguments) = items[index]
        else { return out }
        if let wireID = call["id"] as? String, !wireID.isEmpty { callID = wireID }
        if let function = call["function"] as? [String: Any] {
            if let wireName = function["name"] as? String, !wireName.isEmpty { name = wireName }
            if let fragment = function["arguments"] as? String { arguments += fragment }
        }
        items[index] = .functionCall(
            id: id, index: index, callID: callID, name: name, arguments: arguments
        )
        return out
    }

    /// Closes every open item and emits the terminal `response.completed`. A backend that
    /// never sent a call id gets one synthesized here — Codex round-trips the id into the
    /// next turn's `function_call_output`, so it must exist and be unique within the response.
    private func close() -> [Data] {
        guard !finished else { return [] }
        finished = true
        var out: [Data] = []

        for (position, item) in items.enumerated() {
            if case .functionCall(let id, let index, let callID, let name, let arguments) = item,
               callID.isEmpty {
                items[position] = .functionCall(
                    id: id, index: index, callID: "call_\(responseID.suffix(6))_\(position)",
                    name: name, arguments: arguments
                )
            }
        }
        for item in items {
            let index: Int
            switch item {
            case .message(_, let itemIndex, _),
                 .reasoning(_, let itemIndex, _),
                 .functionCall(_, let itemIndex, _, _, _):
                index = itemIndex
            }
            out.append(event("response.output_item.done", [
                "output_index": index, "item": itemJSON(item),
            ]))
        }
        out.append(event("response.completed", [
            "response": responseObject(status: "completed"),
        ]))
        out.append(GatewayAPI.sseDone)
        return out
    }

    /// The terminal failure event, for a backend that died mid-stream or a model that never
    /// came up. Codex surfaces the message verbatim, so it should read like a sentence.
    public func failure(message: String) -> [Data] {
        guard !finished else { return [] }
        finished = true
        return [
            event("response.failed", [
                "response": responseObject(
                    status: "failed",
                    error: ["code": "silicon_gateway", "message": message]
                ),
            ]),
            GatewayAPI.sseDone,
        ]
    }

    /// The assembled non-streaming response body, for the rare `stream: false` caller.
    public func completedResponseBody() -> Data {
        (try? JSONSerialization.data(
            withJSONObject: responseObject(status: "completed")
        )) ?? Data("{}".utf8)
    }
}

import Foundation
import Testing
@testable import SiliconControl

@Suite("Gateway thinking control")
struct GatewayThinkingTests {

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @Test("llama.cpp dialect is stripped and hoisted for the node")
    func nodeHoistsNestedForm() {
        let body = try! JSONSerialization.data(withJSONObject: [
            "model": "m", "chat_template_kwargs": ["enable_thinking": false],
        ])
        let out = json(GatewayAPI.normalizingThinking(inBody: body, forNode: true))
        #expect(out["enable_thinking"] as? Bool == false)
        #expect(out["chat_template_kwargs"] == nil)
    }

    @Test("top-level form is nested for llama.cpp")
    func localNestsTopLevelForm() {
        let body = try! JSONSerialization.data(withJSONObject: [
            "model": "m", "enable_thinking": false,
        ])
        let out = json(GatewayAPI.normalizingThinking(inBody: body, forNode: false))
        let kwargs = out["chat_template_kwargs"] as? [String: Any]
        #expect(kwargs?["enable_thinking"] as? Bool == false)
        #expect(out["enable_thinking"] == nil)
    }

    @Test("no preference leaves the body alone (local)")
    func absentPreferenceUntouchedLocal() {
        let body = try! JSONSerialization.data(withJSONObject: [
            "model": "m", "messages": [["role": "user", "content": "hi"]],
        ])
        let out = json(GatewayAPI.normalizingThinking(inBody: body, forNode: false))
        #expect(out["chat_template_kwargs"] == nil)
        #expect(out["enable_thinking"] == nil)
        #expect((out["messages"] as? [[String: Any]])?.count == 1)
    }

    @Test("node strips foreign kwargs even without a thinking preference")
    func nodeStripsForeignKwargs() {
        let body = try! JSONSerialization.data(withJSONObject: [
            "model": "m", "chat_template_kwargs": ["some_flag": true],
        ])
        let out = json(GatewayAPI.normalizingThinking(inBody: body, forNode: true))
        #expect(out["chat_template_kwargs"] == nil)
        #expect(out["enable_thinking"] == nil)
    }

    @Test("top-level wins when both spellings disagree")
    func topLevelWins() {
        let body = try! JSONSerialization.data(withJSONObject: [
            "model": "m", "enable_thinking": true,
            "chat_template_kwargs": ["enable_thinking": false],
        ])
        let out = json(GatewayAPI.normalizingThinking(inBody: body, forNode: true))
        #expect(out["enable_thinking"] as? Bool == true)
    }
}

@Suite("Gateway empty-content diagnostics")
struct GatewayWarningTests {

    @Test("reasoning that ate the budget is diagnosed")
    func reasoningBurn() {
        let warning = GatewayAPI.emptyContentWarning(
            content: "", reasoningChars: 12_000, finishReason: "length"
        )
        #expect(warning?.contains("enable_thinking") == true)
    }

    @Test("plain truncation before content is diagnosed")
    func lengthWithoutReasoning() {
        let warning = GatewayAPI.emptyContentWarning(
            content: "", reasoningChars: 0, finishReason: "length"
        )
        #expect(warning?.contains("max_tokens") == true)
    }

    @Test("a healthy answer raises nothing")
    func healthyAnswer() {
        #expect(GatewayAPI.emptyContentWarning(
            content: "hello", reasoningChars: 500, finishReason: "stop"
        ) == nil)
        #expect(GatewayAPI.emptyContentWarning(
            content: "", reasoningChars: 0, finishReason: "stop"
        ) == nil)
    }

    @Test("buffered responses are inspected and annotated")
    func bufferedInspection() throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "choices": [[
                "finish_reason": "length",
                "message": ["role": "assistant", "content": "",
                            "reasoning_content": "hmm..."],
            ]],
        ])
        let warning = try #require(GatewayAPI.emptyContentWarning(inResponseBody: response))
        let annotated = GatewayAPI.attachingWarning(
            toResponseBody: response, warning: warning
        )
        let out = try JSONSerialization.jsonObject(with: annotated) as? [String: Any]
        let silicon = out?["silicon"] as? [String: Any]
        #expect((silicon?["warning"] as? String)?.isEmpty == false)
    }

    @Test("the stream audit hears deltas, usage, and the diagnosis")
    func streamAudit() {
        let audit = GatewayStreamAudit()
        audit.feed(payload: #"{"choices":[{"delta":{"reasoning_content":"thinking hard"}}]}"#)
        audit.feed(payload: #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#)
        audit.feed(payload: #"{"choices":[],"usage":{"prompt_tokens":40,"completion_tokens":900}}"#)
        audit.feed(payload: "[DONE]")
        #expect(audit.contentChars == 0)
        #expect(audit.reasoningChars > 0)
        #expect(audit.promptTokens == 40)
        #expect(audit.outputTokens == 900)
        #expect(audit.warning != nil)

        let healthy = GatewayStreamAudit()
        healthy.feed(payload: #"{"choices":[{"delta":{"content":"An answer"}}]}"#)
        healthy.feed(payload: #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        #expect(healthy.warning == nil)
        #expect(healthy.responsePreview == "An answer")
    }
}

@Suite("Gateway wait budget")
struct GatewayWaitTests {

    @Test("header parsing clamps and defaults")
    func headerParsing() {
        #expect(GatewayAPI.waitBudget(fromHeader: nil) == 0)
        #expect(GatewayAPI.waitBudget(fromHeader: "abc") == 0)
        #expect(GatewayAPI.waitBudget(fromHeader: "-5") == 0)
        #expect(GatewayAPI.waitBudget(fromHeader: "180") == 180)
        #expect(GatewayAPI.waitBudget(fromHeader: " 240 ") == 240)
        #expect(GatewayAPI.waitBudget(fromHeader: "9999") == 600)
    }
}

@Suite("Gateway prompt preview")
struct GatewayPreviewTests {

    @Test("the last user message leads, truncated, with a total count")
    func lastUserMessage() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "m",
            "messages": [
                ["role": "system", "content": "be brief"],
                ["role": "user", "content": "first question"],
                ["role": "assistant", "content": "first answer"],
                ["role": "user", "content": String(repeating: "x", count: 400)],
            ],
        ])
        let (preview, chars) = GatewayAPI.promptPreview(inBody: body)
        #expect(preview?.count == 150)
        #expect(preview?.allSatisfy { $0 == "x" } == true)
        #expect(chars == "be brief".count + "first question".count
                + "first answer".count + 400)
    }
}

@Suite("Gateway models silicon block")
struct GatewayModelBlockTests {

    @Test("the new fleet fields render when present and vanish when absent")
    func extendedFields() throws {
        let rich = GatewayAPI.Model(
            id: "node/box/m", displayName: "M", where_: "box",
            thinkingControls: ["enable_thinking"], tokensPerSecond: 43.21,
            pendingRequests: 2, queueDepth: 1
        )
        let plain = GatewayAPI.Model(id: "local/x", displayName: "X", where_: "This Mac")
        let listed = try JSONSerialization.jsonObject(
            with: GatewayAPI.modelsJSON([rich, plain])
        ) as? [String: Any]
        let data = listed?["data"] as? [[String: Any]] ?? []
        let richBlock = data.first { ($0["id"] as? String) == "node/box/m" }?["silicon"]
            as? [String: Any]
        #expect(richBlock?["thinkingControls"] as? [String] == ["enable_thinking"])
        #expect(richBlock?["tokensPerSecond"] as? Double == 43.2)
        #expect(richBlock?["pendingRequests"] as? Int == 2)
        #expect(richBlock?["queueDepth"] as? Int == 1)
        let plainBlock = data.first { ($0["id"] as? String) == "local/x" }?["silicon"]
            as? [String: Any]
        #expect(plainBlock?["thinkingControls"] == nil)
        #expect(plainBlock?["tokensPerSecond"] == nil)
    }
}

@Suite("Gateway discovery file")
struct GatewayDiscoveryTests {

    @Test("write, read, liveness, remove")
    func lifecycle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gwdisc-\(UUID().uuidString)")
        GatewayDiscovery.write(
            port: 51_349, pid: ProcessInfo.processInfo.processIdentifier,
            version: "1.2.3", directory: directory
        )
        let data = try Data(contentsOf: GatewayDiscovery.fileURL(directory: directory))
        let payload = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(payload["port"] as? Int == 51_349)
        #expect(payload["base_url"] as? String == "http://127.0.0.1:51349/v1")
        #expect(GatewayDiscovery.isAlive(payload))

        var dead = payload
        dead["pid"] = 99_999_999
        #expect(!GatewayDiscovery.isAlive(dead))

        GatewayDiscovery.remove(directory: directory)
        #expect(!FileManager.default.fileExists(
            atPath: GatewayDiscovery.fileURL(directory: directory).path
        ))
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Gateway ledger")
struct GatewayLedgerTests {

    @Test("a request's life is recorded and aggregated")
    func lifecycle() async {
        let ledger = GatewayLedger(directory: nil, previews: true)
        let id = await ledger.begin(
            endpoint: "chat", modelID: "local/x", stream: true,
            promptChars: 900, promptPreview: "what is up"
        )
        #expect(await ledger.inFlight(modelID: "local/x") == 1)
        await ledger.noteEnsured(id, backendModel: "x")
        await ledger.finish(
            id, ok: true, responsePreview: "not much",
            promptTokens: 30, outputTokens: 500
        )
        let snapshot = await ledger.snapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot[0].ok == true)
        #expect(snapshot[0].promptPreview == "what is up")
        #expect(snapshot[0].responsePreview == "not much")
        #expect(await ledger.inFlight(modelID: "local/x") == 0)
        let stats = await ledger.stats()
        #expect(stats["local/x"]?.requests == 1)
        #expect(stats["local/x"]?.failures == 0)
    }

    @Test("previews off means no message content on record")
    func previewsOff() async {
        let ledger = GatewayLedger(directory: nil, previews: false)
        let id = await ledger.begin(
            endpoint: "chat", modelID: "local/x", stream: false,
            promptChars: 10, promptPreview: "secret"
        )
        await ledger.finish(id, ok: true, responsePreview: "also secret")
        let entry = await ledger.snapshot()[0]
        #expect(entry.promptPreview == nil)
        #expect(entry.responsePreview == nil)
        #expect(entry.promptChars == 10)
    }

    @Test("completed entries survive a restart through the JSONL")
    func persistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString)")
        let first = GatewayLedger(directory: directory, previews: true)
        let id = await first.begin(
            endpoint: "chat", modelID: "node/box/m", stream: true,
            promptChars: 5, promptPreview: "hi"
        )
        await first.finish(id, ok: true, promptTokens: 10, outputTokens: 200)
        let inFlight = await first.begin(
            endpoint: "chat", modelID: "node/box/m", stream: true,
            promptChars: 5, promptPreview: "never finished"
        )
        _ = inFlight

        let second = GatewayLedger(directory: directory, previews: true)
        let restored = await second.snapshot()
        #expect(restored.count == 1)
        #expect(restored[0].modelID == "node/box/m")
        #expect(restored[0].ok == true)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("the in-memory window stays bounded")
    func bounded() async {
        let ledger = GatewayLedger(directory: nil, previews: true, keep: 5)
        for index in 0..<12 {
            let id = await ledger.begin(
                endpoint: "chat", modelID: "local/x", stream: false,
                promptChars: index, promptPreview: nil
            )
            await ledger.finish(id, ok: true)
        }
        #expect(await ledger.snapshot().count == 5)
    }

    @Test("generation rate needs honest numbers")
    func rateRules() {
        var entry = GatewayLedgerEntry(
            id: "e", startedAt: Date(), endpoint: "chat", modelID: "m",
            backendModel: nil, stream: true, promptChars: 0,
            promptPreview: nil, responsePreview: nil,
            promptTokens: nil, outputTokens: 480,
            ensureMs: 2000, totalMs: 10_000, ok: true, detail: nil, warning: nil
        )
        #expect(entry.tokensPerSecond == 60)
        entry.outputTokens = 4
        #expect(entry.tokensPerSecond == nil)
        entry.outputTokens = 480
        entry.totalMs = 2200
        #expect(entry.tokensPerSecond == nil)
    }
}
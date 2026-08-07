import Foundation
import SiliconCore

/// Streams chat completions from an OpenAI-compatible endpoint over server-sent events.
///
/// Both `llama-server` and `mlx_lm.server` speak this protocol, which is what lets the runtime
/// abstraction stay as thin as it is.
struct OpenAIChatClient: Sendable {

    let endpoint: URL
    private let session: URLSession

    init(endpoint: URL) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        // A long prompt on a slow model can take minutes before the first token; the default
        // 60-second timeout would abort a perfectly healthy generation.
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: configuration)
    }

    func stream(_ request: ChatRequest) throws -> AsyncThrowingStream<ChatEvent, any Error> {
        var urlRequest = URLRequest(url: endpoint.appendingPathComponent("v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(WireChatRequest(request))

        let session = self.session
        // Capturing the mutable `urlRequest` directly would let the task race with further
        // mutation on this side; freeze it first.
        let finalRequest = urlRequest
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Started before the request goes out. Capturing it after `bytes(for:)` returns
                // measures nothing: llama.cpp withholds the SSE response headers until it has a
                // first token to send, so the interval collapsed to zero and every reported
                // time-to-first-token was 0.00s.
                let startedAt = Date()
                do {
                    let (bytes, response) = try await session.bytes(for: finalRequest)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        throw RuntimeError.launchFailed("Chat endpoint returned HTTP \(code)")
                    }

                    var metrics = GenerationMetrics()
                    var firstTokenAt: Date?
                    let decoder = JSONDecoder()

                    // SSE frames are line-oriented, so iterating lines is both correct and
                    // cheap here — unlike a bulk download, the volume is tiny.
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? decoder.decode(WireStreamChunk.self, from: data)
                        else { continue }

                        if let delta = chunk.choices?.first?.delta {
                            if let reasoning = delta.reasoning_content, !reasoning.isEmpty {
                                // Reasoning is still the model producing output, so it stops the
                                // latency clock — a reasoning model is not "thinking silently"
                                // from the user's point of view.
                                if firstTokenAt == nil { firstTokenAt = Date() }
                                continuation.yield(.reasoningToken(reasoning))
                            }
                            if let content = delta.content, !content.isEmpty {
                                if firstTokenAt == nil { firstTokenAt = Date() }
                                continuation.yield(.token(content))
                            }
                        }

                        if let usage = chunk.usage {
                            metrics.promptTokens = usage.prompt_tokens ?? metrics.promptTokens
                            metrics.generatedTokens = usage.completion_tokens ?? metrics.generatedTokens
                        }
                        // Prefer the server's own timings: they measure the model, not the
                        // network and JSON decoding on this side.
                        if let timings = chunk.timings {
                            metrics.prefillTokensPerSecond =
                                timings.prompt_per_second ?? metrics.prefillTokensPerSecond
                            metrics.generationTokensPerSecond =
                                timings.predicted_per_second ?? metrics.generationTokensPerSecond
                            metrics.promptTokens = timings.prompt_n ?? metrics.promptTokens
                            metrics.generatedTokens = timings.predicted_n ?? metrics.generatedTokens
                        }
                    }

                    metrics.timeToFirstToken =
                        (firstTokenAt ?? Date()).timeIntervalSince(startedAt)
                    if metrics.generationTokensPerSecond == 0, let firstTokenAt,
                       metrics.generatedTokens > 0 {
                        let elapsed = Date().timeIntervalSince(firstTokenAt)
                        if elapsed > 0 {
                            metrics.generationTokensPerSecond =
                                Double(metrics.generatedTokens) / elapsed
                        }
                    }

                    continuation.yield(.finished(metrics))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Polls `/health` until the model has finished loading.
    func waitUntilReady(timeout: TimeInterval, isCancelled: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let healthURL = endpoint.appendingPathComponent("health")

        while Date() < deadline {
            if isCancelled() { return false }
            var request = URLRequest(url: healthURL)
            request.timeoutInterval = 2
            if let (_, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse {
                // 200 means loaded and ready. 503 means still loading, which is expected while
                // a 40 GB model is being read off disk.
                if http.statusCode == 200 { return true }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }
}

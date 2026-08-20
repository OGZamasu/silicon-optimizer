import Foundation

/// The vocabulary of the model gateway: one OpenAI-compatible facade over every model this
/// app can reach — each local install and every model a swarm peer offers — so external
/// harnesses (DeepSeek Harness, Codex) can list them all and call any one of them without
/// knowing which machine serves it or whether it is loaded yet.
///
/// Everything here is pure data and translation, kept apart from the server so tests can pin
/// the wire behavior without sockets.
public enum GatewayAPI {

    // MARK: - Model identity

    /// Where a gateway model actually runs.
    public enum Location: Sendable, Equatable {
        case local
        case node(String)
    }

    /// Gateway model ids are permanent once seen by a harness: DeepSeek Harness sessions and
    /// Codex threads store them, so the scheme — `local/<install id>` and
    /// `node/<peer slug>/<model>` — must never change shape.
    public static func modelID(local installID: String) -> String {
        "local/\(installID)"
    }

    public static func modelID(peerSlug: String, model: String) -> String {
        "node/\(peerSlug)/\(model)"
    }

    /// A peer's name as it appears inside a model id: lowercase, alphanumerics kept,
    /// everything else a dash. Mirrors the harness's swarm provider slugs so the two
    /// spellings of a peer never diverge.
    public static func peerSlug(_ name: String) -> String {
        String(name.lowercased().map { character in
            character.isLetter || character.isNumber ? character : "-"
        })
    }

    /// A parsed gateway model id. Node model names may themselves contain slashes
    /// (HF-style "org/model"), so only the first two separators structure the id.
    public enum ParsedModelID: Sendable, Equatable {
        case local(installID: String)
        case node(peerSlug: String, model: String)
    }

    /// One model, two spellings: nodes list the file ("qwen3_8_27b.ninfer") but serve the
    /// model under its display name ("qwen3.8-27b"). Comparing through this keeps the
    /// picker to one entry and stops a start-then-mismatch false alarm.
    public static func normalizedModelName(_ name: String) -> String {
        var trimmed = name.lowercased()
        for suffix in [".ninfer", ".gguf", ".safetensors", ".bin"]
        where trimmed.hasSuffix(suffix) {
            trimmed = String(trimmed.dropLast(suffix.count))
        }
        return trimmed.filter { $0.isLetter || $0.isNumber }
    }

    public static func modelNamesMatch(_ first: String, _ second: String) -> Bool {
        first == second || normalizedModelName(first) == normalizedModelName(second)
    }

    public static func parseModelID(_ id: String) -> ParsedModelID? {
        if id.hasPrefix("local/") {
            let install = String(id.dropFirst("local/".count))
            return install.isEmpty ? nil : .local(installID: install)
        }
        if id.hasPrefix("node/") {
            let rest = id.dropFirst("node/".count)
            guard let separator = rest.firstIndex(of: "/") else { return nil }
            let slug = String(rest[..<separator])
            let model = String(rest[rest.index(after: separator)...])
            guard !slug.isEmpty, !model.isEmpty else { return nil }
            return .node(peerSlug: slug, model: model)
        }
        return nil
    }

    // MARK: - Model listing

    /// One entry in `GET /v1/models`. The `silicon` extension block carries what the OpenAI
    /// shape cannot: a human name, where the model runs, its context, and whether picking it
    /// means a wait (load) or an instant answer (already serving).
    public struct Model: Sendable, Equatable {
        public var id: String
        public var displayName: String
        /// "This Mac" or the peer's real name — for pickers, not for routing.
        public var where_: String
        public var contextWindow: Int?
        /// True when a request to this model would be answered without a load.
        public var serving: Bool
        public var quantization: String?

        public init(
            id: String, displayName: String, where_: String,
            contextWindow: Int? = nil, serving: Bool = false, quantization: String? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.where_ = where_
            self.contextWindow = contextWindow
            self.serving = serving
            self.quantization = quantization
        }
    }

    /// Renders the OpenAI-style model list. Serving models lead so a picker's first
    /// suggestion is the one that answers immediately.
    public static func modelsJSON(_ models: [Model]) -> Data {
        let ordered = models.sorted { first, second in
            if first.serving != second.serving { return first.serving }
            return first.id < second.id
        }
        let data = ordered.map { model -> [String: Any] in
            var silicon: [String: Any] = [
                "name": model.displayName,
                "where": model.where_,
                "serving": model.serving,
            ]
            if let context = model.contextWindow { silicon["contextWindow"] = context }
            if let quantization = model.quantization { silicon["quantization"] = quantization }
            return [
                "id": model.id,
                "object": "model",
                "created": 0,
                "owned_by": "silicon-optimizer",
                "silicon": silicon,
            ]
        }
        let payload: [String: Any] = ["object": "list", "data": data]
        return (try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        )) ?? Data("{\"object\":\"list\",\"data\":[]}".utf8)
    }

    // MARK: - Server-sent events

    /// One SSE frame. Responses-API events carry their type on an `event:` line as well as
    /// inside the JSON; chat completions use bare `data:` lines. Comments are the legal
    /// keep-alive both harnesses' parsers ignore but count as transport activity.
    public static func sseData(_ json: Data, event: String? = nil) -> Data {
        var frame = Data()
        if let event {
            frame.append(Data("event: \(event)\n".utf8))
        }
        frame.append(Data("data: ".utf8))
        frame.append(json)
        frame.append(Data("\n\n".utf8))
        return frame
    }

    public static func sseComment(_ text: String) -> Data {
        // A comment must be one line; anything else would break framing.
        let clean = text.replacingOccurrences(of: "\n", with: " ")
        return Data(": \(clean)\n\n".utf8)
    }

    public static let sseDone = Data("data: [DONE]\n\n".utf8)

    /// The in-stream error shape OpenAI-compatible servers use once the SSE head is out and
    /// a plain HTTP status is no longer possible.
    public static func sseErrorPayload(_ message: String) -> Data {
        let payload: [String: Any] = ["error": ["message": message, "type": "silicon_gateway"]]
        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return sseData(json)
    }

    // MARK: - Responses API → chat completions (request)

    public enum TranslationError: Error, LocalizedError {
        case notJSON
        case missingModel

        public var errorDescription: String? {
            switch self {
            case .notJSON: "The request body is not a JSON object."
            case .missingModel: "The request names no model."
            }
        }
    }

    /// Translates one Responses-API request (what Codex sends — it dropped chat-completions
    /// support in early 2026) into the chat-completions request every backend here actually
    /// speaks. Returns the backend body plus whether the caller asked for a stream.
    ///
    /// Item mapping: `message` keeps its role (developer becomes system), `function_call`
    /// returns as an assistant tool call, `function_call_output` becomes a tool message, and
    /// `reasoning` items are dropped — a chat backend cannot replay another model's thoughts.
    /// Unknown item types are skipped rather than fatal: Codex adds vocabulary faster than
    /// this file will change, and a lost annotation is better than a dead chat tab.
    public static func chatRequestBody(
        fromResponsesRequest body: Data, backendModel: String
    ) throws -> (body: Data, stream: Bool) {
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { throw TranslationError.notJSON }

        var messages: [[String: Any]] = []
        if let instructions = request["instructions"] as? String, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }

        let input = request["input"] as? [[String: Any]] ?? []
        for item in input {
            // A bare string item is legal in the spec; Codex always sends typed items.
            guard let type = item["type"] as? String else { continue }
            switch type {
            case "message":
                let role = item["role"] as? String ?? "user"
                let text = messageText(item["content"])
                messages.append([
                    "role": role == "developer" ? "system" : role,
                    "content": text,
                ])
            case "function_call", "custom_tool_call":
                let arguments = item["arguments"] as? String
                    ?? item["input"] as? String ?? "{}"
                messages.append([
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [[
                        "id": item["call_id"] as? String ?? item["id"] as? String ?? "call_0",
                        "type": "function",
                        "function": [
                            "name": item["name"] as? String ?? "tool",
                            "arguments": arguments,
                        ],
                    ]],
                ])
            case "function_call_output", "custom_tool_call_output":
                messages.append([
                    "role": "tool",
                    "tool_call_id": item["call_id"] as? String ?? "call_0",
                    "content": outputText(item["output"]),
                ])
            default:
                // reasoning, local_shell_call, web_search_call, …: nothing a chat backend
                // can honor. Skipped, not fatal.
                continue
            }
        }

        var chat: [String: Any] = [
            "model": backendModel,
            "messages": messages,
        ]

        // Responses tools are flat; chat tools nest under "function". Built-in tool types
        // (web_search, local_shell) have no chat equivalent and are dropped — Codex only
        // sends them when configured to, and a backend that never saw the tool simply
        // never calls it.
        let tools = (request["tools"] as? [[String: Any]] ?? []).compactMap {
            tool -> [String: Any]? in
            let type = tool["type"] as? String
            guard type == "function" || type == "custom", let name = tool["name"] as? String
            else { return nil }
            var function: [String: Any] = ["name": name]
            if let description = tool["description"] as? String {
                function["description"] = description
            }
            if let parameters = tool["parameters"], !(parameters is NSNull) {
                function["parameters"] = parameters
            } else if type == "custom" {
                // Freeform tools carry raw text; a chat backend needs *a* schema, and one
                // string argument is the honest translation.
                function["parameters"] = [
                    "type": "object",
                    "properties": ["input": ["type": "string"]],
                    "required": ["input"],
                ]
            }
            return ["type": "function", "function": function]
        }
        if !tools.isEmpty {
            chat["tools"] = tools
            if let choice = request["tool_choice"] as? String { chat["tool_choice"] = choice }
        }

        if let maxTokens = request["max_output_tokens"] as? Int { chat["max_tokens"] = maxTokens }
        if let temperature = request["temperature"] { chat["temperature"] = temperature }

        let stream = request["stream"] as? Bool ?? false
        chat["stream"] = stream
        if stream {
            chat["stream_options"] = ["include_usage": true]
        }

        let encoded = try JSONSerialization.data(withJSONObject: chat)
        return (encoded, stream)
    }

    /// Flattens Responses message content — an array of typed text parts or a bare
    /// string — into the plain string chat messages carry. Image parts are dropped;
    /// this route is text-only.
    private static func messageText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { part -> String? in
            let type = part["type"] as? String
            guard type == "input_text" || type == "output_text" || type == "text"
            else { return nil }
            return part["text"] as? String
        }.joined()
    }

    /// A function result's output: a string in Codex's dialect, occasionally a typed
    /// content object in the wider spec.
    private static func outputText(_ output: Any?) -> String {
        if let text = output as? String { return text }
        if let object = output as? [String: Any] {
            if let text = object["text"] as? String { return text }
            if let parts = object["content"] { return messageText(parts) }
        }
        if let parts = output as? [[String: Any]] { return messageText(parts) }
        return ""
    }

    // MARK: - Model name extraction

    /// The one field the gateway needs from any inbound request before routing it.
    public static func requestedModel(inBody body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return json["model"] as? String
    }

    /// Rewrites the `model` field so the backend sees its own spelling of the name —
    /// engines 404 requests for models they know by another string.
    public static func rewritingModel(inBody body: Data, to model: String) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else { return body }
        json["model"] = model
        return (try? JSONSerialization.data(withJSONObject: json)) ?? body
    }

    /// Whether a chat-completions request asked for a stream.
    public static func wantsStream(body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return false }
        return json["stream"] as? Bool ?? false
    }

    // MARK: - Media serving

    /// File types the chat surfaces may embed. Anything else is refused — the media
    /// endpoint exists to play results, not to read files.
    public static let mediaContentTypes: [String: String] = [
        "mp4": "video/mp4", "mov": "video/quicktime", "webm": "video/webm",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "webp": "image/webp", "gif": "image/gif",
        "wav": "audio/wav", "mp3": "audio/mpeg", "m4a": "audio/mp4",
        "aiff": "audio/aiff", "flac": "audio/flac",
        "glb": "model/gltf-binary", "obj": "text/plain",
    ]

    /// Whether a path may be served or revealed: a real file, a known media type, and
    /// inside one of the app's own output folders. Symlinks are resolved first so a link
    /// inside an allowed root cannot reach outside it.
    public static func isAllowedMediaPath(_ path: String, roots: [String]) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard mediaContentTypes[resolved.pathExtension.lowercased()] != nil else {
            return false
        }
        let canonical = resolved.path
        return roots.contains { root in
            let cleanRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            return canonical == cleanRoot
                || canonical.hasPrefix(cleanRoot.hasSuffix("/") ? cleanRoot : cleanRoot + "/")
        }
    }

    /// One parsed `Range: bytes=` header — WebKit probes media with `bytes=0-1` and then
    /// seeks, so a media endpoint without ranges plays nothing.
    public static func byteRange(header: String?, fileSize: Int) -> Range<Int>? {
        guard let header, header.hasPrefix("bytes="), fileSize > 0 else { return nil }
        let spec = header.dropFirst("bytes=".count)
        // Only the first range of a multi-range request; players never send more.
        guard let piece = spec.split(separator: ",").first,
              let dash = piece.firstIndex(of: "-") else { return nil }
        let startText = piece[..<dash].trimmingCharacters(in: .whitespaces)
        let endText = piece[piece.index(after: dash)...].trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            // Suffix form: the last N bytes.
            guard let suffix = Int(endText), suffix > 0 else { return nil }
            return max(0, fileSize - suffix)..<fileSize
        }
        guard let start = Int(startText), start >= 0, start < fileSize else { return nil }
        let end = Int(endText).map { min($0, fileSize - 1) } ?? (fileSize - 1)
        guard end >= start else { return nil }
        return start..<(end + 1)
    }

    /// Media file paths mentioned in a piece of text — how the chat surfaces find
    /// something playable in a tool result or an assistant message.
    ///
    /// Path segments may contain single spaces ("Movies/Silicon Optimizer" is the
    /// default output folder), which is why this is not a simple no-whitespace match;
    /// the lookbehind keeps it from biting into URLs.
    public static let mediaPathPattern =
        #"(?<![:/\w])(/(?:[\w.\-]+(?: [\w.\-]+)*/)*[\w.\-]+(?: [\w.\-]+)*"#
        + #"\.(?i:mp4|mov|webm|png|jpe?g|webp|gif|wav|mp3|m4a|aiff|flac|glb|obj))\b"#

    public static func mediaPaths(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: mediaPathPattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: 1), in: text) else { return nil }
            let path = String(text[matchRange])
            return seen.insert(path).inserted ? path : nil
        }
    }
}

import Foundation
import SiliconCore

public struct ChatMessage: Sendable, Codable, Hashable, Identifiable {
    public enum Role: String, Sendable, Codable {
        case system, user, assistant, tool
    }

    public var id: UUID
    public var role: Role
    public var content: String
    /// Base64 image data URLs, for vision models.
    public var images: [String]
    /// Separated reasoning output, where the model emits it distinctly from the answer.
    public var reasoning: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(), role: Role, content: String,
        images: [String] = [], reasoning: String? = nil, createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.images = images
        self.reasoning = reasoning
        self.createdAt = createdAt
    }
}

public struct ChatRequest: Sendable {
    public var messages: [ChatMessage]
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int?
    public var stop: [String]
    /// Effort hint for models that expose one, such as gpt-oss.
    public var reasoningEffort: String?

    public init(
        messages: [ChatMessage], temperature: Double = 0.7, topP: Double = 0.95,
        maxTokens: Int? = nil, stop: [String] = [], reasoningEffort: String? = nil
    ) {
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.stop = stop
        self.reasoningEffort = reasoningEffort
    }
}

/// One event from a streaming completion.
public enum ChatEvent: Sendable {
    case token(String)
    case reasoningToken(String)
    case finished(GenerationMetrics)
}

// MARK: - Wire format

/// The subset of the OpenAI chat schema every runtime here implements.
struct WireChatRequest: Encodable {
    var messages: [WireMessage]
    var temperature: Double
    var top_p: Double
    var max_tokens: Int?
    var stop: [String]?
    var stream: Bool
    var stream_options: StreamOptions?
    var reasoning_effort: String?

    struct StreamOptions: Encodable {
        var include_usage: Bool
    }

    struct WireMessage: Encodable {
        var role: String
        /// Either a plain string or an array of content parts when images are attached — the
        /// OpenAI schema overloads this field, so it is encoded manually.
        var content: Content

        enum Content: Encodable {
            case text(String)
            case parts([Part])

            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let value): try container.encode(value)
                case .parts(let parts): try container.encode(parts)
                }
            }
        }

        struct Part: Encodable {
            var type: String
            var text: String?
            var image_url: ImageURL?

            struct ImageURL: Encodable { var url: String }

            static func text(_ value: String) -> Part {
                Part(type: "text", text: value, image_url: nil)
            }
            static func image(_ dataURL: String) -> Part {
                Part(type: "image_url", text: nil, image_url: ImageURL(url: dataURL))
            }
        }
    }

    init(_ request: ChatRequest) {
        self.messages = request.messages.map { message in
            if message.images.isEmpty {
                return WireMessage(role: message.role.rawValue, content: .text(message.content))
            }
            var parts: [WireMessage.Part] = [.text(message.content)]
            parts.append(contentsOf: message.images.map(WireMessage.Part.image))
            return WireMessage(role: message.role.rawValue, content: .parts(parts))
        }
        self.temperature = request.temperature
        self.top_p = request.topP
        self.max_tokens = request.maxTokens
        self.stop = request.stop.isEmpty ? nil : request.stop
        self.stream = true
        self.stream_options = StreamOptions(include_usage: true)
        self.reasoning_effort = request.reasoningEffort
    }
}

struct WireStreamChunk: Decodable {
    var choices: [Choice]?
    var usage: Usage?
    /// llama.cpp appends its own timing block to the final chunk.
    var timings: Timings?

    struct Choice: Decodable {
        var delta: Delta?
        var finish_reason: String?

        struct Delta: Decodable {
            var content: String?
            /// Some builds separate chain-of-thought into its own field.
            var reasoning_content: String?
        }
    }

    struct Usage: Decodable {
        var prompt_tokens: Int?
        var completion_tokens: Int?
    }

    struct Timings: Decodable {
        var prompt_n: Int?
        var prompt_ms: Double?
        var prompt_per_second: Double?
        var predicted_n: Int?
        var predicted_ms: Double?
        var predicted_per_second: Double?
    }
}

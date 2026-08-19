import Foundation

/// The "sharp" chat template for Qwen 3.5, 3.6 and 3.8.
///
/// It is a chat template, not a fine-tune: no weights change. What changes is the
/// system prompt the model sees, which tells it to lead with the answer and drop the
/// preamble, the restatement of the question and the filler transitions. The published
/// claim is fewer thinking tokens at the same or better accuracy — worth having on a
/// machine where every token is a second of your own hardware.
///
/// Kept as its own type because the file has to be fetched, kept somewhere stable, and
/// handed to llama-server as a path; a bare URL in the runtime would leave all three of
/// those unowned.
public enum SharpTemplate {

    public static let repository = "peculiar-ragdoll/Qwen-Sharp-Chat-Templates"
    public static let file = "chat_template.jinja"

    /// Where the downloaded template lives. Beside the app's own support files rather
    /// than inside a model folder: one copy serves every Qwen you load.
    public static var localURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiliconOptimizer/chat-templates/qwen-sharp.jinja")
    }

    public static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }

    /// Whether this model is one the template was written for.
    ///
    /// Applying it to something else is not a crash but a quiet quality regression —
    /// the template assumes Qwen's thinking blocks and tool-call grammar — so the app
    /// checks rather than trusting a global switch. `identifier` is a second name for
    /// the same model, such as its catalog id or the architecture from its GGUF header;
    /// either naming it is enough.
    public static func suits(modelName: String, identifier: String? = nil) -> Bool {
        names(modelName) || names(identifier ?? "")
    }

    private static func names(_ raw: String) -> Bool {
        let name = raw.lowercased()
        guard name.contains("qwen") else { return false }
        // The published targets. A version arrives written every way a filename can
        // write it — qwen3.5, qwen-3.5, qwen3_5, qwen35 — so each is spelled out.
        let versions = ["3.5", "3-5", "3_5", "35", "3.6", "3-6", "3_6", "36",
                        "3.8", "3-8", "3_8", "38"]
        return versions.contains {
            name.contains("qwen\($0)") || name.contains("qwen \($0)")
                || name.contains("qwen-\($0)")
        }
    }

    /// Fetches the template, replacing any previous copy.
    public static func download(
        session: URLSession = .shared, token: String? = nil
    ) async throws -> URL {
        let source = HuggingFaceClient.downloadURL(repository: repository, file: file)
        var request = URLRequest(url: source)
        request.timeoutInterval = 60
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else {
            throw TemplateError.unavailable
        }
        // A template that is not a template would break every load that used it, and
        // the failure would look like a model problem.
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("{%"), text.count > 200 else { throw TemplateError.notATemplate }

        let destination = localURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }

    public enum TemplateError: LocalizedError {
        case unavailable
        case notATemplate

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                "The sharp template could not be downloaded from Hugging Face."
            case .notATemplate:
                "What came back from Hugging Face was not a chat template."
            }
        }
    }
}

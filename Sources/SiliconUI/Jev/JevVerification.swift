import Foundation
import SiliconControl
import SiliconRuntime

// MARK: - What came of it

/// What verification decided about one local answer.
enum VerificationOutcome: Sendable, Equatable {
    /// Jev looked and found nothing. The local reply goes back as it is.
    case accepted
    /// A stronger model answered the same prompt, and this is what it said.
    case escalated(to: String, reply: String, reasons: [String], latency: TimeInterval)
    /// Something was flagged but not hard enough — or could not be acted on — to be worth
    /// another model's time. The local reply goes back with the reasons attached.
    case annotated(reasons: [String])
    /// Jev is off, this feature is off, there is no key, or the budget is spent. Nothing
    /// was sent and nothing was spent; the caller behaves exactly as it did before.
    case unavailable

    /// The three words the wire uses, or nil when nothing ran.
    var verdictName: String? {
        switch self {
        case .accepted: "accept"
        case .escalated: "escalate"
        case .annotated: "annotate"
        case .unavailable: nil
        }
    }

    var reasons: [String] {
        switch self {
        case .accepted, .unavailable: []
        case .escalated(_, _, let reasons, _): reasons
        case .annotated(let reasons): reasons
        }
    }

    var escalatedTo: String? {
        if case .escalated(let model, _, _, _) = self { return model }
        return nil
    }
}

enum JevVerificationError: Error, LocalizedError, Equatable {
    case escalationFailed(status: Int, detail: String)
    case escalationEmpty(model: String)

    var errorDescription: String? {
        switch self {
        case .escalationFailed(let status, let detail):
            "The escalation model answered HTTP \(status): \(detail)"
        case .escalationEmpty(let model):
            "\(model) returned an empty answer."
        }
    }
}

// MARK: - Running a prompt on a stronger model

/// Re-runs a prompt on any model the gateway can reach — a swarm node, a cloud provider, or
/// another model on this Mac.
///
/// It goes through this Mac's own loopback gateway rather than at a provider directly, and
/// that is the whole point: the gateway already knows how to start a node's engine, how to
/// hold a cloud provider's key, how to translate the thinking dialects, and it writes every
/// request to the activity ledger. An escalation is then visible on the Swarm page like any
/// other request instead of being a second, invisible network path.
struct GatewayEscalation: Sendable {

    var baseURL: URL
    var token: String
    /// A cold cloud model or a node that has to start an engine can take a while, and the
    /// gateway blocks until it is ready.
    var timeout: TimeInterval = 300
    var session: URLSession = .shared

    private struct Body: Encodable {
        var model: String
        var stream = false
        var max_tokens: Int
        var messages: [Message]

        struct Message: Encodable {
            var role: String
            var content: Content

            /// The OpenAI schema overloads `content`: a string, or an array of parts when
            /// there are images. Encoded by hand for the same reason the runtime does it.
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
            }
        }
    }

    private struct Reply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message?
        }
        var choices: [Choice]?
    }

    func run(
        modelID: String, messages: [ControlAPI.ChatRequest.Message], maxTokens: Int
    ) async throws -> String {
        let body = Body(
            model: modelID,
            max_tokens: maxTokens,
            messages: messages.map { message in
                guard !message.images.isEmpty else {
                    return Body.Message(role: message.role, content: .text(message.content))
                }
                var parts = [Body.Message.Part(
                    type: "text", text: message.content, image_url: nil
                )]
                parts += message.images.map {
                    Body.Message.Part(
                        type: "image_url", text: nil,
                        image_url: .init(url: $0)
                    )
                }
                return Body.Message(role: message.role, content: .parts(parts))
            }
        )

        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/chat/completions")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw JevVerificationError.escalationFailed(
                status: status,
                detail: String(decoding: data.prefix(512), as: UTF8.self)
            )
        }
        let decoded = try JSONDecoder().decode(Reply.self, from: data)
        let text = (decoded.choices?.first?.message?.content ?? "")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JevVerificationError.escalationEmpty(model: modelID)
        }
        return text
    }
}

// MARK: - The verifier

/// The prompt as it was actually sent, which is what an escalation has to re-run.
struct VerificationPrompt: Sendable {
    var messages: [ControlAPI.ChatRequest.Message]

    init(messages: [ControlAPI.ChatRequest.Message]) { self.messages = messages }

    /// The last thing the user said — what `answers_the_question` is about.
    var lastUserMessage: String {
        messages.last { $0.role == "user" }?.content
            ?? messages.last?.content ?? ""
    }

    var systemPrompt: String? {
        let joined = messages.filter { $0.role == "system" }
            .map(\.content).joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    /// Everything else the model could see: the earlier turns, and the fact that images
    /// were attached. Used when the caller does not supply a context of its own.
    var derivedContext: String? {
        var turns: [(role: String, content: String)] = []
        var trailingUserSeen = false
        for message in messages.reversed() {
            if message.role == "system" { continue }
            if !trailingUserSeen, message.role == "user" { trailingUserSeen = true; continue }
            turns.append((role: message.role, content: message.content))
        }
        return VerificationQuestions.context(
            priorTurns: turns.reversed(),
            imageCount: messages.reduce(0) { $0 + $1.images.count }
        )
    }
}

/// Verification as a value: four things it needs, all injected.
///
/// Injected rather than reached for, so every rule below can be exercised against a fake
/// gateway and a `JevService` pointed at a loopback double — no shared instance, no
/// Keychain, no real key, no real money. `AppModel.verify` builds the production one.
struct JevVerifier: Sendable {

    /// Whether Jev would answer for `.verification` right now. Cheap: no network, no
    /// Keychain prompt.
    var isAvailable: @Sendable () async -> Bool
    /// Asks the seven questions about one state.
    var ask: @Sendable (JSONContent) async throws -> ControlAPI.DecideResponse
    /// Which gateway model a flagged answer is re-run on, or nil for none.
    var escalationTarget: @Sendable () async -> String?
    /// Runs the prompt on that model and returns what it said.
    var escalate: @Sendable (String, [ControlAPI.ChatRequest.Message], Int) async throws -> String

    /// The most tokens an escalated run may generate.
    ///
    /// This feature's own ceiling, deliberately not the caller's. A caller that asked for
    /// 200 tokens and got a truncated answer would get the same truncation from a second
    /// model under the same limit, which is the one outcome escalation exists to avoid —
    /// and a hard number here is what stops one flagged answer becoming an open-ended bill
    /// on someone's cloud key.
    static let escalatedTokenCap = 2_048

    // MARK: Judging

    /// Jev's verdict on one answer, or nil when nothing was asked.
    ///
    /// Nil covers both "this feature is off" and "the request failed": in each case there
    /// is no verdict, and a verification feature that turned a TypeSafe outage into a
    /// failed chat would be worse than no verification at all. Verification is advice about
    /// an answer that already exists, so it never fails the answer.
    func judge(
        prompt: VerificationPrompt, reply: String, context: String?, truncated: Bool
    ) async -> VerificationVerdict? {
        guard await isAvailable() else { return nil }
        let state = VerificationQuestions.state(
            message: prompt.lastUserMessage,
            systemPrompt: prompt.systemPrompt,
            reply: reply,
            context: context ?? prompt.derivedContext
        )
        do {
            let answers = try VerificationAnswers(try await ask(state))
            return VerificationPolicy.verdict(answers, wasTruncated: truncated)
        } catch {
            return nil
        }
    }

    /// Judge, and — when the verdict says so and there is somewhere to send it — re-run the
    /// prompt on a stronger model and return that answer instead.
    ///
    /// At most one escalation, always. The second answer is verified too, because an owner
    /// reading "escalated to gpt-5.5" deserves to know if the stronger model also went
    /// wrong, but its verdict cannot cause a third run: a cascade that can re-enter itself
    /// is a loop with a credit card attached.
    func verify(
        prompt: VerificationPrompt, reply: String, context: String?, truncated: Bool
    ) async -> VerificationOutcome {
        guard let verdict = await judge(
            prompt: prompt, reply: reply, context: context, truncated: truncated
        ) else { return .unavailable }

        switch verdict {
        case .accept:
            return .accepted
        case .annotate(let reasons):
            return .annotated(reasons: reasons)
        case .escalate(let reasons):
            guard let target = await escalationTarget() else {
                // Nothing to escalate to. The reader still gets the reasons — which is the
                // difference between an answer that is merely suspect and one that looks
                // fine — and nothing is spent pretending otherwise.
                return .annotated(reasons: reasons + [Self.noTargetNote])
            }
            let startedAt = Date()
            let better: String
            do {
                better = try await escalate(
                    target, prompt.messages, Self.escalatedTokenCap
                )
            } catch {
                // The local answer is still the answer. A gateway that refused is a fact
                // about this Mac, not about the reply, so it is reported beside the
                // reasons rather than thrown at whoever asked a chat question.
                return .annotated(
                    reasons: reasons + [
                        "Could not re-run this on \(target): \(error.localizedDescription)",
                    ]
                )
            }
            let latency = Date().timeIntervalSince(startedAt)

            // The second look. Its verdict is reported, never acted on: no third rung.
            var finalReasons = reasons
            let second = await judge(
                prompt: prompt, reply: better, context: context,
                // The escalated run had this feature's own budget, not the caller's, and
                // the gateway does not hand back a finish reason here — so truncation is
                // not claimed for it either way.
                truncated: false
            )
            if let second, second != .accept {
                finalReasons.append(
                    "The stronger model's answer was flagged too: "
                    + second.reasons.joined(separator: " ")
                )
            }
            return .escalated(
                to: target, reply: better, reasons: finalReasons, latency: latency
            )
        }
    }

    static let noTargetNote =
        "No escalation model is set, and no node or cloud model is available to re-run it "
        + "on. Pick one in Settings → TypeSafe (Jev)."

    /// What a streaming caller says instead of escalating.
    ///
    /// Streams do not escalate, and the reason is that the tokens are already on the
    /// reader's screen. By the time the last one has been sent, the local answer *is* the
    /// answer: replacing it would mean blanking a message someone has been reading for
    /// thirty seconds, and appending a second full answer under it is not a verdict, it is
    /// a second answer. So the stream says what it found and what would have fixed it, and
    /// leaves the choice to whoever is reading. `POST /chat`, which returns one object and
    /// has shown nothing, escalates for real.
    static func streamSuggestion(target: String?) -> String {
        guard let target else { return noTargetNote }
        return "Send this again on \(target) for a stronger answer — or use POST /chat, "
            + "which re-runs flagged answers itself."
    }
}

// MARK: - The app's verifier

extension AppModel {

    /// Verifies one finished local answer, and escalates it when the policy says to.
    ///
    /// - Parameters:
    ///   - prompt: the request exactly as it was sent, because that is what an escalation
    ///     has to re-run.
    ///   - reply: what the local model said.
    ///   - context: anything else the caller wants judged against. Nil derives it from the
    ///     prompt's earlier turns and attachments.
    ///   - truncated: whether the token budget ended the answer. The caller reads it from
    ///     `GenerationMetrics.wasTruncated(budget:)` — the runtime's own `finish_reason` —
    ///     and Jev is never asked to guess at it.
    func verify(
        prompt: VerificationPrompt, reply: String, context: String? = nil, truncated: Bool
    ) async -> VerificationOutcome {
        await jevVerifier().verify(
            prompt: prompt, reply: reply, context: context, truncated: truncated
        )
    }

    /// The verdict alone, with no escalation — what the streaming paths use.
    func verifyWithoutEscalating(
        prompt: VerificationPrompt, reply: String, context: String? = nil, truncated: Bool
    ) async -> (verdict: VerificationVerdict, target: String?)? {
        let verifier = jevVerifier()
        guard let verdict = await verifier.judge(
            prompt: prompt, reply: reply, context: context, truncated: truncated
        ) else { return nil }
        // Resolved even though nothing is run, so the suggestion can name a model instead
        // of telling the reader to go and find one.
        guard case .escalate = verdict else { return (verdict, nil) }
        return (verdict, await verifier.escalationTarget())
    }

    /// The production wiring: the shared service, this Mac's own gateway.
    func jevVerifier() -> JevVerifier {
        let gateway = GatewayEscalation(
            baseURL: URL(string: "http://127.0.0.1:\(gatewayPort())")!,
            token: gatewayToken
        )
        return JevVerifier(
            isAvailable: {
                // Waited on rather than assumed: a request in the first milliseconds of
                // launch must not read as "no key" on a Mac that has one.
                await JevBootstrap.ready()
                return await JevService.shared.isAvailable(.verification)
            },
            ask: { state in try await VerificationQuestions.ask(state: state) },
            escalationTarget: { [weak self] in
                guard let self else { return nil }
                return await self.verificationEscalationTarget()
            },
            escalate: { modelID, messages, maxTokens in
                try await gateway.run(
                    modelID: modelID, messages: messages, maxTokens: maxTokens
                )
            }
        )
    }

    /// Which model a flagged answer is re-run on.
    ///
    /// The owner's pick wins, and is honoured even if the gateway cannot see it right now —
    /// a node that is asleep answers with its own error, which is a better thing to report
    /// than silently substituting a model they did not choose.
    ///
    /// Otherwise: a model a swarm node is already serving, then an enabled cloud model.
    /// Never a model on this Mac, however capable. Escalating to a local model would unload
    /// the one that just answered, in the middle of the request that answered with it —
    /// the machine is busy being the thing being verified.
    func verificationEscalationTarget() async -> String? {
        await JevBootstrap.ready()
        if let chosen = await JevService.shared.settings().verificationEscalationModel,
           !chosen.isEmpty {
            return chosen
        }
        // `gatewayServableModels()`, not `gatewayModels()`: the latter offers the virtual
        // `silicon/auto`, and "escalate to whatever routing picks" is not an escalation —
        // it is a coin toss that may land on the model that just answered.
        let models = await gatewayServableModels()
        func kind(_ id: String) -> GatewayAPI.ParsedModelID? { GatewayAPI.parseModelID(id) }

        if let serving = models.first(where: { model in
            guard case .node = kind(model.id) else { return false }
            return model.serving
        }) { return serving.id }

        if let cloud = models.first(where: {
            if case .cloud = kind($0.id) { return true }
            return false
        }) { return cloud.id }

        return nil
    }
}

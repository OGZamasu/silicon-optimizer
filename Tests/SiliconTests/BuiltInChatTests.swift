import Foundation
import Testing
@testable import SiliconRuntime
@testable import SiliconUI

/// The Chat tab's own engine (Settings → Chat → Built-in): the Mac answering from the loaded
/// model, one token at a time, into the conversation the question was asked in.
@Suite("Built-in chat", .redirectedConversationStore)
@MainActor
struct BuiltInChatTests {

    /// Switching to another thread mid-answer used to cut the reply short: every token after
    /// the switch was looked for in the thread now on screen, not found there, and dropped —
    /// and the truncated reply was what got saved.
    @Test func anAnswerKeepsGoingIntoItsOwnThreadWhenAnotherIsOpened() async throws {
        let model = AppModel(settings: .init())
        let runtime = ScriptedChatRuntime()
        model.newConversation()
        let asked = try #require(model.selectedConversationID)
        model.send("Tell me about kettles", images: [], to: runtime)
        try await until { await runtime.chats == 1 }

        await runtime.say("Kettles ", in: 0)
        try await until { model.reply(in: asked) == "Kettles " }
        model.newConversation()
        let other = try #require(model.selectedConversationID)
        #expect(other != asked)
        await runtime.say("boil water.", in: 0)
        await runtime.finish(0)
        try await until { !model.isGenerating }

        #expect(model.reply(in: asked) == "Kettles boil water.")
        #expect(model.conversations.first { $0.id == other }?.messages.isEmpty == true)
    }

    /// Polls `condition` for up to five seconds; the answer streams on tasks of its own.
    private func until(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw BuiltInChatTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum BuiltInChatTestError: Error { case timeout }

private extension AppModel {
    /// The last assistant message's text in `conversation`.
    func reply(in conversation: Conversation.ID) -> String? {
        conversations.first { $0.id == conversation }?.messages.last { $0.role == .assistant }?.content
    }
}

/// A loaded model whose every answer is written by the test, token by token.
private actor ScriptedChatRuntime: InferenceRuntime {
    nonisolated var kind: RuntimeKind { .llamaCpp }
    nonisolated static func locate() -> RuntimeInstallation? { nil }
    var state: RuntimeState { .ready(endpoint: URL(string: "http://127.0.0.1:9")!) }
    var lastMetrics: GenerationMetrics? { nil }

    private var answers: [AsyncThrowingStream<ChatEvent, any Error>.Continuation] = []

    /// How many answers have been asked for.
    var chats: Int { answers.count }

    func start(_ request: LoadRequest) async throws {}
    func stop() async {}

    func chat(_ request: ChatRequest) async throws -> AsyncThrowingStream<ChatEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        answers.append(continuation)
        return stream
    }

    func say(_ token: String, in answer: Int) { answers[answer].yield(.token(token)) }
    func finish(_ answer: Int) { answers[answer].finish() }
}

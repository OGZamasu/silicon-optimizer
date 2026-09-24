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

    /// Return pressed again mid-answer started a second answer over the first: Stop could
    /// then stop only the second, both wrote into the thread, and when the first finished the
    /// app believed nothing was running — and told a phone the thread was free.
    @Test func aSecondQuestionMidAnswerIsNotAsked() async throws {
        let model = AppModel(settings: .init())
        let runtime = ScriptedChatRuntime()
        model.newConversation()
        let thread = try #require(model.selectedConversationID)
        model.send("First", images: [], to: runtime)
        try await until { await runtime.chats == 1 }

        model.send("Second", images: [], to: runtime)
        model.regenerate()
        #expect(model.transcript(of: thread) == ["First", ""])
        #expect(model.isGenerating)
        #expect(model.isAnswering(thread))

        await runtime.say("One.", in: 0)
        await runtime.finish(0)
        try await until { !model.isGenerating }
        #expect(await runtime.chats == 1)
        #expect(model.transcript(of: thread) == ["First", "One."])
        #expect(!model.isAnswering(thread))
    }

    /// Stop, then ask again at once. The stopped answer winds down a moment later, and used to
    /// clear the new answer's handle as it went — leaving Stop with nothing to stop — and to
    /// tell a phone the thread was free while the new answer was still being written into it.
    @Test func aStoppedAnswerWindingDownLeavesTheNextOneRunning() async throws {
        let model = AppModel(settings: .init())
        let runtime = ScriptedChatRuntime()
        model.newConversation()
        let thread = try #require(model.selectedConversationID)
        model.send("First", images: [], to: runtime)
        try await until { await runtime.chats == 1 }

        model.stopGenerating()
        model.send("Second", images: [], to: runtime)
        try await until { await runtime.chats == 2 }
        try await until { await runtime.hasEnded(0) }
        // The stopped answer's clean-up follows its stream's end on the main actor; give it
        // every chance to (wrongly) take the running answer with it.
        try? await until(within: .milliseconds(300)) { !model.isGenerating }
        #expect(model.isGenerating)
        #expect(model.isAnswering(thread))

        await runtime.finish(1)
        try await until { !model.isGenerating }
        #expect(!model.isAnswering(thread))
    }

    /// Polls `condition` until it holds; the answer streams on tasks of its own.
    private func until(
        within limit: Duration = .seconds(5), _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + limit
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

    /// Every message's text in `conversation`, in order.
    func transcript(of conversation: Conversation.ID) -> [String]? {
        conversations.first { $0.id == conversation }?.messages.map(\.content)
    }
}

/// A loaded model whose every answer is written by the test, token by token.
private actor ScriptedChatRuntime: InferenceRuntime {
    nonisolated var kind: RuntimeKind { .llamaCpp }
    nonisolated static func locate() -> RuntimeInstallation? { nil }
    var state: RuntimeState { .ready(endpoint: URL(string: "http://127.0.0.1:9")!) }
    var lastMetrics: GenerationMetrics? { nil }

    private var answers: [AsyncThrowingStream<ChatEvent, any Error>.Continuation] = []
    private var ended: Set<Int> = []

    /// How many answers have been asked for.
    var chats: Int { answers.count }

    /// Whether answer `index` has stopped being read — finished, or its reader cancelled.
    func hasEnded(_ index: Int) -> Bool { ended.contains(index) }

    func start(_ request: LoadRequest) async throws {}
    func stop() async {}

    func chat(_ request: ChatRequest) async throws -> AsyncThrowingStream<ChatEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        let index = answers.count
        continuation.onTermination = { _ in Task { await self.markEnded(index) } }
        answers.append(continuation)
        return stream
    }

    private func markEnded(_ index: Int) { ended.insert(index) }

    func say(_ token: String, in answer: Int) { answers[answer].yield(.token(token)) }
    func finish(_ answer: Int) { answers[answer].finish() }
}

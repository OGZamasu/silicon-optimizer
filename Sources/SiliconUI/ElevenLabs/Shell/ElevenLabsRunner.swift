import Foundation
import Observation
import SiliconElevenLabs

/// Runs one ElevenLabs operation for a screen: checks the arguments, asks first when the
/// operation is destructive or reaches the real world, shows progress with a way to stop,
/// keeps the last result and the record of what was sent.
///
/// Every section and the Explorer run their calls through one of these, so confirmation,
/// cancel, error wording, the cost note, "Show API call", the show-once display of
/// credentials and the session's recent list behave the same everywhere — and so a section's
/// view-model can be tested without SwiftUI: build the runner with a `Context` whose client
/// has a `FakeElevenLabsTransport` behind it (or an `AppModel` whose `elevenLabsLink` has
/// one), call `perform`, answer `confirmation`, and read `phase`, `result`, `failure`.
@MainActor
@Observable
final class ElevenLabsRunner: Identifiable {

    enum Phase: Equatable, Sendable {
        case idle
        /// Waiting for the owner to confirm a destructive or real-world operation.
        case awaitingConfirmation
        case running
        case succeeded
        case failed
        case cancelled
    }

    /// For the `…/stream` operations: take the whole answer once it is done, or play the
    /// audio as it arrives (and keep it too).
    enum StreamMode: String, CaseIterable, Identifiable, Sendable {
        case collect
        case play

        var id: String { rawValue }
        var title: String {
            switch self {
            case .collect: "Collect, then play"
            case .play: "Play as it arrives"
            }
        }
    }

    /// How a runner reaches the account. The app's comes from `AppModel`; a test builds one
    /// around a client with a fake transport.
    struct Context {
        /// The linked account's client, read when a run starts. Nil means not linked.
        var client: @MainActor () -> ElevenLabsClient?
        /// Where a stream played as it arrives is kept. Nil makes `.play` collect instead.
        var sink: @MainActor () -> (any ElevenLabsFileSink)?
        /// The pane's state, for the recent list and the connection banner. Optional so a
        /// view-model test does not need one.
        var pane: ElevenLabsPaneState?

        init(
            client: @escaping @MainActor () -> ElevenLabsClient?,
            sink: @escaping @MainActor () -> (any ElevenLabsFileSink)? = { nil },
            pane: ElevenLabsPaneState? = nil
        ) {
            self.client = client
            self.sink = sink
            self.pane = pane
        }

        /// The running app's: the linked client, the output folder, the pane's state.
        @MainActor static func app(_ model: AppModel) -> Context {
            Context(
                client: { [weak model] in model?.elevenLabsClient },
                // The core's dated output folder, registered with the media table.
                sink: { [weak model] in model.flatMap { $0.elevenLabsLinked ? $0.elevenLabsSink() : nil } },
                pane: model.elevenLabsPane
            )
        }
    }

    nonisolated let id = UUID()
    let operation: ElevenLabsOperation
    /// Only consulted for operations with `supportsStreaming`.
    var streamMode: StreamMode = .collect
    /// The name results get in the recent list; the operation's summary when nil.
    var title: String?
    /// Off for background reads (a list refresh) that would only clutter the recent list.
    var recordsResults = true

    private(set) var phase: Phase = .idle
    /// What the last run was asked to send.
    private(set) var arguments: [String: JSONValue] = [:]
    private(set) var files: [String: [ElevenLabsFile]] = [:]
    /// Every problem with the last arguments, as the client words them. Nothing was sent.
    private(set) var problems: [String] = []
    private(set) var failure: ElevenLabsRunnerFailure?
    /// The last answer. For a credential-returning operation, with the secret masked — the
    /// secret itself is in `credential` until dismissed.
    private(set) var result: ElevenLabsResult?
    /// What the last run sent (or would have), with the key left out: "Show API call".
    private(set) var apiCall: ElevenLabsCallDescription?
    /// The question on screen while `phase` is `.awaitingConfirmation`.
    private(set) var confirmation: ElevenLabsConfirmationRequest?
    /// A key, secret, token or signed URL the last answer carried, shown once.
    private(set) var credential: ElevenLabsRevealedCredential?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    /// Bytes of body received so far, while a stream plays.
    private(set) var receivedBytes = 0
    /// Why the last `perform` sent nothing although the arguments were fine: a run that is
    /// not a read was already in flight. Cleared when a run starts.
    private(set) var refusal: String?
    /// What a Cancel left behind: for anything but a read cancelled after it was handed to
    /// the client, that it may already have been billed or performed.
    private(set) var cancellationNote: String?

    /// What a second run is refused with while one that is not a read is in flight.
    static let busyMessage = "A run is already in progress — cancel it first, and note it may already have been billed."
    /// What a Cancel says once a request that is not a read may have gone out.
    static let cancelledAfterSendingMessage = "Cancelled. The request may already have been billed or performed."
    /// What a confirmed question says when the account or region changed while it was open.
    static let accountChangedMessage =
        "The ElevenLabs account or region changed while this question was open, so nothing was sent. Run it again to be asked anew."
    /// Plays a stream as it arrives; nil when not playing one.
    private(set) var streamPlayer: ElevenLabsStreamPlayer?

    @ObservationIgnored private let context: Context
    @ObservationIgnored private var task: Task<ElevenLabsResult, any Error>?
    @ObservationIgnored private var pendingConfirmation: CheckedContinuation<Bool, Never>?
    /// Which run owns the runner's state. Every run takes a new one, and so does Cancel; a
    /// run's frame that wakes up — from its answer, a late completion, a withdrawn question —
    /// under another number touches nothing, so it can never mark a newer run cancelled,
    /// failed or done.
    @ObservationIgnored private var generation = 0
    /// The pane session the current run started in; its reports reach the pane only while
    /// that session lasts.
    @ObservationIgnored private var runEpoch: Int?

    init(operation: ElevenLabsOperation, context: Context) {
        self.operation = operation
        self.context = context
    }

    convenience init(operation: ElevenLabsOperation, model: AppModel) {
        self.init(operation: operation, context: .app(model))
    }

    /// Nil when the catalog has no such operation.
    convenience init?(operationID: String, context: Context) {
        guard let operation = ElevenLabsCatalog.operation(operationID) else { return nil }
        self.init(operation: operation, context: context)
    }

    convenience init?(operationID: String, model: AppModel) {
        self.init(operationID: operationID, context: .app(model))
    }

    var isRunning: Bool { phase == .running }
    var isAwaitingConfirmation: Bool { phase == .awaitingConfirmation }
    /// The failure in words, for the line under the Run button.
    var errorMessage: String? { failure?.message }
    /// What running it costs, for the Run button's caption. Nil for free operations.
    var costNote: String? { ElevenLabsCostNote.text(for: operation) }

    /// Starts a run and returns at once; watch `phase`. See `perform`, including what happens
    /// to a run already in flight.
    func run(
        arguments: [String: JSONValue], files: [String: [ElevenLabsFile]] = [:],
        subject: String? = nil, consequence: String? = nil
    ) {
        Task { await perform(arguments: arguments, files: files, subject: subject, consequence: consequence) }
    }

    /// Checks `arguments`, asks for confirmation when the operation's risk calls for it,
    /// runs, and returns the answer — nil when it was refused, declined, cancelled, failed or
    /// replaced by a newer run (see `phase`, `problems` and `failure`).
    ///
    /// A run started while another is in flight (or waiting for its answer to a question):
    /// - for a **read**, replaces it: restarting is free, so the old request is cancelled, its
    ///   `perform` returns nil, and nothing it does afterwards reaches this runner's state;
    /// - for **anything else** — generate, modify, destructive, real world — is refused and sends
    ///   nothing: the run in flight may already have been billed or acted on, and a second one
    ///   would do it again. `refusal` says so; the run in flight carries on untouched.
    ///
    /// Cancel, then run again, is allowed for everything (the owner chose it); `cancellationNote`
    /// then says the cancelled request may already have been billed or performed. Either way a
    /// cancelled or replaced run's late completion never touches the next run.
    ///
    /// - Parameters:
    ///   - subject: What the operation acts on, in words ("the voice “Rachel”", "12 phone
    ///     numbers"), for the confirmation's title.
    ///   - consequence: What will happen, when the section knows better than the generic
    ///     sentence built from the operation.
    @discardableResult
    func perform(
        arguments: [String: JSONValue], files: [String: [ElevenLabsFile]] = [:],
        subject: String? = nil, consequence: String? = nil
    ) async -> ElevenLabsResult? {
        if phase == .running || phase == .awaitingConfirmation {
            guard operation.risk == .read else {
                refusal = Self.busyMessage
                return nil
            }
            abandonCurrentRun()
        }
        generation += 1
        let run = generation
        refusal = nil
        cancellationNote = nil
        context.pane?.track(self)
        runEpoch = context.pane?.epoch
        self.arguments = arguments
        self.files = files
        problems = []
        failure = nil
        credential = nil
        receivedBytes = 0
        stopStreamPlayer()

        guard let client = context.client() else {
            return fail(.notLinked)
        }

        // Nothing is sent, and nothing is asked, for arguments the client would refuse.
        let known = ElevenLabsCatalog.operation(operation.id) != nil
        if known {
            let found = client.validate(operation.id, arguments: arguments, files: files)
            if !found.isEmpty { return fail(.invalidArguments(found)) }
            apiCall = try? client.describe(operation.id, arguments: arguments, files: files)
        } else {
            apiCall = nil
        }

        if operation.requiresConfirmation {
            let request = ElevenLabsConfirmationRequest.make(
                for: operation, subject: subject, consequence: consequence, call: apiCall
            )
            let answer = await askForConfirmation(request, run: run)
            guard run == generation else { return nil }
            guard answer else {
                phase = .idle
                return nil
            }
            // The answer was given for the account and host the question was asked on. If the
            // session ended, the link went, or the region moved meanwhile, the same click would
            // act on another account or host: send nothing.
            let sessionEnded = context.pane.map { $0.epoch != runEpoch } ?? false
            guard !sessionEnded, let now = context.client(), now.region == client.region else {
                return fail(.other(Self.accountChangedMessage))
            }
        }

        phase = .running
        startedAt = Date()
        finishedAt = nil
        let playing = operation.supportsStreaming && streamMode == .play && context.sink() != nil
        let operation = operation
        let task: Task<ElevenLabsResult, any Error>
        if playing, let sink = context.sink() {
            let player = ElevenLabsStreamPlayer(outputFormat: arguments["output_format"]?.stringValue)
            streamPlayer = player
            task = Task { [weak self] in
                try await ElevenLabsStreamCollector.collect(
                    client.stream(operation.id, arguments: arguments, files: files),
                    operation: operation, sink: sink, player: player,
                    outputFormat: arguments["output_format"]?.stringValue,
                    progress: { bytes in
                        await MainActor.run {
                            guard let self, self.generation == run else { return }
                            self.receivedBytes = bytes
                        }
                    }
                )
            }
        } else {
            task = Task { try await client.call(operation, arguments: arguments, files: files) }
        }
        self.task = task
        // Counted until the request itself ends, whatever becomes of this run meanwhile: a
        // cancelled request may still be on the wire.
        let billable = operation.risk != .read
        let pane = context.pane
        if billable { pane?.billableRunStarted() }
        defer { if billable { pane?.billableRunEnded() } }

        do {
            let answer = try await task.value
            guard run == generation else { return nil }
            self.task = nil
            return succeed(answer)
        } catch {
            guard run == generation else { return nil }
            self.task = nil
            if Task.isCancelled || (error as? ElevenLabsError) == .cancelled || error is CancellationError {
                phase = .cancelled
                finishedAt = Date()
                return nil
            }
            return fail(ElevenLabsRunnerFailure(error), error: error)
        }
    }

    /// Answers the confirmation on screen with yes.
    func confirm() {
        resolveConfirmation(true)
    }

    /// Answers the confirmation on screen with no: nothing is sent.
    func decline() {
        resolveConfirmation(false)
    }

    /// Stops the run in flight, or declines the confirmation on screen.
    func cancel() {
        if phase == .awaitingConfirmation {
            decline()
            return
        }
        guard phase == .running else { return }
        generation += 1
        cancellationNote = operation.risk == .read ? "Cancelled." : Self.cancelledAfterSendingMessage
        refusal = nil
        phase = .cancelled
        finishedAt = Date()
        task?.cancel()
        task = nil
        stopStreamPlayer()
    }

    /// Forgets the credential on screen. It is not kept anywhere else.
    func dismissCredential() {
        credential = nil
    }

    /// Back to a blank slate, as before the first run.
    func reset() {
        cancel()
        phase = .idle
        arguments = [:]
        files = [:]
        problems = []
        failure = nil
        result = nil
        apiCall = nil
        credential = nil
        refusal = nil
        cancellationNote = nil
        startedAt = nil
        finishedAt = nil
        receivedBytes = 0
        stopStreamPlayer()
    }

    // MARK: - Steps

    private func askForConfirmation(_ request: ElevenLabsConfirmationRequest, run: Int) async -> Bool {
        confirmation = request
        phase = .awaitingConfirmation
        context.pane?.present(self)
        let answer = await withCheckedContinuation { pendingConfirmation = $0 }
        // A newer run may already be asking its own question; leave that one on screen.
        if run == generation {
            confirmation = nil
            context.pane?.dismissConfirmation(of: self)
        }
        return answer
    }

    /// Lets go of the run in flight so a new one can start clean: its request is cancelled,
    /// or its question withdrawn, and its frame — whenever it wakes — finds another
    /// generation and leaves everything alone.
    private func abandonCurrentRun() {
        generation += 1
        task?.cancel()
        task = nil
        stopStreamPlayer()
        if confirmation != nil {
            confirmation = nil
            context.pane?.dismissConfirmation(of: self)
        }
        resolveConfirmation(false)
    }

    /// Whether this runner's host must show its confirmation itself: only when there is no
    /// pane to do it (a runner built for a test, or outside the ElevenLabs pane).
    var presentsOwnConfirmation: Bool { context.pane == nil }

    private func resolveConfirmation(_ answer: Bool) {
        guard let continuation = pendingConfirmation else { return }
        pendingConfirmation = nil
        continuation.resume(returning: answer)
    }

    private func succeed(_ answer: ElevenLabsResult) -> ElevenLabsResult {
        // Every answer is shown masked: a credential operation's named fields, and in any
        // answer the account's key preview and `sk_…` keys. Only a credential operation's
        // fields go on the shown-once card.
        if operation.returnsCredential {
            let revealed = ElevenLabsRevealedCredential(operation: operation, result: answer)
            credential = revealed.fields.isEmpty ? nil : revealed
        }
        let shown = ElevenLabsRevealedCredential.masked(answer, for: operation)
        result = shown
        refusal = nil
        phase = .succeeded
        finishedAt = Date()
        streamPlayer?.finish()
        if let pane = currentPane {
            pane.noteSuccess()
            if recordsResults { pane.record(shown, operation: operation, title: title) }
        }
        return shown
    }

    @discardableResult
    private func fail(_ failure: ElevenLabsRunnerFailure, error: (any Error)? = nil) -> ElevenLabsResult? {
        if case .invalidArguments(let found) = failure { problems = found }
        self.failure = failure
        refusal = nil
        phase = .failed
        finishedAt = Date()
        stopStreamPlayer()
        if let error { currentPane?.noteFailure(error) }
        return nil
    }

    /// The pane, while it is still in the session this run started in.
    private var currentPane: ElevenLabsPaneState? {
        guard let pane = context.pane, pane.epoch == runEpoch else { return nil }
        return pane
    }

    private func stopStreamPlayer() {
        streamPlayer?.stop()
        streamPlayer = nil
    }
}

/// A failed run, sorted by what the owner can do about it.
enum ElevenLabsRunnerFailure: Equatable, Sendable {
    /// No key is linked.
    case notLinked
    /// The arguments were refused before anything was sent; every problem is listed.
    case invalidArguments([String])
    /// ElevenLabs refused the key (401).
    case keyRejected(String)
    /// The key works but may not do this (403): a plan or permission limit.
    case forbidden(String)
    case rateLimited(String)
    /// ElevenLabs could not be reached.
    case offline(String)
    /// The Keychain would not hand the key over.
    case credentialUnavailable(String)
    /// Any other answer from ElevenLabs, or a local problem.
    case other(String)

    init(_ error: any Error) {
        guard let error = error as? ElevenLabsError else {
            self = .other(ElevenLabsRedaction.redact(error.localizedDescription))
            return
        }
        let message = ElevenLabsRedaction.redact(error.description)
        switch error {
        case .notLinked: self = .notLinked
        case .invalidArguments(let problems): self = .invalidArguments(problems.map { ElevenLabsRedaction.redact($0) })
        case .api(let status, _, _, _) where status == 401: self = .keyRejected(message)
        case .api(let status, _, _, _) where status == 403: self = .forbidden(message)
        case .rateLimited: self = .rateLimited(message)
        case .network: self = .offline(message)
        case .credentialUnavailable: self = .credentialUnavailable(message)
        case .api, .unknownOperation, .refusedHost, .tooLarge, .cancelled: self = .other(message)
        }
    }

    /// In words that can be shown as they are. Never the key.
    var message: String {
        switch self {
        case .notLinked:
            ElevenLabsError.notLinked.description
        case .invalidArguments(let problems):
            ElevenLabsError.invalidArguments(problems).description
        case .keyRejected(let message):
            message + " The key may have been revoked; reconnect in Settings → ElevenLabs."
        case .forbidden(let message), .rateLimited(let message), .offline(let message),
             .credentialUnavailable(let message), .other(let message):
            message
        }
    }
}

/// The note under a Run button about what running the operation spends.
enum ElevenLabsCostNote {

    /// What an operation is billed by, as far as the note is concerned.
    enum Measure: Equatable, Sendable {
        /// The characters of text sent: speech, dialogue.
        case characters
        /// The length of the audio sent or made, in the words for it ("audio", "song"…).
        case length(of: String)
        /// Money charged to the workspace rather than credits: a Productions order.
        case money
        /// Something else, or not known.
        case other
    }

    static func measure(of operation: ElevenLabsOperation) -> Measure {
        let path = operation.path
        func under(_ prefix: String) -> Bool { ElevenLabsSection.matches(path, prefix: prefix) }
        if under("/v1/text-to-speech") || under("/v1/text-to-dialogue") { return .characters }
        if under("/v1/speech-to-speech") || under("/v1/audio-isolation") || under("/v1/speech-to-text")
            || under("/v1/forced-alignment") {
            return .length(of: "audio")
        }
        if under("/v1/dubbing") { return .length(of: "source") }
        if under("/v1/music") { return .length(of: "music") }
        if under("/v1/sound-generation") { return .length(of: "sound") }
        if under("/v1/productions/orders"), path.hasSuffix("/submit") { return .money }
        return .other
    }

    /// Nil for operations that spend nothing.
    ///
    /// - Parameters:
    ///   - characters: The text's length, when the section knows it.
    ///   - seconds: The audio's length — sent or asked for — when the section knows it.
    ///   - message: The section's own words — a quote's price, say — used instead, whether or
    ///     not the operation is marked billable.
    static func text(
        for operation: ElevenLabsOperation, characters: Int? = nil, seconds: Double? = nil, message: String? = nil
    ) -> String? {
        if let message, !message.isEmpty { return message }
        guard operation.billable else { return nil }
        switch measure(of: operation) {
        case .money:
            return "Charges money to your workspace — not credits."
        case .characters:
            if let characters, characters > 0 {
                return "Uses credits — about \(characters.formatted()) characters' worth."
            }
            return "Uses credits by the characters sent."
        case .length(let what):
            if let seconds, seconds > 0 {
                return "Uses credits by the length of the \(what) — about \(duration(seconds)) of it."
            }
            return "Uses credits by the length of the \(what)."
        case .other:
            if let characters, characters > 0 {
                return "Uses credits — about \(characters.formatted()) characters' worth."
            }
            return "Uses credits from your ElevenLabs balance."
        }
    }

    /// "45 s", "3 min 20 s".
    static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(max(whole, 1)) s" }
        let rest = whole % 60
        return rest == 0 ? "\(whole / 60) min" : "\(whole / 60) min \(rest) s"
    }
}

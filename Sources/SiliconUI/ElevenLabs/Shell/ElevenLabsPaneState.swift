import Foundation
import Observation
import SiliconElevenLabs

/// What the ElevenLabs pane keeps while the app runs: the section on screen, the search, the
/// session's results, the voices list every picker shares, and whether the account is
/// reachable.
///
/// Held by `AppModel` rather than by the pane's views, because the main window shows one tab
/// at a time behind a `switch`: a result made in Speech must still be in the recent list after
/// a trip to Chat and back, and the voices fetched once must not be fetched again by every
/// picker that appears.
@MainActor
@Observable
final class ElevenLabsPaneState {

    /// Why the account cannot be used right now, for the pane's empty/error states.
    enum ConnectionProblem: Equatable, Sendable {
        /// ElevenLabs refused the key (401): revoked, rotated, or for another region.
        case keyRejected(String)
        /// ElevenLabs could not be reached at all.
        case offline(String)
        /// The Keychain would not hand the key over (locked, or its dialog dismissed).
        case credentialUnavailable(String)
    }

    /// The section on screen. Remembered across launches in the running app.
    var section: ElevenLabsSection {
        didSet {
            guard section != oldValue else { return }
            defaults?.set(section.rawValue, forKey: Self.sectionKey)
        }
    }

    /// The search box above the section list: filters sections and operations.
    var search = ""

    /// The session's recent results are on screen instead of a section.
    private(set) var showsRecents = false

    /// The operation the Explorer shows, by id.
    var explorerSelection: String?

    /// This session's results, newest first. Never credential-bearing ones; never persisted.
    private(set) var recents: [ElevenLabsRecentResult] = []

    /// The last problem reaching the account; cleared by the next call that works.
    var connectionProblem: ConnectionProblem?

    /// Every voice the account can use, fetched once and shared by every picker.
    let voices: ElevenLabsVoiceDirectory

    /// The Explorer's filters and the operations opened in it, made when it is first shown.
    @ObservationIgnored private var explorerModel: ElevenLabsExplorerModel?

    /// How many results the session keeps. Files stay on disk either way; this bounds the
    /// list, not the output folder.
    static let recentLimit = 50
    static let sectionKey = "dev.siliconoptimizer.elevenlabs.section"

    /// The runner whose confirmation is on screen; others wait their turn in `waiting`.
    /// The pane presents it, so no section can forget to host the sheet.
    private(set) var confirming: ElevenLabsRunner?
    @ObservationIgnored private var waiting: [ElevenLabsRunner] = []

    /// Which account session this is. `reset()` starts a new one; whatever a run started in an
    /// older session reports afterwards — a result, a refused key — is dropped, so one
    /// account's answers never land in another's list or banner.
    @ObservationIgnored private(set) var epoch = 0
    /// Requests that are not reads, handed to the client and not finished — counted across
    /// sessions, because a reset does not take them back off the wire. While any is in
    /// flight, a region switch or a new key is refused: a fresh runner on the same account
    /// could send it a second time.
    private(set) var billableRunsInFlight = 0
    /// Every runner that has run with this pane, weakly, so a reset can reach the ones still
    /// asking or running.
    @ObservationIgnored private var runners: [WeakRunner] = []
    /// Runners with a shown-once secret on screen: forgotten when the owner leaves.
    @ObservationIgnored private var credentialHolders: [WeakRunner] = []

    private struct WeakRunner {
        weak var runner: ElevenLabsRunner?
    }

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let client: @MainActor () -> ElevenLabsClient?
    /// Each section's state for the session, and the client it was made for — held weakly and
    /// compared by identity: an address can be reused by the next client once the old one is
    /// freed, which would make another account look like the same one.
    @ObservationIgnored private var states: [String: AnyObject] = [:]
    @ObservationIgnored private weak var statesClient: ElevenLabsClient?
    @ObservationIgnored private var statesBound = false

    /// Said in the pane after an account change cut off a request that may cost money or
    /// act — its answer will never be shown, so the owner has to look for themselves.
    var previousAccountNotice: String?
    static let previousAccountMessage =
        "A request to the previous account may already have gone out — check it on elevenlabs.io."

    /// - Parameters:
    ///   - defaults: Where the section is remembered; nil under a test, which must not write
    ///     the owner's preferences.
    ///   - client: The linked account's client, read at the moment it is needed.
    init(defaults: UserDefaults?, client: @escaping @MainActor () -> ElevenLabsClient?) {
        self.defaults = defaults
        self.client = client
        section = ElevenLabsSection.resolve(remembered: defaults?.string(forKey: Self.sectionKey) ?? "")
        voices = ElevenLabsVoiceDirectory(client: client)
    }

    // MARK: - Section state

    /// The state `section` keeps for the session — its view-model, typed text, the list it
    /// loaded — made by `make` on first use and handed back after that, so a trip to another
    /// section or tab loses nothing.
    ///
    /// It is dropped, with every other section's, when the account's client changes: a
    /// disconnect, a new key, a region change. Nothing made for one key or region survives
    /// into another.
    ///
    ///     let screen = model.elevenLabsPane.state(for: .speech) { SpeechScreenModel(model: model) }
    func state<State: AnyObject>(for section: ElevenLabsSection, make: () -> State) -> State {
        state(key: "section." + section.rawValue, make: make)
    }

    /// `state(for:make:)` under any key — for state several sections share.
    func state<State: AnyObject>(key: String, make: () -> State) -> State {
        dropStatesIfTheAccountChanged()
        if let existing = states[key] as? State { return existing }
        let made = make()
        states[key] = made
        return made
    }

    /// Forgets every section's state now — and, since that state belonged to the account,
    /// declines its questions and cancels its runs too.
    func dropSectionStates() {
        endAccountWork()
        states.removeAll()
        statesClient = nil
        statesBound = false
    }

    private func dropStatesIfTheAccountChanged() {
        let current = client()
        if statesBound {
            // Same account only while it is the very client the states were made for.
            guard let current, current === statesClient else {
                dropSectionStates()
                bindStates(to: current)
                return
            }
        } else {
            // First use, or after a disconnect: nothing made yet belongs to another account.
            bindStates(to: current)
        }
    }

    private func bindStates(to client: ElevenLabsClient?) {
        statesClient = client
        statesBound = client != nil
    }

    /// Ends what the old account left going. Every question asked or waiting is declined —
    /// confirmed later it would run against the next account, with its key or its host — and
    /// every run is cancelled. A request that is not a read cut off this way leaves a notice
    /// in the pane, because its answer will never be shown. Late reports from before are
    /// dropped by the new epoch.
    private func endAccountWork() {
        epoch += 1
        forgetCredentials()
        let asking = [confirming].compactMap { $0 } + waiting
        confirming = nil
        waiting = []
        for runner in asking { runner.decline() }
        var cutOff = billableRunsInFlight > 0
        for runner in runners.compactMap(\.runner) {
            if runner.isRunning, runner.operation.risk != .read { cutOff = true }
            runner.cancel()
        }
        if cutOff { previousAccountNotice = Self.previousAccountMessage }
    }

    // MARK: - Confirmation

    /// Puts `runner`'s question on screen, after any already there.
    func present(_ runner: ElevenLabsRunner) {
        if confirming == nil { confirming = runner } else if !waiting.contains(where: { $0 === runner }) { waiting.append(runner) }
    }

    /// Takes `runner`'s question off screen, and shows the next one waiting.
    func dismissConfirmation(of runner: ElevenLabsRunner) {
        waiting.removeAll { $0 === runner }
        guard confirming === runner else { return }
        confirming = waiting.isEmpty ? nil : waiting.removeFirst()
    }

    /// Shows `section`. Leaving one forgets any secret it showed once.
    func open(_ section: ElevenLabsSection) {
        if section != self.section || showsRecents { forgetCredentials() }
        self.section = section
        showsRecents = false
    }

    /// Shows the Explorer with `operationID` selected.
    func openInExplorer(_ operationID: String) {
        explorerSelection = operationID
        open(.explorer)
    }

    /// Shows this session's results.
    func showRecents() {
        forgetCredentials()
        showsRecents = true
    }

    /// `runner` is showing a secret once; it is forgotten when the owner leaves.
    func holdCredential(_ runner: ElevenLabsRunner) {
        credentialHolders.removeAll { $0.runner == nil }
        if !credentialHolders.contains(where: { $0.runner === runner }) {
            credentialHolders.append(WeakRunner(runner: runner))
        }
    }

    /// Forgets every secret shown once: they are for the moment they were asked for.
    func forgetCredentials() {
        for runner in credentialHolders.compactMap(\.runner) { runner.dismissCredential() }
        credentialHolders.removeAll()
    }

    /// The Explorer's model, made on first use with `context`.
    func explorer(context: @autoclosure () -> ElevenLabsRunner.Context) -> ElevenLabsExplorerModel {
        if let explorerModel { return explorerModel }
        let made = ElevenLabsExplorerModel(context: context())
        explorerModel = made
        return made
    }

    /// Adds a finished run to the session's list, unless its answer carried a credential:
    /// those are shown once, where they were asked for, and nowhere else.
    func record(_ result: ElevenLabsResult, operation: ElevenLabsOperation, title: String? = nil) {
        guard !operation.returnsCredential else { return }
        recents.insert(
            ElevenLabsRecentResult(operation: operation, title: title ?? operation.summary, result: result),
            at: 0
        )
        if recents.count > Self.recentLimit { recents.removeLast(recents.count - Self.recentLimit) }
    }

    func removeRecent(_ id: ElevenLabsRecentResult.ID) {
        recents.removeAll { $0.id == id }
    }

    func clearRecents() {
        recents.removeAll()
    }

    /// What a failed call says about the connection as a whole, if anything: a rejected key or
    /// an unreachable host is the pane's business, not only the section's.
    func noteFailure(_ error: any Error) {
        switch error as? ElevenLabsError {
        case .api(let status, _, let message, _) where status == 401:
            connectionProblem = .keyRejected(message)
        case .network(let why):
            connectionProblem = .offline(why)
        case .credentialUnavailable(let why):
            connectionProblem = .credentialUnavailable(why)
        default:
            break
        }
    }

    /// A call went through, so whatever was wrong with the connection no longer is.
    func noteSuccess() {
        connectionProblem = nil
    }

    // MARK: - Runs

    /// A runner is about to run with this pane.
    func track(_ runner: ElevenLabsRunner) {
        runners.removeAll { $0.runner == nil }
        if !runners.contains(where: { $0.runner === runner }) { runners.append(WeakRunner(runner: runner)) }
    }

    func billableRunStarted() {
        billableRunsInFlight += 1
    }

    func billableRunEnded() {
        billableRunsInFlight = max(0, billableRunsInFlight - 1)
    }

    /// Forgets everything tied to the account: on disconnect, a new key, or a region change.
    ///
    /// Every question still asked is declined — confirming one later would run it against the
    /// next account — and every run still going is cancelled, so its runner says it may
    /// already have been billed and refuses nothing it should not. Late answers from before
    /// are dropped by the epoch.
    func reset() {
        endAccountWork()
        showsRecents = false
        recents.removeAll()
        connectionProblem = nil
        explorerSelection = nil
        explorerModel = nil
        dropSectionStates()
        voices.reset()
    }
}

/// One result from this session, for the recent list.
struct ElevenLabsRecentResult: Identifiable, Sendable {
    let id = UUID()
    var operationID: String
    var title: String
    var date = Date()
    var result: ElevenLabsResult

    init(operation: ElevenLabsOperation, title: String, result: ElevenLabsResult, date: Date = Date()) {
        operationID = operation.id
        self.title = title
        self.result = result
        self.date = date
    }
}

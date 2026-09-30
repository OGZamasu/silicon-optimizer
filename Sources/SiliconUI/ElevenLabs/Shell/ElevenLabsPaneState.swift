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

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let client: @MainActor () -> ElevenLabsClient?
    /// Each section's state for the session, and the client it was made for.
    @ObservationIgnored private var states: [String: AnyObject] = [:]
    @ObservationIgnored private var statesClient: ObjectIdentifier?

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

    /// Forgets every section's state now.
    func dropSectionStates() {
        states.removeAll()
        statesClient = nil
    }

    private func dropStatesIfTheAccountChanged() {
        let current = client().map(ObjectIdentifier.init)
        guard current != statesClient else { return }
        states.removeAll()
        statesClient = current
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

    /// Shows `section`.
    func open(_ section: ElevenLabsSection) {
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
        showsRecents = true
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

    /// Forgets everything tied to the account: on disconnect, or a region change.
    func reset() {
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

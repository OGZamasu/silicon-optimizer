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

    /// How many results the session keeps. Files stay on disk either way; this bounds the
    /// list, not the output folder.
    static let recentLimit = 50
    static let sectionKey = "dev.siliconoptimizer.elevenlabs.section"

    @ObservationIgnored private let defaults: UserDefaults?

    /// - Parameters:
    ///   - defaults: Where the section is remembered; nil under a test, which must not write
    ///     the owner's preferences.
    ///   - client: The linked account's client, read at the moment it is needed.
    init(defaults: UserDefaults?, client: @escaping @MainActor () -> ElevenLabsClient?) {
        self.defaults = defaults
        section = ElevenLabsSection.resolve(remembered: defaults?.string(forKey: Self.sectionKey) ?? "")
        voices = ElevenLabsVoiceDirectory(client: client)
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

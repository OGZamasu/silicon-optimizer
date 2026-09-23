import Foundation
import SiliconControl

/// Why a load did not end with a model in memory, in a form both a person and a phone can
/// read.
///
/// The bug this exists for: a 27B ternary model was asked for from the phone, the runtime
/// process was gone eight seconds later, and what came back was the last eight lines of
/// llama.cpp's log — cut off mid-sentence, under the heading "The model did not finish
/// loading". Nothing recorded *that the process had ended*, let alone how, so the app had
/// nothing better to show. Now the ending is recorded where the failure is built, the
/// sentence names it, and the log goes behind a tap instead of into the headline.

/// Who asked a server process to stop, when the app is the one that asked.
///
/// A stop the app requested is a completely different fact from a process that died on its
/// own, and mixing them is exactly how "the system killed your model" and "you pressed
/// unload" came out looking the same.
public enum StopRequest: String, Sendable, Equatable, Codable {
    /// The model was unloaded — by the owner, by the idle timer, or by `POST /unload`.
    case unload
    /// Another load took the machine.
    case replaced
}

/// What became of a server process.
public struct ProcessTermination: Sendable, Equatable {
    /// The status it exited with, when it exited of its own accord. Nil when a signal
    /// ended it.
    public var exitStatus: Int32?
    /// The signal that ended it, when one did. Nil when it exited normally.
    public var signal: Int32?
    /// Set when this app asked it to stop, and why. Nil means nobody here asked — which is
    /// what makes "it stopped on its own" a fact rather than a guess.
    public var stopRequest: StopRequest?
    /// How long it ran, from `run()` to the moment it ended.
    public var ranFor: TimeInterval

    public init(
        exitStatus: Int32? = nil, signal: Int32? = nil,
        stopRequest: StopRequest? = nil, ranFor: TimeInterval = 0
    ) {
        self.exitStatus = exitStatus
        self.signal = signal
        self.stopRequest = stopRequest
        self.ranFor = ranFor
    }
}

/// How a load ended, from the runtime's point of view. Three shapes, because three genuinely
/// different things happen: the process went away, the process is fine but never answered,
/// or the load itself was called off.
public enum LoadEnding: Sendable, Equatable {
    case processEnded(ProcessTermination)
    /// The process is still alive and still has not answered `/health`.
    case neverAnswered(after: TimeInterval)
    /// The load was called off before it finished. `by` names what called it off, when
    /// that is known.
    case cancelled(by: String?)
}

/// A failed load, reduced to one sentence plus the facts behind it.
public struct LoadFailure: Sendable, Equatable {

    /// The machine-readable half. A client switches on this; a person reads `summary`.
    public enum Reason: String, Sendable, Equatable, Codable, CaseIterable {
        /// The runtime exited on its own, with a status.
        case exited
        /// A signal ended it — on this machine, usually the memory pressure killer.
        case killed
        /// Another load took the machine from this one.
        case replaced
        /// The load was called off: an unload, or the app shutting down.
        case cancelled
        /// The process is alive and never answered in the time it was given.
        case timedOut
        /// The runtime binary could not be started at all.
        case launchFailed
        /// There is no such runtime on this machine.
        case notInstalled
    }

    public var reason: Reason
    /// One sentence, and the only thing meant for a headline. This is what `RuntimeState`
    /// carries and what `/status` answers as `state`.
    public var summary: String
    /// The runtime's own words: the tail of its log. Meant for "show me the log", never
    /// for the line the person reads first.
    public var detail: String?
    public var runtime: RuntimeKind
    public var exitStatus: Int32?
    public var signal: Int32?
    /// True only when another load is what ended this one.
    public var wasReplaced: Bool
    public var at: Date
    /// The installed model the load was for. `LoadFailureRecorder` keeps one failure for
    /// the whole app, and two loads can overlap, so the failure says whose it is rather
    /// than leaving a client to assume it is about the load it asked for.
    public var modelID: String?

    public init(
        reason: Reason, summary: String, detail: String? = nil, runtime: RuntimeKind,
        exitStatus: Int32? = nil, signal: Int32? = nil, wasReplaced: Bool = false,
        at: Date = Date(), modelID: String? = nil
    ) {
        self.reason = reason
        self.summary = summary
        self.detail = detail
        self.runtime = runtime
        self.exitStatus = exitStatus
        self.signal = signal
        self.wasReplaced = wasReplaced
        self.at = at
        self.modelID = modelID
    }

    /// The shape a client gets. `summary` is deliberately absent: it is already on the wire
    /// as `state`, and sending the same sentence twice invites the two to disagree.
    public var wire: ControlAPI.LoadFailure {
        ControlAPI.LoadFailure(
            reason: reason.rawValue,
            detail: detail,
            runtime: runtime.rawValue,
            exitStatus: exitStatus.map(Int.init),
            signal: signal.map(Int.init),
            wasReplaced: wasReplaced,
            at: ControlAPI.timestamp(at),
            modelID: modelID
        )
    }
}

// MARK: - Turning an ending into words

extension LoadEnding {

    /// The one sentence a person reads. `process` is the name of the binary — the thing a
    /// user can look for in Activity Monitor — and `replacedBy` names the load that took
    /// the machine, when one did.
    public func sentence(process: String, replacedBy: String? = nil) -> String {
        switch self {
        case .processEnded(let termination):
            return Self.sentence(
                for: termination, process: process, replacedBy: replacedBy
            )
        case .neverAnswered(let seconds):
            return "\(process) never answered in \(Self.spell(seconds))."
        case .cancelled(let by):
            guard let by else {
                return "The load was cancelled before \(process) finished loading."
            }
            return "The load was cancelled by \(by) before \(process) finished loading."
        }
    }

    private static func sentence(
        for termination: ProcessTermination, process: String, replacedBy: String?
    ) -> String {
        // What the app asked for comes first. A server we told to stop did not "die", and a
        // SIGTERM we sent it is not a diagnosis of anything.
        switch termination.stopRequest {
        case .replaced:
            guard let replacedBy else { return "\(process) was replaced by another load." }
            return "\(process) was replaced by another load (\(replacedBy))."
        case .unload:
            return "\(process) was stopped by an unload before it finished loading."
        case .none:
            break
        }

        let lived = spell(termination.ranFor)
        if let signal = termination.signal {
            return "\(process) was killed (signal \(signal)) after \(lived)"
                + "\(Self.explain(signal: signal, after: termination.ranFor))"
        }
        // Exit 0 is still a failure — it never answered — but "stopped on its own (exit 0)"
        // reads like a success somebody mislabelled, so it says what was missing.
        guard let status = termination.exitStatus, status != 0 else {
            return "\(process) stopped on its own after \(lived), before it finished "
                + "loading (exit 0)."
        }
        return "\(process) stopped on its own after \(lived) (exit \(status))."
    }

    /// What a signal usually means on this machine, when it usually means something.
    ///
    /// SIGKILL *during* a load is the memory pressure killer far more often than it is
    /// anything else — nothing else on a Mac reaches for it while a process is reading tens
    /// of gigabytes — and a person who has just watched a 27B model disappear is owed that
    /// sentence rather than the number on its own.
    ///
    /// SIGKILL in the first moment is a different animal and must not be blamed on memory:
    /// a binary that never got to run is one Gatekeeper refused — a quarantined download, a
    /// build whose signature does not check out — and telling that owner to reduce their
    /// context length would send them somewhere with nothing to find.
    private static func explain(signal: Int32, after seconds: TimeInterval) -> String {
        switch signal {
        case SIGKILL where seconds < Self.tooSoonForMemoryPressure:
            return ", which this early usually means macOS refused to run it at all — a "
                + "quarantined or unsigned build — rather than memory pressure."
        case SIGKILL:
            return ", which usually means the system reclaimed its memory."
        case SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP:
            return ", which means it crashed."
        default:
            return "."
        }
    }

    /// Before this, a SIGKILL is about the binary; after it, about the memory. Two seconds
    /// is long enough for any real load to have started reading weights and short enough
    /// that a Gatekeeper kill is always inside it.
    static let tooSoonForMemoryPressure: TimeInterval = 2

    /// Durations as a person would say them: seconds up to two minutes, then minutes, then
    /// hours. Exact seconds are noise once a load has been going for minutes, and "0
    /// seconds" is not a thing anyone says.
    ///
    /// Rounded before it is classified, not after, or 119.6 seconds is "120 seconds" and an
    /// hour is "60 minutes".
    static func spell(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 1 else { return "less than a second" }
        let whole = Int(seconds.rounded())
        if whole < 120 { return "\(whole) second\(whole == 1 ? "" : "s")" }
        let minutes = Int((Double(whole) / 60).rounded())
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = Int((Double(minutes) / 60).rounded())
        return "\(hours) hour\(hours == 1 ? "" : "s")"
    }

    /// The machine-readable half of the same fact.
    public var reason: LoadFailure.Reason {
        switch self {
        case .processEnded(let termination):
            switch termination.stopRequest {
            case .replaced: return .replaced
            case .unload: return .cancelled
            case .none: return termination.signal == nil ? .exited : .killed
            }
        case .neverAnswered: return .timedOut
        case .cancelled: return .cancelled
        }
    }

    /// Whether this app — or the person using it — is the reason the load ended.
    ///
    /// The distinction the summary turns on: a runtime that was stopped on purpose is not
    /// diagnosable, and reading its log for advice puts words in its mouth. A load replaced
    /// while its log happened to carry "failed to allocate" was being reported as running
    /// out of memory, which is a bug report nobody can act on.
    public var wasAppCaused: Bool {
        switch self {
        case .processEnded(let termination): termination.stopRequest != nil
        case .cancelled: true
        case .neverAnswered: false
        }
    }

    var exitStatus: Int32? {
        guard case .processEnded(let termination) = self else { return nil }
        return termination.exitStatus
    }

    var signal: Int32? {
        guard case .processEnded(let termination) = self else { return nil }
        return termination.signal
    }
}

/// Shared bits of turning a runtime's output into a failure, so llama.cpp and MLX cannot
/// drift into describing the same ending two different ways.
public enum LoadDiagnosis {

    /// How much of a failed server's log travels with the failure.
    ///
    /// This is the part a phone puts behind a tap, not the part it shows: it rides on every
    /// `/status` poll, so it is bounded twice — by lines, because the interesting part of a
    /// llama.cpp failure is always at the end, and by characters, because one line of a
    /// metadata dump can be enormous.
    public static let detailLines = 20
    public static let detailCharacters = 4_000

    /// Reads how a load ended, and — when this app is what stopped it — finds out whether
    /// another load is the reason.
    ///
    /// Shared by both runtimes rather than written twice: they end loads in exactly the same
    /// way, and two copies of this would be two chances to describe the same ending
    /// differently.
    static func ending(
        of server: ServerProcess,
        readiness: OpenAIChatClient.Readiness,
        claim: LoadArbiter.Claim,
        arbiter: LoadArbiter,
        timeout: TimeInterval
    ) async -> (ending: LoadEnding, replacedBy: String?) {
        // Cancelled while the process was still perfectly alive: the load was called off,
        // and nothing happened to the runtime at all.
        if readiness == .cancelled, server.hasEnded == false { return (.cancelled(by: nil), nil) }
        guard let termination = await server.termination else {
            return (.neverAnswered(after: timeout), nil)
        }
        guard termination.stopRequest != nil else { return (.processEnded(termination), nil) }
        // This app stopped it. Either another load took the machine or the model was
        // unloaded, and only the arbiter can tell those apart — a moment later.
        guard let newer = await arbiter.displacement(of: claim) else {
            return (.processEnded(termination), nil)
        }
        var replaced = termination
        replaced.stopRequest = .replaced
        return (.processEnded(replaced), newer.model)
    }

    /// The failure a runtime reports, assembled from the ending and the sentence that
    /// runtime made of it.
    static func failure(
        ending: LoadEnding, summary: String, log: String, runtime: RuntimeKind,
        modelID: String
    ) -> LoadFailure {
        LoadFailure(
            reason: ending.reason,
            summary: summary,
            detail: tail(of: log),
            runtime: runtime,
            exitStatus: ending.exitStatus,
            signal: ending.signal,
            wasReplaced: ending.reason == .replaced,
            modelID: modelID
        )
    }

    /// The tail of a log, or nil when there is nothing worth carrying.
    ///
    /// Paths are reduced to file names on the way out. See `withoutPaths`.
    public static func tail(of log: String) -> String? {
        let tail = withoutPaths(
            log
                .split(separator: "\n", omittingEmptySubsequences: true)
                .suffix(detailLines)
                .joined(separator: "\n")
        )
        guard !tail.isEmpty else { return nil }
        guard tail.count > detailCharacters else { return tail }
        return "…" + tail.suffix(detailCharacters)
    }

    /// Absolute paths, reduced to the name of the file at the end of them.
    ///
    /// A llama.cpp log names the model file on most of its opening lines, and that path is
    /// somebody's home: which drive, which folders, what those folders are called. This
    /// text travels — to a phone, and on `/events` — so the part that identifies the model
    /// stays and the part that describes the owner's disk does not. It is not the only
    /// guard: a chat-scope device and the swarm are sent no `detail` at all.
    static func withoutPaths(_ text: String) -> String {
        guard let expression = absolutePath else { return text }
        let whole = text as NSString
        var out = ""
        var cursor = 0
        for match in expression.matches(
            in: text, range: NSRange(location: 0, length: whole.length)
        ) {
            out += whole.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            let path = whole.substring(with: match.range)
            let name = path.split(separator: "/").last.map(String.init) ?? path
            // The match can end on the spaces that followed the path; keep them, or the
            // file name runs into the next word.
            let trailing = String(path.reversed().prefix { $0 == " " })
            out += name.trimmingCharacters(in: .whitespaces) + trailing
            cursor = match.range.location + match.range.length
        }
        return out + whole.substring(from: cursor)
    }

    /// Two or more slash-separated segments, starting at a slash. Quotes, brackets, commas
    /// and colons end a segment, because that is what a log puts around a path — and a
    /// segment may contain spaces, because folder names do.
    private static let absolutePath = try? NSRegularExpression(
        pattern: #"/(?:[^/\n'"(),:]+/)+[^/\n'"(),:]*"#
    )
}

// MARK: - Keeping the last one

/// The last load that failed, kept where the control API can still find it.
///
/// It has to live outside the runtime object because the app throws that object away the
/// moment a load fails — which is precisely when a phone polling `/status` wants to know
/// what happened. The instance form is for tests, exactly as `ChildProcessRegistry` does
/// it: a suite builds its own and cannot see, or disturb, another suite's failures.
public final class LoadFailureRecorder: @unchecked Sendable {

    public static let shared = LoadFailureRecorder()

    private let lock = NSLock()
    private var failure: LoadFailure?

    public init() {}

    public var last: LoadFailure? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    public func record(_ failure: LoadFailure) {
        lock.lock()
        self.failure = failure
        lock.unlock()
    }

    /// Called when a load succeeds, so a stale sentence cannot be shown beside a model that
    /// is running perfectly well.
    public func clear() {
        lock.lock()
        failure = nil
        lock.unlock()
    }
}

import Foundation
import SiliconElevenLabs

/// How a live screen reaches the account, the devices and the output folder. The app's comes
/// from `AppModel`; a test builds one around a client on the fake transport, the fake socket and
/// the fake audio.
struct LiveContext {
    /// The linked account's client, read when a session starts. Nil means not linked.
    var client: @MainActor () -> ElevenLabsClient?
    /// Where sockets are opened.
    var connector: @MainActor () -> any ElevenLabsSocketConnector
    /// The microphone and speaker.
    var audio: @MainActor () -> any LiveAudioIO
    /// Where saved audio and transcripts go. Nil: saving is not offered.
    var sink: @MainActor () -> (any ElevenLabsFileSink)?
    /// The pane, for the account session and the billable-run count. Optional for tests.
    var pane: ElevenLabsPaneState?
    var limits = ElevenLabsRealtime.Limits()
    /// How many microphone chunks may wait for a socket that has stopped taking them.
    var microphoneQueueCapacity = LiveMicrophoneQueue.defaultCapacity
    /// Live transcription's commits and its wait for the last text.
    var transcription = LiveTranscriptionTiming()

    @MainActor static func app(_ model: AppModel) -> LiveContext {
        LiveContext(
            client: { [weak model] in model?.elevenLabsClient },
            connector: { [weak model] in model?.elevenLabsSocketConnector ?? UnavailableElevenLabsSocketConnector() },
            audio: { LiveAudioDevices.shared },
            sink: { [weak model] in model.flatMap { $0.elevenLabsLinked ? $0.elevenLabsSink() : nil } },
            pane: model.elevenLabsPane
        )
    }

    /// A realtime opener on the current client, or nil when nothing is linked.
    /// What a session that stopped taking microphone audio ends with.
    static let microphoneFellBehind = "The connection stopped taking microphone audio, so the session was ended rather "
        + "than leave a gap in what was said. What was sent may have been billed."

    /// What a session whose microphone was stopped by a device change ends with. Ended, not
    /// restarted: the new device needs its format and (for an agent) voice processing set up
    /// again, and a session that silently switched microphones mid-bill is worse than one Start.
    static let devicesChanged = "The audio device changed (headphones, or another microphone), which stops the "
        + "microphone, so the session was ended rather than go on without hearing you. Start again to use the new "
        + "device. What was sent may have been billed."

    @MainActor func realtime() -> ElevenLabsRealtime? {
        client().map { ElevenLabsRealtime(client: $0, connector: connector(), limits: limits) }
    }
}

/// Live transcription's commits and Stop's wait for the last text.
struct LiveTranscriptionTiming: Sendable {
    /// Committing by hand, seconds of audio after a commit from which the next one is made at the
    /// first quiet moment, so a word is not cut where that can be helped. ElevenLabs recommends one
    /// every 20–30 s, and commits on its own after about 36 s of audio — which would be a
    /// committed transcript nobody asked for, and so throw off the count Stop waits on.
    var commitEvery: Double = 20
    /// …and the latest it is made, quiet or not, so a loud room still commits before ElevenLabs does.
    var commitCap: Double = 28
    /// A quiet moment: the last 100 ms sent below this RMS level (about −34 dBFS).
    var quietLevel: Float = 0.02
    /// How fast a file is sent: a second of audio every this long.
    var filePace: Duration = .milliseconds(100)
    /// How long Stop waits for the last text at most.
    var finalWait: Duration = .seconds(4)
    /// Committing at pauses: after the first text that follows Stop's commit, how long nothing more
    /// must arrive — an automatic commit's text can land just before Stop's own.
    var finalQuiet: Duration = .milliseconds(750)

    /// Whether to commit by hand right after `chunk` went, `secondsSinceCommit` after the last
    /// commit: from `commitEvery` on at a quiet moment (`chunk`'s last 100 ms, 16-bit PCM, below
    /// `quietLevel`; audio in another encoding is never taken as quiet), and at `commitCap` whatever.
    func commitsAfter(_ chunk: Data, pcm: Bool, secondsSinceCommit: Double, bytesPerSecond: Int) -> Bool {
        guard secondsSinceCommit >= commitEvery else { return false }
        if secondsSinceCommit >= max(commitCap, commitEvery) { return true }
        return pcm && LiveAudioLevel.tailRMS(ofPCM16: chunk, bytes: bytesPerSecond / 10) < quietLevel
    }

    /// The hand-commit choice, as the commit picker shows it.
    var handCommitLabel: String {
        "When I press Stop, and every \(Int(commitEvery))–\(Int(max(commitCap, commitEvery))) s at a quiet moment"
    }
}

/// The app's one set of audio devices, made when a live screen first needs them.
@MainActor
enum LiveAudioDevices {
    static let shared: any LiveAudioIO = LiveEngineAudio()
}

/// What a live session belongs to: the client (by identity, held weakly) and the pane's account
/// session at the moment it started. Another key, another region, a disconnect — any of them
/// makes it stale, and a stale session is ended rather than left talking to the old account.
@MainActor
struct LiveAccountBinding {
    private weak var client: ElevenLabsClient?
    private let epoch: Int?
    private let bound: Bool

    init(client: ElevenLabsClient?, pane: ElevenLabsPaneState?) {
        self.client = client
        epoch = pane?.epoch
        bound = client != nil
    }

    func isCurrent(in context: LiveContext) -> Bool {
        guard bound, let client, let now = context.client(), now === client, now.region == client.region else {
            return false
        }
        if let pane = context.pane, pane.epoch != epoch { return false }
        return true
    }
}

/// A live screen's session, as the pane ends it when the account changes.
@MainActor
protocol ElevenLabsLiveWork: AnyObject {
    /// Ends the session at once (declining whatever was asked of the owner). True when a session
    /// that may have been billed was cut off.
    func endForAccountChange() -> Bool
}

/// The pseudo-operations live files are written under: not in the REST catalog (the sockets are
/// not in the OpenAPI spec), named so the output list and media table say what made them.
enum ElevenLabsLiveOperations {
    static let speech = operation("realtime_text_to_speech", "/v1/text-to-speech/{voice_id}/stream-input", .generate)
    static let transcription = operation("realtime_speech_to_text", "/v1/speech-to-text/realtime", .generate)
    static let conversation = operation("realtime_agent_conversation", "/v1/convai/conversation", .realWorld)

    private static func operation(_ id: String, _ path: String, _ risk: ElevenLabsRisk) -> ElevenLabsOperation {
        ElevenLabsOperation(
            id: id, method: "WSS", path: path, group: "Realtime", summary: id.replacingOccurrences(of: "_", with: " "),
            details: "", deprecated: false, parameters: [], body: nil, response: .events, risk: risk,
            billable: true, returnsCredential: false, supportsStreaming: true
        )
    }
}

/// How a session ended, for the line under the controls.
enum LiveOutcome: Equatable, Sendable {
    /// Nothing was opened, so nothing was billed.
    case notStarted(String)
    /// It ran and ended as asked (or the server ended it normally).
    case ended(String)
    /// It ended in a way that leaves its billing unknown: a dropped socket, a cancel while
    /// starting, a server error — say so, and do not reconnect.
    case mayHaveBeenBilled(String)

    /// Shown on screen: every URL's query and every signature or token masked, whatever made it.
    var message: String {
        switch self {
        case .notStarted(let text), .ended(let text), .mayHaveBeenBilled(let text): ElevenLabsRealtimeRedaction.scrub(text)
        }
    }

    var isWarning: Bool {
        if case .ended = self { return false }
        return true
    }

    static let accountChanged =
        "Ended because the ElevenLabs account or region changed. What it had sent may have been billed to the previous account."
    static let leftScreen = "Ended because you left this screen."

    /// A failure to start, sorted by whether anything can have reached ElevenLabs.
    static func failedToStart(_ error: any Error) -> LiveOutcome {
        if let error = error as? ElevenLabsError {
            switch error {
            case .notLinked, .credentialUnavailable, .invalidArguments, .unknownOperation, .refusedHost:
                return .notStarted(ElevenLabsRunnerFailure(error).message)
            case .api(let status, _, _, _) where status < 500:
                return .notStarted(ElevenLabsRunnerFailure(error).message)
            default:
                return .mayHaveBeenBilled(ElevenLabsRunnerFailure(error).message + Self.checkFirst)
            }
        }
        let realtime = ElevenLabsRealtimeError(wrapping: error)
        switch realtime {
        case .notLinked, .credentialUnavailable, .invalidConfiguration, .refusedHost:
            return .notStarted(realtime.description)
        case .handshakeFailed(let status, _) where (status ?? 500) < 500:
            return .notStarted(realtime.description)
        case .signedLink(let inner):
            if case .api(let status, _, _, _) = inner, status < 500 { return .notStarted(realtime.description) }
            return .mayHaveBeenBilled(realtime.description + Self.checkFirst)
        default:
            return .mayHaveBeenBilled(realtime.description + Self.checkFirst)
        }
    }

    static let checkFirst = " It may have started on ElevenLabs' side and been billed; check before trying again."
}

/// Seconds as "0:42" or "1:02:03".
enum LiveClock {
    /// An amount of audio: "4.3 s" under a minute, the clock above.
    static func amount(_ seconds: TimeInterval) -> String {
        seconds < 60 ? String(format: "%.1f s", max(0, seconds)) : text(seconds)
    }

    static func text(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        let hours = whole / 3_600, minutes = whole / 60 % 60, rest = whole % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

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
    @MainActor func realtime() -> ElevenLabsRealtime? {
        client().map { ElevenLabsRealtime(client: $0, connector: connector(), limits: limits) }
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

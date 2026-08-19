import Foundation

/// The live state of the on-screen persona, shared between the app (which writes it as
/// the character speaks) and the control server (which serves it to OBS).
///
/// A lock rather than an actor: the audio meter updates this many times a second from a
/// timer, and the HTTP handler reads it from another queue — both want a plain
/// synchronous get and set, and neither wants to await the other.
public final class OverlayBroadcast: @unchecked Sendable {
    public static let shared = OverlayBroadcast()

    public struct State: Codable, Sendable, Equatable {
        /// Whether the character is talking right now.
        public var speaking: Bool = false
        /// How loudly, 0–1 — what drives the mouth.
        public var level: Double = 0
        /// Optional line shown as a caption under the character.
        public var caption: String = ""
        /// The persona's name, for the overlay's own labelling.
        public var name: String = ""
        /// Changes whenever the portrait does, so the page reloads the image only then.
        public var portraitVersion: Int = 0
        /// Where the lips are, as a fraction of the portrait's height from the top —
        /// found by Vision rather than assumed, so the jaw hinges at the mouth and not
        /// at whatever a fixed line happened to land on.
        public var mouthTop: Double = 0.66
        /// Whether a second, mouth-open drawing is available to cross to.
        public var hasOpenMouth: Bool = false
        /// Whether a closed-eyes drawing is available, so blinks can be real.
        public var hasClosedEyes: Bool = false
        /// Where the overlay can read live face tracking, when it is running. The
        /// page polls this directly rather than through the app: head motion wants
        /// every frame it can get, and a relay would cost it latency for nothing.
        public var trackerURL: String = ""
    }

    private let lock = NSLock()
    private var _state = State()
    private var _portrait: Data?
    private var _openMouthPortrait: Data?
    private var _closedEyesPortrait: Data?

    public var state: State {
        get { lock.lock(); defer { lock.unlock() }; return _state }
        set { lock.lock(); _state = newValue; lock.unlock() }
    }

    public var portrait: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _portrait
    }

    public var openMouthPortrait: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _openMouthPortrait
    }

    public var closedEyesPortrait: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _closedEyesPortrait
    }

    /// Replaces the portrait and bumps the version so open overlays pick it up.
    public func setPortrait(
        _ data: Data?, name: String, mouthTop: Double = 0.66,
        openMouth: Data? = nil, closedEyes: Data? = nil
    ) {
        lock.lock()
        _portrait = data
        _openMouthPortrait = openMouth
        _closedEyesPortrait = closedEyes
        _state.name = name
        _state.mouthTop = mouthTop
        _state.hasOpenMouth = openMouth != nil
        _state.hasClosedEyes = closedEyes != nil
        _state.portraitVersion += 1
        lock.unlock()
    }

    /// The address the overlay should poll for tracking, or empty when the tracker
    /// is not running and the character should fall back to the voice.
    public func setTrackerURL(_ url: String) {
        lock.lock()
        _state.trackerURL = url
        lock.unlock()
    }

    public func setSpeaking(_ speaking: Bool, level: Double = 0, caption: String? = nil) {
        lock.lock()
        _state.speaking = speaking
        _state.level = level
        if let caption { _state.caption = caption }
        lock.unlock()
    }
}

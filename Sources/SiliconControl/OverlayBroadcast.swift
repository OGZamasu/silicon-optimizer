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
    }

    private let lock = NSLock()
    private var _state = State()
    private var _portrait: Data?

    public var state: State {
        get { lock.lock(); defer { lock.unlock() }; return _state }
        set { lock.lock(); _state = newValue; lock.unlock() }
    }

    public var portrait: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _portrait
    }

    /// Replaces the portrait and bumps the version so open overlays pick it up.
    public func setPortrait(_ data: Data?, name: String) {
        lock.lock()
        _portrait = data
        _state.name = name
        _state.portraitVersion += 1
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

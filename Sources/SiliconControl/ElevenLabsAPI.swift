import Foundation

// MARK: - ElevenLabs over the control API

/// `/elevenlabs/*`: the owner's ElevenLabs account, reached through the app that holds its key.
///
/// This module does not link the ElevenLabs client, and neither does the MCP bridge that links
/// this module. The routes carry JSON between HTTP and the host; only the app talks to
/// ElevenLabs, so the key never leaves it.
public enum ElevenLabsControl {

    /// Whether a request path is one of the ElevenLabs routes, for the caller policy.
    ///
    /// By its first segment, case-insensitively, the way the router splits a path. `//elevenlabs/call`
    /// is routed as `/elevenlabs/call`, and `/ElevenLabs/call` is refused rather than
    /// answered 404, so there is no spelling of the path that slips past the rule.
    public static func isElevenLabsPath(_ path: String) -> Bool {
        guard let first = path.split(separator: "/").first else { return false }
        return first.lowercased() == "elevenlabs"
    }

    /// What every caller but this Mac's own control token is told, on either listener.
    ///
    /// Paired phones at full scope included: ElevenLabs calls spend the owner's credits and
    /// some place real phone calls, and that is the owner's decision to make at the Mac, not
    /// a phone's, the same rule as the TypeSafe budget.
    public static let onlyThisMac =
        "ElevenLabs spends the owner's credits, so only this Mac's own control token can use it."
}

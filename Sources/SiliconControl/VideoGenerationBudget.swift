import Foundation

/// End-to-end limits for synchronous video tools. The local adapter gives an accepted
/// job twelve hours including its queue; each outer caller must also allow submission,
/// a final in-flight status request, the artifact transfer, and response overhead.
/// Keep the Python provider's VIDEO_* constants in sync (covered by its contract test).
public enum VideoGenerationBudget {
    public static let nodeJobSeconds = 12 * 60 * 60
    public static let nodeRequestSeconds = 120
    public static let statusRequestSeconds = 30
    public static let downloadSeconds = 600
    public static let responseOverheadSeconds = 60
    public static let controlSeconds = nodeJobSeconds + 2 * nodeRequestSeconds
        + downloadSeconds + responseOverheadSeconds
    public static let toolSeconds = controlSeconds + responseOverheadSeconds
    public static let toolMilliseconds = toolSeconds * 1000
}

import Foundation

/// What a swarm node says about a job it is running.
///
/// Every delegating tool — clips, meshes, portrait takes — polls the same
/// `GET /v1/jobs/{id}` and gets the same fields back, so they all read one type and show one
/// kind of line. Before this, each tool invented its own wording and most of them showed a
/// spinner for five minutes, which tells someone nothing about whether to wait or go away.
///
/// Parsed liberally on purpose: the node is maintained on another machine, and a renamed key
/// there should cost a detail in the caption, not the whole render.
public struct NodeJobProgress: Sendable, Equatable {

    /// What the node is doing right now, in its own words — "video-denoise", "retopology".
    public var stage: String?
    /// 0...1 when the node reports one.
    public var fraction: Double?
    public var step: Int?
    public var stepsTotal: Int?
    /// Seconds the node expects to still need.
    public var eta: TimeInterval?
    /// Seconds since the node started the job. Not the same as time since submission: a job
    /// can sit in the queue first.
    public var elapsed: TimeInterval?
    /// Waiting for the card rather than using it. A queued job reports no progress, and
    /// showing its 0% as though it were rendering reads as a stall.
    public var isQueued = false
    /// How many jobs are ahead of this one, when the node counts them.
    public var queuePosition: Int?

    public init() {}

    /// A stage the app itself knows about — sending, downloading — where there is no node
    /// report to parse yet.
    public static func stage(_ name: String) -> NodeJobProgress {
        var progress = NodeJobProgress()
        progress.stage = name
        return progress
    }

    public init(from status: [String: Any]) {
        let state = ((status["status"] ?? status["state"]) as? String)?.lowercased() ?? ""
        isQueued = ["queued", "pending", "waiting"].contains(state)
        queuePosition = Self.integer(status, "queue_position", "position", "queue_index")

        stage = (status["stage"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        step = Self.integer(status, "step", "current_step")
        stepsTotal = Self.integer(status, "steps_total", "total_steps", "steps")
        eta = Self.number(status, "eta_seconds", "eta_s", "eta")
        elapsed = Self.number(status, "elapsed_s", "elapsed_seconds", "elapsed")

        if let raw = Self.number(status, "progress", "percent", "percent_complete") {
            // Some services count 0–1 and some count 0–100. Anything above 1 can only be the
            // second kind, and clamping keeps a 105% bar off the screen.
            let normalised = raw > 1 ? raw / 100 : raw
            fraction = min(max(normalised, 0), 1)
        } else if let step, let stepsTotal, stepsTotal > 0 {
            fraction = min(max(Double(step) / Double(stepsTotal), 0), 1)
        }
    }

    /// The one line every swarm tool shows: what it is doing, how far in, how much longer.
    ///
    /// Only the parts the node actually reported appear. A node that says nothing but
    /// "running" produces the fallback rather than a row of empty separators.
    public func line(fallback: String = "Working") -> String {
        if isQueued {
            guard let queuePosition, queuePosition > 0 else { return "Queued on the node" }
            return queuePosition == 1
                ? "Queued on the node — 1 job ahead"
                : "Queued on the node — \(queuePosition) jobs ahead"
        }

        var parts: [String] = []
        if let stage, !stage.isEmpty { parts.append(Self.readable(stage)) }
        if let step, let stepsTotal, stepsTotal > 0 { parts.append("step \(step) of \(stepsTotal)") }
        if let fraction { parts.append("\(Int((fraction * 100).rounded()))%") }
        if let elapsed, elapsed >= 1 { parts.append("\(Self.duration(elapsed)) in") }
        if let eta, eta >= 1 { parts.append("~\(Self.duration(eta)) left") }
        return parts.isEmpty ? fallback : parts.joined(separator: " · ")
    }

    /// "video-denoise" is how the node names a stage and how its logs name it; a caption in an
    /// app should still read like English.
    static func readable(_ stage: String) -> String {
        let spaced = stage.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// h:mm:ss past an hour, m:ss below it. Zero-padded minutes so the number stops jittering
    /// as it counts down.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, remainder) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    private static func number(_ status: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            if let value = status[key] as? Double { return value }
            if let value = status[key] as? Int { return Double(value) }
            if let text = status[key] as? String, let value = Double(text) { return value }
        }
        return nil
    }

    private static func integer(_ status: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let value = status[key] as? Int { return value }
            if let value = status[key] as? Double { return Int(value) }
            if let text = status[key] as? String, let value = Int(text) { return value }
        }
        return nil
    }
}

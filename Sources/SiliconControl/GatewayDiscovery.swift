import Foundation

/// A well-known file naming the gateway's loopback endpoint, so local agents find it
/// without spelunking through `lsof`. No secrets ever go in here — the gateway is
/// loopback-only and token-free by design, and this file must stay as harmless as it
/// is convenient.
public enum GatewayDiscovery {

    public static func fileURL(directory: URL) -> URL {
        directory.appendingPathComponent("gateway.json")
    }

    public static func write(port: Int, pid: Int32, version: String, directory: URL) {
        let payload: [String: Any] = [
            "service": "silicon-optimizer-gateway",
            "base_url": "http://127.0.0.1:\(port)/v1",
            "port": port,
            "pid": Int(pid),
            "version": version,
            "started_at": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try? data.write(to: fileURL(directory: directory), options: .atomic)
    }

    public static func remove(directory: URL) {
        try? FileManager.default.removeItem(at: fileURL(directory: directory))
    }

    /// Whether the file describes a gateway that is actually alive — stale files from a
    /// crashed process name a dead pid, and readers should treat them as absent.
    public static func isAlive(_ payload: [String: Any]) -> Bool {
        guard let pid = payload["pid"] as? Int else { return false }
        return kill(pid_t(pid), 0) == 0
    }
}
import Foundation

/// A well-known, owner-readable file naming the gateway's loopback endpoint and per-launch
/// bearer. Sandboxed helpers can be granted this capability without making every same-host
/// process or hostile web origin an implicit gateway administrator.
public enum GatewayDiscovery {

    public static func fileURL(directory: URL) -> URL {
        directory.appendingPathComponent("gateway.json")
    }

    public static func write(
        port: Int, pid: Int32, version: String, token: String, directory: URL
    ) {
        let payload: [String: Any] = [
            "service": "silicon-optimizer-gateway",
            "base_url": "http://127.0.0.1:\(port)/v1",
            "port": port,
            "pid": Int(pid),
            "token": token,
            "version": version,
            "started_at": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // createDirectory leaves an existing directory's mode unchanged. Tighten it before
        // the atomic writer creates its temporary file so there is no world-readable window.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
        let url = fileURL(directory: directory)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
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

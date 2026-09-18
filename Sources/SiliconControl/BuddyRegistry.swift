import Foundation

/// The register of paired devices: it owns `buddy.json`, holds the one open pairing code,
/// and answers the only question the server asks on every request — "is this bearer a
/// device I know?".
///
/// An actor because it is read from every connection and written from the Settings window,
/// and because the rate-limit state has to be one shared count, not one per listener.
public actor BuddyRegistry {

    /// Pairing is the single unauthenticated POST on this server, so a wrong code has to
    /// cost something. Six digits is only a safe secret at this rate: five tries a minute,
    /// and ten failures shuts an address out for a quarter of an hour.
    public static let attemptsPerMinute = 5
    public static let failuresBeforeLockout = 10
    public static let lockoutDuration: TimeInterval = 900

    /// Enough sources to survive a phone retrying behind CGNAT, few enough that a spray of
    /// forged addresses cannot grow this without bound.
    private static let trackedSources = 256

    public static let shared = BuddyRegistry()

    private let url: URL
    private var config: BuddyConfig
    private var invitation: BuddyInvitation?
    private var attempts: [String: Attempt] = [:]

    private struct Attempt {
        var recent: [Date] = []
        var failures = 0
        var lockedUntil: Date?
        var touchedAt = Date()
    }

    public init(url: URL = BuddyConfig.configURL) {
        self.url = url
        self.config = BuddyConfig.load(from: url)
    }

    // MARK: - The toggle

    public var allowsTailnetDevices: Bool { config.allowTailnetDevices }

    public func setAllowsTailnetDevices(_ allowed: Bool) {
        guard config.allowTailnetDevices != allowed else { return }
        config.allowTailnetDevices = allowed
        config.save(to: url)
    }

    // MARK: - Invitations

    /// Opens an invitation, replacing any code still on screen: two live codes would mean
    /// the owner cannot tell which screen admitted which device.
    @discardableResult
    public func invite(
        host: String, port: Int,
        lifetime: TimeInterval = BuddyPairing.codeLifetime, now: Date = Date()
    ) -> BuddyInvitation {
        let fresh = BuddyInvitation(
            code: BuddyPairing.makeCode(), host: host, port: port,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        invitation = fresh
        return fresh
    }

    public func openInvitation(at moment: Date = Date()) -> BuddyInvitation? {
        guard let invitation, invitation.isLive(at: moment) else { return nil }
        return invitation
    }

    public func cancelInvitation() { invitation = nil }

    // MARK: - Pairing

    public enum PairOutcome: Sendable, Equatable {
        case paired(ControlAPI.BuddyPairResponse)
        case refused(status: Int, message: String)
    }

    /// Spends the open code and mints the device its own credential. The token leaves here
    /// once, in the response; what stays behind is its digest.
    public func pair(
        _ request: ControlAPI.BuddyPairRequest, from source: String,
        macName: String, port: Int, now: Date = Date()
    ) -> PairOutcome {
        if let refusal = throttle(source, at: now) { return refusal }

        guard let name = SwarmPairing.normalizedClientName(request.deviceName),
              let platform = SwarmPairing.normalizedClientName(request.platform)
        else {
            recordFailure(source, at: now)
            return .refused(status: 400, message: "The request does not name a device.")
        }
        guard let invitation, invitation.isLive(at: now) else {
            recordFailure(source, at: now)
            return .refused(
                status: 403,
                message: "No pairing code is open. Open Settings → Silicon Buddy on the Mac "
                    + "and tap Pair a device."
            )
        }
        let offered = request.code.filter { !$0.isWhitespace }
        guard BuddyPairing.digestsMatch(offered, invitation.code) else {
            recordFailure(source, at: now)
            return .refused(status: 403, message: "That pairing code is not the one on screen.")
        }

        // One use. The code burns whether or not the device ever comes back.
        self.invitation = nil
        attempts[source] = nil

        let token = BuddyPairing.makeDeviceToken()
        let device = BuddyDevice(
            id: UUID().uuidString, name: name, platform: platform,
            tokenHash: BuddyPairing.hash(token: token), pairedAt: now, lastSeen: now
        )
        config.devices.append(device)
        config.save(to: url)

        return .paired(ControlAPI.BuddyPairResponse(
            deviceID: device.id, token: token, macName: macName, port: port
        ))
    }

    /// Nil when the address may try, a refusal when it may not.
    private func throttle(_ source: String, at now: Date) -> PairOutcome? {
        pruneSources(at: now)
        var record = attempts[source] ?? Attempt()
        record.touchedAt = now
        if let until = record.lockedUntil {
            guard now >= until else {
                attempts[source] = record
                return .refused(
                    status: 429,
                    message: "Too many failed pairing attempts. Try again later."
                )
            }
            // The lockout served its purpose; the address starts over rather than staying
            // one wrong guess away from another quarter of an hour.
            record.lockedUntil = nil
            record.failures = 0
            record.recent = []
        }
        record.recent = record.recent.filter { now.timeIntervalSince($0) < 60 }
        guard record.recent.count < Self.attemptsPerMinute else {
            attempts[source] = record
            return .refused(status: 429, message: "Too many pairing attempts. Wait a minute.")
        }
        record.recent.append(now)
        attempts[source] = record
        return nil
    }

    private func recordFailure(_ source: String, at now: Date) {
        var record = attempts[source] ?? Attempt()
        record.failures += 1
        record.touchedAt = now
        if record.failures >= Self.failuresBeforeLockout {
            record.lockedUntil = now.addingTimeInterval(Self.lockoutDuration)
        }
        attempts[source] = record
    }

    private func pruneSources(at now: Date) {
        guard attempts.count > Self.trackedSources else { return }
        let stale = attempts
            .sorted { $0.value.touchedAt < $1.value.touchedAt }
            .prefix(attempts.count - Self.trackedSources)
        for entry in stale where entry.value.lockedUntil.map({ now >= $0 }) ?? true {
            attempts[entry.key] = nil
        }
    }

    // MARK: - Using a device token

    /// The device that owns this bearer, with its last-seen time stamped. An unknown bearer
    /// gets nil, which is what turns into the server's 401.
    @discardableResult
    public func authorize(bearer: String, at now: Date = Date()) -> ControlAPI.BuddyDeviceSummary? {
        let offered = BuddyPairing.hash(token: bearer)
        guard let index = config.devices.firstIndex(where: {
            BuddyPairing.digestsMatch($0.tokenHash, offered)
        }) else { return nil }

        // Writing the file on every request would put a disk write in front of every token
        // the model streams. A minute's resolution is all "last seen" ever means.
        let previous = config.devices[index].lastSeen
        config.devices[index].lastSeen = now
        if previous.map({ now.timeIntervalSince($0) > 60 }) ?? true {
            config.save(to: url)
        }
        return config.devices[index].summary
    }

    public func devices() -> [ControlAPI.BuddyDeviceSummary] {
        config.devices.sorted { $0.pairedAt < $1.pairedAt }.map(\.summary)
    }

    /// True when a device was there to revoke, so the server can tell a stale id from a
    /// successful revocation.
    @discardableResult
    public func revoke(deviceID: String) -> Bool {
        let before = config.devices.count
        config.devices.removeAll { $0.id == deviceID }
        guard config.devices.count != before else { return false }
        config.save(to: url)
        return true
    }

    /// The whole record, for the Settings window and for tests.
    public func snapshot() -> BuddyConfig { config }
}

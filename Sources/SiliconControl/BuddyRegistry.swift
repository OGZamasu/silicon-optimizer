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

    /// A code is burned after this many wrong guesses from anywhere at all. The per-source
    /// limiter alone is a botnet away from useless: ten addresses trying five a minute is
    /// still fifty guesses a minute at a six-digit secret.
    public static let guessesPerCode = 10

    /// The most addresses this keeps failure counts for. Enough to survive a phone retrying
    /// behind CGNAT; bounded so a spray of forged sources cannot grow it without limit.
    private static let trackedSources = 256

    public static let shared = BuddyRegistry()

    private let url: URL
    private var config: BuddyConfig
    private var invitation: BuddyInvitation?
    /// Wrong guesses against the code currently open, from every source together.
    private var invitationGuesses = 0
    private var attempts: [String: Attempt] = [:]
    /// Streams each device is holding open, and how to end them.
    private var liveStreams: [String: [UUID: @Sendable () -> Void]] = [:]

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

    /// Turning this off suspends every paired device rather than forgetting it: the list
    /// survives, the tokens stop working, and anything a device is holding open ends now.
    public func setAllowsTailnetDevices(_ allowed: Bool) {
        guard config.allowTailnetDevices != allowed else { return }
        config.allowTailnetDevices = allowed
        config.save(to: url)
        if !allowed {
            invitation = nil
            invitationGuesses = 0
            endEveryStream()
        }
    }

    // MARK: - Invitations

    /// Opens an invitation, replacing any code still on screen: two live codes would mean
    /// the owner cannot tell which screen admitted which device.
    @discardableResult
    public func invite(
        host: String, port: Int, scope: BuddyScope = .full,
        lifetime: TimeInterval = BuddyPairing.codeLifetime, now: Date = Date()
    ) -> BuddyInvitation {
        let fresh = BuddyInvitation(
            code: BuddyPairing.makeCode(), host: host, port: port, scope: scope,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        invitation = fresh
        invitationGuesses = 0
        return fresh
    }

    public func openInvitation(at moment: Date = Date()) -> BuddyInvitation? {
        guard let invitation, invitation.isLive(at: moment) else { return nil }
        return invitation
    }

    public func cancelInvitation() {
        invitation = nil
        invitationGuesses = 0
    }

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
        // One sentence for "no code is open" and for "wrong code" alike. Two would tell an
        // outsider exactly when the owner is standing at the Settings window.
        let offered = request.code.filter { !$0.isWhitespace }
        guard let invitation, invitation.isLive(at: now),
              BuddyPairing.digestsMatch(offered, invitation.code)
        else {
            recordFailure(source, at: now)
            noteWrongCode()
            return .refused(status: 403, message: Self.wrongCode)
        }

        // One use. The code burns whether or not the device ever comes back.
        self.invitation = nil
        invitationGuesses = 0
        attempts[source] = nil

        let token = BuddyPairing.makeDeviceToken()
        let device = BuddyDevice(
            id: UUID().uuidString, name: name, platform: platform, scope: invitation.scope,
            tokenHash: BuddyPairing.hash(token: token), pairedAt: now, lastSeen: now,
            // Recorded, so a device that was told where to dial can be told apart later
            // from one paired before that was a promise worth making.
            pairedPort: port
        )
        config.devices.append(device)
        config.save(to: url)

        return .paired(ControlAPI.BuddyPairResponse(
            deviceID: device.id, token: token, macName: macName, port: port,
            scope: device.effectiveScope.rawValue
        ))
    }

    public static let wrongCode = "That pairing code is not the one on screen."

    /// Burns the open code once the guesses against it add up, whoever made them.
    private func noteWrongCode() {
        guard invitation != nil else { return }
        invitationGuesses += 1
        if invitationGuesses >= Self.guessesPerCode {
            invitation = nil
            invitationGuesses = 0
        }
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

    /// Drops the least recently seen records once the table is over its ceiling, skipping
    /// any address still serving a lockout — forgetting one of those would hand an attacker
    /// a reset for the price of filling the table. That means the table can sit above the
    /// ceiling while a lot of addresses are locked out, which is the correct trade: the
    /// locked set is bounded by how many addresses managed ten failures each.
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
    /// gets nil, and so does every bearer once the owner turns the toggle off — suspending
    /// devices has to mean suspending them, not merely closing the door they came in by.
    @discardableResult
    public func authorize(bearer: String, at now: Date = Date()) -> ControlAPI.BuddyDeviceSummary? {
        guard config.allowTailnetDevices else { return nil }
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

    /// Whether this device is still paired and still allowed. The `/events` heartbeat asks
    /// each time round, so a revocation reaches a stream that was opened hours ago.
    public func isKnown(deviceID: String) -> Bool {
        config.allowTailnetDevices && config.devices.contains { $0.id == deviceID }
    }

    /// True when a device was there to revoke, so the server can tell a stale id from a
    /// successful revocation.
    @discardableResult
    public func revoke(deviceID: String) -> Bool {
        let before = config.devices.count
        config.devices.removeAll { $0.id == deviceID }
        guard config.devices.count != before else { return false }
        config.save(to: url)
        // Revoking has to reach what the device is already holding. Without this, an
        // `/events` subscription or a chat mid-answer outlives its credential by hours.
        endStreams(forDevice: deviceID)
        return true
    }

    // MARK: - Streams a device is holding

    /// Remembers how to end one stream, and hands back the ticket that releases it.
    ///
    /// Nil when the device is no longer one — revoked, or suspended, between the request
    /// being authorized and its stream being registered. Without that answer a revocation
    /// landing inside that window would find nothing to cancel and the stream would run on.
    public func registerStream(
        deviceID: String, cancel: @escaping @Sendable () -> Void
    ) -> UUID? {
        guard isKnown(deviceID: deviceID) else { return nil }
        let ticket = UUID()
        liveStreams[deviceID, default: [:]][ticket] = cancel
        return ticket
    }

    public func releaseStream(deviceID: String, ticket: UUID) {
        liveStreams[deviceID]?.removeValue(forKey: ticket)
        if liveStreams[deviceID]?.isEmpty == true { liveStreams[deviceID] = nil }
    }

    public func endStreams(forDevice id: String) {
        let ending = liveStreams.removeValue(forKey: id) ?? [:]
        for cancel in ending.values { cancel() }
    }

    public func endEveryStream() {
        let ending = liveStreams
        liveStreams = [:]
        for device in ending.values {
            for cancel in device.values { cancel() }
        }
    }

    /// The whole record, for the Settings window and for tests.
    public func snapshot() -> BuddyConfig { config }
}

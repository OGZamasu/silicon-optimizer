import Foundation
import Testing
@testable import SiliconControl

/// The register behind Settings → Silicon Buddy: what a pairing code is worth, how long it
/// is worth it for, and what a wrong guess costs.
@Suite("Silicon Buddy pairing register")
struct BuddyPairingRegistryTests {

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-\(UUID()).json")
    }

    /// A register with devices allowed, which is the state every pairing test is about.
    private func openRegistry(at file: URL) async -> BuddyRegistry {
        let registry = BuddyRegistry(url: file)
        await registry.setAllowsTailnetDevices(true)
        return registry
    }

    private func request(code: String) -> ControlAPI.BuddyPairRequest {
        .init(code: code, deviceName: "Galaxy S24 Ultra", platform: "android")
    }

    @Test func aCodeWorksOnceAndMintsATokenThatIsOnlyStoredAsAHash() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let registry = await openRegistry(at: file)

        let invitation = await registry.invite(host: "100.64.1.2", port: 8788)
        #expect(invitation.url
            == "siliconbuddy://pair?host=100.64.1.2&port=8788&code=\(invitation.code)")
        #expect(invitation.displayCode.count == 7)

        let outcome = await registry.pair(
            request(code: invitation.code), from: "100.64.9.9",
            macName: "Studio", port: 8788
        )
        guard case .paired(let response) = outcome else {
            Issue.record("the right code should pair"); return
        }
        #expect(response.macName == "Studio" && response.port == 8788)
        #expect(response.token.count >= 40)

        // The file on disk must not be replayable: the hash is there, the token is not.
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains(response.token))
        #expect(text.contains(BuddyPairing.hash(token: response.token)))

        // One use. A second device offering the same code gets nothing.
        let again = await registry.pair(
            request(code: invitation.code), from: "100.64.9.9",
            macName: "Studio", port: 8788
        )
        // The same sentence as a wrong code. Two different ones would tell an outsider
        // exactly when the owner is standing at the Settings window with a code open.
        #expect(again == .refused(status: 403, message: BuddyRegistry.wrongCode))
    }

    @Test func aCodeStopsWorkingAfterFiveMinutes() async {
        let registry = await openRegistry(at: temporaryFile())
        let opened = Date()
        let invitation = await registry.invite(host: "100.64.1.2", port: 8788, now: opened)

        #expect(await registry.openInvitation(at: opened.addingTimeInterval(299)) != nil)
        #expect(await registry.openInvitation(at: opened.addingTimeInterval(301)) == nil)

        let outcome = await registry.pair(
            request(code: invitation.code), from: "100.64.9.9", macName: "Studio",
            port: 8788, now: opened.addingTimeInterval(301)
        )
        guard case .refused(let status, _) = outcome else {
            Issue.record("an expired code should be refused"); return
        }
        #expect(status == 403)
    }

    @Test func fiveTriesAMinuteThenTheAddressWaits() async {
        let registry = await openRegistry(at: temporaryFile())
        let start = Date()
        await registry.invite(host: "100.64.1.2", port: 8788, now: start)

        for attempt in 0..<BuddyRegistry.attemptsPerMinute {
            let outcome = await registry.pair(
                request(code: "000000"), from: "100.64.9.9", macName: "Studio",
                port: 8788, now: start.addingTimeInterval(Double(attempt))
            )
            #expect(outcome == .refused(status: 403, message: BuddyRegistry.wrongCode))
        }
        let throttled = await registry.pair(
            request(code: "000000"), from: "100.64.9.9", macName: "Studio",
            port: 8788, now: start.addingTimeInterval(6)
        )
        #expect(throttled == .refused(
            status: 429, message: "Too many pairing attempts. Wait a minute."
        ))

        // A different phone behind a different address is not punished for this one.
        let other = await registry.pair(
            request(code: "000000"), from: "100.64.9.10", macName: "Studio",
            port: 8788, now: start.addingTimeInterval(6)
        )
        #expect(other == .refused(status: 403, message: BuddyRegistry.wrongCode))
    }

    @Test func tenFailuresLockTheAddressOutForAQuarterOfAnHour() async {
        let registry = await openRegistry(at: temporaryFile())
        let start = Date()
        await registry.invite(host: "100.64.1.2", port: 8788, lifetime: 100_000, now: start)

        var moment = start
        for _ in 0..<(BuddyRegistry.failuresBeforeLockout / BuddyRegistry.attemptsPerMinute) {
            for attempt in 0..<BuddyRegistry.attemptsPerMinute {
                _ = await registry.pair(
                    request(code: "000000"), from: "100.64.9.9", macName: "Studio",
                    port: 8788, now: moment.addingTimeInterval(Double(attempt))
                )
            }
            moment = moment.addingTimeInterval(61)
            // A fresh code each window: the per-code cap would otherwise burn it first,
            // and this test is about the per-address lockout.
            await registry.invite(
                host: "100.64.1.2", port: 8788, lifetime: 100_000, now: moment
            )
        }

        // The right code is now no help: the address itself is shut out.
        let invitation = await registry.openInvitation(at: moment)
        let lockedOut = await registry.pair(
            request(code: invitation?.code ?? ""), from: "100.64.9.9",
            macName: "Studio", port: 8788, now: moment
        )
        #expect(lockedOut == .refused(
            status: 429, message: "Too many failed pairing attempts. Try again later."
        ))

        // And it lifts on its own, rather than needing the app restarted.
        let after = moment.addingTimeInterval(BuddyRegistry.lockoutDuration + 1)
        let allowed = await registry.pair(
            request(code: invitation?.code ?? ""), from: "100.64.9.9",
            macName: "Studio", port: 8788, now: after
        )
        guard case .paired = allowed else {
            Issue.record("the lockout should expire"); return
        }
    }

    @Test func aNamelessDeviceIsRefusedWithoutSpendingTheCode() async {
        let registry = await openRegistry(at: temporaryFile())
        let invitation = await registry.invite(host: "100.64.1.2", port: 8788)
        let outcome = await registry.pair(
            .init(code: invitation.code, deviceName: "  ", platform: "android"),
            from: "100.64.9.9", macName: "Studio", port: 8788
        )
        #expect(outcome == .refused(
            status: 400, message: "The request does not name a device."
        ))
        // The code survives a malformed request; only a correct one burns it.
        #expect(await registry.openInvitation() != nil)
    }

    @Test func aDeviceTokenAuthorizesStampsLastSeenAndCanBeRevoked() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let registry = await openRegistry(at: file)
        let invitation = await registry.invite(host: "100.64.1.2", port: 8788)
        guard case .paired(let response) = await registry.pair(
            request(code: invitation.code), from: "100.64.9.9",
            macName: "Studio", port: 8788
        ) else { Issue.record("pairing should succeed"); return }

        let later = Date().addingTimeInterval(3600)
        let device = await registry.authorize(bearer: response.token, at: later)
        #expect(device?.id == response.deviceID)
        #expect(device?.platform == "android")
        #expect(await registry.authorize(bearer: "not-a-token") == nil)

        // Reloading the file must see the stamp, not just the in-memory copy. ISO-8601 on
        // disk keeps whole seconds, so this compares to the second it is written in.
        let reloaded = BuddyConfig.load(from: file)
        let stamped = try #require(reloaded.devices.first?.lastSeen)
        #expect(abs(stamped.timeIntervalSince(later)) < 1)

        // And the listing never carries the hash that makes the token guessable.
        let listed = await registry.devices()
        #expect(listed.count == 1 && listed.first?.name == "Galaxy S24 Ultra")
        let listingJSON = try String(
            decoding: JSONEncoder().encode(listed), as: UTF8.self
        )
        #expect(!listingJSON.contains(reloaded.devices[0].tokenHash))

        #expect(await registry.revoke(deviceID: response.deviceID))
        #expect(await registry.revoke(deviceID: response.deviceID) == false)
        #expect(await registry.authorize(bearer: response.token) == nil)
        #expect(BuddyConfig.load(from: file).devices.isEmpty)
    }

    /// A device paired before the tailnet listener took a fixed port holds an address that
    /// no longer answers, and nothing about its token says so. The row has to say it, or
    /// the owner debugs a working phone: `buddy.json` from that version has no port at all,
    /// which is the one durable mark those devices carry.
    @Test func aDevicePairedBeforeThePortMovedIsFlaggedForRepairing() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        // Written by the version that did not record one.
        var config = BuddyConfig(allowTailnetDevices: true, devices: [])
        config.devices.append(BuddyDevice(
            id: "old", name: "iPhone", platform: "ios",
            tokenHash: BuddyPairing.hash(token: "whatever"), pairedAt: Date()
        ))
        config.save(to: file)

        let registry = BuddyRegistry(url: file)
        #expect(await registry.devices().first?.needsRepair == true)

        // One paired now is told where to dial, and knows it.
        await registry.invite(host: "100.64.0.9", port: ControlServer.tailnetPort)
        let invitation = try #require(await registry.openInvitation())
        guard case .paired(let response) = await registry.pair(
            .init(code: invitation.code, deviceName: "Pixel", platform: "android"),
            from: "100.64.0.4", macName: "Mac", port: ControlServer.tailnetPort
        ) else {
            Issue.record("Pairing was refused")
            return
        }
        let fresh = try #require(await registry.devices().first { $0.id == response.deviceID })
        #expect(fresh.needsRepair == false)
        // And it survives the trip through the file, which is where it has to live.
        #expect(BuddyConfig.load(from: file).devices
            .first { $0.id == response.deviceID }?.pairedPort == ControlServer.tailnetPort)
    }

    @Test func theToggleIsOffUntilSomeoneTurnsItOnAndSurvivesARestart() async {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(await BuddyRegistry(url: file).allowsTailnetDevices == false)
        await BuddyRegistry(url: file).setAllowsTailnetDevices(true)
        #expect(await BuddyRegistry(url: file).allowsTailnetDevices)

        // An unreadable file reads as "nothing allowed" rather than inheriting a default.
        try? Data("not json".utf8).write(to: file)
        #expect(await BuddyRegistry(url: file).allowsTailnetDevices == false)
    }

    @Test func tokensAreLongRandomAndComparedByDigest() {
        let tokens = (0..<64).map { _ in BuddyPairing.makeDeviceToken() }
        #expect(Set(tokens).count == tokens.count)
        // 32 bytes, base64url without padding.
        #expect(tokens.allSatisfy { $0.count == 43 })
        #expect(tokens.allSatisfy { !$0.contains("+") && !$0.contains("/") && !$0.contains("=") })

        let hash = BuddyPairing.hash(token: tokens[0])
        #expect(hash.count == 64)
        #expect(BuddyPairing.digestsMatch(hash, BuddyPairing.hash(token: tokens[0])))
        #expect(!BuddyPairing.digestsMatch(hash, BuddyPairing.hash(token: tokens[1])))
        #expect(!BuddyPairing.digestsMatch(hash, String(hash.dropLast())))
    }

    /// The per-source limiter alone is a botnet away from useless: ten addresses trying
    /// five a minute is still fifty guesses a minute at a six-digit secret.
    @Test func aCodeBurnsAfterTenWrongGuessesFromAnywhereAtAll() async {
        let registry = await openRegistry(at: temporaryFile())
        let start = Date()
        let invitation = await registry.invite(
            host: "100.64.1.2", port: 8788, lifetime: 100_000, now: start
        )

        // One guess each from ten different addresses, so no single one is ever throttled.
        for attempt in 0..<BuddyRegistry.guessesPerCode {
            let outcome = await registry.pair(
                request(code: "000000"), from: "100.64.9.\(attempt)",
                macName: "Studio", port: 8788, now: start
            )
            #expect(outcome == .refused(status: 403, message: BuddyRegistry.wrongCode))
        }
        #expect(await registry.openInvitation(at: start) == nil)

        // And the real code is worth nothing now either.
        let tooLate = await registry.pair(
            request(code: invitation.code), from: "100.64.9.200",
            macName: "Studio", port: 8788, now: start
        )
        #expect(tooLate == .refused(status: 403, message: BuddyRegistry.wrongCode))
    }

    @Test func aDeviceIsPairedWithTheScopeTheOwnerChose() async {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let registry = await openRegistry(at: file)

        let invitation = await registry.invite(host: "100.64.1.2", port: 8788, scope: .chat)
        guard case .paired(let response) = await registry.pair(
            request(code: invitation.code), from: "100.64.9.9", macName: "Studio", port: 8788
        ) else { Issue.record("pairing should succeed"); return }
        #expect(response.scope == "chat")
        #expect(await registry.devices().first?.scope == "chat")

        // Full control is what an owner gets by default, and what a file written before
        // scopes existed is read as.
        let legacy = BuddyDevice(
            id: "old", name: "Old phone", platform: "ios",
            tokenHash: "x", pairedAt: Date()
        )
        #expect(legacy.effectiveScope == .full)
        #expect(BuddyScope.allCases.map(\.rawValue) == ControlAPI.buddyScopes)
    }

    /// Suspending devices has to mean suspending them, not merely closing the door they
    /// came in by — the register is where the tokens stop being credentials.
    @Test func aSuspendedRegisterAuthorizesNobody() async {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let registry = await openRegistry(at: file)
        let invitation = await registry.invite(host: "100.64.1.2", port: 8788)
        guard case .paired(let response) = await registry.pair(
            request(code: invitation.code), from: "100.64.9.9", macName: "Studio", port: 8788
        ) else { Issue.record("pairing should succeed"); return }

        #expect(await registry.authorize(bearer: response.token) != nil)
        #expect(await registry.isKnown(deviceID: response.deviceID))
        await registry.setAllowsTailnetDevices(false)
        #expect(await registry.authorize(bearer: response.token) == nil)
        #expect(await registry.isKnown(deviceID: response.deviceID) == false)
        #expect(await registry.devices().count == 1)
    }

    /// Revoking reaches what the device is already holding, not merely its next request.
    @Test func endingAStreamIsPartOfRevoking() async {
        let registry = await openRegistry(at: temporaryFile())
        let invitation = await registry.invite(host: "100.64.1.2", port: 8788)
        guard case .paired(let phone) = await registry.pair(
            request(code: invitation.code), from: "100.64.9.9", macName: "Studio", port: 8788
        ) else { Issue.record("pairing should succeed"); return }

        let ended = Ended()
        let ticket = await registry.registerStream(deviceID: phone.deviceID) {
            Task { await ended.note() }
        }
        #expect(ticket != nil)

        #expect(await registry.revoke(deviceID: phone.deviceID))
        await ended.wait()

        // And a device that stopped being one between being authorized and getting here is
        // told so, rather than being handed a ticket nothing will ever pull. Chat streams
        // have no heartbeat to re-check them, so this is the only backstop they get.
        let refused = await registry.registerStream(deviceID: phone.deviceID) {}
        #expect(refused == nil)
    }

    /// The same window, from the other direction: suspending everything must also refuse a
    /// registration that is only now arriving.
    @Test func aSuspendedRegisterHandsOutNoStreamTickets() async {
        let registry = await openRegistry(at: temporaryFile())
        let invitation = await registry.invite(host: "100.64.1.2", port: 8788)
        guard case .paired(let phone) = await registry.pair(
            request(code: invitation.code), from: "100.64.9.9", macName: "Studio", port: 8788
        ) else { Issue.record("pairing should succeed"); return }

        let ended = Ended()
        _ = await registry.registerStream(deviceID: phone.deviceID) {
            Task { await ended.note() }
        }
        await registry.setAllowsTailnetDevices(false)
        await ended.wait()
        #expect(await registry.registerStream(deviceID: phone.deviceID) {} == nil)
    }

    @Test func codesAreSixDigitsAndReadableAloud() {
        for _ in 0..<200 {
            let code = BuddyPairing.makeCode()
            #expect(code.count == 6)
            #expect(code.allSatisfy { $0.isNumber })
            #expect(BuddyPairing.display(code: code)
                == "\(code.prefix(3)) \(code.suffix(3))")
        }
    }

    /// A code read off a screen arrives with the space the owner saw in it.
    @Test func aCodeTypedWithItsSpaceStillPairs() async {
        let registry = await openRegistry(at: temporaryFile())
        let invitation = await registry.invite(host: "100.64.1.2", port: 8788)
        let outcome = await registry.pair(
            .init(code: invitation.displayCode, deviceName: "iPad mini", platform: "ipados"),
            from: "100.64.9.9", macName: "Studio", port: 8788
        )
        guard case .paired = outcome else {
            Issue.record("a spaced code is the same code"); return
        }
    }
}

/// A latch for "this closure ran", since stream cancellation has no return value.
actor Ended {
    private var happened = false

    func note() { happened = true }

    func wait() async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !happened, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(happened)
    }
}

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

    private func request(code: String) -> ControlAPI.BuddyPairRequest {
        .init(code: code, deviceName: "Galaxy S24 Ultra", platform: "android")
    }

    @Test func aCodeWorksOnceAndMintsATokenThatIsOnlyStoredAsAHash() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let registry = BuddyRegistry(url: file)

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
        #expect(again == .refused(
            status: 403,
            message: "No pairing code is open. Open Settings → Silicon Buddy on the Mac "
                + "and tap Pair a device."
        ))
    }

    @Test func aCodeStopsWorkingAfterFiveMinutes() async {
        let registry = BuddyRegistry(url: temporaryFile())
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
        let registry = BuddyRegistry(url: temporaryFile())
        let start = Date()
        await registry.invite(host: "100.64.1.2", port: 8788, now: start)

        for attempt in 0..<BuddyRegistry.attemptsPerMinute {
            let outcome = await registry.pair(
                request(code: "000000"), from: "100.64.9.9", macName: "Studio",
                port: 8788, now: start.addingTimeInterval(Double(attempt))
            )
            #expect(outcome == .refused(
                status: 403, message: "That pairing code is not the one on screen."
            ))
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
        #expect(other == .refused(
            status: 403, message: "That pairing code is not the one on screen."
        ))
    }

    @Test func tenFailuresLockTheAddressOutForAQuarterOfAnHour() async {
        let registry = BuddyRegistry(url: temporaryFile())
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
        let registry = BuddyRegistry(url: temporaryFile())
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
        let registry = BuddyRegistry(url: file)
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
        let registry = BuddyRegistry(url: temporaryFile())
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

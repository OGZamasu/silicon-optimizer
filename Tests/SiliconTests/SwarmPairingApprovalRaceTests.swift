import Foundation
import Network
import Testing
@testable import SiliconControl
@testable import SiliconUI

@Suite("Swarm approval cancellation", .serialized)
@MainActor
struct SwarmPairingApprovalRaceTests {
    private struct TimedOut: Error {}

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TimedOut()
    }

    private func fixture() async throws -> (
        model: AppModel, server: PairingServer, node: FakeMemberNode,
        receipt: PairingReceipt, config: SwarmConfig, port: Int
    ) {
        let node = try await FakeMemberNode()
        let server = PairingServer(hostName: "Owner")
        let port = try await BuddyControlTests.freeLoopbackPort()
        try await server.start(on: "127.0.0.1", port: port)
        try await Task.sleep(for: .milliseconds(100))
        let receipt = try await PairingClient.requestJoin(
            host: "127.0.0.1", name: "Joiner", port: port
        )
        let model = AppModel(settings: .init())
        model.pairingServer = server
        guard let pending = await server.pending() else { throw TimedOut() }
        model.pairingRequest = pending
        let config = SwarmConfig(swarmToken: "owner-admin", peers: [
            SwarmPeer(name: "fake-node", baseURL: node.baseURL)
        ])
        return (model, server, node, receipt, config, port)
    }

    @Test("denial during mint revokes the key before reporting denied")
    func denyDuringMint() async throws {
        let (model, server, node, receipt, config, port) = try await fixture()
        defer { node.stop(); Task { await server.stop() } }

        model.approvePairing(receipt.requestID, using: config)
        try await node.waitForPost()
        #expect((await node.snapshot()).activeNames == ["Joiner"])
        model.denyPairing(receipt.requestID)
        #expect(model.pairingApprovalState == .cancelling(receipt.requestID))
        await node.releasePost()

        try await waitUntil {
            let snapshot = await node.snapshot()
            return snapshot.deletes == 1 && model.pairingApprovalTask == nil
        }
        let status = try await PairingClient.status(
            host: "127.0.0.1", requestID: receipt.requestID,
            port: port
        )
        #expect(status.state == "denied")
        #expect(status.swarm == nil)
        #expect((await node.snapshot()).activeNames.isEmpty)
    }

    @Test("closing after approval revokes an uncollected key")
    func closeBeforeDelivery() async throws {
        let (model, server, node, receipt, config, _) = try await fixture()
        defer { node.stop(); Task { await server.stop() } }
        await node.releasePost()
        model.approvePairing(receipt.requestID, using: config)
        try await waitUntil { model.pairingApprovalState == .committed(receipt.requestID) }
        #expect((await node.snapshot()).activeNames == ["Joiner"])

        model.stopPairingInvite()
        try await waitUntil {
            let snapshot = await node.snapshot()
            return snapshot.deletes == 1 && model.pairingStopTask == nil
        }
        #expect((await node.snapshot()).activeNames.isEmpty)
    }

    @Test("failed key revocation stays visible and blocks another invite")
    func failedRevocation() async throws {
        let (model, server, node, receipt, config, _) = try await fixture()
        defer { node.stop(); Task { await server.stop() } }
        await node.releasePost()
        await node.setRejectDeletes(true)
        model.approvePairing(receipt.requestID, using: config)
        try await waitUntil { model.pairingApprovalState == .committed(receipt.requestID) }

        model.stopPairingInvite()
        try await waitUntil { model.pairingStopTask == nil }
        #expect((await node.snapshot()).activeNames == ["Joiner"])
        #expect(model.pairingCleanupNeeded?.clientName == "Joiner")
        #expect(model.alert?.message.contains("before inviting another device") == true)
        #expect(model.startPairingInvite() != nil)
        #expect(model.pairingServer == nil)
        try await waitUntil { model.pairingStopTask == nil }
        #expect(model.pairingCleanupNeeded != nil)
    }

    @Test("cancelling a repeat request leaves the existing member key intact")
    func repeatRequestKeepsExistingKey() async throws {
        let (model, server, node, receipt, config, port) = try await fixture()
        defer { node.stop(); Task { await server.stop() } }
        await node.seedMember("Joiner", token: "existing-key")
        await node.releasePost()

        model.approvePairing(receipt.requestID, using: config)
        try await waitUntil { model.pairingApprovalTask == nil }
        #expect(model.pairingApprovalError?.contains("already has a key") == true)
        #expect((await node.snapshot()).posts == 1)
        #expect((await node.snapshot()).deletes == 0)
        #expect(await node.token(for: "Joiner") == "existing-key")

        model.denyPairing(receipt.requestID)
        try await waitUntil { await server.pending() == nil }
        let status = try await PairingClient.status(
            host: "127.0.0.1", requestID: receipt.requestID, port: port
        )
        #expect(status.state == "denied")
        #expect(await node.token(for: "Joiner") == "existing-key")
    }

    @Test("a later name conflict rolls back only newly minted peer keys")
    func laterConflictRollsBackNewKeys() async throws {
        let (model, server, firstNode, receipt, config, _) = try await fixture()
        let conflictingNode = try await FakeMemberNode()
        defer {
            firstNode.stop()
            conflictingNode.stop()
            Task { await server.stop() }
        }
        await firstNode.releasePost()
        await conflictingNode.seedMember("Joiner", token: "existing-key")
        let twoPeers = SwarmConfig(swarmToken: config.swarmToken, peers: [
            config.peers[0],
            SwarmPeer(name: "conflicting-node", baseURL: conflictingNode.baseURL),
        ])

        model.approvePairing(receipt.requestID, using: twoPeers)
        try await waitUntil { model.pairingApprovalTask == nil }
        #expect((await firstNode.snapshot()).posts == 1)
        #expect((await firstNode.snapshot()).deletes == 1)
        #expect((await firstNode.snapshot()).activeNames.isEmpty)
        #expect((await conflictingNode.snapshot()).posts == 1)
        #expect((await conflictingNode.snapshot()).deletes == 0)
        #expect(await conflictingNode.token(for: "Joiner") == "existing-key")
        #expect(model.pairingApprovalError?.contains("already has a key") == true)
    }

    @Test("owner self-provisioning may still replace its own existing key")
    func ownerKeyReplacement() async throws {
        let (model, server, node, _, config, _) = try await fixture()
        defer { node.stop(); Task { await server.stop() } }
        await node.seedMember("Owner", token: "old-owner-key")
        await node.releasePost()

        let result = await model.mintClientToken(
            on: config.peers[0], clientName: "Owner", admin: config.effectiveToken,
            role: "admin"
        )
        guard case .minted(let token, _) = result else {
            Issue.record("Owner token replacement did not mint a new key")
            return
        }
        #expect(token == "member-key")
        #expect((await node.snapshot()).posts == 2)
        #expect((await node.snapshot()).deletes == 1)
        #expect(await node.token(for: "Owner") == "member-key")
    }

    @Test("closing during mint revokes the key when the node responds")
    func closeDuringMint() async throws {
        let (model, server, node, receipt, config, _) = try await fixture()
        defer { node.stop(); Task { await server.stop() } }
        model.approvePairing(receipt.requestID, using: config)
        try await node.waitForPost()
        model.stopPairingInvite()
        await node.releasePost()

        try await waitUntil {
            let snapshot = await node.snapshot()
            return snapshot.deletes == 1 && model.pairingApprovalTask == nil
                && model.pairingStopTask == nil
        }
        #expect((await node.snapshot()).activeNames.isEmpty)
    }

    @Test("collected approval keeps the member key and cannot be denied afterward")
    func deliveredApproval() async throws {
        let (model, server, node, receipt, config, port) = try await fixture()
        defer { node.stop(); Task { await server.stop() } }
        await node.releasePost()
        model.approvePairing(receipt.requestID, using: config)
        try await waitUntil { model.pairingApprovalState == .committed(receipt.requestID) }

        // A stale button action cannot claim to undo an already committed approval.
        model.denyPairing(receipt.requestID)
        #expect(model.pairingApprovalState == .committed(receipt.requestID))
        #expect(model.pairingApprovalError?.contains("already been committed") == true)
        let approved = try await PairingClient.status(
            host: "127.0.0.1", requestID: receipt.requestID,
            port: port
        )
        #expect(approved.state == "approved")
        #expect(approved.swarm?.peers.first?.token == "member-key")
        #expect(await server.wasDelivered())

        model.startPairingPoll()
        try await waitUntil { model.pairingDelivered }
        #expect(model.pairingRequest == nil)
        // A stale action after delivery must not replace and then revoke the key.
        model.approvePairing(receipt.requestID, using: config)
        #expect(model.pairingApprovalTask == nil)
        model.denyPairing(receipt.requestID)
        try await Task.sleep(for: .milliseconds(50))
        #expect((await node.snapshot()).posts == 1)
        #expect((await node.snapshot()).deletes == 0)

        model.stopPairingInvite()
        try await waitUntil { model.pairingStopTask == nil }
        #expect((await node.snapshot()).activeNames == ["Joiner"])
        #expect((await node.snapshot()).deletes == 0)
    }
}

/// A real loopback HTTP node whose POST can be held after it creates a key. Holding
/// the response creates the same interleaving as a slow remote token mint.
private final class FakeMemberNode: @unchecked Sendable {
    private actor KeyStore {
        var active: [String: String] = [:]
        var posts = 0
        var deletes = 0
        var rejectDeletes = false
        var released = false
        var heldResponse: CheckedContinuation<Void, Never>?

        func mint(_ name: String) async -> String? {
            posts += 1
            guard active[name] == nil else { return nil }
            active[name] = "member-key"
            if !released {
                await withCheckedContinuation { heldResponse = $0 }
            }
            return "member-key"
        }

        func seedMember(_ name: String, token: String) { active[name] = token }
        func token(for name: String) -> String? { active[name] }

        func releasePost() {
            released = true
            heldResponse?.resume()
            heldResponse = nil
        }

        func setRejectDeletes(_ reject: Bool) { rejectDeletes = reject }

        func revoke(_ name: String) -> Bool {
            deletes += 1
            if rejectDeletes { return false }
            active.removeValue(forKey: name)
            return true
        }

        func snapshot() -> (posts: Int, deletes: Int, activeNames: [String]) {
            (posts, deletes, active.keys.sorted())
        }
    }

    private let listener: NWListener
    private let keys = KeyStore()
    let port: Int
    var baseURL: String { "http://127.0.0.1:\(port)" }

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        let keys = self.keys
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            Task {
                defer { connection.cancel() }
                guard let request = try? await HTTPRequest.read(from: connection) else { return }
                let response: HTTPResponse
                switch (request.method, request.path) {
                case ("POST", "/swarm/clients"):
                    guard let join = try? request.decode(PairingJoinRequest.self) else { return }
                    if let token = await keys.mint(join.name) {
                        response = .json(["token": token])
                    } else {
                        response = .error(409, "member already exists")
                    }
                case ("DELETE", let path) where path.hasPrefix("/swarm/clients/"):
                    let revoked = await keys.revoke(String(path.dropFirst("/swarm/clients/".count)))
                    response = revoked ? .json(["ok": "true"])
                        : .error(503, "node temporarily unavailable")
                default:
                    response = .error(404, "unknown route")
                }
                try? await response.write(to: connection)
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        var readyPort: Int?
        for _ in 0..<300 {
            if case .ready = listener.state, let bound = listener.port?.rawValue {
                readyPort = Int(bound)
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let readyPort else { throw URLError(.cannotConnectToHost) }
        port = readyPort
    }

    func stop() { listener.cancel() }
    func releasePost() async { await keys.releasePost() }
    func seedMember(_ name: String, token: String) async {
        await keys.seedMember(name, token: token)
    }
    func token(for name: String) async -> String? { await keys.token(for: name) }
    func setRejectDeletes(_ reject: Bool) async { await keys.setRejectDeletes(reject) }
    func snapshot() async -> (posts: Int, deletes: Int, activeNames: [String]) {
        await keys.snapshot()
    }

    func waitForPost() async throws {
        for _ in 0..<300 {
            if (await keys.snapshot()).posts > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }
}

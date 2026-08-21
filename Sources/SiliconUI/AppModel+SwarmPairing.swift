import AppKit
import Foundation
import SiliconControl

/// The app half of Bluetooth-style swarm pairing: hosting an invite (owner) and
/// joining someone else's swarm (new member). All transient UI state lives here;
/// the wire protocol and the listener live in SiliconControl.
extension AppModel {

    // MARK: - Owner: hosting an invite

    /// Opens the pairing window: bind the listener to this Mac's tailscale address and
    /// wait for a knock. Returns an error sentence when hosting cannot start.
    @discardableResult
    func startPairingInvite() -> String? {
        guard pairingServer == nil else { return nil }
        guard let address = SwarmPairing.tailnetIPv4() else {
            return "This Mac has no tailscale address. Join the tailnet first — "
                + "pairing rides on it."
        }
        let config = SwarmConfig.ensureExists()
        guard config.effectiveToken != nil else {
            return "The swarm config has no admin token. Delete swarm.json and "
                + "reopen this sheet to regenerate it."
        }
        let server = PairingServer(
            hostName: Host.current().localizedName ?? "This Mac"
        )
        Task { [weak self] in
            do {
                try await server.start(on: address)
            } catch {
                await MainActor.run {
                    self?.stopPairingInvite()
                    self?.alert = AlertContent(
                        title: "Could not open the invite",
                        message: "Binding \(address):\(SwarmPairing.port) failed: "
                            + error.localizedDescription
                    )
                }
            }
        }
        pairingServer = server
        pairingAddress = address
        pairingRequest = nil
        pairingDelivered = false
        pairingLegacyShared = []
        startPairingPoll()
        return nil
    }

    func stopPairingInvite() {
        let server = pairingServer
        pairingServer = nil
        pairingRequest = nil
        pairingDelivered = false
        pairingPollTask?.cancel()
        pairingPollTask = nil
        Task { await server?.stop() }
    }

    /// Approval mints the joiner their OWN credential on every node that can issue one
    /// (per-client tokens, node work order #125) and delivers a config carrying those —
    /// never the shared admin token, unless a legacy node leaves no choice. The nodes'
    /// activity logs then name the member on every job, and one member can be revoked
    /// without rotating everyone.
    func approvePairing(_ id: String) {
        guard let server = pairingServer,
              let joinerName = pairingRequest?.name,
              let config = SwarmConfig.load()
        else { return }
        Task {
            var released = SwarmConfig(swarmToken: nil, peers: [])
            var legacyShared: [String] = []
            for peer in config.peers {
                if let minted = await self.mintClientToken(
                    on: peer, clientName: joinerName, admin: config.effectiveToken
                ) {
                    released.peers.append(SwarmPeer(
                        name: peer.name, baseURL: peer.baseURL, token: minted
                    ))
                } else {
                    // A node without the client-token API (pre-#125) can only be
                    // shared the old way. Named in the sheet so the owner knows.
                    released.peers.append(SwarmPeer(
                        name: peer.name, baseURL: peer.baseURL, token: config.effectiveToken
                    ))
                    legacyShared.append(peer.name)
                }
            }
            self.pairingLegacyShared = legacyShared
            await server.approve(id, releasing: released)
        }
    }

    /// Mints a per-client token on one node using the admin credential. Returns nil
    /// when the node cannot (missing endpoint, unreachable) — the caller decides the
    /// fallback. A 409 means the name already has a token there; since only admins
    /// reach this path, replace it (revoke, re-mint) so pairing the same machine
    /// twice heals rather than fails.
    func mintClientToken(
        on peer: SwarmPeer, clientName: String, admin: String?
    ) async -> String? {
        guard let admin else { return nil }
        func attempt() async -> (Int, String?) {
            guard let base = URL(string: peer.baseURL.trimmingCharacters(in: .whitespaces))
            else { return (0, nil) }
            var request = URLRequest(url: base.appendingPathComponent("swarm/clients"))
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(admin)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(
                withJSONObject: ["name": clientName]
            )
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { return (0, nil) }
            let token = (try? JSONSerialization.jsonObject(with: data)
                as? [String: Any])?["token"] as? String
            return (http.statusCode, token)
        }

        let (status, token) = await attempt()
        if (200..<300).contains(status), let token { return token }
        if status == 409 {
            _ = await revokeClientToken(on: peer, clientName: clientName, admin: admin)
            let (retryStatus, retryToken) = await attempt()
            if (200..<300).contains(retryStatus) { return retryToken }
        }
        return nil
    }

    @discardableResult
    func revokeClientToken(
        on peer: SwarmPeer, clientName: String, admin: String?
    ) async -> Bool {
        guard let admin,
              let base = URL(string: peer.baseURL.trimmingCharacters(in: .whitespaces)),
              let encoded = clientName.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
              )
        else { return false }
        var request = URLRequest(
            url: base.appendingPathComponent("swarm/clients").appendingPathComponent(encoded)
        )
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.setValue("Bearer \(admin)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// The members a node knows (names and timestamps only — tokens never travel).
    func listPeerClients(_ peer: PeerStatus) async -> [PeerClientInfo] {
        guard let admin = swarmConfig?.effectiveToken,
              let base = URL(string: peer.baseURL.trimmingCharacters(in: .whitespaces))
        else { return [] }
        var request = URLRequest(url: base.appendingPathComponent("swarm/clients"))
        request.timeoutInterval = 15
        request.setValue("Bearer \(admin)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return Self.parsePeerClients(list)
    }

    /// Lenient, like all peer parsing: today's nodes send name/created/last_seen;
    /// the usage counters (#132) appear here the moment a node starts sending them.
    nonisolated static func parsePeerClients(_ list: [[String: Any]]) -> [PeerClientInfo] {
        list.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return PeerClientInfo(
                name: name,
                created: entry["created"] as? String,
                lastSeen: entry["last_seen"] as? String,
                jobsTotal: entry["jobs_total"] as? Int,
                jobsByKind: entry["jobs_by_kind"] as? [String: Int],
                llmRequests: entry["llm_requests"] as? Int
            )
        }
    }

    struct PeerClientInfo: Identifiable, Sendable, Equatable {
        var name: String
        var created: String?
        var lastSeen: String?
        var jobsTotal: Int?
        var jobsByKind: [String: Int]?
        var llmRequests: Int?
        var id: String { name }

        init(name: String, created: String? = nil, lastSeen: String? = nil,
             jobsTotal: Int? = nil, jobsByKind: [String: Int]? = nil,
             llmRequests: Int? = nil) {
            self.name = name
            self.created = created
            self.lastSeen = lastSeen
            self.jobsTotal = jobsTotal
            self.jobsByKind = jobsByKind
            self.llmRequests = llmRequests
        }
    }

    /// One person's key to one node — a row in the Swarm page's People panel.
    struct SwarmMember: Identifiable, Sendable, Equatable {
        var peerName: String
        var info: PeerClientInfo
        var id: String { "\(peerName)/\(info.name)" }
    }

    /// This Mac's name as members see it — the same one `ensureOwnClientTokens` mints.
    var localMachineName: String {
        Host.current().localizedName ?? "This Mac"
    }

    /// Rebuilds the People panel: every keyholder on every reachable node. Only the
    /// swarm owner holds the master token these listings need; members get an empty
    /// list and the panel says so.
    func refreshSwarmMembers() async {
        guard swarmConfig?.effectiveToken != nil else {
            swarmMembers = []
            swarmMembersLoaded = true
            return
        }
        var gathered: [SwarmMember] = []
        for peer in swarmPeers where peer.reachable {
            for info in await listPeerClients(peer) {
                gathered.append(SwarmMember(peerName: peer.name, info: info))
            }
        }
        // This Mac first, then the order people joined.
        let mine = localMachineName
        swarmMembers = gathered.sorted {
            if ($0.info.name == mine) != ($1.info.name == mine) {
                return $0.info.name == mine
            }
            return ($0.info.created ?? "") < ($1.info.created ?? "")
        }
        swarmMembersLoaded = true
    }

    /// Gives THIS Mac its own per-client identity on every node that can mint one, so
    /// node activity logs attribute our jobs by name instead of "swarm (shared token)".
    /// Runs after swarm refreshes, once per peer per app run; legacy nodes are skipped
    /// silently and keep receiving the shared token.
    func ensureOwnClientTokens() async {
        guard var config = SwarmConfig.load(), let admin = config.effectiveToken
        else { return }
        let ourName = localMachineName
        var changed = false
        for peer in config.peers {
            guard peer.token == nil,
                  !clientTokenAttempted.contains(peer.name),
                  swarmPeers.first(where: { $0.name == peer.name })?.reachable == true
            else { continue }
            clientTokenAttempted.insert(peer.name)
            if let minted = await mintClientToken(
                on: peer, clientName: ourName, admin: admin
            ) {
                config.setToken(minted, forPeer: peer.name)
                changed = true
            }
        }
        if changed { config.save() }
    }

    func denyPairing(_ id: String) {
        guard let server = pairingServer else { return }
        pairingRequest = nil
        Task { await server.deny(id) }
    }

    private func startPairingPoll() {
        pairingPollTask?.cancel()
        pairingPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let server = self.pairingServer else { return }
                let pending = await server.pending()
                let delivered = await server.wasDelivered()
                self.pairingRequest = pending
                if delivered { self.pairingDelivered = true }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Joiner: finding and joining a swarm

    /// Sweeps the tailnet for machines holding an open invite: every tailscale peer,
    /// probed on the pairing port in parallel, two-second knocks.
    func scanForSwarmInvites() async -> [DiscoveredInvite] {
        let peers = tailscalePeers()
        guard !peers.isEmpty else { return [] }
        return await withTaskGroup(of: DiscoveredInvite?.self) { group in
            for peer in peers where peer.online {
                group.addTask {
                    guard let hello = await PairingClient.hello(host: peer.ip),
                          hello.accepting
                    else { return nil }
                    return DiscoveredInvite(hostName: hello.name, ip: peer.ip)
                }
            }
            var found: [DiscoveredInvite] = []
            for await invite in group {
                if let invite { found.append(invite) }
            }
            return found.sorted { $0.hostName < $1.hostName }
        }
    }

    /// Asks to join and waits for the owner's decision. Reports progress through the
    /// returned stream of states so the sheet can mirror the other screen.
    func joinSwarm(at invite: DiscoveredInvite) async -> JoinOutcome {
        let deviceName = Host.current().localizedName ?? "A Mac"
        let receipt: PairingReceipt
        do {
            receipt = try await PairingClient.requestJoin(
                host: invite.ip, name: deviceName
            )
        } catch {
            return .failed(error.localizedDescription)
        }
        joinCode = receipt.code

        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            if Task.isCancelled { return .failed("Cancelled.") }
            do {
                let status = try await PairingClient.status(
                    host: invite.ip, requestID: receipt.requestID
                )
                switch status.state {
                case "approved":
                    guard let received = status.swarm else {
                        return .failed("Approved, but no configuration arrived.")
                    }
                    let merged = (SwarmConfig.load() ?? SwarmConfig(peers: []))
                        .adopting(received)
                    merged.save()
                    await refreshSwarm()
                    return .joined(peerCount: merged.peers.count)
                case "denied":
                    return .failed("The owner declined.")
                case "expired":
                    return .failed("The request expired before a decision.")
                default:
                    break
                }
            } catch {
                // Transient poll failures are just the tailnet breathing; keep waiting.
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return .failed("Timed out waiting for a decision.")
    }

    /// Tailscale peers via the CLI, wherever it is installed. An empty answer means
    /// no CLI (or no tailnet) — the join sheet falls back to a typed address.
    func tailscalePeers() -> [TailscalePeerInfo] {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
        ]
        guard let binary = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return SwarmPairing.peers(inStatusJSON: data)
    }

    // MARK: - Shapes

    struct DiscoveredInvite: Identifiable, Equatable, Sendable {
        var hostName: String
        var ip: String
        var id: String { ip }
    }

    enum JoinOutcome: Equatable {
        case joined(peerCount: Int)
        case failed(String)
    }
}
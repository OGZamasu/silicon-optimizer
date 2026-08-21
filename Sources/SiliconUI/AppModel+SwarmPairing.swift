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
            return "The swarm config has no token to share. Delete swarm.json and "
                + "reopen this sheet to regenerate it."
        }
        let server = PairingServer(
            hostName: Host.current().localizedName ?? "This Mac",
            release: config
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

    func approvePairing(_ id: String) {
        guard let server = pairingServer else { return }
        Task { await server.approve(id) }
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
import SiliconControl
import SwiftUI

/// The owner's side of pairing: this Mac is discoverable exactly as long as this sheet
/// is open. A knock shows the device's name and the six-digit code — the same code the
/// other screen shows — and one button admits them.
struct SwarmInviteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var startupError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Invite to the swarm")
                .font(.title3.weight(.semibold))

            if let startupError {
                Label(startupError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.pairingDelivered {
                delivered
            } else if let request = model.pairingRequest {
                pending(request)
            } else {
                waiting
            }

            HStack {
                Spacer()
                Button(model.pairingDelivered ? "Done" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { startupError = model.startPairingInvite() }
        .onDisappear { model.stopPairingInvite() }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for someone to ask to join…")
            }
            Text("On their Mac: Settings → Swarm → Join a swarm. This Mac is "
                 + "discoverable at \(model.pairingAddress ?? "?") only while this "
                 + "sheet is open.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pending(_ request: PendingPairing) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(request.name) wants to join")
                .font(.headline)
            HStack {
                Spacer()
                Text(request.code)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .kerning(2)
                Spacer()
            }
            Text("Check that the same code is on their screen, then let them in. "
                 + "They receive the swarm token and the node list.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("Deny") { model.denyPairing(request.id) }
                Button("Let Them In") { model.approvePairing(request.id) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var delivered: some View {
        Label(
            "They're in — the swarm config is on their Mac and its nodes should "
            + "appear for them within a few seconds.",
            systemImage: "checkmark.circle.fill"
        )
        .foregroundStyle(.green)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The joiner's side: scan the tailnet for open invites (or type an address), knock,
/// read the code aloud, wait for the owner.
struct SwarmJoinSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case scanning
        case found([AppModel.DiscoveredInvite])
        case requesting(AppModel.DiscoveredInvite)
        case waiting(code: String)
        case done(String)
        case failed(String)
    }

    @State private var phase: Phase = .scanning
    @State private var manualAddress = ""
    @State private var joinTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Join a swarm")
                .font(.title3.weight(.semibold))

            content

            HStack {
                if case .found = phase {
                    Button("Scan Again") { startScan() }
                }
                Spacer()
                Button(closeLabel) {
                    joinTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { startScan() }
        .onDisappear { joinTask?.cancel() }
    }

    private var closeLabel: String {
        if case .done = phase { return "Done" }
        return "Cancel"
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .scanning:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking for open invites on your tailnet…")
            }
        case .found(let invites):
            VStack(alignment: .leading, spacing: 10) {
                if invites.isEmpty {
                    Text("No open invites found. Ask the swarm's owner to open "
                         + "Settings → Swarm → Invite to the swarm, then scan again — "
                         + "or enter their tailscale address directly.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(invites) { invite in
                        Button {
                            join(invite)
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.circle.badge.plus")
                                Text(invite.hostName)
                                Spacer()
                                Text(invite.ip)
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                    }
                }
                HStack(spacing: 8) {
                    TextField("100.x.y.z", text: $manualAddress)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Button("Knock") {
                        let address = manualAddress.trimmingCharacters(in: .whitespaces)
                        guard SwarmPairing.isTailnetIPv4(address) else { return }
                        join(.init(hostName: address, ip: address))
                    }
                }
                .font(.callout)
            }
        case .requesting(let invite):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Knocking on \(invite.hostName)…")
            }
        case .waiting(let code):
            VStack(alignment: .leading, spacing: 12) {
                Text("Read this code to the swarm's owner")
                    .font(.headline)
                HStack {
                    Spacer()
                    Text(code)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .kerning(2)
                    Spacer()
                }
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for them to let you in…")
                        .foregroundStyle(.secondary)
                }
            }
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Start Over") { startScan() }
            }
        }
    }

    private func startScan() {
        phase = .scanning
        joinTask?.cancel()
        joinTask = Task {
            let invites = await model.scanForSwarmInvites()
            if !Task.isCancelled { phase = .found(invites) }
        }
    }

    private func join(_ invite: AppModel.DiscoveredInvite) {
        phase = .requesting(invite)
        joinTask?.cancel()
        joinTask = Task {
            // The model publishes the code as soon as the knock is answered; mirror it.
            let watcher = Task {
                while !Task.isCancelled {
                    if let code = model.joinCode, case .requesting = phase {
                        phase = .waiting(code: code)
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { watcher.cancel() }
            model.joinCode = nil
            let outcome = await model.joinSwarm(at: invite)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .joined(let peerCount):
                phase = .done(
                    "You're in. \(peerCount) node\(peerCount == 1 ? "" : "s") now "
                    + "appear in your app — models on them show up in every engine's "
                    + "picker."
                )
            case .failed(let message):
                phase = .failed(message)
            }
        }
    }
}
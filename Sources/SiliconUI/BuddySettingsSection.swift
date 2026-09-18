import AppKit
import SiliconControl
import SwiftUI

/// Settings → Silicon Buddy.
///
/// The toggle here is the whole security story: off, the control API is what it has always
/// been — loopback and one token. On, a second listener goes up on this Mac's tailscale
/// address and nowhere else, and only devices the owner has paired can use it. Nothing about
/// this makes anything public; a phone that is not on the tailnet cannot see the Mac at all.
struct BuddySettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var buddy = BuddyCenter.shared
    @State private var showingPairing = false

    var body: some View {
        Section("Silicon Buddy") {
            Toggle(
                "Allow Silicon Buddy devices on the tailnet",
                isOn: Binding(
                    get: { buddy.allowsTailnetDevices },
                    set: { allowed in
                        Task { await buddy.setAllowsTailnetDevices(allowed, server: model.controlServer) }
                    }
                )
            )
            .disabled(buddy.isBusy)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Pair a device…") {
                    showingPairing = true
                    Task { await buddy.pairDevice(server: model.controlServer) }
                }
                .disabled(!buddy.allowsTailnetDevices || buddy.isBusy)
                Spacer()
            }

            if buddy.devices.isEmpty {
                Text("No devices paired yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(buddy.devices) { device in
                    deviceRow(device)
                }
            }
        }
        .task { await buddy.refresh(server: model.controlServer) }
        .sheet(isPresented: $showingPairing) {
            BuddyPairingSheet(buddy: buddy) {
                showingPairing = false
                Task { await buddy.cancelInvitation() }
            }
        }
        .onChange(of: showingPairing) { _, shown in
            // A sheet dismissed any other way — Escape, or clicking away — must burn the
            // code too. A live code the owner cannot see is a code they cannot revoke.
            guard !shown else { return }
            Task {
                await buddy.cancelInvitation()
                await buddy.refresh(server: model.controlServer)
            }
        }
    }

    private var statusText: String {
        if let problem = buddy.problem { return problem }
        guard buddy.allowsTailnetDevices else {
            return "Off. The control API stays on 127.0.0.1, as it always has."
        }
        guard let address = buddy.reachAddress else {
            return "On, but this Mac has no tailscale address yet. Join the tailnet and "
                + "the listener comes up on its own."
        }
        return "Reachable from your tailnet at \(address). Nothing is published beyond it."
    }

    @ViewBuilder
    private func deviceRow(_ device: ControlAPI.BuddyDeviceSummary) -> some View {
        LabeledContent(device.name) {
            HStack(spacing: 10) {
                Text(Self.describe(device))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Revoke") { Task { await buddy.revoke(device.id) } }
                    .buttonStyle(.link)
            }
        }
    }

    static func describe(_ device: ControlAPI.BuddyDeviceSummary) -> String {
        var parts = [device.platform]
        if let paired = ControlAPI.date(fromTimestamp: device.pairedAt) {
            parts.append("paired \(paired.formatted(date: .abbreviated, time: .omitted))")
        }
        // "Never" rather than nothing: a device that paired and was never heard from again
        // is worth noticing before you go looking for why the phone is not answering.
        if let seen = ControlAPI.date(fromTimestamp: device.lastSeen ?? "") {
            parts.append("last seen \(seen.formatted(date: .abbreviated, time: .shortened))")
        } else {
            parts.append("never seen")
        }
        return parts.joined(separator: " · ")
    }
}

/// The pairing sheet: one QR, one code, five minutes.
struct BuddyPairingSheet: View {
    let buddy: BuddyCenter
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair a device")
                .font(.headline)

            if let invitation = buddy.invitation {
                code(invitation)
            } else {
                VStack(spacing: 8) {
                    Text(buddy.problem ?? "The code has expired.")
                        .multilineTextAlignment(.center)
                    Text("Codes last five minutes and work once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 280)
            }

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    @ViewBuilder
    private func code(_ invitation: BuddyInvitation) -> some View {
        if let image = BuddyCenter.qrCode(for: invitation.url) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: 220, height: 220)
                .accessibilityLabel("Pairing code \(invitation.displayCode)")
        }
        Text(invitation.displayCode)
            .font(.system(.title, design: .monospaced))
            .textSelection(.enabled)
        // Typed in by hand when a camera will not cooperate, which on a tablet propped up
        // behind a monitor is most of the time.
        Text("Scan this in Silicon Buddy, or type the code and \(invitation.host).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}

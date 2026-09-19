import AppKit
import SiliconControl
import SwiftUI

/// Settings → Silicon Buddy.
///
/// The toggle here is the whole security story: off, device tokens mean nothing and the
/// control API is what it has always been — loopback and one token. On, the listener on
/// this Mac's tailscale address (shared with the swarm, which binds the same one) honours
/// the devices the owner has paired, and nothing else. Nothing about this makes anything
/// public; a phone that is not on the tailnet cannot see the Mac at all.
struct BuddySettingsSection: View {
    @Environment(AppModel.self) private var model
    /// A singleton, so this is a reference rather than something the view owns. Observation
    /// still tracks it: `@Observable` watches the properties `body` reads, not the wrapper.
    private let buddy = BuddyCenter.shared
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
            BuddyPairingSheet(buddy: buddy, server: model.controlServer) {
                showingPairing = false
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
        // The server's own reason comes first — it is nearly always "join the tailnet
        // first", and guessing at it sends people to the wrong screen.
        if let problem = buddy.problem { return problem }
        guard buddy.allowsTailnetDevices else {
            return "Off. Device tokens are refused everywhere, and paired devices are "
                + "suspended until you turn this back on."
        }
        guard let address = buddy.reachAddress else {
            return "On, but the listener is not up yet. Nothing is reachable until it is."
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
        parts.append((BuddyScope(rawValue: device.scope) ?? .full).label.lowercased())
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

/// The pairing sheet: one QR, one code, five minutes — and the one decision only the owner
/// standing over the device can make, which is how much of the Mac it gets.
struct BuddyPairingSheet: View {
    let buddy: BuddyCenter
    let server: ControlServer?
    let onClose: () -> Void

    @State private var paired = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair a device")
                .font(.headline)

            scopePicker

            if paired {
                Label("Paired.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(width: 280)
            } else if let invitation = buddy.invitation {
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
                Button(paired ? "Done" : "Cancel", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        // The device tells the Mac it has paired by spending the code, so the sheet watches
        // for that rather than waiting to be reopened before it shows the new row.
        .task {
            while !Task.isCancelled, !paired {
                if await buddy.followPairing(server: server) { paired = true }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("This device gets", selection: Binding(
                get: { buddy.nextScope },
                set: { scope in
                    // Changing the answer has to change the code: one already on screen was
                    // issued for the old one.
                    Task { await buddy.pairDevice(server: server, scope: scope) }
                }
            )) {
                ForEach(BuddyScope.allCases, id: \.self) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .disabled(paired)
            Text(buddy.nextScope.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 280)
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

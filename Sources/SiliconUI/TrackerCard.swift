import AppKit
import SiliconRuntime
import SwiftUI

/// Face tracking: your head and expressions, read from the camera and worn by the
/// character — here, and by any VTuber app that speaks VMC.
struct TrackerCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        // The badge is the reason to fold this at all: someone can see tracking is
        // running without opening the panel that says so.
        CollapsibleCard(
            title: "Motion tracking", systemImage: "figure.wave",
            badge: model.trackerIsRunning
                ? String(format: "live · %.0f fps", model.trackerFPS) : nil,
            isExpanded: model.videoPanel(.tracking)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Reads your head position, blinks, mouth and eyebrows from the "
                    + "camera. Your character follows them instead of just reacting "
                    + "to the voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !model.trackerInstallation.isInstalled {
                    installRow
                } else {
                    controls
                    if let error = model.trackerError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    vmcRow
                }
            }
        }
    }

    // MARK: - Install

    @ViewBuilder
    private var installRow: some View {
        if let job = model.repairs["tracker-install"] {
            HStack(spacing: 8) {
                if job.error == nil { ProgressView().controlSize(.small) }
                Text(job.error ?? job.stage)
                    .font(.caption)
                    .foregroundStyle(job.error == nil ? .secondary : Color.orange)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.trackerInstallation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    model.installTracker()
                } label: {
                    Label("Set up tracking", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    if model.trackerIsRunning || isStarting {
                        model.stopTracking()
                    } else {
                        model.startTracking()
                    }
                } label: {
                    Label(
                        model.trackerIsRunning || isStarting ? "Stop tracking" : "Start tracking",
                        systemImage: model.trackerIsRunning || isStarting
                            ? "stop.circle.fill" : "figure.wave"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(model.trackerIsRunning ? .red : nil)

                if isStarting {
                    ProgressView().controlSize(.small)
                    Text(startingStage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if model.trackerIsRunning {
                    Text(String(format: "%.0f fps", model.trackerFPS))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) {
                Toggle("Mirror", isOn: $model.trackerMirror)
                    .toggleStyle(.checkbox)
                Toggle("Upper body", isOn: $model.trackBody)
                    .toggleStyle(.checkbox)
                    .help("Reads shoulders, lean and where the hands are")
                Toggle("Fingers", isOn: $model.trackHands)
                    .toggleStyle(.checkbox)
                    .help("Reads every finger joint and sends them as VMC finger "
                        + "bones — for a rigged model with hands")
                HStack(spacing: 6) {
                    Text("Smoothing")
                    Slider(value: $model.trackerSmoothing, in: 0.1...0.9)
                        .frame(width: 110)
                }
                .help("Lower is steadier, higher follows you more closely")
            }
            .font(.caption)
            .disabled(model.trackerIsRunning)

            if model.trackerIsRunning {
                Text("Your character on the overlay is following you now. Blinks and "
                    + "mouth shapes use the drawings you gave them; without those it "
                    + "falls back to shading and the jaw warp.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isStarting: Bool {
        if case .starting = model.trackerState { return true }
        return false
    }

    private var startingStage: String {
        if case .starting(let stage) = model.trackerState { return stage }
        return "Starting…"
    }

    // MARK: - VMC

    private var vmcRow: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            Toggle("Also send to a VTuber app (VMC)", isOn: $model.settings.sendVMC)
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(model.trackerIsRunning)

            if model.settings.sendVMC {
                HStack(spacing: 8) {
                    TextField("Host", text: $model.settings.vmcHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    TextField(
                        "Port",
                        value: $model.settings.vmcPort, format: .number.grouping(.never)
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                }
                .font(.caption)
                .disabled(model.trackerIsRunning)
            }

            Text("VSeeFace, VTube Studio, Warudo and Inochi2D all accept VMC, so a "
                + "properly rigged Live2D or VRM model can be driven by this tracking "
                + "— rigging is their trade, not ours. 39539 is the port they listen "
                + "on by default.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

import AppKit
import SiliconRuntime
import SwiftUI

/// The live face camera: your camera in, the selected character's face out, served
/// where OBS can take it.
struct FaceCamCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Card(title: "Face camera", systemImage: "video.badge.waveform") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Wear your character's face on camera. Your expressions drive it, "
                    + "so it looks around and reacts the way you do — and nothing "
                    + "leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !model.faceCamInstallation.isInstalled {
                    installRow
                } else {
                    controls
                    if let error = model.faceCamError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.faceCamIsLive {
                        liveAddress
                    }
                    Text("The face comes from the selected character's portrait. Use "
                        + "faces you have the right to use — your own, or a character "
                        + "you made.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { model.refreshCameras() }
    }

    // MARK: - Install

    @ViewBuilder
    private var installRow: some View {
        if let job = model.repairs["facecam-install"] {
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
                Text(model.faceCamInstallation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.installFaceCam()
                } label: {
                    Label("Set up the face camera", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text("Installs Deep-Live-Cam, the open-source face swapper, into its "
                    + "own environment.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Camera", selection: $model.selectedCameraIndex) {
                    if model.availableCameras.isEmpty {
                        Text("No camera found").tag(0)
                    }
                    ForEach(Array(model.availableCameras.enumerated()), id: \.offset) {
                        index, name in
                        Text(name).tag(index)
                    }
                }
                .frame(maxWidth: 260)
                .disabled(model.faceCamIsLive)

                Button {
                    if model.faceCamIsLive || isStarting {
                        model.stopFaceCam()
                    } else {
                        model.startFaceCam()
                    }
                } label: {
                    Label(
                        model.faceCamIsLive || isStarting ? "Stop" : "Go live",
                        systemImage: model.faceCamIsLive || isStarting
                            ? "stop.circle.fill" : "video.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(model.faceCamIsLive ? .red : nil)
                .disabled(model.selectedPersona == nil)

                if isStarting {
                    ProgressView().controlSize(.small)
                    Text(startingStage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if model.faceCamIsLive {
                    Text(String(format: "%.0f fps", model.faceCamFPS))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(model.faceCamFPS >= 12 ? Color.secondary : .orange)
                        .help(model.faceCamFPS >= 12
                            ? "Smooth enough for streaming"
                            : "Slower than streaming likes — close other heavy work")
                }
            }

            HStack(spacing: 14) {
                Toggle("Mirror", isOn: $model.faceCamMirror)
                    .help("Show the picture the way a front camera does")
                Toggle("Keep my mouth", isOn: $model.faceCamMouthMask)
                    .help("Leaves your own mouth showing through, which lip-syncs "
                        + "far better than the swapped one")
                HStack(spacing: 6) {
                    Text("Strength")
                    Slider(value: $model.faceCamOpacity, in: 0.2...1)
                        .frame(width: 110)
                }
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            .disabled(model.faceCamIsLive)
        }
    }

    private var isStarting: Bool {
        if case .starting = model.faceCamState { return true }
        return false
    }

    private var startingStage: String {
        if case .starting(let stage) = model.faceCamState { return stage }
        return "Starting…"
    }

    // MARK: - Live

    @ViewBuilder
    private var liveAddress: some View {
        if let url = model.faceCamURL {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(url.absoluteString)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary, in: .rect(cornerRadius: 7))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Preview", systemImage: "safari")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text("Add it in OBS as a Browser Source. For Zoom, Discord or anything "
                    + "else that wants a webcam, start OBS's own Virtual Camera — macOS "
                    + "only lets OBS publish one.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

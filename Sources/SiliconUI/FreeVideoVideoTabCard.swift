import AppKit
import AVKit
import SiliconRuntime
import SwiftUI
import UniformTypeIdentifiers

/// A native composer for a connected Windows/Linux FreeVideo engine, with no paid service key.
struct FreeVideoVideoTabCard: View {
    @Environment(AppModel.self) private var app
    @State private var isExpanded = true

    private var studio: FreeVideoStudio { app.freeVideoStudio }

    var body: some View {
        @Bindable var studio = studio
        CollapsibleCard(title: "FreeVideo", systemImage: "film.stack", badge: badge,
                        isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Generate MiniMax H3 video with sound on your NVIDIA computer. FreeVideo runs through ComfyUI on Windows or Linux; this Mac sends the request and saves the finished clip.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The engine needs at least 8 GB of VRAM and 16 GB of RAM. Complete model setup and accept the model terms in FreeVideo before connecting.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("ComfyUI address", text: $studio.endpoint,
                          prompt: Text("http://your-nvidia-computer:8188"))
                    .disabled(!studio.isRestored || studio.isBusy || studio.isChecking)
                    .onSubmit { Task { await studio.saveConnection() } }
                HStack {
                    Button(studio.isChecking ? "Checking…" : "Check connection") {
                        Task { await studio.checkConnection() }
                    }
                    .disabled(!studio.isRestored || studio.isChecking || studio.isBusy)
                    Button("Open workspace") { openWorkspace() }
                        .disabled(workspaceURL == nil)
                    Link("Set up FreeVideo", destination: URL(string: "https://github.com/FlashML-org/FreeVideo#getting-started")!)
                }
                .controlSize(.small)

                if !studio.isRestored {
                    if studio.isRestoring {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading saved connection and jobs…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if studio.error != nil {
                        Button("Retry loading saved state") { Task { await studio.restore() } }
                            .controlSize(.small)
                    }
                }

                if let status = studio.engineStatus {
                    Label(status.ready ? "Engine ready" : "Setup incomplete",
                          systemImage: status.ready ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(status.ready ? .green : .orange)
                        .font(.caption)
                    if !status.detail.isEmpty {
                        Text(status.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()
                TextField("Describe the scene, motion, dialogue, and sound", text: $studio.prompt,
                          axis: .vertical)
                    .lineLimit(3...8)
                    .padding(8)
                    .background(.background.secondary, in: .rect(cornerRadius: 7))
                    .disabled(studio.isBusy)

                Picker("Canvas", selection: canvasBinding) {
                    Text("768 × 448 — lighter landscape").tag("768x448")
                    Text("448 × 768 — lighter portrait").tag("448x768")
                    Text("1344 × 768 — landscape").tag("1344x768")
                    Text("768 × 1344 — portrait").tag("768x1344")
                }
                .disabled(studio.isBusy)
                Picker("Length", selection: $studio.seconds) {
                    ForEach([3.0, 5.0, 10.0, 15.0], id: \.self) { seconds in
                        Text("\(Int(seconds)) s").tag(seconds)
                    }
                }
                .disabled(studio.isBusy)
                Text("24 fps. H3 rounds duration up to its frame grid. Larger canvases and longer clips use more memory.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Seed (blank = random)", text: $studio.seed)
                    .disabled(studio.isBusy)
                Toggle("Two-pass sampling", isOn: $studio.twoPass).disabled(studio.isBusy)
                Text("Generate the scene first, then refine it at the selected canvas size.")
                    .font(.caption).foregroundStyle(.secondary)
                framePicker(title: "First frame", value: studio.firstFrame) { studio.firstFrame = $0 }
                framePicker(title: "Last frame", value: studio.lastFrame) { studio.lastFrame = $0 }
                Text("Use Open workspace for reference video, reference audio, and LoRAs.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if studio.uncertainSubmission {
                    Label("Check the workspace queue and history before sending another job.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("I checked the workspace") {
                        Task { await studio.acknowledgeUnknownSubmission() }
                    }
                    .controlSize(.small)
                } else if let pending = studio.pending {
                    Text("Saved job on \(pending.endpoint.host ?? pending.endpoint.absoluteString). Resume follows this job without starting another render.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(studio.isBusy ? "Following job…" : "Resume saved job") {
                            Task { await studio.resume() }
                        }
                        .disabled(studio.isBusy || studio.isCancelling)
                        Button(studio.isCancelling ? "Cancelling…" : "Cancel job") {
                            Task { await studio.cancel() }
                        }
                        .disabled(studio.isCancelling)
                    }
                    .controlSize(.small)
                    if !studio.isBusy {
                        Button("I checked the workspace; forget saved job") {
                            Task { await studio.forgetSavedJob() }
                        }
                        .font(.caption).buttonStyle(.link)
                        .disabled(studio.isCancelling)
                    }
                } else {
                    Button("Generate video") {
                        Task { await studio.generate(outputDirectory: app.settings.resolvedVideoOutputDirectory) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!studio.canGenerate)
                    if !studio.isReady {
                        Text("Check the connection to a ready FreeVideo engine to generate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let stage = studio.stage {
                    HStack {
                        if studio.isBusy { ProgressView().controlSize(.small) }
                        Text(stage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = studio.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if let file = studio.displayedClip {
                    Divider()
                    ClipPlayer(url: file, controlsStyle: .floating)
                        .frame(height: 210)
                        .clipShape(.rect(cornerRadius: 8))
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        Button("Open video") { NSWorkspace.shared.open(file) }
                    }
                    .controlSize(.small)
                }
                if !studio.history.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Saved FreeVideo clips").font(.caption).foregroundStyle(.secondary)
                        ForEach(studio.history.prefix(10)) { clip in
                            Button {
                                studio.selectedClip = clip.file
                            } label: {
                                HStack {
                                    Image(systemName: "play.rectangle")
                                    Text(clip.prompt).lineLimit(1)
                                    Spacer()
                                    Text(clip.completedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(clip.file.path)
                        }
                    }
                }
            }
        }
        .task { await studio.restore() }
        .onDisappear { Task { await studio.saveConnection() } }
    }

    private var badge: String {
        if studio.isBusy { return "rendering" }
        if studio.pending != nil { return "saved job" }
        return studio.isReady ? "ready" : "connect engine"
    }

    private var workspaceURL: URL? {
        studio.pending?.endpoint ?? studio.uncertainEndpoint
            ?? (try? FreeVideoRuntime.validatedBaseURL(studio.endpoint))
    }

    private func openWorkspace() {
        guard let url = workspaceURL else { return }
        NSWorkspace.shared.open(url)
    }

    private var canvasBinding: Binding<String> {
        Binding(get: { "\(studio.width)x\(studio.height)" }, set: { value in
            let parts = value.split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else { return }
            studio.width = parts[0]
            studio.height = parts[1]
        })
    }

    private func framePicker(title: String, value: URL?, set: @escaping (URL?) -> Void) -> some View {
        HStack {
            Button(value == nil ? "Add \(title.lowercased())" : title) {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                if panel.runModal() == .OK { set(panel.url) }
            }
            .disabled(studio.isBusy)
            if let value {
                Text(value.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                Button("Remove", systemImage: "xmark") { set(nil) }
                    .labelStyle(.iconOnly).disabled(studio.isBusy)
            }
        }
        .controlSize(.small)
    }
}

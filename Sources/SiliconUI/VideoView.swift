import AVKit
import SiliconCatalog
import SiliconRuntime
import SwiftUI
import UniformTypeIdentifiers

/// The Video tab. Generation runs on a swarm node with a CUDA card — local video on
/// Apple Silicon is not worth pretending about yet — so this tab is honest about which
/// machine will do the work and what state it is in.
struct VideoView: View {
    @Environment(AppModel.self) private var model
    @State private var recentClips: [URL] = []
    @State private var showsRecents = false
    @State private var selectedClip: URL?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                if proxy.size.width >= 900 {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            PersonaCards()
                            composerCard
                        }
                        .frame(width: 400)
                        VStack(spacing: 16) {
                            resultCard
                            recentsPane
                        }
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 16) {
                        PersonaCards()
                        composerCard
                        resultCard
                        recentsPane
                    }
                    .padding(20)
                }
            }
        }
        .background(.background)
        .navigationTitle("Video")
        .task {
            await model.refreshSwarm()
            refreshRecents()
        }
        .onChange(of: model.videoResults.count) { refreshRecents() }
    }

    private var selectedEntry: VideoEntry? {
        VideoCatalog.entry(id: model.selectedVideoModel)
    }

    /// What the player shows: a clip picked from recents, else this session's newest,
    /// else the newest on disk — coming back to the tab should show your last clip
    /// rather than an empty state contradicted by the recents pane below it.
    private var displayedClip: URL? {
        selectedClip ?? model.videoResults.first?.file ?? recentClips.first
    }

    // MARK: - Composer

    private var composerCard: some View {
        @Bindable var model = model
        return Card(title: "Make a clip", systemImage: "film") {
            VStack(alignment: .leading, spacing: 12) {
                nodeRow

                Picker("Model", selection: $model.selectedVideoModel) {
                    ForEach(VideoCatalog.all) { entry in
                        Text(entry.name).tag(entry.id)
                    }
                }

                if let entry = selectedEntry {
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextEditor(text: $model.videoPrompt)
                        .font(.body)
                        .frame(minHeight: 90)
                        .padding(6)
                        .background(.background.secondary, in: .rect(cornerRadius: 7))
                        .overlay(alignment: .topLeading) {
                            if model.videoPrompt.isEmpty {
                                Text("Describe the shot — subject, motion, mood.")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 12)
                                    .padding(.leading, 11)
                                    .allowsHitTesting(false)
                            }
                        }

                    HStack {
                        Picker("Length", selection: $model.videoSeconds) {
                            Text("3 s").tag(3)
                            Text("5 s").tag(5)
                            Text("8 s").tag(8)
                        }
                        Picker("Size", selection: $model.videoResolution) {
                            Text("480p").tag("480p")
                            Text("720p").tag("720p")
                            Text("1080p").tag("1080p")
                        }
                    }

                    if entry.supportsImageInput {
                        imageRow
                    }

                    Text(timingNote(for: entry))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let error = model.videoError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button {
                            model.generateVideo()
                        } label: {
                            Label("Generate", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.isGeneratingVideo
                            || model.videoCapableNode == nil
                            || model.videoPrompt.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )

                        if model.isGeneratingVideo {
                            ProgressView().controlSize(.small)
                            Text(model.videoStage ?? "Working")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Button("Cancel") { model.cancelVideo() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    /// What the render will actually cost. The catalog carries an estimate; a node
    /// that has run the thing carries a measurement, and a measurement wins.
    private func timingNote(for entry: VideoEntry) -> String {
        guard let node = model.videoCapableNode,
              let capability = node.capabilities.first(where: {
                  $0.kind == NodeVideoRuntime.capabilityKind && $0.ready
              }),
              let seconds = capability.typicalSeconds, seconds > 0
        else { return "Typically \(entry.typicalDuration)." }

        let measured = seconds < 90
            ? "about \(Int(seconds.rounded())) seconds"
            : "about \(Int((seconds / 60).rounded())) minutes"
        return "\(node.name) measures \(measured) for a clip like this."
    }

    /// The machine doing the work, stated plainly — with the truth when there is none.
    @ViewBuilder
    private var nodeRow: some View {
        if let node = model.videoCapableNode {
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("Renders on \(node.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                Text("No node can make video yet. Your silicon-node machine has the "
                    + "card for it — the request to set it up is already filed on the "
                    + "shared hub, and this tab lights up the moment it's ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var imageRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            if let image = model.videoImage {
                Text(image.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    model.videoImage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
            } else {
                Text("Optional: a still image to animate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Choose image…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    panel.allowsMultipleSelection = false
                    NSApp.activate(ignoringOtherApps: true)
                    if panel.runModal() == .OK {
                        model.videoImage = panel.url
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer()
        }
    }

    // MARK: - Result

    private var resultCard: some View {
        Card(title: "Result", systemImage: "play.rectangle") {
            if let clip = displayedClip {
                ClipPlayer(url: clip)
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .background(.background.secondary, in: .rect(cornerRadius: 8))

                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([clip])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    Button {
                        NSWorkspace.shared.open(clip)
                    } label: {
                        Label("Open in QuickTime", systemImage: "arrow.up.forward.app")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                EmptyStateView(
                    systemImage: "film",
                    title: "No clip yet",
                    message: "Describe a shot and generate. The clip plays here and "
                        + "lands on disk as an MP4."
                )
            }
        }
    }

    // MARK: - Recents

    private var recentsPane: some View {
        RecentsPane(
            title: "Recent clips",
            systemImage: "clock",
            items: recentClips.map { ClipFile(url: $0) },
            isExpanded: $showsRecents
        ) { item in
            VStack(spacing: 4) {
                ClipThumbnail(url: item.url)
                Text(item.url.lastPathComponent
                    .replacingOccurrences(of: "silicon-video-", with: ""))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 96)
            }
        } onSelect: { item in
            selectedClip = item.url
        }
    }

    private struct ClipFile: Identifiable {
        var id: String { url.path }
        var url: URL
    }

    private func refreshRecents() {
        let directory = model.settings.resolvedVideoOutputDirectory
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        recentClips = contents
            .filter { ["mp4", "webm", "mov"].contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return dateA > dateB
            }
            .prefix(60)
            .map { $0 }
    }
}

/// The clip player.
///
/// AppKit's `AVPlayerView` rather than SwiftUI's `VideoPlayer`: the SwiftUI wrapper
/// aborted this app on first display, inside its own representable's generic metadata
/// (`_AVKit_SwiftUI` → `getSuperclassMetadata` → fatalError), taking the whole app down
/// the moment a rendered clip appeared. The AppKit view is the same player without the
/// wrapper, and it brings real transport controls with it.
struct ClipPlayer: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        context.coordinator.url = url
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        // Only a different file replaces the player; anything else would restart
        // playback on every unrelated state change.
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        view.player = AVPlayer(url: url)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var url: URL?
    }
}

/// First frames of saved clips, rendered once and cached — the mesh thumbnail pattern,
/// pointed at video.
actor ClipThumbnails {
    static let shared = ClipThumbnails()
    private var cache: [String: CGImage] = [:]

    func frame(for url: URL) async -> CGImage? {
        if let hit = cache[url.path] { return hit }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        cache[url.path] = image
        return image
    }
}

struct ClipThumbnail: View {
    var url: URL
    @State private var frame: CGImage?

    var body: some View {
        ZStack {
            if let frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 96, height: 60)
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 8))
        .task(id: url) {
            frame = await ClipThumbnails.shared.frame(for: url)
        }
    }
}

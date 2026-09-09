import AVKit
import SiliconCatalog
import SiliconRuntime
import SwiftUI
import UniformTypeIdentifiers

/// The Video tab. Generation runs through a model-aware video node, which may be a
/// paired CUDA machine or a loopback adapter for an Apple Silicon runtime such as
/// Phosphene. The selected catalog entry decides which exact capability must be ready.
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
                            composerCard
                            PersonaCards()
                        }
                        .frame(width: 400)
                        VStack(spacing: 16) {
                            VideoQueueView()
                            resultCard
                            recentsPane
                        }
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 16) {
                        composerCard
                        PersonaCards()
                        VideoQueueView()
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
        .onChange(of: model.videoResults.count) {
            refreshRecents()
            model.revealVideoPanel(.result)
        }
        .onChange(of: model.selectedVideoModel) {
            guard let entry = selectedEntry else { return }
            model.videoSeconds = entry.normalizedSeconds(model.videoSeconds)
            model.videoSampling = .nodeDefault
        }
        .onChange(of: selectedClip) { model.revealVideoPanel(.result) }
    }

    private var selectedEntry: VideoEntry? {
        VideoCatalog.entry(id: model.selectedVideoModel)
    }

    private var selectedNode: AppModel.PeerStatus? {
        selectedEntry.flatMap { model.videoCapableNode(for: $0) }
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
        return CollapsibleCard(
            title: model.videoBatchMode ? "Queue a batch" : "Make a clip", systemImage: "film",
            badge: selectedNode.map { "on \($0.name)" },
            isExpanded: model.videoPanel(.clip)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                nodeRow

                Picker("Mode", selection: $model.videoBatchMode) {
                    Text("Single clip").tag(false)
                    Text("Batch & variations").tag(true)
                }
                .pickerStyle(.segmented)

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

                    TextEditor(text: model.videoBatchMode ? $model.videoBatchPrompts : $model.videoPrompt)
                        .font(.body)
                        .frame(minHeight: model.videoBatchMode ? 170 : 90)
                        .padding(6)
                        .background(.background.secondary, in: .rect(cornerRadius: 7))
                        .overlay(alignment: .topLeading) {
                            if (model.videoBatchMode ? model.videoBatchPrompts : model.videoPrompt).isEmpty {
                                Text(model.videoBatchMode
                                     ? "Describe each shot in its own paragraph. Separate shots with a blank line."
                                     : "Describe the shot — subject, motion, mood.")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 12)
                                    .padding(.leading, 11)
                                    .allowsHitTesting(false)
                            }
                        }

                    if model.videoBatchMode {
                        Text("One paragraph per shot. Blank lines separate shots; each variation uses a different saved seed.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Batch name (optional)", text: $model.videoBatchTitle)
                        Stepper("\(model.videoBatchVariations) variation\(model.videoBatchVariations == 1 ? "" : "s") per prompt",
                                value: $model.videoBatchVariations, in: 1...VideoBatchQueue.maximumVariations)
                        TextField("Base seed (blank = random)", text: $model.videoBatchSeed)
                            .help("An integer from 0 to 4294967295. Each following clip increments it; use the same value to compare sampling settings.")
                        Text("\(batchPromptCount) prompts × \(model.videoBatchVariations) = \(batchClipCount) clips · \(batchClipCount * model.videoSeconds) seconds of footage")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Room for \(max(0, VideoBatchQueue.maximumPending - model.videoBatchQueue.pendingCount)) more queued clips.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    HStack {
                        Picker("Length", selection: $model.videoSeconds) {
                            ForEach(entry.supportedSeconds, id: \.self) {
                                Text("\($0) s").tag($0)
                            }
                        }
                        Picker("Size", selection: $model.videoResolution) {
                            Text("480p").tag("480p")
                            Text("720p").tag("720p")
                            Text("1080p").tag("1080p")
                        }
                    }

                    if entry.id == "hailuo-h3" {
                        Picker("Sampling", selection: $model.videoSampling) {
                            ForEach(VideoSampling.allCases, id: \.self) { sampling in
                                Text(sampling.label).tag(sampling)
                            }
                        }
                        .disabled(!model.supportsH3Sampling)
                        Text(model.supportsH3Sampling
                             ? "Full sampling uses the non-Turbo schedule at the same canvas size. It takes longer, but is not guaranteed to look better. Size can increase memory use."
                             : "Per-clip sampling requires the updated local video node. Renderer default keeps the node’s configured setting.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if entry.supportsImageInput && !model.videoBatchMode {
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
                        if model.videoBatchMode {
                            Button {
                                model.enqueueVideoComposer()
                            } label: {
                                Label("Queue \(batchClipCount) clips", systemImage: "text.badge.plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(batchClipCount == 0 || batchClipCount + model.videoBatchQueue.pendingCount > VideoBatchQueue.maximumPending
                                      || model.videoBatchQueue.storageError != nil || model.isEnqueuingVideoBatch)
                        } else {
                        Button {
                            model.generateVideo()
                        } label: {
                            Label("Generate", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.isGeneratingVideo
                            || selectedNode == nil
                            || model.videoPrompt.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )
                        }

                        if model.isGeneratingVideo && model.activeVideoQueueID == nil {
                            Button("Cancel") { model.cancelVideo() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }

                    if model.videoBatchMode {
                        Text("Leave Silicon Optimizer open to run the queue. It prevents idle sleep while work is queued; keep the Mac powered and its lid open. Quitting saves the queue; reopening reconnects to the current job before starting the next.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let message = model.videoQueueMessage {
                            Text(message).font(.caption).foregroundStyle(.orange)
                        }
                    }

                    // Its own row, full width. Squeezed in beside the buttons, the line that
                    // says how far along the node is — the whole point of showing it — was
                    // the first thing to be truncated away.
                    if model.isGeneratingVideo {
                        VStack(alignment: .leading, spacing: 4) {
                            if let fraction = model.videoProgress {
                                ProgressView(value: fraction)
                                    .progressViewStyle(.linear)
                            } else {
                                ProgressView()
                                    .progressViewStyle(.linear)
                            }
                            Text(model.videoStage ?? "Working")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var batchPromptCount: Int { VideoBatchQueue.parsePrompts(model.videoBatchPrompts).count }
    private var batchClipCount: Int { batchPromptCount * model.videoBatchVariations }

    /// What the render will actually cost. The catalog carries an estimate; a node
    /// that has run the thing carries a measurement, and a measurement wins.
    private func timingNote(for entry: VideoEntry) -> String {
        guard let node = model.videoCapableNode(for: entry),
              let capability = model.videoCapability(for: entry, on: node),
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
        if let node = selectedNode {
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("Renders on \(node.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else if let entry = selectedEntry {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                Text("No ready node offers \(entry.name). "
                    + (entry.setupHint ?? "Enable its \(entry.capabilityID) capability."))
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
        CollapsibleCard(
            title: "Result", systemImage: "play.rectangle",
            badge: displayedClip?.lastPathComponent
                .replacingOccurrences(of: "silicon-video-", with: ""),
            isExpanded: model.videoPanel(.result)
        ) {
            if let clip = displayedClip {
                ClipPlayer(url: clip)
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .background(.background.secondary, in: .rect(cornerRadius: 8))

                if let receipt = receipt(for: clip) {
                    Text(receipt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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

    /// Where a clip came from: the model, the machine, and how long it took. Only for
    /// clips made this session — a file picked out of the recents carries no such record.
    private func receipt(for clip: URL) -> String? {
        guard let result = model.videoResults.first(where: { $0.file == clip })
        else { return nil }
        var parts = [result.modelName]
        if let node = result.node { parts.append("on \(node)") }
        if result.elapsed >= 1 { parts.append(NodeJobProgress.durationText(result.elapsed)) }
        return parts.joined(separator: " · ")
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

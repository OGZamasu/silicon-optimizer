import AppKit
import SiliconRuntime
import SwiftUI

/// Persistent history, not transient task state: it remains useful after a relaunch.
struct VideoQueueView: View {
    @Environment(AppModel.self) private var model
    @State private var uncertainRetry: VideoQueueItem?
    @State private var stopFollowing: VideoQueueItem?
    @State private var cancelRender: VideoQueueItem?

    var body: some View {
        CollapsibleCard(title: "Video queue", systemImage: "list.bullet.rectangle",
                        badge: "\(model.videoBatchQueue.pendingCount) queued/running",
                        isExpanded: model.videoPanel(.queue)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(model.videoBatchQueue.isPaused ? "Resume queue" : "Pause after this clip") {
                        model.videoQueueAction(model.videoBatchQueue.isPaused ? "resume" : "pause")
                    }
                    .disabled(model.videoBatchQueue.storageError != nil)
                    Spacer()
                    Button("Clear finished history") { model.videoQueueAction("clear_finished") }
                        .buttonStyle(.borderless)
                        .disabled(!model.videoBatchQueue.items.contains { $0.status == .completed })
                }
                Text(model.videoBatchQueue.isPaused
                     ? "Paused: an accepted clip can finish, but no new render will start."
                     : "One clip at a time. Keep adding single clips or batches in the composer while this queue renders.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = model.videoBatchQueue.storageError ?? model.videoQueueMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.videoBatchQueue.items.isEmpty {
                    Text("Your next clip will appear here. Use Add to queue in Make a clip, or queue a batch of prompts and variations.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Active and waiting clips first · newest finished clips first")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(model.videoBatchQueue.displayItems) { item in
                                row(item)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 420)
                }
            }
        }
        .alert("Render this clip again?", isPresented: Binding(
            get: { uncertainRetry != nil }, set: { if !$0 { uncertainRetry = nil } }
        )) {
            Button("Cancel", role: .cancel) { uncertainRetry = nil }
            Button("I checked the node — render again") {
                if let item = uncertainRetry {
                    model.videoQueueAction("retry", id: item.id, confirmNewRender: true)
                }
                uncertainRetry = nil
            }
        } message: {
            Text("The original submission may still be running. Check the node first. This explicitly creates a new render and may produce another copy. Then resume the queue when ready.")
        }
        .alert("Stop following this clip?", isPresented: Binding(
            get: { stopFollowing != nil }, set: { if !$0 { stopFollowing = nil } }
        )) {
            Button("Keep following", role: .cancel) { stopFollowing = nil }
            Button("Stop following") {
                if let item = stopFollowing { model.cancelVideo(item.id) }
                stopFollowing = nil
            }
        } message: {
            Text("This pauses the queue and stops the app waiting. It does not stop the GPU render. The saved receipt lets you reconnect and download later. To stop the render itself, use Cancel render where the node offers it, or the node's own controls.")
        }
        .alert("Cancel this render?", isPresented: Binding(
            get: { cancelRender != nil }, set: { if !$0 { cancelRender = nil } }
        )) {
            Button("Keep rendering", role: .cancel) { cancelRender = nil }
            Button("Cancel render", role: .destructive) {
                if let item = cancelRender { model.videoQueueAction("cancel", id: item.id) }
                cancelRender = nil
            }
        } message: {
            Text("Asks \(cancelRender?.nodeName ?? "the node") to stop rendering this clip and nothing else. If it finishes first, the clip is kept. Nothing is resubmitted either way.")
        }
    }

    /// What asking the node to cancel came to, in the words a person needs later.
    private static func cancelLine(_ cancel: VideoCancelRecord) -> String {
        let detail = cancel.detail.map { ": \($0)" } ?? ""
        switch cancel.state {
        case .sending: return "Asking the node to cancel…"
        case .requested: return "Cancel requested — waiting for the node to confirm"
        case .confirmed: return "Cancelled on the node" + detail
        case .completed: return "Finished before the cancel took effect; the clip is kept"
        case .failed: return "Had already failed when the cancel arrived" + detail
        case .unsupported: return "The node could not stop this render" + detail
        case .unknown: return "Cancel not confirmed; the render may still be running" + detail
        }
    }

    private func row(_ item: VideoQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(item.batchName) · \(item.label)").font(.subheadline.weight(.medium))
                Spacer()
                Text(item.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            Text(item.request.prompt).font(.caption).lineLimit(3).textSelection(.enabled)
            Text("\(item.request.entryID) · \(item.request.seconds)s · \(item.request.resolution) · seed \(String(item.request.seed ?? 0))")
                .font(.caption2).foregroundStyle(.secondary)
            if let detail = item.detail {
                // How these settings were arrived at, when nobody typed them. Kept with the
                // clip rather than shown once at enqueue time: the queue outlives the
                // composer, and "why is this one 8 seconds?" is asked days later.
                Label(detail, systemImage: "wand.and.stars")
                    .font(.caption2).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.request.entryID == "hailuo-h3" {
                Text(item.request.h3Turbo.map { $0 ? VideoSampling.turbo.label : VideoSampling.full.label }
                     ?? VideoSampling.nodeDefault.label)
                    .font(.caption2).foregroundStyle(.secondary)
                if let steps = item.request.h3Steps {
                    Text("\(steps) sigma points · \(steps - 1) denoising passes per window")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            VideoQueueProgress(itemID: item.id)
            if let cancel = item.cancel {
                Label(Self.cancelLine(cancel), systemImage: "stop.circle")
                    .font(.caption2).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = item.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack(spacing: 12) {
                if let file = item.file {
                    Button("Play") { NSWorkspace.shared.open(file) }
                    Button("Show clip") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
                Button("Output folder") { NSWorkspace.shared.open(item.request.outputDirectory) }
                if item.status == .pending {
                    Button("Remove") { model.videoQueueAction("remove", id: item.id) }
                }
                if model.canCancelVideo(item) {
                    Button("Cancel render…") { cancelRender = item }
                }
                if model.activeVideoQueueID == item.id {
                    Button("Stop following…") { stopFollowing = item }
                }
                if item.status == .cancelled {
                    // The node confirmed the old render stopped: a new one is not a duplicate.
                    Button("Render again") { model.videoQueueAction("retry", id: item.id) }
                }
                if item.status == .failed {
                    Button(item.canReconnect ? "Reconnect / download" : "Retry render") {
                        if item.uncertainSubmission { uncertainRetry = item }
                        else { model.videoQueueAction("retry", id: item.id) }
                    }
                    if item.canReconnect {
                        Button("Render again…") { uncertainRetry = item }
                    }
                }
            }
            .buttonStyle(.borderless).font(.caption)
        }
    }
}

/// Progress observation belongs to this small child, not the history list.
private struct VideoQueueProgress: View {
    @Environment(AppModel.self) private var model
    let itemID: String

    var body: some View {
        if model.activeVideoQueueID == itemID {
            ProgressView(value: model.videoProgress).progressViewStyle(.linear)
            Text(model.videoStage ?? "Reconnecting").font(.caption).foregroundStyle(.secondary)
        }
    }
}

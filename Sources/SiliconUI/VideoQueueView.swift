import AppKit
import SiliconRuntime
import SwiftUI

/// Persistent history, not transient task state: it remains useful after a relaunch.
struct VideoQueueView: View {
    @Environment(AppModel.self) private var model
    @State private var uncertainRetry: VideoQueueItem?

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
            if item.request.entryID == "hailuo-h3" {
                Text(item.request.h3Turbo.map { $0 ? VideoSampling.turbo.label : VideoSampling.full.label }
                     ?? VideoSampling.nodeDefault.label)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if model.activeVideoQueueID == item.id {
                ProgressView(value: model.videoProgress).progressViewStyle(.linear)
                Text(model.videoStage ?? "Reconnecting").font(.caption).foregroundStyle(.secondary)
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

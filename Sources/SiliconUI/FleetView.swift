import AppKit
import SiliconControl
import SwiftUI

/// The Fleet tab: every request the model gateway has routed — which model, which
/// machine, how long, how many tokens — with the per-model speed estimates the ledger
/// feeds back into `/v1/models`. The orchestrated game build kept this record by hand;
/// the gateway keeps it automatically now, and this is where it reads well.
struct FleetView: View {
    @Environment(AppModel.self) private var model

    @State private var entries: [GatewayLedgerEntry] = []
    @State private var stats: [String: GatewayModelStats] = [:]
    @State private var expanded: Set<String> = []

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                List {
                    if !stats.isEmpty {
                        Section("Models") {
                            ForEach(stats.keys.sorted(), id: \.self) { modelID in
                                if let stat = stats[modelID] {
                                    statRow(modelID: modelID, stat: stat)
                                }
                            }
                        }
                    }
                    Section("Requests") {
                        ForEach(entries) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }
        }
        .navigationTitle("Fleet")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: previewsBinding) {
                    Label("Previews", systemImage: "text.magnifyingglass")
                }
                .help("Keep short prompt/response excerpts in the ledger (local only)")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([ledgerURL])
                } label: {
                    Label("Reveal Log", systemImage: "doc.text.magnifyingglass")
                }
                .help("Show gateway-ledger.jsonl in Finder")
            }
        }
        .task {
            while !Task.isCancelled {
                if let ledger = model.gatewayLedger {
                    entries = await ledger.snapshot()
                    stats = await ledger.stats()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var ledgerURL: URL {
        SwarmConfig.configURL.deletingLastPathComponent()
            .appendingPathComponent("gateway-ledger.jsonl")
    }

    private var previewsBinding: Binding<Bool> {
        Binding(
            get: { model.settings.fleetPreviewsEnabled ?? true },
            set: { enabled in
                model.settings.fleetPreviewsEnabled = enabled
                model.settings.save()
                if let ledger = model.gatewayLedger {
                    Task { await ledger.setPreviews(enabled) }
                }
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No gateway traffic yet")
                .font(.title3.weight(.semibold))
            Text("Every request an external engine routes through the model gateway — "
                 + "DeepSeek Harness, Codex, Qwen Code, or any agent on this Mac — "
                 + "shows up here with its model, timing, and token counts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statRow(modelID: String, stat: GatewayModelStats) -> some View {
        HStack(spacing: 10) {
            Text(shortName(modelID))
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if stat.inFlight > 0 {
                Label("\(stat.inFlight) in flight", systemImage: "circle.dotted")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("\(stat.requests) request\(stat.requests == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if stat.failures > 0 {
                Text("\(stat.failures) failed")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let rate = stat.tokensPerSecond {
                Text("\(rate, specifier: "%.1f") tok/s")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.blue)
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: GatewayLedgerEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(entry))
                    .frame(width: 8, height: 8)
                Text(entry.startedAt, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(shortName(entry.modelID))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.endpoint)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                if entry.warning != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.orange)
                        .help(entry.warning ?? "")
                }
                Spacer()
                tokensLabel(entry)
                durationLabel(entry)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if expanded.contains(entry.id) {
                    expanded.remove(entry.id)
                } else {
                    expanded.insert(entry.id)
                }
            }

            if expanded.contains(entry.id) {
                VStack(alignment: .leading, spacing: 4) {
                    if let prompt = entry.promptPreview {
                        detailLine(label: "asked", text: prompt)
                    }
                    if let answer = entry.responsePreview {
                        detailLine(label: "answered", text: answer)
                    }
                    if let warning = entry.warning {
                        detailLine(label: "warning", text: warning)
                    }
                    if let detail = entry.detail {
                        detailLine(label: "detail", text: detail)
                    }
                    if let ensure = entry.ensureMs, ensure > 1000 {
                        detailLine(
                            label: "getting ready",
                            text: String(
                                format: "%.1fs before generation began",
                                Double(ensure) / 1000
                            )
                        )
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 1)
    }

    private func detailLine(label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 74, alignment: .trailing)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func statusColor(_ entry: GatewayLedgerEntry) -> Color {
        switch entry.ok {
        case nil: .orange
        case true?: entry.warning == nil ? .green : .yellow
        case false?: .red
        }
    }

    @ViewBuilder
    private func tokensLabel(_ entry: GatewayLedgerEntry) -> some View {
        if let output = entry.outputTokens {
            Text("\(entry.promptTokens.map { "\($0)↑ " } ?? "")\(output)↓")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Prompt and completion tokens")
        }
    }

    @ViewBuilder
    private func durationLabel(_ entry: GatewayLedgerEntry) -> some View {
        if let total = entry.totalMs {
            Text(total >= 1000
                 ? String(format: "%.1fs", Double(total) / 1000)
                 : "\(total)ms")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
        }
    }

    /// "local/hf:unsloth/Qwen3.8-27B-GGUF@Q4_K_M" is a routing id, not a label —
    /// show the tail humans recognize plus where it runs.
    private func shortName(_ modelID: String) -> String {
        switch GatewayAPI.parseModelID(modelID) {
        case .local(let install):
            let tail = install.split(separator: "/").last.map(String.init) ?? install
            return "\(tail) · This Mac"
        case .node(let slug, let name):
            return "\(name) · \(slug)"
        case nil:
            return modelID
        }
    }
}
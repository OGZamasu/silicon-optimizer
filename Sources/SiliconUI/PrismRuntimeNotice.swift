import SiliconCatalog
import SwiftUI

/// The runtime story for a model that needs PrismML's llama.cpp fork, in one line: fetched
/// automatically with the weights, fetching now, failed (with a retry), or ready.
struct PrismRuntimeNotice: View {
    @Environment(AppModel.self) private var model
    var entry: ModelEntry
    /// Show the green "ready" line too, for the detail sheet; rows stay quiet when all is well.
    var showsWhenReady = false

    var body: some View {
        if model.hasPrismTernaryRuntime {
            if showsWhenReady {
                Label(
                    "PrismML's llama.cpp fork is installed — this build reads the format.",
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else if let install = model.prismRuntimeInstall {
            if let error = install.error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(
                        "Fetching PrismML's llama.cpp fork failed: \(error)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { model.installPrismRuntime() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("PrismML's llama.cpp fork: \(install.stage)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(
                    "Needs PrismML's llama.cpp fork (12 MB) — fetched automatically with the "
                        + "weights.",
                    systemImage: "arrow.down.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                Button("Fetch now") { model.installPrismRuntime() }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
    }
}

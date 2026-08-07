import SiliconCore
import SiliconPlanner
import SiliconRuntime
import SwiftUI

/// One-click benchmark and scorecard.
struct BenchmarkCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Benchmark", systemImage: "stopwatch") {
            if let phase = model.benchmarkPhase {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(phase.label)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text("Takes about a minute. Leave the machine otherwise idle for an "
                         + "accurate result.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else if let report = model.benchmarkReport {
                scorecard(report)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Measure what this model actually does on this Mac, and recalibrate "
                         + "future estimates against the result.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.runBenchmark()
                    } label: {
                        Label("Run benchmark", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.runtimeState.isRunning)
                }
            }
        }
    }

    @ViewBuilder
    private func scorecard(_ report: BenchmarkRunner.Report) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(report.score)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(scoreColor(report.score))
                VStack(alignment: .leading, spacing: 0) {
                    Text(report.grade).font(.headline)
                    Text("\(report.modelName) · \(report.quantization)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Re-run") { model.runBenchmark() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            HStack {
                Readout(
                    label: "Generation",
                    value: String(format: "%.0f", report.shortPromptGeneration),
                    caption: "tokens/sec"
                )
                Readout(
                    label: "Prompt",
                    value: String(format: "%.0f", report.longPromptPrefill),
                    caption: "tokens/sec"
                )
                Readout(
                    label: "First token",
                    value: String(format: "%.2fs", report.timeToFirstToken),
                    caption: "latency"
                )
            }

            // Measured against predicted is the interesting number — it says whether to trust
            // the planner's advice on this machine.
            HStack {
                Text("Predicted \(Int(report.predictedGeneration)) tok/s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%% of prediction", report.generationAccuracy * 100))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(
                        report.generationAccuracy > 0.85 ? .green : .orange
                    )
            }

            if !model.benchmarkFindings.isEmpty {
                Divider()
                ForEach(model.benchmarkFindings) { finding in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(finding.severity))
                            .foregroundStyle(color(finding.severity))
                            .imageScale(.small)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(finding.title).font(.callout.weight(.medium))
                            Text(finding.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 85...: .green
        case 70..<85: .mint
        case 50..<70: .yellow
        case 30..<50: .orange
        default: .red
        }
    }

    private func icon(_ severity: BenchmarkRunner.Finding.Severity) -> String {
        switch severity {
        case .good: "checkmark.circle.fill"
        case .advice: "lightbulb.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private func color(_ severity: BenchmarkRunner.Finding.Severity) -> Color {
        switch severity {
        case .good: .green
        case .advice: .blue
        case .warning: .orange
        }
    }
}

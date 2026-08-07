import SiliconCore
import SiliconHardware
import SiliconPlanner
import SwiftUI

// MARK: - Palette

enum Palette {
    /// Traffic-light colours used consistently for every "how much headroom is left" reading,
    /// so a colour means the same thing on the dashboard as it does in a memory plan.
    static func pressure(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.70: .green
        case ..<0.85: .yellow
        case ..<0.95: .orange
        default: .red
        }
    }

    static func verdict(_ verdict: MemoryPlan.Verdict) -> Color {
        switch verdict {
        case .comfortable: .green
        case .tight: .yellow
        case .willSwap: .orange
        case .impossible: .red
        }
    }
}

// MARK: - Cards

/// The standard container. One rounded rectangle, one material, used everywhere so the window
/// reads as a single surface rather than a pile of controls.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label {
                    Text(title)
                        .font(.headline)
                } icon: {
                    if let systemImage { Image(systemName: systemImage) }
                }
                .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.5), lineWidth: 0.5)
        }
    }
}

// MARK: - Readouts

/// A labelled number. Monospaced digits keep the layout from jittering as values update once a
/// second — the single most important detail in a live dashboard.
struct Readout: View {
    var label: String
    var value: String
    var caption: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A horizontal capacity bar with optional segments, used for memory breakdowns.
struct SegmentedBar: View {
    struct Segment: Identifiable {
        var id: String { label }
        var label: String
        var bytes: Bytes
        var color: Color
    }

    var segments: [Segment]
    var total: Bytes
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: width(for: segment, in: geometry.size.width))
                }
                Rectangle().fill(.quaternary)
            }
            .clipShape(.rect(cornerRadius: height / 2))
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.4), value: segments.map(\.bytes.rawValue))
    }

    private func width(for segment: Segment, in available: CGFloat) -> CGFloat {
        guard total.rawValue > 0 else { return 0 }
        return max(0, available * segment.bytes.fraction(of: total))
    }
}

/// Legend entry paired with `SegmentedBar`.
struct LegendRow: View {
    var color: Color
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.callout)
            Spacer()
            Text(value)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Graphs

/// A compact live graph. Drawn with `Path` rather than Charts so it stays cheap enough to update
/// every second without measurable CPU cost.
struct Sparkline: View {
    var values: [Double]           // each 0...1
    var tint: Color
    var showsFill = true

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(max(1, values.count - 1))

            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(
                    x: CGFloat(index) * step,
                    y: size.height * (1 - CGFloat(value.clamped(to: 0...1)))
                )
                index == 0 ? line.move(to: point) : line.addLine(to: point)
            }

            if showsFill {
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(
                    fill,
                    with: .linearGradient(
                        Gradient(colors: [tint.opacity(0.35), tint.opacity(0.02)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
            }
            context.stroke(line, with: .color(tint), lineWidth: 1.5)
        }
        .drawingGroup()
    }
}

/// A circular gauge for a single 0–1 value.
struct Gauge: View {
    var value: Double
    var label: String
    var caption: String
    var tint: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(.quaternary, style: .init(lineWidth: 8, lineCap: .round))
                Circle()
                    .trim(from: 0, to: 0.75 * value.clamped(to: 0...1))
                    .stroke(tint, style: .init(lineWidth: 8, lineCap: .round))
                    .animation(.smooth(duration: 0.5), value: value)
                VStack(spacing: 0) {
                    Text("\(Int(value.clamped(to: 0...1) * 100))")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                // Undo the container's rotation so the readout stays upright — only the arcs
                // are meant to turn.
                .rotationEffect(.degrees(-135))
            }
            // Rotated so the 25% gap sits at the bottom, like a physical gauge.
            .rotationEffect(.degrees(135))
            .frame(width: 72, height: 72)

            VStack(spacing: 1) {
                Text(label).font(.caption.weight(.medium))
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Badges

struct Badge: View {
    var text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(tint.opacity(0.15), in: .capsule)
        .foregroundStyle(tint)
    }
}

struct RatingStars: View {
    var rating: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { index in
                Image(systemName: index <= rating ? "star.fill" : "star")
                    .imageScale(.small)
            }
        }
        .foregroundStyle(.yellow)
        .accessibilityLabel("\(rating) out of 5")
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Helpers

extension Int {
    /// Formats a token count the way model documentation does: 32K, 128K, 1M.
    var contextLabel: String {
        if self >= 1_048_576 { return "\(self / 1_048_576)M" }
        if self >= 1024 { return "\(self / 1024)K" }
        return String(self)
    }
}

extension TimeInterval {
    var durationLabel: String {
        if self < 60 { return "\(Int(self))s" }
        if self < 3600 { return "\(Int(self / 60))m \(Int(self.truncatingRemainder(dividingBy: 60)))s" }
        return String(format: "%.1fh", self / 3600)
    }
}

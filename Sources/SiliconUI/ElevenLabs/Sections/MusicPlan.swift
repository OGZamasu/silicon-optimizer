import Foundation
import SiliconElevenLabs
import SwiftUI

/// A composition plan in the sections shape (`MusicPrompt`): global styles to have and to
/// avoid, then sections with their own styles, length and lyrics. What `POST /v1/music/plan`
/// answers and what composing from a plan sends.
struct MusicPlan: Hashable, Sendable {
    struct Section: Identifiable, Hashable, Sendable {
        let id = UUID()
        var name: String
        var durationMs: Int
        var lines: [String]
        var positiveStyles: [String]
        var negativeStyles: [String]
        /// Anything else the section carried (`source_from` for inpainting), sent back as is.
        var extra: [String: JSONValue] = [:]

        static func == (lhs: Section, rhs: Section) -> Bool {
            lhs.name == rhs.name && lhs.durationMs == rhs.durationMs && lhs.lines == rhs.lines
                && lhs.positiveStyles == rhs.positiveStyles && lhs.negativeStyles == rhs.negativeStyles
                && lhs.extra == rhs.extra
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(durationMs)
            hasher.combine(lines)
        }
    }

    var positiveStyles: [String]
    var negativeStyles: [String]
    var sections: [Section]

    /// The keys a section is built from; the rest go to `extra`.
    static let sectionKeys: Set<String> = [
        "section_name", "duration_ms", "lines", "positive_local_styles", "negative_local_styles",
    ]

    /// From the sections shape; nil for any other (the chunks shape newer models use is
    /// edited as JSON).
    init?(json: JSONValue) {
        guard let sections = json["sections"].arrayValue else { return nil }
        positiveStyles = (json["positive_global_styles"].arrayValue ?? []).compactMap(\.stringValue)
        negativeStyles = (json["negative_global_styles"].arrayValue ?? []).compactMap(\.stringValue)
        self.sections = sections.map { section in
            Section(
                name: section["section_name"].stringValue ?? "",
                durationMs: section["duration_ms"].intValue ?? 0,
                lines: (section["lines"].arrayValue ?? []).compactMap(\.stringValue),
                positiveStyles: (section["positive_local_styles"].arrayValue ?? []).compactMap(\.stringValue),
                negativeStyles: (section["negative_local_styles"].arrayValue ?? []).compactMap(\.stringValue),
                extra: (section.objectValue ?? [:]).filter { !Self.sectionKeys.contains($0.key) && $0.value != .null }
            )
        }
    }

    init(positiveStyles: [String], negativeStyles: [String], sections: [Section]) {
        self.positiveStyles = positiveStyles
        self.negativeStyles = negativeStyles
        self.sections = sections
    }

    var json: JSONValue {
        .object([
            "positive_global_styles": .array(positiveStyles.map(JSONValue.string)),
            "negative_global_styles": .array(negativeStyles.map(JSONValue.string)),
            "sections": .array(sections.map { section in
                var object = section.extra
                object["section_name"] = .string(section.name)
                object["duration_ms"] = .number(Double(section.durationMs))
                object["lines"] = .array(section.lines.map(JSONValue.string))
                object["positive_local_styles"] = .array(section.positiveStyles.map(JSONValue.string))
                object["negative_local_styles"] = .array(section.negativeStyles.map(JSONValue.string))
                return .object(object)
            }),
        ])
    }

    var totalMs: Int { sections.reduce(0) { $0 + $1.durationMs } }

    /// What the schema's limits say about this plan (`composition_plan` in `generate`).
    func problems(operationID: String = "generate") -> [String] {
        var problems: [String] = []
        let base = "composition_plan"
        if let limit = CreativeSpec.maxItems(operationID, "\(base).sections"), sections.count > limit {
            problems.append("A plan takes at most \(limit) sections.")
        }
        if sections.isEmpty { problems.append("The plan has no sections.") }
        let duration = CreativeSpec.range(operationID, "\(base).sections[].duration_ms")
        let nameLimit = CreativeSpec.maxLength(operationID, "\(base).sections[].section_name")
        let lineLimit = CreativeSpec.maxLength(operationID, "\(base).sections[].lines[]")
        let linesLimit = CreativeSpec.maxItems(operationID, "\(base).sections[].lines")
        for (index, section) in sections.enumerated() {
            let label = section.name.isEmpty ? "Section \(index + 1)" : "“\(section.name)”"
            if section.name.isEmpty { problems.append("Section \(index + 1) needs a name.") }
            if let nameLimit, section.name.count > nameLimit { problems.append("\(label)'s name takes at most \(nameLimit) characters.") }
            if let duration, !duration.contains(Double(section.durationMs)) {
                problems.append("\(label) must last between \(Int(duration.lowerBound / 1000)) and \(Int(duration.upperBound / 1000)) seconds.")
            }
            if let linesLimit, section.lines.count > linesLimit { problems.append("\(label) takes at most \(linesLimit) lines.") }
            if let lineLimit, section.lines.contains(where: { $0.count > lineLimit }) {
                problems.append("\(label) has a line over \(lineLimit) characters.")
            }
        }
        return problems
    }
}

/// Edits a plan in the sections shape: global styles, then each section's name, length,
/// styles and lyrics.
struct MusicPlanEditor: View {
    @Binding var plan: MusicPlan
    /// The range a section's length takes, in milliseconds, from the schema.
    var durationRange: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CreativeTagField(title: "Styles to have", tags: $plan.positiveStyles, prompt: "e.g. warm analog synths")
            CreativeTagField(title: "Styles to avoid", tags: $plan.negativeStyles, prompt: "e.g. distorted guitar")
            ForEach(Array(plan.sections.enumerated()), id: \.element.id) { index, section in
                sectionEditor(index: index, id: section.id)
            }
            HStack {
                Button {
                    plan.sections.append(MusicPlan.Section(
                        name: "Section \(plan.sections.count + 1)",
                        durationMs: Int(max(durationRange.lowerBound, min(15_000, durationRange.upperBound))),
                        lines: [], positiveStyles: [], negativeStyles: []
                    ))
                } label: {
                    Label("Add a section", systemImage: "plus")
                }
                Spacer()
                Text("Total \(ElevenLabsAudioPlayerView.clock(Double(plan.totalMs) / 1000))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
    }

    private func sectionEditor(index: Int, id: MusicPlan.Section.ID) -> some View {
        let section = Binding<MusicPlan.Section>(
            get: { plan.sections.first { $0.id == id } ?? plan.sections[min(index, plan.sections.count - 1)] },
            set: { new in if let position = plan.sections.firstIndex(where: { $0.id == id }) { plan.sections[position] = new } }
        )
        let seconds = Binding<Double>(
            get: { Double(section.wrappedValue.durationMs) / 1000 },
            set: { section.wrappedValue.durationMs = Int(($0 * 1000).rounded()) }
        )
        let lyrics = Binding<String>(
            get: { section.wrappedValue.lines.joined(separator: "\n") },
            set: { section.wrappedValue.lines = $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(index + 1)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                TextField("Name", text: section.name, prompt: Text("Verse, chorus, bridge…"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                Button {
                    guard index > 0 else { return }
                    plan.sections.swapAt(index, index - 1)
                } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless).disabled(index == 0)
                    .accessibilityLabel("Move section \(index + 1) up")
                Button {
                    guard index < plan.sections.count - 1 else { return }
                    plan.sections.swapAt(index, index + 1)
                } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.borderless).disabled(index == plan.sections.count - 1)
                    .accessibilityLabel("Move section \(index + 1) down")
                Button {
                    plan.sections.removeAll { $0.id == id }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove section \(index + 1)")
            }
            CreativeSlider(
                title: "Length", value: seconds,
                range: (durationRange.lowerBound / 1000)...(durationRange.upperBound / 1000), step: 1,
                format: { ElevenLabsAudioPlayerView.clock($0) }
            )
            CreativeTagField(title: "Styles", tags: section.positiveStyles, prompt: "What this section should have")
            CreativeTagField(title: "Avoid", tags: section.negativeStyles, prompt: "What it should not")
            VStack(alignment: .leading, spacing: 3) {
                Text("Lyrics (a line per line; empty for instrumental)").font(.callout)
                ElevenLabsTextArea(text: lyrics, prompt: nil, minHeight: 60)
            }
        }
        .padding(10)
        .background(.background, in: .rect(cornerRadius: 8))
    }
}

/// A song's waveform as bars (`waveform_visual`).
struct MusicWaveform: View {
    let samples: [Double]

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let peak = max(samples.map(abs).max() ?? 1, 0.0001)
            let width = size.width / CGFloat(samples.count)
            for (index, sample) in samples.enumerated() {
                let height = max(1, CGFloat(abs(sample) / peak) * size.height)
                let rect = CGRect(x: CGFloat(index) * width, y: (size.height - height) / 2,
                                  width: max(1, width * 0.7), height: height)
                context.fill(Path(rect), with: .color(.accentColor.opacity(0.7)))
            }
        }
        .frame(height: 48)
        .accessibilityLabel("Waveform")
    }
}

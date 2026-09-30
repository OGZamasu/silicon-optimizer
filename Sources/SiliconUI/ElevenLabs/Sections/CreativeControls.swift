import AppKit
import AVFoundation
import SiliconElevenLabs
import SwiftUI
import UniformTypeIdentifiers

// The pieces the creative screens are built from. Every value range, choice list and default
// a control shows is handed in by its screen, which reads it from the catalog (`CreativeSpec`).

// MARK: - Layout

/// A titled group of controls on a creative screen.
struct CreativeCard<Accessory: View, Content: View>: View {
    var title: String?
    var systemImage: String?
    let accessory: Accessory
    let content: Content

    init(
        _ title: String? = nil, systemImage: String? = nil,
        @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || !(accessory is EmptyView) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let title {
                        if let systemImage {
                            Label(title, systemImage: systemImage).font(.headline)
                        } else {
                            Text(title).font(.headline)
                        }
                    }
                    Spacer(minLength: 6)
                    accessory
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }
}

extension CreativeCard where Accessory == EmptyView {
    init(_ title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, systemImage: systemImage, accessory: { EmptyView() }, content: content)
    }
}

/// A row of tabs inside a screen (Music's Compose, Plan, Stems…).
struct CreativeTabs<Tab: Hashable & Identifiable>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let title: (Tab) -> String

    var body: some View {
        Picker("Show", selection: $selection) {
            ForEach(tabs) { tab in Text(title(tab)).tag(tab) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// Words, chips or tags laid out in rows that wrap.
struct CreativeFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Inputs

/// A labelled slider over the range the catalog gives, with the value, the spec's default
/// marked, and a way back to it.
struct CreativeSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var defaultValue: Double?
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    /// What the low and high ends mean ("More variable", "More stable").
    var low: String?
    var high: String?
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 4)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let defaultValue, abs(defaultValue - value) > (step ?? 0.0001) / 2 {
                    Button {
                        value = defaultValue
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Back to the default, \(format(defaultValue))")
                    .accessibilityLabel("Reset \(title) to \(format(defaultValue))")
                }
            }
            .font(.callout)
            // A stepped slider draws a tick per step; past a few dozen that is a dotted smear,
            // so fine steps are applied by rounding instead.
            if let step, (range.upperBound - range.lowerBound) / step <= 20 {
                Slider(value: $value, in: range, step: step)
                    .accessibilityLabel(title)
            } else {
                Slider(value: Binding(get: { value }, set: { value = Self.snapped($0, to: step, in: range) }), in: range)
                    .accessibilityLabel(title)
            }
            if low != nil || high != nil {
                HStack {
                    Text(low ?? "")
                    Spacer()
                    Text(high ?? "")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .help(help ?? "")
    }
}

extension CreativeSlider {
    /// `value` rounded to the nearest `step` from the range's start, kept inside the range.
    static func snapped(_ value: Double, to step: Double?, in range: ClosedRange<Double>) -> Double {
        guard let step, step > 0 else { return value }
        let snapped = range.lowerBound + ((value - range.lowerBound) / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

/// An on/off choice among several, as a chip that shows it is on in any window state.
struct CreativeChipToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                if isOn { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                Text(title)
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
            .background(isOn ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: .capsule)
            .overlay(Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.55) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A binding to whether `element` is in `set`.
func creativeMembership<Element: Hashable>(_ element: Element, in set: Binding<Set<Element>>) -> Binding<Bool> {
    Binding(
        get: { set.wrappedValue.contains(element) },
        set: { on in
            if on { set.wrappedValue.insert(element) } else { set.wrappedValue.remove(element) }
        }
    )
}

/// One of the values an argument's `enum` lists.
struct CreativeChoicePicker: View {
    let title: String
    @Binding var selection: String
    let choices: [String]
    var label: (String) -> String = { ElevenLabsFormField.humanized($0) }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(choices, id: \.self) { choice in
                Text(label(choice)).tag(choice)
            }
            if !selection.isEmpty, !choices.contains(selection) {
                Text(selection).tag(selection)
            }
        }
        .pickerStyle(.menu)
    }
}

/// A whole number that may be left out (a seed), checked against a range.
struct CreativeOptionalIntegerField: View {
    let title: String
    @Binding var value: Int?
    var range: ClosedRange<Double>?
    var prompt = "Random"

    @State private var text = ""

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, text: $text, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 160)
                    .onChange(of: text) { _, new in
                        let trimmed = new.trimmingCharacters(in: .whitespaces)
                        value = trimmed.isEmpty ? nil : Int(trimmed)
                    }
                if !text.isEmpty, value == nil {
                    Text("Not a whole number").font(.caption).foregroundStyle(.red)
                } else if let value, let range, !range.contains(Double(value)) {
                    Text("Between \(Int(range.lowerBound)) and \(Int(range.upperBound))")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onAppear { text = value.map(String.init) ?? "" }
    }
}

/// Tags typed one at a time (Return adds), shown as removable chips.
struct CreativeTagField: View {
    let title: String
    @Binding var tags: [String]
    var prompt = "Add and press Return"
    var maxItems: Int?

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                if let maxItems {
                    Text("\(tags.count) of \(maxItems)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if !tags.isEmpty {
                CreativeFlowLayout {
                    ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                        HStack(spacing: 3) {
                            Text(tag).lineLimit(1)
                            Button {
                                tags.remove(at: index)
                            } label: {
                                Image(systemName: "xmark").font(.caption2.weight(.bold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(tag)")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14), in: .capsule)
                    }
                }
            }
            TextField(title, text: $draft, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .disabled(maxItems.map { tags.count >= $0 } ?? false)
                .onSubmit(add)
        }
    }

    private func add() {
        let pieces = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for piece in pieces where !tags.contains(piece) {
            if let maxItems, tags.count >= maxItems { break }
            tags.append(piece)
        }
        draft = ""
    }
}

/// Picks a model from the account's list, limited to the ones that can do the job.
struct CreativeModelPicker: View {
    let title: String
    @Binding var selection: String
    let directory: CreativeModelsDirectory
    let include: (CreativeModel) -> Bool

    var body: some View {
        let models = directory.models.filter(include)
        LabeledContent(title) {
            HStack(spacing: 6) {
                Picker(title, selection: $selection) {
                    ForEach(models) { model in
                        Text(model.name).tag(model.id)
                    }
                    if !selection.isEmpty, !models.contains(where: { $0.id == selection }) {
                        Text(directory.model(id: selection)?.name ?? selection).tag(selection)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 280)
                if directory.loading { ProgressView().controlSize(.small) }
            }
        }
        .task { await directory.loadIfNeeded() }
    }
}

// MARK: - Files

/// A file to send: dropped on the box or chosen, with its size and length, and a player
/// when it is audio.
struct CreativeFileField: View {
    let title: String
    @Binding var url: URL?
    var types: [UTType] = [.audio, .movie]
    var prompt = "Drop an audio or video file here, or choose one."

    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout)
            if let url {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(CreativeMedia.summary(of: url))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button("Replace…") { choose() }.controlSize(.small)
                    Button {
                        self.url = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(url.lastPathComponent)")
                }
                if CreativeMedia.isAudio(url) {
                    ElevenLabsAudioPlayerView(url: url).id(url)
                }
            } else {
                Button(action: choose) {
                    VStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down").font(.title2)
                        Text(prompt).font(.callout).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 84)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(targeted ? Color.accentColor : .secondary.opacity(0.4),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first(where: \.isFileURL) else { return false }
            url = first
            return true
        } isTargeted: { targeted = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        url = chosen
    }
}

/// Several files to send, in order (videos for music, training audio for a fine-tune).
struct CreativeFilesField: View {
    let title: String
    @Binding var urls: [URL]
    var types: [UTType] = [.audio]
    var maxItems: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                if let maxItems {
                    Text("\(urls.count) of \(maxItems)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                HStack(spacing: 6) {
                    Text("\(index + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(CreativeMedia.summary(of: url)).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button {
                        urls.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(url.lastPathComponent)")
                }
                .font(.callout)
            }
            Button(urls.isEmpty ? "Choose files…" : "Add files…", action: choose)
                .controlSize(.small)
                .disabled(maxItems.map { urls.count >= $0 } ?? false)
        }
        .dropDestination(for: URL.self) { dropped, _ in
            add(dropped.filter(\.isFileURL))
            return true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ new: [URL]) {
        for url in new where !urls.contains(url) {
            if let maxItems, urls.count >= maxItems { break }
            urls.append(url)
        }
    }
}

/// What the creative screens say about a local file.
@MainActor
enum CreativeMedia {
    static func isAudio(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }

    static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }

    /// "4.2 MB · 1:03", or just the size when the length cannot be read quickly.
    static func summary(of url: URL) -> String {
        var pieces: [String] = []
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            pieces.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if isAudio(url), let seconds = duration(of: url) {
            pieces.append(ElevenLabsAudioPlayerView.clock(seconds))
        }
        return pieces.joined(separator: " · ")
    }

    /// How many channels an audio file has, from its header.
    static func channelCount(of url: URL) -> Int? {
        header(of: url)?.channels
    }

    /// The length of an audio file, from its header.
    static func duration(of url: URL) -> Double? {
        header(of: url)?.seconds
    }

    private struct Header {
        var seconds: Double?
        var channels: Int
    }

    /// Headers read so far, by file and its modification date: views ask on every draw.
    private static var headers: [URL: (modified: Date?, header: Header?)] = [:]

    private static func header(of url: URL) -> Header? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = headers[url], cached.modified == modified { return cached.header }
        let header = (try? AVAudioFile(forReading: url)).map { file -> Header in
            let rate = file.processingFormat.sampleRate
            return Header(seconds: rate > 0 ? Double(file.length) / rate : nil, channels: Int(file.fileFormat.channelCount))
        }
        if headers.count > 200 { headers.removeAll() }
        headers[url] = (modified, header)
        return header
    }
}

// MARK: - Output formats

/// Output format ids, in words: `mp3_44100_128` → "MP3 · 44.1 kHz · 128 kbps".
enum CreativeOutputFormat {
    static func title(_ id: String) -> String {
        if id == "auto" { return "Automatic" }
        let parts = id.split(separator: "_").map(String.init)
        guard let codec = parts.first else { return id }
        let name: String = switch codec {
        case "mp3": "MP3"
        case "pcm": "PCM"
        case "wav": "WAV"
        case "opus": "Opus"
        case "ulaw": "μ-law"
        case "alaw": "A-law"
        default: codec.uppercased()
        }
        var pieces = [name]
        if parts.count > 1, let rate = Double(parts[1]) {
            // 44100 → "44.1", 22050 → "22.05", 16000 → "16".
            var khz = String(format: "%.2f", rate / 1000)
            while khz.hasSuffix("0") { khz.removeLast() }
            if khz.hasSuffix(".") { khz.removeLast() }
            pieces.append(khz + " kHz")
        }
        if parts.count > 2, let bitrate = Int(parts[2]) {
            pieces.append("\(bitrate) kbps")
        }
        return pieces.joined(separator: " · ")
    }

    /// Whether a stream in this format plays as it arrives: the shell's stream player decodes
    /// MP3 and raw PCM live; other formats are only kept. "auto" is not a format the player
    /// can read — a screen whose default it is leaves it unsent (it means MP3).
    static func playsLive(_ id: String) -> Bool {
        id.hasPrefix("mp3_") || id.hasPrefix("pcm_")
    }
}

/// The output format picker: the operation's own formats, in words.
struct CreativeOutputFormatPicker: View {
    @Binding var selection: String
    let choices: [String]

    var body: some View {
        CreativeChoicePicker(title: "Format", selection: $selection, choices: choices, label: CreativeOutputFormat.title)
    }
}

// MARK: - Timed text

/// A player for a file with timed words under it: the word being heard is marked, and a
/// line's time jumps there. Headerless audio plays at the rate the run asked for.
struct CreativeTimedPlayer: View {
    let url: URL
    let words: [CreativeTimedWord]
    var title: String?
    var showsSpeakers = true

    @State private var player: ElevenLabsAudioPlayer

    init(url: URL, words: [CreativeTimedWord], title: String? = nil, showsSpeakers: Bool = true,
         contentType: String = "audio/mpeg", outputFormat: String? = nil) {
        self.url = url
        self.words = words
        self.title = title
        self.showsSpeakers = showsSpeakers
        _player = State(initialValue: ElevenLabsAudioPlayer(
            url: url, raw: Self.rawFormat(url: url, contentType: contentType, outputFormat: outputFormat)
        ))
    }

    /// How to read `url` when it has no header; nil when it has one.
    static func rawFormat(url: URL, contentType: String, outputFormat: String?) -> ElevenLabsRawAudio.Format? {
        guard let encoding = ElevenLabsRawAudio.encoding(url: url, contentType: contentType) else { return nil }
        return ElevenLabsRawAudio.Format(
            encoding: encoding,
            sampleRate: ElevenLabsRawAudio.sampleRate(outputFormat: outputFormat) ?? encoding.fallbackRate
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CreativePlayerBar(player: player, title: title)
            CreativeTranscriptView(
                segments: CreativeTimeline.segments(words),
                currentTime: player.isPlaying || player.currentTime > 0 ? player.currentTime : nil,
                showsSpeakers: showsSpeakers,
                onSeek: { time in
                    player.seek(to: time)
                    if !player.isPlaying { player.play() }
                }
            )
        }
        .onAppear { player.prepare() }
        .onDisappear { player.stop() }
    }
}

/// Play/pause, a scrubber and the times, over a player the caller holds.
struct CreativePlayerBar: View {
    let player: ElevenLabsAudioPlayer
    var title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
            }
            HStack(spacing: 10) {
                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .disabled(player.problem != nil)
                Slider(
                    value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                    in: 0...max(player.duration, 0.01)
                )
                .disabled(player.duration <= 0)
                Text("\(ElevenLabsAudioPlayerView.clock(player.currentTime)) / \(ElevenLabsAudioPlayerView.clock(player.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                ElevenLabsFileActions(url: player.url)
            }
            if let problem = player.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

/// Segments as lines: time (a button that jumps there), speaker, text — with the word at
/// `currentTime` marked.
struct CreativeTranscriptView: View {
    let segments: [CreativeSegment]
    var currentTime: Double?
    var showsSpeakers = true
    var onSeek: ((Double) -> Void)?

    /// Lines drawn at most; the rest is in the exports.
    static let lineLimit = 1500

    var body: some View {
        let speakers = orderedSpeakers
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(segments.prefix(Self.lineLimit)) { segment in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button(CreativeTimeline.clock(segment.start)) { onSeek?(segment.start) }
                        .buttonStyle(.link)
                        .font(.caption.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                        .disabled(onSeek == nil)
                        .help("Play from here")
                    VStack(alignment: .leading, spacing: 2) {
                        if showsSpeakers, speakers.count > 1 || (segment.speaker != nil && speakers.count == 1 && segment.speaker != "speaker_0") {
                            Text(CreativeTimeline.speakerName(segment.speaker))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Self.color(for: segment.speaker, in: speakers))
                        }
                        Text(attributed(segment))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if segments.count > Self.lineLimit {
                Text("… \(segments.count - Self.lineLimit) more lines — export to see all of them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var orderedSpeakers: [String] {
        var seen = Set<String>()
        return segments.compactMap(\.speaker).filter { seen.insert($0).inserted }
    }

    private func attributed(_ segment: CreativeSegment) -> AttributedString {
        let playing = currentTime.flatMap { time -> Int? in
            guard time >= segment.start, time <= segment.end + 0.05 else { return nil }
            return CreativeTimeline.wordIndex(at: time, in: segment.words)
        }
        var text = AttributedString()
        var previous: String?
        for (index, word) in segment.words.enumerated() {
            if previous != nil, let first = word.text.first, !",.;:!?…)”’".contains(first) {
                text += AttributedString(" ")
            }
            var piece = AttributedString(word.text)
            if word.isEvent {
                piece.foregroundColor = .secondary
            }
            if index == playing {
                piece.backgroundColor = Color.accentColor.opacity(0.28)
            }
            text += piece
            previous = word.text
        }
        return text
    }

    static func color(for speaker: String?, in speakers: [String]) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]
        guard let speaker, let index = speakers.firstIndex(of: speaker) else { return .secondary }
        return palette[index % palette.count]
    }
}

// MARK: - Takes

/// A take's audio: a player — for raw PCM, μ-law or A-law, which has no header, the shell's
/// raw player at the rate the run asked for.
struct CreativeAudioResult: View {
    let url: URL
    let contentType: String
    var bytes: Int = 0
    var title: String?
    var outputFormat: String?

    /// - Parameter showsTitle: Off where the take's title is already drawn above it.
    init(take: CreativeTake, title: String? = nil, showsTitle: Bool = true) {
        url = take.file
        contentType = take.contentType
        bytes = take.bytes
        self.title = showsTitle ? (title ?? take.title) : nil
        outputFormat = take.outputFormat
    }

    init(url: URL, contentType: String, bytes: Int = 0, title: String? = nil, outputFormat: String? = nil) {
        self.url = url
        self.contentType = contentType
        self.bytes = bytes
        self.title = title
        self.outputFormat = outputFormat
    }

    var isRaw: Bool { ElevenLabsFileResult.isRawAudio(url: url, contentType: contentType.lowercased()) }

    var body: some View {
        if isRaw {
            VStack(alignment: .leading, spacing: 4) {
                if let title { Text(title).font(.callout.weight(.medium)).lineLimit(1) }
                ElevenLabsFileResult(url: url, contentType: contentType, bytes: bytes, outputFormat: outputFormat)
            }
        } else {
            ElevenLabsAudioPlayerView(url: url, title: title).id(url)
        }
    }
}

/// A result a screen made this session, kept so earlier takes stay one click away.
struct CreativeTake: Identifiable, Hashable, Sendable {
    let id = UUID()
    var title: String
    var date: Date
    var file: URL
    var contentType: String
    var bytes: Int
    var requestID: String?
    var characterCost: Int?
    /// The `output_format` the run asked for: headerless audio's sample rate comes from it.
    var outputFormat: String?

    /// Nil when the answer wrote no file.
    init?(result: ElevenLabsResult, title: String, outputFormat: String? = nil, date: Date = Date()) {
        guard let file = CreativeResults.audioFile(in: result) else { return nil }
        self.title = title
        self.date = date
        self.file = file.url
        contentType = file.contentType
        bytes = file.bytes
        requestID = CreativeResults.requestID(of: result)
        characterCost = result.meta.characterCost
        self.outputFormat = outputFormat
    }

    /// For a run's answer: the take, with the format the runner asked for.
    @MainActor
    init?(result: ElevenLabsResult, title: String, runner: ElevenLabsRunner) {
        self.init(result: result, title: title, outputFormat: runner.arguments["output_format"]?.stringValue)
    }
}

/// Earlier takes, newest first, each with a player.
struct CreativeTakesList: View {
    let takes: [CreativeTake]
    var onRemove: ((CreativeTake) -> Void)?

    var body: some View {
        if !takes.isEmpty {
            CreativeCard("Earlier takes", systemImage: "square.stack") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(takes) { take in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(take.title).font(.callout.weight(.medium)).lineLimit(1)
                                Spacer(minLength: 4)
                                if let cost = take.characterCost {
                                    Label("\(cost.formatted())", systemImage: "creditcard")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .help("Characters this take used")
                                }
                                Text(take.date, style: .time).font(.caption).foregroundStyle(.secondary)
                                if let onRemove {
                                    Button {
                                        onRemove(take)
                                    } label: {
                                        Image(systemName: "xmark")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove from this list (the file stays in the output folder)")
                                    .accessibilityLabel("Remove \(take.title) from the list")
                                }
                            }
                            CreativeAudioResult(take: take, showsTitle: false)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Saving text

/// Asks where, then writes an export (subtitles, a transcript) there.
@MainActor
enum CreativeExport {
    static func save(_ text: String, suggestedName: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static let srtType = UTType(filenameExtension: "srt") ?? .plainText
    static let vttType = UTType(filenameExtension: "vtt") ?? .plainText
}

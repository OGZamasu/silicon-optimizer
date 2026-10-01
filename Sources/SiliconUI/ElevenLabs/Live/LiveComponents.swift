import AppKit
import SiliconElevenLabs
import SwiftUI

/// A titled group on a live screen.
struct LiveCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.18)))
    }
}

/// The microphone's state, always visible while it is on: red and named.
struct LiveMicrophoneIndicator: View {
    let on: Bool
    let muted: Bool

    /// Muting sends silence, and ElevenLabs bills silence like speech: transcription by the
    /// audio's length, a conversation by the minute.
    static func label(muted: Bool) -> String {
        muted ? "Microphone on, muted — silence is sent, and still billed" : "Microphone on"
    }

    static let muteHelp = "Sends silence instead of your voice; nothing you say leaves the Mac. The session stays "
        + "open and the muted time is still billed (transcription by the audio's length, agents by the minute) — "
        + "Stop or End to stop the bill."

    var body: some View {
        if on {
            HStack(spacing: 6) {
                Circle()
                    .fill(muted ? Color.orange : Color.red)
                    .frame(width: 9, height: 9)
                Text(Self.label(muted: muted))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(muted ? .orange : .red)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill((muted ? Color.orange : Color.red).opacity(0.12)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(muted ? "Microphone on and muted" : "Microphone on")
        }
    }
}

/// A bar for the loudness of what is being sent.
struct LiveLevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(level > 0.85 ? Color.orange : Color.green)
                    .frame(width: geometry.size.width * CGFloat(max(0, min(1, level))))
            }
        }
        .frame(width: 120, height: 6)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

/// What a session has used, measured here: what the owner is billed by.
struct LiveUsageLine: View {
    let usage: ElevenLabsRealtimeUsage?
    var now = Date()
    /// What ElevenLabs bills this kind of session by, in a sentence.
    let billedBy: String
    var showsCharacters = false
    var showsAudioSent = false
    var showsMessages = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let usage {
                HStack(spacing: 14) {
                    Label(LiveClock.text(usage.duration(now: now)), systemImage: "timer")
                    if showsCharacters { Label("\(usage.charactersSent.formatted()) characters sent", systemImage: "character.cursor.ibeam") }
                    if showsAudioSent { Label("\(LiveClock.amount(usage.audioSecondsSent)) of audio sent", systemImage: "arrow.up.circle") }
                    if usage.audioSecondsReceived > 0 {
                        Label("\(LiveClock.amount(usage.audioSecondsReceived)) of audio received", systemImage: "arrow.down.circle")
                    }
                    if showsMessages, usage.messagesSent > 0 { Label("\(usage.messagesSent) typed", systemImage: "keyboard") }
                }
                .font(.callout.monospacedDigit())
            }
            Text(billedBy)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// How the last session ended. A warning when its billing is not known.
struct LiveOutcomeBanner: View {
    let outcome: LiveOutcome

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: outcome.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(outcome.isWarning ? .orange : .green)
            Text(outcome.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill((outcome.isWarning ? Color.orange : Color.green).opacity(0.08)))
    }
}

/// A file a live screen saved: its name, and Reveal.
struct LiveSavedFile: View {
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link)
        }
    }
}

/// A phase as a word and a dot.
struct LivePhaseLabel: View {
    let text: String
    let live: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(live ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(text).font(.callout.weight(.medium))
        }
    }
}

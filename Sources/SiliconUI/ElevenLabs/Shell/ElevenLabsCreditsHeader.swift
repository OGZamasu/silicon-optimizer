import SiliconElevenLabs
import SwiftUI

/// The pane's header: plan, credits left and when they reset, region, and Disconnect.
///
/// The balance is whatever the last free account check said; the refresh button checks
/// again. Nothing here spends credits.
struct ElevenLabsCreditsHeader: View {
    @Environment(AppModel.self) private var model
    /// Shows a Disconnect link when given.
    var onDisconnect: (() -> Void)?

    @State private var refreshing = false

    init(onDisconnect: (() -> Void)? = nil) {
        self.onDisconnect = onDisconnect
    }

    var body: some View {
        let account = model.elevenLabsAccount
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                identity(account)
                Spacer(minLength: 12)
                balance(account)
                actions
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    identity(account)
                    Spacer(minLength: 8)
                    actions
                }
                balance(account)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func identity(_ account: ElevenLabsAccount?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ElevenLabs")
                .font(.headline)
            Text([account.map { Self.planName($0.tier) }, model.elevenLabsRegion.displayName]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func balance(_ account: ElevenLabsAccount?) -> some View {
        if let account {
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(account.remainingCharacters.formatted()) of \(account.characterLimit.formatted()) credits left")
                    .font(.callout.monospacedDigit())
                ProgressView(value: Self.usedFraction(account))
                    .progressViewStyle(.linear)
                    .tint(Palette.pressure(Self.usedFraction(account)))
                    .frame(width: 180)
                if let reset = account.nextResetAt {
                    Text("Resets \(reset.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("Balance not checked yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                refreshing = true
                Task {
                    await model.refreshElevenLabsBalance()
                    refreshing = false
                }
            } label: {
                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Check the balance again (free)")
            .accessibilityLabel("Refresh balance")
            .disabled(refreshing)
            if let onDisconnect {
                Button("Disconnect", action: onDisconnect)
                    .buttonStyle(.link)
            }
        }
    }

    static func usedFraction(_ account: ElevenLabsAccount) -> Double {
        guard account.characterLimit > 0 else { return 0 }
        return min(1, max(0, Double(account.characterCount) / Double(account.characterLimit)))
    }

    static func planName(_ tier: String) -> String {
        let cleaned = tier.replacingOccurrences(of: "_", with: " ")
        return (cleaned.first.map { $0.uppercased() + cleaned.dropFirst() } ?? tier) + " plan"
    }
}

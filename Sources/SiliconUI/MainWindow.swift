import SiliconCore
import SwiftUI

/// The main window: a standard macOS sidebar layout hosting the four sections.
public struct MainWindow: View {
    public static let identifier = "main"

    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $model.chatColumnVisibility) {
            List(selection: $model.selectedTab) {
                ForEach(AppModel.Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    TransfersFooter()
                    machineFooter
                }
            }
        } detail: {
            switch model.selectedTab {
            case .dashboard: DashboardView()
            case .models: ModelBrowserView()
            case .chat: ChatView()
            case .images: ImageView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 940, minHeight: 620)
        .onChange(of: model.selectedTab) {
            // The expanded chat borrows the whole window; leaving the tab gives it back.
            if model.selectedTab != .chat {
                model.chatColumnVisibility = .all
            }
        }
        .alert(item: $model.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    /// Always-visible reminder of what the machine is, since every recommendation depends on it.
    private var machineFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(model.profile.totalMemory.formatted)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                Spacer()
                Text("\(Int(model.metrics.memoryUsedFraction * 100))% used")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Palette.pressure(model.metrics.memoryUsedFraction))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .padding(.top, 4)
        }
    }
}

/// Downloads in flight, pinned above the machine footer.
///
/// It sits in the sidebar because that is the only place on screen that does not change when you
/// switch tabs. Downloading a model and then going to look at something else used to mean the
/// transfer vanished from view entirely; a model fetched from a Hugging Face search had nowhere
/// to appear in the first place.
///
/// Takes no space at all when nothing is transferring — a permanently reserved empty strip is a
/// worse trade in a 170pt sidebar than a footer that grows.
struct TransfersFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let transfers = model.activeTransfers
        if !transfers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                header(count: transfers.count)
                ForEach(transfers) { transfer in
                    row(transfer)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .transition(.opacity)
            .animation(.default, value: transfers.count)
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.down.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(count == 1 ? "Downloading" : "\(count) downloading")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            // The aggregate rate, because with two transfers running neither row's figure is
            // the answer to "is my connection busy".
            if model.transferBytesPerSecond > 0 {
                Text("\(Bytes(Int64(model.transferBytesPerSecond)).formatted)/s")
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(_ transfer: AppModel.ActiveTransfer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(transfer.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                Button {
                    model.cancelTransfer(transfer)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Cancel this download")
            }

            if let error = transfer.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let progress = transfer.progress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                HStack(spacing: 3) {
                    Text("\(Int(progress.fraction * 100))%")
                    Text("of \(progress.bytesExpected.formatted)")
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 2)
                    if let remaining = progress.estimatedTimeRemaining, remaining > 1 {
                        Text(remaining.durationLabel)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            } else {
                // Resolving which files to fetch takes a round trip to Hugging Face, and a row
                // that appears with an empty bar reads as a stalled download rather than a
                // starting one.
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Starting…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

extension AppModel.AlertContent: Equatable {
    public static func == (lhs: AppModel.AlertContent, rhs: AppModel.AlertContent) -> Bool {
        lhs.id == rhs.id
    }
}

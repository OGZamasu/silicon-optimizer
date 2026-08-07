import SwiftUI

/// The main window: a standard macOS sidebar layout hosting the four sections.
public struct MainWindow: View {
    public static let identifier = "main"

    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(selection: $model.selectedTab) {
                ForEach(AppModel.Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                machineFooter
            }
        } detail: {
            switch model.selectedTab {
            case .dashboard: DashboardView()
            case .models: ModelBrowserView()
            case .chat: ChatView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 940, minHeight: 620)
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

extension AppModel.AlertContent: Equatable {
    public static func == (lhs: AppModel.AlertContent, rhs: AppModel.AlertContent) -> Bool {
        lhs.id == rhs.id
    }
}

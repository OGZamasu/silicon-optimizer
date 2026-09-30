import Charts
import SiliconElevenLabs
import SwiftUI

/// Usage: the plan and what is left of it, usage over time, and the API requests made.
struct UsageSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        UsageScreen(model: VoicesStudioModels.model(UsageSectionModel.self, for: app) {
            UsageSectionModel(environment: $0)
        })
    }
}

struct UsageScreen: View {
    @Bindable var model: UsageSectionModel

    var body: some View {
        ElevenLabsSectionPage(.usage) {
            Button {
                Task { await model.refreshAll() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } content: {
            UsagePlanCard(model: model)
            UsageChartCard(model: model)
            UsageRequestsCard(model: model)
            VoicesStudioActivity(actions: model.actions, fallback: model.actions.runner("get_user_subscription_info"))
        }
        .task { if model.account == nil { await model.refreshAll() } }
    }
}

struct UsagePlanCard: View {
    let model: UsageSectionModel

    var body: some View {
        Card(title: "Plan", systemImage: "gauge.with.needle") {
            VoicesStudioListState(loading: model.actions.isRunning("get_user_subscription_info"),
                                  problem: model.actions.problem("get_user_subscription_info"),
                                  isEmpty: model.account == nil, emptyText: "")
            if let account = model.account {
                HStack(alignment: .top, spacing: 16) {
                    Readout(label: "Plan", value: VoicesStudioFormat.words(account.tier),
                            caption: account.status.map(VoicesStudioFormat.words))
                    Readout(label: "Credits left", value: account.remaining.formatted(),
                            caption: "of \(account.limit.formatted())", tint: Palette.pressure(account.fraction))
                    Readout(label: "Resets", value: VoicesStudioFormat.date(unixSeconds: account.resetsAt) ?? "—",
                            caption: account.billingPeriod.map(VoicesStudioFormat.words))
                }
                ProgressView(value: account.fraction)
                    .tint(Palette.pressure(account.fraction))
                HStack(spacing: 16) {
                    if let slots = account.voiceSlots {
                        VoicesStudioFact("Voice slots", "\(slots.used) of \(slots.limit)")
                    }
                    if let slots = account.professionalSlots {
                        VoicesStudioFact("Professional voices", "\(slots.used) of \(slots.limit)")
                    }
                }
                VoicesStudioFact("Seat", account.seatType.map(VoicesStudioFormat.words))
                VoicesStudioFact("Overage so far", account.overage)
                if let cents = account.nextInvoiceCents {
                    VoicesStudioFact("Next invoice", (Double(cents) / 100).formatted(.currency(code: (account.currency ?? "usd").uppercased()))
                                     + (VoicesStudioFormat.date(unixSeconds: account.nextPaymentAt).map { " on \($0)" } ?? ""))
                }
                if account.openInvoices > 0 {
                    Label("\(account.openInvoices) unpaid invoice\(account.openInvoices == 1 ? "" : "s")",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
                VoicesStudioFact("Plan change", account.pendingChange)
            }
        }
    }
}

struct UsageChartCard: View {
    @Bindable var model: UsageSectionModel

    var body: some View {
        Card(title: "Usage over time", systemImage: "chart.bar.xaxis") {
            HStack(spacing: 8) {
                Picker("Span", selection: $model.span) {
                    ForEach(UsageSectionModel.Span.allCases) { Text($0.title).tag($0) }
                }
                Picker("Buckets", selection: $model.bucket) {
                    ForEach(UsageSectionModel.Bucket.allCases) { Text($0.title).tag($0) }
                }
                Picker("By", selection: $model.groupBy) {
                    Text("Everything together").tag("")
                    ForEach(model.groupings, id: \.self) { Text("By \(VoicesStudioFormat.words($0).lowercased())").tag($0) }
                }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: model.span) { Task { await model.refreshUsage(); await model.refreshRequests() } }
            .onChange(of: model.bucket) { Task { await model.refreshUsage() } }
            .onChange(of: model.groupBy) { Task { await model.refreshUsage() } }
            VoicesStudioListState(loading: model.actions.isRunning("usage_by_product_over_time"),
                                  problem: model.actions.problem("usage_by_product_over_time"),
                                  isEmpty: model.usage?.rows.isEmpty ?? true, emptyText: "No usage in this span.")
            if let usage = model.usage, !usage.points.isEmpty {
                Text("\(usage.valueName): \(usage.total.formatted(.number.precision(.fractionLength(0...2)))) in all")
                    .font(.caption).foregroundStyle(.secondary)
                Chart(usage.points) { point in
                    BarMark(
                        x: .value("Time", point.time, unit: model.bucket == .hour ? .hour : model.bucket == .day ? .day : .weekOfYear),
                        y: .value(usage.valueName, point.value)
                    )
                    .foregroundStyle(by: .value("Group", point.group ?? "All"))
                }
                .frame(height: 220)
            } else if let usage = model.usage, !usage.rows.isEmpty {
                UsageTableView(table: usage)
            }
        }
    }
}

struct UsageRequestsCard: View {
    @Bindable var model: UsageSectionModel

    var body: some View {
        Card(title: "API requests", systemImage: "list.bullet.rectangle") {
            HStack(spacing: 8) {
                TextField("Search requests", text: $model.requestSearch)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.refreshRequests() } }
                Picker("Order", selection: $model.requestSort) {
                    ForEach(model.sorts, id: \.self) { Text($0 == "desc" ? "Newest first" : "Oldest first").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: model.requestSort) { Task { await model.refreshRequests() } }
            }
            VoicesStudioListState(loading: model.actions.isRunning("requests_list"),
                                  problem: model.actions.problem("requests_list"),
                                  isEmpty: model.requests?.rows.isEmpty ?? true, emptyText: "No requests in this span.")
            if let requests = model.requests, !requests.rows.isEmpty {
                UsageTableView(table: requests)
            }
        }
    }
}

/// An analytics answer as a scrolling table, the columns as the answer names them.
struct UsageTableView: View {
    let table: UsageTable
    static let rowLimit = 200

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                        Text(VoicesStudioFormat.words(column)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Divider()
                ForEach(Array(table.rows.prefix(Self.rowLimit).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                            Text(UsageTable.cell(value)).font(.caption.monospacedDigit()).lineLimit(1).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        if table.rows.count > Self.rowLimit {
            Text("The first \(Self.rowLimit) of \(table.rows.count) rows.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

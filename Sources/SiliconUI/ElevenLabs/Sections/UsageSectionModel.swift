import Foundation
import Observation
import SiliconElevenLabs

// MARK: - Data

/// The plan and balance, from `GET /v1/user/subscription` and `GET /v1/user`.
struct UsageAccount: Sendable {
    var tier: String
    var status: String?
    var used: Int
    var limit: Int
    var resetsAt: Int?
    var billingPeriod: String?
    var voiceSlots: (used: Int, limit: Int)?
    var professionalSlots: (used: Int, limit: Int)?
    var canExtend: Bool?
    var currency: String?
    var overage: String?
    var nextInvoiceCents: Int?
    var nextPaymentAt: Int?
    var openInvoices: Int
    var pendingChange: String?
    var firstName: String?
    var seatType: String?

    init(subscription: JSONValue, user: JSONValue?) {
        tier = subscription["tier"].stringValue ?? "?"
        status = subscription["status"].stringValue
        used = subscription["character_count"].intValue ?? 0
        limit = subscription["character_limit"].intValue ?? 0
        resetsAt = subscription["next_character_count_reset_unix"].intValue
        billingPeriod = subscription["billing_period"].stringValue
        if let slots = subscription["voice_slots_used"].intValue, let max = subscription["voice_limit"].intValue {
            voiceSlots = (slots, max)
        }
        if let slots = subscription["professional_voice_slots_used"].intValue,
           let max = subscription["professional_voice_limit"].intValue {
            professionalSlots = (slots, max)
        }
        canExtend = subscription["can_extend_character_limit"].boolValue
        currency = subscription["currency"].stringValue
        let amount = subscription["current_overage"]["amount"].stringValue
        overage = amount.flatMap { $0 == "0" || $0 == "0.00" ? nil : "\($0) \(subscription["current_overage"]["currency"].stringValue?.uppercased() ?? "")" }
        nextInvoiceCents = subscription["next_invoice"]["amount_due_cents"].intValue
        nextPaymentAt = subscription["next_invoice"]["next_payment_attempt_unix"].intValue
        openInvoices = subscription["open_invoices"].arrayValue?.count ?? 0
        let change = subscription["pending_change"]
        pendingChange = change["kind"].stringValue.map { kind in
            [VoicesStudioFormat.words(kind), change["next_tier"].stringValue].compactMap { $0 }.joined(separator: " to ")
        }
        firstName = user?["first_name"].stringValue
        seatType = user?["seat_type"].stringValue
    }

    var remaining: Int { max(0, limit - used) }
    var fraction: Double { limit > 0 ? min(1, Double(used) / Double(limit)) : 0 }
}

/// A table the analytics routes answer with: columns, their types and units, and rows.
struct UsageTable: Hashable, Sendable {
    var columns: [String]
    var types: [String]
    var units: [String]
    var rows: [[JSONValue]]

    init(json: JSONValue) {
        columns = json["columns"].arrayValue?.compactMap(\.stringValue) ?? []
        types = json["column_types"].arrayValue?.compactMap(\.stringValue) ?? []
        units = json["column_units"].arrayValue?.compactMap(\.stringValue) ?? []
        rows = (json["rows"].arrayValue ?? []).map { $0.arrayValue ?? [] }
    }

    /// One bar of the chart: a time bucket, a group (or nil), a value.
    struct Point: Identifiable, Hashable, Sendable {
        var time: Date
        var group: String?
        var value: Double
        var id: String { "\(time.timeIntervalSince1970)/\(group ?? "")" }
    }

    var timeColumn: Int? { types.firstIndex(of: "DateTime") }
    /// The measured column: the last numeric one.
    var valueColumn: Int? { types.lastIndex { $0 == "Float" || $0 == "Int" } }
    /// A text column to split bars by (what the query grouped by).
    var groupColumn: Int? { types.firstIndex { $0 == "String" } }

    var valueName: String {
        guard let column = valueColumn else { return "" }
        let unit = units.indices.contains(column) ? units[column] : ""
        let name = VoicesStudioFormat.words(columns[column])
        return unit.isEmpty || unit == columns[column] ? name : "\(name) (\(unit))"
    }

    var points: [Point] {
        guard let timeColumn, let valueColumn else { return [] }
        return rows.compactMap { row in
            guard row.indices.contains(timeColumn), row.indices.contains(valueColumn),
                  let time = Self.date(row[timeColumn]), let value = row[valueColumn].doubleValue else { return nil }
            let group = groupColumn.flatMap { row.indices.contains($0) ? row[$0].stringValue : nil }
            return Point(time: time, group: group, value: value)
        }
    }

    var total: Double { points.reduce(0) { $0 + $1.value } }

    static func date(_ value: JSONValue) -> Date? {
        if let number = value.doubleValue { return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number) }
        guard let text = value.stringValue else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            plain.dateFormat = format
            if let date = plain.date(from: text) { return date }
        }
        return nil
    }

    static func cell(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .null: "—"
        case .number: value.jsonString()
        case .bool(let flag): flag ? "yes" : "no"
        case .array, .object: value.jsonString()
        }
    }
}

// MARK: - Model

/// Usage: the plan, balance, voice slots and invoices at a glance; usage over time by product,
/// model, voice or member; and the list of API requests.
@MainActor
@Observable
final class UsageSectionModel {

    enum Span: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90
        var id: Int { rawValue }
        var title: String { "Last \(rawValue) days" }
    }

    enum Bucket: Int, CaseIterable, Identifiable {
        case hour = 3600, day = 86400, week = 604800
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .hour: "Hourly"
            case .day: "Daily"
            case .week: "Weekly"
            }
        }
    }

    let actions: VoicesStudioActions
    private(set) var account: UsageAccount?
    var span: Span = .month
    var bucket: Bucket = .day
    var groupBy = "product_type"
    private(set) var usage: UsageTable?
    var requestSearch = ""
    var requestSort = "desc"
    private(set) var requests: UsageTable?
    /// "Now", fixed by tests so ranges are reproducible.
    @ObservationIgnored var now: () -> Date = Date.init

    init(environment: VoicesStudioEnvironment) {
        actions = VoicesStudioActions(context: environment.context)
    }

    // MARK: Spec

    static let controls: [VoicesStudioControl] = [
        .init("usage_by_product_over_time", "start_time"),
        .init("usage_by_product_over_time", "end_time"),
        .init("usage_by_product_over_time", "interval_seconds",
              describedValues: Bucket.allCases.map { String($0.rawValue) }),
        .init("usage_by_product_over_time", "group_by", enumerated: true),
        .init("usage_by_product_over_time", "time_zone"),
        .init("requests_list", "start_time"),
        .init("requests_list", "end_time"),
        .init("requests_list", "limit"),
        .init("requests_list", "search"),
        .init("requests_list", "sort", enumerated: true),
    ]

    static let callsWithoutControls: Set<String> = ["get_user_info", "get_user_subscription_info"]
    static let explorerOnly: [String: String] = [
        "usage_characters": "Deprecated in the spec; the section charts usage with POST /v1/workspace/analytics/query/usage-by-product-over-time, which replaces it.",
    ]

    var groupings: [String] { VoicesStudioSchema.choices("usage_by_product_over_time", "group_by") }
    var sorts: [String] { VoicesStudioSchema.choices("requests_list", "sort") }

    // MARK: Account

    func refreshAccount() async {
        guard let subscription = await actions.perform("get_user_subscription_info", quietly: true)?.voicesStudioJSON
        else { return }
        let user = await actions.perform("get_user_info", quietly: true)?.voicesStudioJSON
        account = UsageAccount(subscription: subscription, user: user)
    }

    // MARK: Usage

    /// Milliseconds since 1970, the unit both analytics routes take.
    func range() -> (start: Int, end: Int) {
        let end = now()
        let start = end.addingTimeInterval(-Double(span.rawValue) * 86_400)
        return (Int(start.timeIntervalSince1970 * 1000), Int(end.timeIntervalSince1970 * 1000))
    }

    func usageArguments() -> [String: JSONValue] {
        let (start, end) = range()
        var arguments: [String: JSONValue] = [
            "start_time": .number(Double(start)), "end_time": .number(Double(end)),
            "interval_seconds": .number(Double(bucket.rawValue)), "time_zone": .string(TimeZone.current.identifier),
        ]
        if !groupBy.isEmpty { arguments["group_by"] = [.string(groupBy)] }
        return arguments
    }

    func refreshUsage() async {
        guard let json = await actions.perform("usage_by_product_over_time", usageArguments(), quietly: true)?
            .voicesStudioJSON else { return }
        usage = UsageTable(json: json)
    }

    func requestArguments() -> [String: JSONValue] {
        let (start, end) = range()
        var arguments: [String: JSONValue] = [
            "start_time": .number(Double(start)), "end_time": .number(Double(end)), "limit": 100,
            "sort": .string(requestSort),
        ]
        arguments.voicesStudioSet("search", VoicesStudioFormat.text(requestSearch))
        return arguments
    }

    func refreshRequests() async {
        guard let json = await actions.perform("requests_list", requestArguments(), quietly: true)?.voicesStudioJSON
        else { return }
        requests = UsageTable(json: json)
    }

    func refreshAll() async {
        await refreshAccount()
        await refreshUsage()
        await refreshRequests()
    }

    // MARK: Test support

    func load(account: UsageAccount?, usage: UsageTable?, requests: UsageTable?) {
        self.account = account
        self.usage = usage
        self.requests = requests
    }
}

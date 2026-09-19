import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime

// MARK: - Fixtures

extension ControlAPI.JevStatus {
    /// A status for the control-route doubles. No key, nothing spent — the shape is what
    /// those tests are about, not the numbers.
    static func fixture(enabled: Bool = false) -> ControlAPI.JevStatus {
        ControlAPI.JevStatus(
            enabled: enabled, model: JevService.pinnedModel,
            availableModels: JevService.allowedModels, keySet: false,
            monthlyBudgetUSD: nil, budgetRemainingUSD: nil, cacheMinutes: 10,
            maxStateBytes: JevService.defaultMaxStateBytes,
            features: JevFeature.allCases.map {
                .init(
                    id: $0.rawValue, displayName: $0.displayName, summary: $0.summary,
                    enabled: $0 == .decideTool, available: false, built: $0.isBuilt,
                    calls: 0, inputTokens: 0, estimatedUSD: 0
                )
            },
            month: JevLedger.monthKey(), calls: 0, inputTokens: 0, estimatedUSD: 0,
            models: [:]
        )
    }
}

/// A private settings/ledger pair and a `JevService` pointed at it. Each test gets its own
/// directory, so they can run in parallel without an environment variable between them.
struct JevHarness {
    let directory: URL
    let service = JevService()

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// One level down, so the permissions test is checking a directory `save` created
    /// rather than one the harness made itself.
    var fileDirectory: URL { directory.appendingPathComponent("store", isDirectory: true) }
    var configURL: URL { fileDirectory.appendingPathComponent("jev.json") }
    var ledgerURL: URL { fileDirectory.appendingPathComponent("jev-ledger.json") }

    func clean() { try? FileManager.default.removeItem(at: directory) }

    /// Wires the service to a key, a server and a recording sleeper.
    func configure(
        key: String? = "sk-fixture", baseURL: URL = URL(string: "http://127.0.0.1:1")!,
        session: URLSession? = nil, sleeps: Sleeps? = nil
    ) async {
        var sleeper: (@Sendable (TimeInterval) async -> Void)?
        if let sleeps {
            sleeper = { seconds in await sleeps.record(seconds) }
        }
        await service.configure(
            keyProvider: { key },
            baseURL: baseURL,
            keyIsSet: { key != nil },
            session: session,
            sleep: sleeper,
            configURL: configURL
        )
    }

    /// The common starting point: Jev on, the decide tool on.
    func enable() async throws {
        try await service.update { settings in
            settings.enabled = true
            settings.features[.decideTool] = true
        }
    }
}

/// Records what the backoff asked to wait, and returns at once — so a retry test costs
/// microseconds and still asserts the real delays.
actor Sleeps {
    private(set) var seconds: [TimeInterval] = []
    func record(_ value: TimeInterval) { seconds.append(value) }
}

/// A loopback server that fails the test if anything reaches it. Every "refuses before the
/// network" case points at one of these.
func untouchedServer(_ comment: String) throws -> CapturingServer {
    try CapturingServer { _, _ in
        Issue.record("A request reached TypeSafe, and \(comment).")
        return .init(body: "{}")
    }
}

let jevAnswer = #"""
    {"model":"jev-1.13.0","usage":{"input_tokens":1000,"output_tokens":4},
     "answers":{"refund":{"type":"noul","noul":0.93}}}
    """#

let jevQuestions: [String: ControlAPI.SystemOneQuestion] = [
    "refund": .init(type: "noul", instructions: .string("The customer asks for money back.")),
]

// MARK: - Settings

@Suite("Jev settings")
struct JevSettingsTests {

    @Test func defaultsAreOffExceptTheDecideTool() {
        let settings = JevSettings()
        #expect(settings.enabled == false)
        #expect(settings.model == "jev-1.13.0")
        #expect(settings.cacheMinutes == 10)
        #expect(settings.monthlyBudgetUSD == nil)
        #expect(settings.maxStateBytes == 64 * 1024)
        #expect(settings.isOn(.decideTool))
        for feature in JevFeature.allCases where feature != .decideTool {
            #expect(!settings.isOn(feature), "\(feature.rawValue) should ship off")
        }
        // The roadmap is visible; a feature is marked built as its own PR lands it.
        #expect(JevFeature.decideTool.isBuilt)
        #expect(JevFeature.routing.isBuilt)
        #expect(JevFeature.allCases.allSatisfy { !$0.summary.isEmpty && !$0.displayName.isEmpty })
    }

    @Test func roundTripsThroughTheFileAndSurvivesUnknownFeatures() async throws {
        let harness = JevHarness()
        defer { harness.clean() }

        await harness.configure()
        try await harness.service.update { settings in
            settings.enabled = true
            settings.model = "jev-latest"
            settings.features[.guardrails] = true
            settings.monthlyBudgetUSD = 12.5
            settings.cacheMinutes = 30
        }
        let written = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: harness.configURL)
        ) as! [String: Any]
        // Every feature is listed, so the file is one a person can edit by hand.
        #expect((written["features"] as! [String: Bool]).count == JevFeature.allCases.count)
        // And nothing that resembles a credential is in it.
        #expect(!written.keys.contains { $0.lowercased().contains("key") })

        let reloaded = JevSettings.load(from: harness.configURL)
        #expect(reloaded.enabled)
        #expect(reloaded.model == "jev-latest")
        #expect(reloaded.isOn(.guardrails))
        #expect(reloaded.isOn(.decideTool))
        #expect(reloaded.monthlyBudgetUSD == 12.5)
        #expect(reloaded.cacheMinutes == 30)

        // A file from a later build mentions a feature this one has never heard of.
        var raw = written
        var features = raw["features"] as! [String: Bool]
        features["timeTravel"] = true
        raw["features"] = features
        try JSONSerialization.data(withJSONObject: raw).write(to: harness.configURL)
        let forward = JevSettings.load(from: harness.configURL)
        #expect(forward.enabled && forward.isOn(.guardrails))
    }

    @Test func aHandEditedFileIsClampedRatherThanTrusted() throws {
        var settings = JevSettings()
        settings.model = "gpt-9"
        settings.cacheMinutes = -4
        settings.maxStateBytes = 1
        settings.monthlyBudgetUSD = -3
        let clamped = settings.normalized()
        // An unknown model would be a 422 on every call, so it falls back to the pin.
        #expect(clamped.model == JevService.pinnedModel)
        #expect(clamped.cacheMinutes == 0)
        #expect(clamped.maxStateBytes == 1_024)
        #expect(clamped.monthlyBudgetUSD == nil)
    }

    @Test func aMissingFileIsTheDefaults() {
        let nowhere = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).json")
        #expect(JevSettings.load(from: nowhere) == JevSettings())
    }

    /// Wherever the settings are pointed — by `SILICON_JEV_CONFIG` in the app, by
    /// `configure(configURL:)` here — the ledger follows them into the same folder. Checked
    /// as the pure rule rather than by setting a process-wide variable other tests can see.
    @Test func theLedgerFollowsTheSettingsWhereverTheyGo() {
        let config = URL(fileURLWithPath: "/tmp/jev-somewhere/jev.json")
        let ledger = JevSettings.ledgerURL(besideConfigAt: config)
        #expect(ledger.lastPathComponent == "jev-ledger.json")
        #expect(ledger.deletingLastPathComponent() == config.deletingLastPathComponent())
        // And the app's own default pair obeys the same rule.
        #expect(JevSettings.ledgerURL == JevSettings.ledgerURL(besideConfigAt: JevSettings.configURL))
    }

    @Test func bothFilesAndTheirDirectoryAreOwnerOnly() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure()
        try await harness.enable()
        var ledger = JevLedger()
        ledger.record(feature: .decideTool, inputTokens: 1, outputTokens: 0,
                      latencyMS: 1, model: "jev-1.13.0")
        try ledger.save(to: harness.ledgerURL)

        func permissions(_ url: URL) throws -> Int {
            try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        }
        #expect(try permissions(harness.configURL) == 0o600)
        #expect(try permissions(harness.ledgerURL) == 0o600)
        // The directory too: 0600 inside a readable folder still leaks that the file exists.
        #expect(try permissions(harness.fileDirectory) == 0o700)
    }
}

// MARK: - Ledger

@Suite("Jev ledger")
struct JevLedgerTests {

    @Test func costsAreInputTokensOnly() {
        #expect(JevLedger.cost(inputTokens: 1_000_000) == 0.042)
        #expect(abs(JevLedger.cost(inputTokens: 1_000) - 0.000042) < 1e-12)
        #expect(JevLedger.cost(inputTokens: 0) == 0)
    }

    @Test func accountsPerFeatureAndPerModelVersion() {
        var ledger = JevLedger()
        let day = Date(timeIntervalSince1970: 1_788_000_000)  // 2026-09-27
        ledger.record(feature: .decideTool, inputTokens: 1_000, outputTokens: 10,
                      latencyMS: 100, model: "jev-1.13.0", at: day)
        ledger.record(feature: .decideTool, inputTokens: 3_000, outputTokens: 20,
                      latencyMS: 300, model: "jev-1.13.0", at: day)
        ledger.record(feature: .guardrails, inputTokens: 6_000, outputTokens: 5,
                      latencyMS: 200, model: "jev-1.14.0", at: day)

        let month = ledger.month(JevLedger.monthKey(day))
        #expect(month.total.calls == 3)
        #expect(month.total.inputTokens == 10_000)
        #expect(month.total.outputTokens == 35)
        #expect(abs(month.total.estimatedUSD - 0.00042) < 1e-12)
        #expect(month.total.averageLatencyMS == 200)
        #expect(month.features["decideTool"]?.calls == 2)
        #expect(month.features["decideTool"]?.inputTokens == 4_000)
        #expect(month.features["guardrails"]?.inputTokens == 6_000)
        // Which version actually answered — how a moved alias gets noticed.
        #expect(month.models == ["jev-1.13.0": 2, "jev-1.14.0": 1])
        #expect(ledger.month("1999-01").total.calls == 0)
    }

    @Test func aNewMonthStartsAtZeroWithoutLosingTheOldOne() {
        var ledger = JevLedger()
        let september = Date(timeIntervalSince1970: 1_788_000_000)
        let october = september.addingTimeInterval(30 * 86_400)
        ledger.record(feature: .decideTool, inputTokens: 5_000_000, outputTokens: 0,
                      latencyMS: 10, model: "jev-1.13.0", at: september)
        ledger.record(feature: .decideTool, inputTokens: 1_000, outputTokens: 0,
                      latencyMS: 10, model: "jev-1.13.0", at: october)

        let septemberKey = JevLedger.monthKey(september)
        let octoberKey = JevLedger.monthKey(october)
        #expect(septemberKey != octoberKey)
        #expect(ledger.spentUSD(in: septemberKey) == 0.21)
        #expect(ledger.months[octoberKey]?.total.calls == 1)
        #expect(abs(ledger.spentUSD(in: octoberKey) - 0.000042) < 1e-12)
        // The rollover is a new key, not a reset: last month is still there.
        #expect(ledger.months.count == 2)
    }

    @Test func monthKeysArePaddedAndSortable() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let january = calendar.date(from: DateComponents(year: 2027, month: 1, day: 3))!
        #expect(JevLedger.monthKey(january, calendar: calendar) == "2027-01")
    }

    @Test func survivesTheFile() throws {
        let harness = JevHarness()
        defer { harness.clean() }
        var ledger = JevLedger()
        ledger.record(feature: .routing, inputTokens: 42, outputTokens: 1,
                      latencyMS: 5, model: "jev-1.13.0")
        try ledger.save(to: harness.ledgerURL)
        #expect(JevLedger.load(from: harness.ledgerURL) == ledger)
    }
}

// MARK: - The gate

@Suite("Jev confidence band")
struct JevBandTests {

    @Test func threeWays() {
        #expect(JevService.confidenceBand(0.95, low: 0.5, high: 0.9) == .act)
        #expect(JevService.confidenceBand(0.9, low: 0.5, high: 0.9) == .act)
        #expect(JevService.confidenceBand(0.7, low: 0.5, high: 0.9) == .confirm)
        #expect(JevService.confidenceBand(0.5, low: 0.5, high: 0.9) == .confirm)
        #expect(JevService.confidenceBand(0.49, low: 0.5, high: 0.9) == .escalate)
        #expect(JevService.confidenceBand(0, low: 0.5, high: 0.9) == .escalate)
    }

    /// A noul is the other shape: the number is the answer, so the certain readings are at
    /// both ends and the useless ones are in the middle. A confidence gate would read 0.02
    /// — a confident no — as no confidence at all.
    @Test func aNoulIsGatedFromBothEndsRatherThanFromAbove() {
        #expect(JevThresholds.noulBand(0.97, yes: 0.9, no: 0.1) == .act)
        #expect(JevThresholds.noulBand(0.9, yes: 0.9, no: 0.1) == .act)
        #expect(JevThresholds.noulBand(0.02, yes: 0.9, no: 0.1) == .act)
        #expect(JevThresholds.noulBand(0.1, yes: 0.9, no: 0.1) == .act)
        #expect(JevThresholds.noulBand(0.5, yes: 0.9, no: 0.1) == .escalate)
        #expect(JevThresholds.noulBand(0.6, yes: 0.9, no: 0.1) == .escalate)
        // Which is exactly where a confidence gate gets it wrong.
        #expect(JevService.confidenceBand(0.02, low: 0.1, high: 0.9) == .escalate)
    }

    @Test func thresholdsCarryTheirOwnNumbers() {
        // Deleting something needs more certainty than picking a tab does, which is the
        // whole reason the two numbers belong to the feature rather than to the gate.
        let destructive = JevThresholds(act: 0.95, confirm: 0.8)
        let harmless = JevThresholds(act: 0.6, confirm: 0.3)
        #expect(destructive.band(0.9) == .confirm)
        #expect(harmless.band(0.9) == .act)
        #expect(destructive.band(0.5) == .escalate)
        #expect(harmless.band(0.5) == .confirm)
    }
}

// MARK: - Asking

@Suite("Jev service")
struct JevServiceTests {

    @Test func refusesWhenDisabledWithoutTouchingTheNetwork() async throws {
        let server = try untouchedServer("Jev is switched off")
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)

        // Master switch off, feature on.
        await #expect(throws: JevError.disabled(.decideTool)) {
            try await harness.service.ask(.decideTool, state: .string("s"), questions: jevQuestions)
        }
        // Master switch on, feature off.
        try await harness.service.update { $0.enabled = true; $0.features[.decideTool] = false }
        await #expect(throws: JevError.disabled(.decideTool)) {
            try await harness.service.ask(.decideTool, state: .string("s"), questions: jevQuestions)
        }
        #expect(await harness.service.isAvailable(.decideTool) == false)
        #expect(server.requests.isEmpty)
    }

    @Test func refusesWithoutAKeyWithoutTouchingTheNetwork() async throws {
        let server = try untouchedServer("no key is stored")
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(key: nil, baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.enable()

        #expect(await harness.service.isAvailable(.decideTool) == false)
        await #expect(throws: JevError.noKey) {
            try await harness.service.ask(.decideTool, state: .string("s"), questions: jevQuestions)
        }
        await #expect(throws: JevError.noKey) { try await harness.service.testConnection() }
        #expect(server.requests.isEmpty)
    }

    @Test func refusesOverBudgetWithoutTouchingTheNetwork() async throws {
        let server = try untouchedServer("the month's budget is already spent")
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.enable()
        try await harness.service.update { $0.monthlyBudgetUSD = 0.01 }

        // $0.042 per million: 500k tokens is 2.1 cents, past a one-cent cap.
        var ledger = JevLedger()
        ledger.record(feature: .decideTool, inputTokens: 500_000, outputTokens: 0,
                      latencyMS: 10, model: "jev-1.13.0")
        try ledger.save(to: harness.ledgerURL)
        // Re-point at the same files so the actor re-reads the ledger it now has.
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)

        #expect(await harness.service.isAvailable(.decideTool) == false)
        await #expect(throws: JevError.budgetExhausted(spentUSD: 0.021, budgetUSD: 0.01)) {
            try await harness.service.ask(.decideTool, state: .string("s"), questions: jevQuestions)
        }
        #expect(server.requests.isEmpty)

        // Raising the cap makes it available again, without a restart.
        try await harness.service.update { $0.monthlyBudgetUSD = 1 }
        #expect(await harness.service.isAvailable(.decideTool))
    }

    @Test func refusesAnOversizedStateWithoutTouchingTheNetwork() async throws {
        let server = try untouchedServer("the state is over the limit")
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.enable()
        try await harness.service.update { $0.maxStateBytes = 2_048 }

        let big = JSONContent.string(String(repeating: "x", count: 4_096))
        await #expect(throws: JevError.tooLarge(bytes: 4_096, limit: 2_048)) {
            try await harness.service.ask(.decideTool, state: big, questions: jevQuestions)
        }
        #expect(server.requests.isEmpty)
    }

    @Test func refusesAMalformedQuestionWithoutTouchingTheNetwork() async throws {
        let server = try untouchedServer("the questions do not validate")
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.enable()

        // A choice with no criteria at all.
        await #expect(throws: ControlAPI.SystemOneValidationError.self) {
            try await harness.service.ask(
                .decideTool, state: .string("s"), questions: ["team": .init(type: "choice")]
            )
        }
        // And the documented per-question ceilings, refused here rather than as a 422.
        let options = Dictionary(
            uniqueKeysWithValues: (0..<256).map { ("option\($0)", JSONContent.null) }
        )
        #expect(throws: ControlAPI.SystemOneValidationError.self) {
            try JevService.checkLimits(["big": .init(type: "choice", criteria: .object(options))])
        }
        #expect(throws: ControlAPI.SystemOneValidationError.self) {
            try JevService.checkLimits([
                "long": .init(type: "score", criteria: .array((0..<11).map { .string("\($0)") })),
            ])
        }
        #expect(throws: ControlAPI.SystemOneValidationError.self) {
            try JevService.checkLimits(["short": .init(type: "score", criteria: .array([.string("a")]))])
        }
        try JevService.checkLimits(jevQuestions)

        // And reached through `ask`, not only called directly — a 256-option choice passes
        // `validate()` and would otherwise leave here as a 422.
        await #expect(throws: ControlAPI.SystemOneValidationError.self) {
            try await harness.service.ask(
                .decideTool, state: .string("s"),
                questions: [
                    "big": .init(
                        type: "choice", instructions: .string("Which one?"),
                        criteria: .object(options)
                    ),
                ]
            )
        }
        await #expect(throws: ControlAPI.SystemOneValidationError.self) {
            try await harness.service.ask(
                .decideTool, state: .string("s"),
                questions: [
                    "long": .init(
                        type: "score", instructions: .string("How much?"),
                        criteria: .array((0..<11).map { .string("level \($0)") })
                    ),
                ]
            )
        }
        // As is a question with no instruction at all.
        await #expect(throws: ControlAPI.SystemOneValidationError.self) {
            try await harness.service.ask(
                .decideTool, state: .string("s"), questions: ["mute": .init(type: "noul")]
            )
        }
        #expect(server.requests.isEmpty)
    }

    @Test func sendsThePinnedModelAndRecordsWhatItCost() async throws {
        let server = try CapturingServer { _, _ in .init(body: jevAnswer) }
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.enable()

        let response = try await harness.service.ask(
            .decideTool, state: .string("Charged twice."), questions: jevQuestions
        )
        #expect(response.answers["refund"] == .noul(0.93))

        let request = try #require(server.requests.first)
        #expect(request.path == "/v1/systemone")
        #expect(request.headers["authorization"] == "Bearer sk-fixture")
        let body = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
        // Pinned, not the SDK default alias.
        #expect(body["model"] as? String == "jev-1.13.0")

        // The ledger has the call, the tokens, the cost and the version that answered.
        let ledger = await harness.service.ledger()
        #expect(ledger.calls == 1)
        #expect(ledger.inputTokens == 1_000)
        #expect(abs(ledger.estimatedUSD - 0.000042) < 1e-12)
        #expect(ledger.month().features["decideTool"]?.calls == 1)
        #expect(ledger.month().models["jev-1.13.0"] == 1)
        #expect(ledger.month().total.averageLatencyMS ?? 0 > 0)
        // And it is on disk, not only in the actor.
        #expect(JevLedger.load(from: harness.ledgerURL).calls == 1)
        // The file the ledger lives in holds no credential.
        let onDisk = String(decoding: try Data(contentsOf: harness.ledgerURL), as: UTF8.self)
        #expect(!onDisk.contains("sk-fixture"))
    }

    @Test func choosingAnAliasSendsTheAlias() async throws {
        let server = try CapturingServer { _, _ in .init(body: jevAnswer) }
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.enable()
        try await harness.service.update { $0.model = "jev-preview" }

        _ = try await harness.service.ask(
            .decideTool, state: .string("s"), questions: jevQuestions
        )
        let body = try JSONSerialization.jsonObject(
            with: try #require(server.requests.first).body
        ) as! [String: Any]
        #expect(body["model"] as? String == "jev-preview")
    }

    @Test func anIdenticalQuestionInsideTheWindowIsNotAskedTwice() async throws {
        let server = try CapturingServer { _, _ in .init(body: jevAnswer) }
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.enable()

        let state = JSONContent.object(["ticket": .string("Charged twice for A-104.")])
        let first = try await harness.service.ask(.decideTool, state: state, questions: jevQuestions)
        let second = try await harness.service.ask(.decideTool, state: state, questions: jevQuestions)
        #expect(server.requests.count == 1)
        #expect(first == second)
        // One call, so one entry in the ledger: a cache hit costs nothing and is not billed.
        #expect(await harness.service.ledger().calls == 1)

        // A different state is a different question.
        _ = try await harness.service.ask(
            .decideTool, state: .string("Something else"), questions: jevQuestions
        )
        #expect(server.requests.count == 2)

        // So is the same state asked for a different feature.
        try await harness.service.update { $0.features[.guardrails] = true }
        _ = try await harness.service.ask(.guardrails, state: state, questions: jevQuestions)
        #expect(server.requests.count == 3)

        // Turning the window off asks again.
        try await harness.service.update { $0.cacheMinutes = 0 }
        _ = try await harness.service.ask(.decideTool, state: state, questions: jevQuestions)
        _ = try await harness.service.ask(.decideTool, state: state, questions: jevQuestions)
        #expect(server.requests.count == 5)
    }

    @Test func anExplicitCacheKeyCollapsesStatesTheCallerCallsTheSame() async throws {
        let server = try CapturingServer { _, _ in .init(body: jevAnswer) }
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.enable()

        _ = try await harness.service.ask(
            .decideTool, state: .object(["path": .string("/a"), "checkedAt": .number(1)]),
            questions: jevQuestions, cacheKey: "/a"
        )
        _ = try await harness.service.ask(
            .decideTool, state: .object(["path": .string("/a"), "checkedAt": .number(2)]),
            questions: jevQuestions, cacheKey: "/a"
        )
        #expect(server.requests.count == 1)
    }

    /// 429 and 529 mean "later". Retry-after is honoured when it is sent, and the doubling
    /// backoff is used when it is not — at most three attempts either way.
    @Test func backsOffOnRateLimitsAndHonoursRetryAfter() async throws {
        let sleeps = Sleeps()
        let server = try CapturingServer { _, served in
            served == 0
                ? .init(status: 429, headers: ["Retry-After": "7"],
                        body: #"{"detail":"slow down"}"#)
                : .init(body: jevAnswer)
        }
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, sleeps: sleeps
        )
        try await harness.enable()

        let response = try await harness.service.ask(
            .decideTool, state: .string("s"), questions: jevQuestions
        )
        #expect(response.answers["refund"] == .noul(0.93))
        #expect(server.requests.count == 2)
        #expect(await sleeps.seconds == [7])
        #expect(await harness.service.lastRetryDelays == [7])
        // The retry is one call, not two, as far as the ledger is concerned.
        #expect(await harness.service.ledger().calls == 1)
    }

    @Test func givesUpAfterThreeAttempts() async throws {
        let sleeps = Sleeps()
        let server = try CapturingServer { _, _ in
            .init(status: 529, body: #"{"detail":"overloaded"}"#)
        }
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, sleeps: sleeps
        )
        try await harness.enable()

        await #expect(throws: SystemOneError.self) {
            try await harness.service.ask(.decideTool, state: .string("s"), questions: jevQuestions)
        }
        #expect(server.requests.count == JevService.maximumAttempts)
        // No retry-after was sent, so the doubling backoff was used.
        #expect(await sleeps.seconds == [1, 2])
        // A failure costs nothing and is not recorded as spend.
        #expect(await harness.service.ledger().calls == 0)
    }

    @Test func aRealErrorIsNotRetried() async throws {
        let sleeps = Sleeps()
        let server = try CapturingServer { _, _ in
            .init(status: 422, body: #"{"detail":"body.questions.refund: Field required"}"#)
        }
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, sleeps: sleeps
        )
        try await harness.enable()

        await #expect(throws: SystemOneError.http(422, "body.questions.refund: Field required")) {
            try await harness.service.ask(.decideTool, state: .string("s"), questions: jevQuestions)
        }
        #expect(server.requests.count == 1)
        #expect(await sleeps.seconds.isEmpty)
    }

    /// A server asking for an hour is asking for more than a UI feature can give it. The
    /// wait is what actually happened, not what the header said — remove the cap in `send`
    /// and this fails.
    @Test func aRetryAfterFurtherOutThanWeWillWaitIsCapped() async throws {
        let sleeps = Sleeps()
        let server = try CapturingServer { _, served in
            served == 0
                ? .init(status: 429, headers: ["Retry-After": "3600"], body: #"{"detail":"later"}"#)
                : .init(body: jevAnswer)
        }
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, sleeps: sleeps
        )
        try await harness.enable()

        _ = try await harness.service.ask(
            .decideTool, state: .string("s"), questions: jevQuestions
        )
        #expect(await sleeps.seconds == [JevService.maximumBackoffSeconds])
        #expect(await sleeps.seconds == [30])
        #expect(server.requests.count == 2)
    }

    @Test func theDoublingBackoffIsTheFallback() {
        #expect(JevService.backoffSeconds(1) == 1)
        #expect(JevService.backoffSeconds(2) == 2)
        #expect(JevService.backoffSeconds(3) == 4)
    }

    @Test func testConnectionListsTheModels() async throws {
        let server = try CapturingServer { _, _ in
            .init(body: #"""
                {"models":[
                  {"name":"jev-latest","description":"stable","release_date":"2026-08-01"},
                  {"name":"jev-preview","description":"newest","release_date":"2026-08-01"}]}
                """#)
        }
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)

        let names = try await harness.service.testConnection()
        #expect(names == ["jev-latest", "jev-preview"])
        let request = try #require(server.requests.first)
        #expect(request.path == "/v1/models")
        #expect(request.headers["authorization"] == "Bearer sk-fixture")
        // Works with Jev switched off: it is how you check a key before turning it on.
        #expect(await harness.service.settings().enabled == false)
    }

    @Test func testConnectionReportsAnUnauthorizedKeyRatherThanThrowingAway() async throws {
        let server = try CapturingServer { _, _ in
            .init(status: 401, body: #"{"detail":"Invalid API key"}"#)
        }
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)

        await #expect(throws: SystemOneError.http(401, SystemOneClient.rejectedKey)) {
            try await harness.service.testConnection()
        }
        do {
            _ = try await harness.service.testConnection()
        } catch {
            #expect(!"\(error)".contains("sk-fixture"))
        }
    }

    /// Two features asking the same question about the same file at the same moment is the
    /// ordinary case. The cache cannot help until the first lands, so the second joins it.
    @Test func concurrentIdenticalAsksBecomeOneRequestAndOneCharge() async throws {
        let server = try CapturingServer { _, _ in .init(body: jevAnswer) }
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.enable()

        let state = JSONContent.object(["file": .string("/a/b.swift")])
        async let first = harness.service.ask(.decideTool, state: state, questions: jevQuestions)
        async let second = harness.service.ask(.decideTool, state: state, questions: jevQuestions)
        let answers = try await [first, second]

        #expect(answers[0] == answers[1])
        #expect(server.requests.count == 1, "the second ask paid for the same bytes again")
        // One request, one entry: billing the joined caller too would be a lie the budget
        // then acts on.
        #expect(await harness.service.ledger().calls == 1)
    }

    /// A ledger that cannot be written is a budget that stops counting, which is the one
    /// thing a spending cap must not do quietly.
    @Test func aLedgerThatCannotBeWrittenIsReportedRatherThanSwallowed() async throws {
        let server = try CapturingServer { _, _ in .init(body: jevAnswer) }
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.enable()
        #expect(await harness.service.ledgerWriteFailed == false)

        // A directory where the file should be: the write fails, the answer still arrives.
        try FileManager.default.createDirectory(
            at: harness.ledgerURL, withIntermediateDirectories: true
        )
        let response = try await harness.service.ask(
            .decideTool, state: .string("s"), questions: jevQuestions
        )
        #expect(response.answers["refund"] == .noul(0.93))
        #expect(await harness.service.ledgerWriteFailed)
        #expect(await harness.service.ledgerWriteError != nil)
        // The in-memory count still moved, so the budget holds for this session at least.
        #expect(await harness.service.ledger().calls == 1)
    }

    /// The convenience a feature actually calls, with a service of its own rather than the
    /// shared one — which is the only way a feature's tests can run without a real key.
    @Test func aQuestionSetCanBeAskedAgainstAnInjectedService() async throws {
        let server = try CapturingServer { _, _ in .init(body: jevAnswer) }
        defer { server.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        try await harness.enable()

        let response = try await SampleQuestions.ask(
            state: .string("Charged twice."), using: harness.service
        )
        let refund = try response.noul("refund")
        #expect(refund == 0.93)
        // The half of the convention the protocol cannot hold: the thresholds that read the
        // answer live in the same file as the question that produced it.
        #expect(JevThresholds.noulBand(
            refund, yes: SampleQuestions.refund.yes, no: SampleQuestions.refund.no
        ) == .act)
        #expect(server.requests.count == 1)
        #expect(await harness.service.ledger().month().features["decideTool"]?.calls == 1)
    }

    /// `isAvailable` is called while Settings is drawing, so it must not read the secret —
    /// on a real Mac that is a consent dialog on screen for a row nobody clicked.
    @Test func availabilityAsksWhetherAKeyExistsRatherThanFetchingIt() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        let reads = Counter()
        await harness.service.configure(
            keyProvider: { Task { await reads.bump() }; return "sk-fixture" },
            baseURL: URL(string: "http://127.0.0.1:1")!,
            keyIsSet: { true },
            configURL: harness.configURL
        )
        try await harness.enable()
        for _ in 0..<5 { _ = await harness.service.isAvailable(.decideTool) }
        #expect(await harness.service.isAvailable(.decideTool))
        #expect(await reads.count == 0)
    }
}

/// Counts how often a closure was called, from wherever it was called.
actor Counter {
    private(set) var count = 0
    func bump() { count += 1 }
}


/// A question set in the shape every feature will use: the questions and the thresholds
/// that read them, in one place.
enum SampleQuestions: JevQuestionSet {
    static let feature = JevFeature.decideTool
    static let questions: [String: ControlAPI.SystemOneQuestion] = jevQuestions
    /// Refunds are money, so the bar is high and the middle escalates.
    static let refund = (yes: 0.9, no: 0.1)
}

// MARK: - Live

/// Against the real TypeSafe API, with a real key, when both are explicitly asked for.
///
/// Never part of an ordinary run: it costs money and needs a credential. The key is read
/// from the environment at the moment it is used and is never printed — not the value, not
/// its length, not a prefix.
@Suite("Jev, live")
struct JevLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SILICON_JEV_LIVE"] == "1"))
    func answersASupportTicket() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.service.configure(
            keyProvider: { ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] },
            keyIsSet: { ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] != nil },
            configURL: harness.configURL
        )
        try await harness.enable()
        guard await harness.service.isAvailable(.decideTool) else {
            Issue.record("SILICON_JEV_LIVE=1 but TYPESAFE_API_KEY is not set.")
            return
        }

        let models = try await harness.service.testConnection()
        #expect(!models.isEmpty)

        let response = try await harness.service.ask(
            .decideTool,
            state: .object([
                "subject": .string("Duplicate charge"),
                "message": .string("I was charged twice for order A-104. I want my money back."),
            ]),
            questions: [
                "refund": .init(
                    type: "noul",
                    instructions: .string("The customer explicitly asks for a refund.")
                ),
                "team": .init(
                    type: "choice",
                    instructions: .string("Which team should handle this?"),
                    criteria: .object([
                        "billing": .string("payments, refunds, duplicate charges"),
                        "technical": .string("bugs and outages"),
                        "sales": .string("pricing and plans"),
                    ])
                ),
            ]
        )
        #expect(response.model.hasPrefix("jev-"))
        guard case .noul(let refund) = response.answers["refund"] else {
            Issue.record("refund should be a noul"); return
        }
        #expect(refund > 0.5)
        guard case .choice(let team, let confidence, _) = response.answers["team"] else {
            Issue.record("team should be a choice"); return
        }
        #expect(team == "billing")
        #expect(JevService.confidenceBand(confidence, low: 0.5, high: 0.9) != .escalate)
        // It really cost something, and the ledger really has it.
        #expect(await harness.service.ledger().inputTokens > 0)
    }
}

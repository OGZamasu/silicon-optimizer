import Foundation

/// One gateway request, from arrival to verdict — what the Fleet tab shows and what the
/// JSONL log keeps. Born when a request is routed, completed when its answer (or error)
/// goes back out.
public struct GatewayLedgerEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var startedAt: Date
    /// "chat" or "responses" — which dialect the caller spoke.
    public var endpoint: String
    public var modelID: String
    public var backendModel: String?
    public var stream: Bool
    /// Character count across every message in the request.
    public var promptChars: Int
    public var promptPreview: String?
    public var responsePreview: String?
    public var promptTokens: Int?
    public var outputTokens: Int?
    /// Time spent making the model ready (loads, node starts, render waits).
    public var ensureMs: Int?
    public var totalMs: Int?
    /// Nil while in flight; then the request's verdict.
    public var ok: Bool?
    public var detail: String?
    /// The empty-content diagnosis, when one applied.
    public var warning: String?

    /// Generation speed for this one request, when it can be computed honestly:
    /// tokens over the time spent generating, not loading.
    public var tokensPerSecond: Double? {
        guard let output = outputTokens, output >= 16,
              let total = totalMs else { return nil }
        let generateMs = total - (ensureMs ?? 0)
        guard generateMs > 500 else { return nil }
        return Double(output) / (Double(generateMs) / 1000)
    }
}

/// Per-model aggregates over the ledger — request counts and a smoothed
/// tokens-per-second estimate that feeds `/v1/models`.
public struct GatewayModelStats: Sendable, Equatable {
    public var requests: Int = 0
    public var failures: Int = 0
    public var inFlight: Int = 0
    public var tokensPerSecond: Double?
    public var lastUsed: Date?
}

/// The gateway's request ledger: a bounded in-memory window for the Fleet tab, appended
/// to a JSONL file so history survives restarts. The orchestrated ROUTE 85 build kept
/// this exact record by hand; the gateway sees every request, so now it keeps it for
/// everyone, automatically.
public actor GatewayLedger {

    private var entries: [GatewayLedgerEntry] = []
    private var rates: [String: Double] = [:]
    private var previews: Bool
    private let keep: Int
    private let maxLogBytes: Int
    private let logURL: URL?

    /// - Parameters:
    ///   - directory: where `gateway-ledger.jsonl` lives; nil keeps the ledger in memory
    ///     only (tests, or previews of the app without a container).
    ///   - previews: whether prompt/response text excerpts are recorded. Metadata is
    ///     always kept; this only governs message content.
    public init(
        directory: URL?, previews: Bool, keep: Int = 400, maxLogBytes: Int = 5_000_000
    ) {
        self.previews = previews
        self.keep = keep
        self.maxLogBytes = maxLogBytes
        self.logURL = directory?.appendingPathComponent("gateway-ledger.jsonl")
        if let logURL {
            (entries, rates) = Self.loadTail(from: logURL, keep: keep)
        }
    }

    public func setPreviews(_ enabled: Bool) {
        previews = enabled
    }

    /// Empties the in-memory window — the view's Clear button. The JSONL on disk is
    /// deliberately untouched (size rotation owns it), and the speed estimates keep
    /// their learning.
    public func clear() {
        entries.removeAll()
    }

    // MARK: - Lifecycle of one request

    public func begin(
        endpoint: String, modelID: String, stream: Bool,
        promptChars: Int, promptPreview: String?
    ) -> String {
        let entry = GatewayLedgerEntry(
            id: UUID().uuidString,
            startedAt: Date(),
            endpoint: endpoint,
            modelID: modelID,
            backendModel: nil,
            stream: stream,
            promptChars: promptChars,
            promptPreview: previews ? promptPreview : nil
        )
        entries.append(entry)
        trim()
        return entry.id
    }

    public func noteEnsured(_ id: String, backendModel: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].backendModel = backendModel
        entries[index].ensureMs = elapsedMs(since: entries[index].startedAt)
    }

    public func finish(
        _ id: String, ok: Bool, detail: String? = nil, warning: String? = nil,
        responsePreview: String? = nil, promptTokens: Int? = nil, outputTokens: Int? = nil
    ) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].totalMs = elapsedMs(since: entries[index].startedAt)
        entries[index].ok = ok
        entries[index].detail = detail
        entries[index].warning = warning
        entries[index].responsePreview = previews ? responsePreview : nil
        entries[index].promptTokens = promptTokens
        entries[index].outputTokens = outputTokens
        absorbRate(entries[index])
        persist(entries[index])
    }

    // MARK: - Reads

    /// Newest first — the order a Fleet activity list wants.
    public func snapshot() -> [GatewayLedgerEntry] {
        entries.reversed()
    }

    public func stats() -> [String: GatewayModelStats] {
        var byModel: [String: GatewayModelStats] = [:]
        for entry in entries {
            var stat = byModel[entry.modelID] ?? GatewayModelStats()
            if entry.ok == nil {
                stat.inFlight += 1
            } else {
                stat.requests += 1
                if entry.ok == false { stat.failures += 1 }
            }
            if stat.lastUsed.map({ entry.startedAt > $0 }) ?? true {
                stat.lastUsed = entry.startedAt
            }
            byModel[entry.modelID] = stat
        }
        for (model, rate) in rates {
            byModel[model, default: GatewayModelStats()].tokensPerSecond = rate
        }
        return byModel
    }

    public func inFlight(modelID: String) -> Int {
        entries.filter { $0.modelID == modelID && $0.ok == nil }.count
    }

    // MARK: - Internals

    private func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private func trim() {
        if entries.count > keep {
            entries.removeFirst(entries.count - keep)
        }
    }

    /// A smoothed per-model generation rate: new observations move the estimate, noise
    /// does not swing it. Only honestly measurable requests contribute (see the entry's
    /// own `tokensPerSecond` rules).
    private func absorbRate(_ entry: GatewayLedgerEntry) {
        guard let observed = entry.tokensPerSecond else { return }
        if let current = rates[entry.modelID] {
            rates[entry.modelID] = current * 0.7 + observed * 0.3
        } else {
            rates[entry.modelID] = observed
        }
    }

    private func persist(_ entry: GatewayLedgerEntry) {
        guard let logURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(Data("\n".utf8))

        let manager = FileManager.default
        try? manager.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: logURL)
        }
    }

    /// One-deep rotation: the log never grows past the cap, and the previous
    /// generation stays readable next to it.
    private func rotateIfNeeded() {
        guard let logURL,
              let size = try? FileManager.default.attributesOfItem(
                atPath: logURL.path
              )[.size] as? Int,
              size > maxLogBytes
        else { return }
        let old = logURL.deletingPathExtension().appendingPathExtension("old.jsonl")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: logURL, to: old)
    }

    /// Rehydrates the in-memory window (and the rate estimates) from the end of the
    /// log — completed entries only; an in-flight entry in a dead process finished
    /// nowhere. Static so the actor's init can run it without isolation.
    private static func loadTail(
        from logURL: URL, keep: Int
    ) -> ([GatewayLedgerEntry], [String: Double]) {
        guard let data = try? Data(contentsOf: logURL) else { return ([], [:]) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [GatewayLedgerEntry] = []
        var rates: [String: Double] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")).suffix(keep) {
            guard let entry = try? decoder.decode(GatewayLedgerEntry.self, from: Data(line)),
                  entry.ok != nil
            else { continue }
            loaded.append(entry)
            if let observed = entry.tokensPerSecond {
                if let current = rates[entry.modelID] {
                    rates[entry.modelID] = current * 0.7 + observed * 0.3
                } else {
                    rates[entry.modelID] = observed
                }
            }
        }
        return (loaded, rates)
    }
}
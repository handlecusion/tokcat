import DataSource
import Foundation

// Port of the run()/collect_messages()/build_payload() pipeline
// (usage_graph.rs:158-404).

/// A per-client usage parser. Stage 1 ships claude + codex; further clients
/// slot into `UsageGraph.registry` in the fixed collect_messages order.
protocol UsageParser {
    static var clientName: String { get }
    /// `cache` is the optional per-file parse cache (nil = cold run). Only
    /// parsers whose per-file output is self-contained may use it.
    static func parse(_ cache: UsageCache?) -> [UsageMessage]
}

public enum UsageGraphError: Error, CustomStringConvertible {
    case invalidYear(String)

    public var description: String {
        switch self {
        case .invalidYear(let year): return "invalid year filter: \(year)"
        }
    }
}

public enum UsageGraph {
    static let version = "tokcat-core/0.1.42"

    /// Fixed client order, mirroring collect_messages (usage_graph.rs:181-192).
    /// Order matters: dedup_messages is first-wins across the concatenation.
    static let registry: [(name: String, parse: @Sendable (UsageCache?) -> [UsageMessage])] = [
        ("claude", ClaudeParser.parse),
        ("codex", CodexParser.parse),
        ("cursor", CursorParser.parse),
        ("opencode", OpenCodeParser.parse),
        ("gemini", GeminiParser.parse),
        ("copilot", CopilotParser.parse),
        ("amp", AmpParser.parse),
        ("droid", DroidParser.parse),
        ("hermes", HermesParser.parse),
        ("grok", GrokParser.parse),
        // Swift-only (no Rust counterpart); kept out of the parity rosters.
        ("omp", OmpParser.parse),
        ("aside", AsideParser.parse),
    ]

    /// Port of run(): parse, optionally filter to a year, aggregate.
    /// `clients` restricts which parsers run (nil = all registered).
    /// `cache` reuses per-file parse results across runs (nil = cold run,
    /// bit-identical to the cacheless path).
    public static func run(
        year: String, clients: [String]? = nil, cache: UsageCache? = nil
    ) throws -> UsagePayload {
        let yearFilter = try normalizeYear(year)
        var messages = collectMessages(clients: clients, cache: cache)
        if let year = yearFilter {
            let prefix = year + "-"
            messages = messages.filter { $0.date.hasPrefix(prefix) }
        }
        return buildPayload(messages)
    }

    static func collectMessages(
        clients: [String]? = nil, cache: UsageCache? = nil
    ) -> [UsageMessage] {
        cache?.beginRun()
        var messages: [UsageMessage] = []
        for entry in registry {
            if let clients, !clients.contains(entry.name) { continue }
            messages.append(contentsOf: entry.parse(cache))
        }
        cache?.endRun()
        // inferProvider and bundledPrice are pure per (model, provider) but
        // string-scan heavy; memoize across the ~10^5-message pass.
        var providerCache: [String: String] = [:]
        var priceCache: [String: Price] = [:]
        return dedupMessages(messages).compactMap { msg -> UsageMessage? in
            var msg = msg
            if msg.timestampMs <= 0 || msg.totalTokens <= 0 { return nil }
            if rustTrim(msg.providerId).isEmpty {
                if let provider = providerCache[msg.modelId] {
                    msg.providerId = provider
                } else {
                    let provider = inferProvider(msg.modelId)
                    providerCache[msg.modelId] = provider
                    msg.providerId = provider
                }
            }
            if msg.cost <= 0.0 {
                let key = "\(msg.modelId)\u{0}\(msg.providerId)"
                let price: Price
                if let cached = priceCache[key] {
                    price = cached
                } else {
                    price = bundledPrice(model: msg.modelId, provider: msg.providerId)
                    priceCache[key] = price
                }
                msg.cost = estimateCost(price: price, tokens: msg.tokens)
            }
            return msg
        }
    }
}

/// Port of normalize_year (usage_graph.rs:169-179).
func normalizeYear(_ year: String) throws -> String? {
    let trimmed = rustTrim(year)
    if trimmed.isEmpty { return nil }
    let bytes = Array(trimmed.utf8)
    if bytes.count == 4, bytes.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
        return trimmed
    }
    throw UsageGraphError.invalidYear(year)
}

/// Port of dedup_messages (usage_graph.rs:211-233): first-wins on the
/// explicit dedup key, falling back to a content key.
func dedupMessages(_ messages: [UsageMessage]) -> [UsageMessage] {
    var seen = Set<String>()
    var out: [UsageMessage] = []
    out.reserveCapacity(messages.count)
    for msg in messages {
        let key =
            msg.dedupKey
            ?? "\(msg.client):\(msg.modelId):\(msg.providerId):\(msg.timestampMs):"
            + "\(msg.tokens.input):\(msg.tokens.output):\(msg.tokens.cacheRead):"
            + "\(msg.tokens.cacheWrite)"
        if seen.insert(key).inserted {
            out.append(msg)
        }
    }
    return out
}

/// Rust `String` Ord: plain byte-wise comparison.
func utf8Less(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}

private struct DayAccumulator {
    var tokens: Int64 = 0
    var cost: Double = 0.0
    var messages: Int32 = 0
    var tokenBreakdown = TokenBreakdown()
    var clients: [String: ContributionClient] = [:]
}

private func satAddI32(_ a: Int32, _ b: Int32) -> Int32 {
    let (r, overflow) = a.addingReportingOverflow(b)
    if overflow { return b > 0 ? Int32.max : Int32.min }
    return r
}

/// Port of build_payload (usage_graph.rs:235-306).
func buildPayload(_ messages: [UsageMessage]) -> UsagePayload {
    var dayMap: [String: DayAccumulator] = [:]

    for msg in messages {
        var day = dayMap[msg.date] ?? DayAccumulator()
        day.tokens = satAdd(day.tokens, msg.totalTokens)
        day.cost += msg.cost
        day.messages = satAddI32(day.messages, msg.messages)
        day.tokenBreakdown.addClamped(msg.tokens)

        let key = "\(msg.client):\(msg.providerId):\(msg.modelId)"
        var client =
            day.clients[key]
            ?? ContributionClient(
                client: msg.client, modelId: msg.modelId, providerId: msg.providerId,
                tokens: TokenBreakdown(), cost: 0.0, messages: 0)
        client.tokens.addClamped(msg.tokens)
        client.cost += msg.cost
        client.messages = Int64(
            satAddI32(Int32(truncatingIfNeeded: client.messages), msg.messages))
        day.clients[key] = client
        dayMap[msg.date] = day
    }

    var contributions: [Contribution] = dayMap.keys
        .sorted(by: utf8Less)
        .map { date in
            let day = dayMap[date]!
            var clients = Array(day.clients.values)
            clients.sort { a, b in
                if a.client != b.client { return utf8Less(a.client, b.client) }
                if a.providerId != b.providerId { return utf8Less(a.providerId, b.providerId) }
                return utf8Less(a.modelId, b.modelId)
            }
            return Contribution(
                date: date,
                totals: ContributionTotals(
                    tokens: day.tokens, cost: day.cost, messages: Int64(day.messages)),
                intensity: 0,
                tokenBreakdown: day.tokenBreakdown,
                clients: clients)
        }

    calculateIntensities(&contributions)
    let summary = calculateSummary(contributions)
    let years = calculateYears(contributions)
    let dateRange = DateRange(
        start: contributions.first?.date ?? "",
        end: contributions.last?.date ?? "")

    return UsagePayload(
        meta: UsageMeta(
            generatedAt: rfc3339MillisUTCNow(),
            version: UsageGraph.version,
            dateRange: dateRange),
        summary: summary,
        years: years,
        contributions: contributions)
}

/// `Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)`.
func rfc3339MillisUTCNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: Date())
}

/// Port of calculate_summary (usage_graph.rs:308-340).
func calculateSummary(_ contributions: [Contribution]) -> UsageSummary {
    var clients = Set<String>()
    var models = Set<String>()
    var totalTokens: Int64 = 0
    var totalCost = 0.0
    var maxCost = 0.0

    for c in contributions {
        totalTokens += c.totals.tokens
        totalCost += c.totals.cost
        maxCost = max(maxCost, c.totals.cost)
        for client in c.clients {
            clients.insert(client.client)
            models.insert(client.modelId)
        }
    }

    let activeDays = contributions.lazy.filter { $0.totals.tokens > 0 }.count
    return UsageSummary(
        totalTokens: totalTokens,
        totalCost: totalCost,
        totalDays: contributions.count,
        activeDays: activeDays,
        averagePerDay: activeDays > 0 ? totalCost / Double(activeDays) : 0.0,
        maxCostInSingleDay: maxCost,
        clients: clients.sorted(by: utf8Less),
        models: models.sorted(by: utf8Less))
}

/// Port of calculate_years (usage_graph.rs:342-380).
func calculateYears(_ contributions: [Contribution]) -> [YearMeta] {
    struct Acc {
        var tokens: Int64 = 0
        var cost = 0.0
        var start = ""
        var end = ""
    }

    var byYear: [String: Acc] = [:]
    for c in contributions {
        guard c.date.utf8.count >= 4 else { continue }
        let year = String(c.date.prefix(4))
        var acc = byYear[year] ?? Acc()
        acc.tokens += c.totals.tokens
        acc.cost += c.totals.cost
        if acc.start.isEmpty || utf8Less(c.date, acc.start) { acc.start = c.date }
        if acc.end.isEmpty || utf8Less(acc.end, c.date) { acc.end = c.date }
        byYear[year] = acc
    }

    return byYear.keys.sorted(by: utf8Less).map { year in
        let acc = byYear[year]!
        return YearMeta(
            year: year, totalTokens: acc.tokens, totalCost: acc.cost,
            range: DateRange(start: acc.start, end: acc.end))
    }
}

/// Port of calculate_intensities (usage_graph.rs:382-404): cost-ratio
/// buckets 0-4 against the max-cost day.
func calculateIntensities(_ contributions: inout [Contribution]) {
    let maxCost = contributions.reduce(0.0) { max($0, $1.totals.cost) }
    if maxCost <= 0.0 { return }
    for i in contributions.indices {
        let ratio = contributions[i].totals.cost / maxCost
        contributions[i].intensity =
            ratio >= 0.75 ? 4 : ratio >= 0.5 ? 3 : ratio >= 0.25 ? 2 : ratio > 0.0 ? 1 : 0
    }
}

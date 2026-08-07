import DataSource
import Foundation

// Port of parse_hermes / hermes_db_path / parse_hermes_db / hermes_provider /
// hermes_timestamp_ms (usage_graph.rs:1584-1589, 2076-2238, 2310-2319).

enum HermesParser: UsageParser {
    static let clientName = "hermes"

    static func parse(_ cache: UsageCache?) -> [UsageMessage] {
        guard let path = hermesDBPath() else { return [] }
        return parseHermesDB(path)
    }
}

/// Port of hermes_db_path (usage_graph.rs:2310-2319).
func hermesDBPath() -> String? {
    if let home = ProcessInfo.processInfo.environment["HERMES_HOME"] {
        let p = joinPath(home, "state.db")
        if isFile(p) { return p }
    }
    guard let home = homeDir() else { return nil }
    let p = joinPath(joinPath(home, ".hermes"), "state.db")
    return isFile(p) ? p : nil
}

/// Port of parse_hermes_db (usage_graph.rs:2076-2189): PRAGMA table_info
/// column tolerance with literal-default substitution for missing columns,
/// ORDER BY started_at,id only when started_at exists.
func parseHermesDB(_ path: String) -> [UsageMessage] {
    guard let db = SQLiteDatabase(readOnlyAtPath: path) else { return [] }

    let columns = sqliteTableColumns(db, table: "sessions")
    let reasoningExpr = sqliteColumnOr(columns, "reasoning_tokens", "0")
    let providerExpr = sqliteColumnOr(columns, "billing_provider", "''")
    let startedExpr = sqliteColumnOr(columns, "started_at", "0")
    let endedExpr = sqliteColumnOr(columns, "ended_at", "0")
    let actualCostExpr = sqliteColumnOr(columns, "actual_cost_usd", "0")
    let estimatedCostExpr = sqliteColumnOr(columns, "estimated_cost_usd", "0")
    let messageCountExpr = sqliteColumnOr(columns, "message_count", "1")
    let orderExpr = columns.contains("started_at") ? "started_at, id" : "id"

    let query = """
        SELECT id, model,
            COALESCE(input_tokens, 0),
            COALESCE(output_tokens, 0),
            COALESCE(cache_read_tokens, 0),
            COALESCE(cache_write_tokens, 0),
            \(reasoningExpr),
            \(providerExpr),
            \(startedExpr),
            \(endedExpr),
            \(actualCostExpr),
            \(estimatedCostExpr),
            \(messageCountExpr)
        FROM sessions
        WHERE model IS NOT NULL AND TRIM(model) != ''
        ORDER BY \(orderExpr)
        """

    guard let stmt = db.prepare(query) else { return [] }
    let fallbackTs = fileModifiedTimestampMs(path)
    var out: [UsageMessage] = []
    while stmt.step() {
        // Any per-column type mismatch skips the row (rusqlite semantics).
        guard let id = stmt.text(0),
            let model = stmt.text(1),
            let input = stmt.i64(2),
            let output = stmt.i64(3),
            let cacheRead = stmt.i64(4),
            let cacheWrite = stmt.i64(5),
            let reasoning = stmt.i64(6),
            let billingProvider = stmt.text(7),
            let startedAt = stmt.f64(8),
            let endedAt = stmt.f64(9),
            let actualCost = stmt.f64(10),
            let estimatedCost = stmt.f64(11),
            let messageCount = stmt.i32(12)
        else { continue }

        let provider = hermesProvider(billingProvider, model: model)
        let ts = hermesTimestampMs(startedAt, endedAt, fallbackTs: fallbackTs)
        let cost = actualCost > 0.0 ? actualCost : estimatedCost > 0.0 ? estimatedCost : 0.0
        var msg = UsageMessage(
            client: "hermes", modelId: model, providerId: provider,
            timestampMs: ts,
            tokens: TokenBreakdown(
                input: max(input, 0),
                output: max(output, 0),
                cacheRead: max(cacheRead, 0),
                cacheWrite: max(cacheWrite, 0),
                reasoning: max(reasoning, 0)),
            cost: cost)
        msg.messages = max(messageCount, 1)
        msg.dedupKey = "hermes:\(id)"
        out.append(msg)
    }
    return out
}

/// Port of hermes_provider (usage_graph.rs:2213-2232).
func hermesProvider(_ billingProvider: String, model: String) -> String {
    let provider = rustTrim(billingProvider).lowercased()
    if provider.contains("anthropic") {
        return "anthropic"
    } else if provider.contains("openai") {
        return "openai"
    } else if provider.contains("google") || provider.contains("gemini") {
        return "google"
    } else if provider.contains("xai") || provider.contains("grok") {
        return "xai"
    } else if provider.contains("deepseek") {
        return "deepseek"
    } else if provider.contains("meta") || provider.contains("llama") {
        return "meta"
    } else if provider.isEmpty {
        return inferProvider(model)
    }
    return provider
}

/// Port of hermes_timestamp_ms (usage_graph.rs:2234-2238): REAL epoch values
/// through the rounding f64 normalizer, actual start before end.
func hermesTimestampMs(_ startedAt: Double, _ endedAt: Double, fallbackTs: Int64) -> Int64 {
    normalizeEpochMsF64(startedAt) ?? normalizeEpochMsF64(endedAt) ?? fallbackTs
}

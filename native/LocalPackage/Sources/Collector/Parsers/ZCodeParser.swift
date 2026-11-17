import DataSource
import Foundation

// ZCode (Z.ai coding agent): authoritative per-request usage lives in
// ~/.zcode/cli/db/db.sqlite, table model_usage — the same rows ZCode's own
// usage display aggregates. Each row is one provider attempt:
//
//   input_tokens                  prompt tokens, INCLUSIVE of cache reads
//   output_tokens                 completion tokens
//   reasoning_tokens              reasoning tokens
//   cache_creation_input_tokens   tokens written to the prompt cache
//   cache_read_input_tokens       tokens served from the prompt cache
//   computed_total_tokens         ZCode's own total: input + output +
//                                 reasoning + cache_creation (cache reads
//                                 are excluded — they are part of input)
//   started_at / completed_at     epoch milliseconds
//   logical_request_id            unique per logical request
//   status                        completed | error | cancelled...
//
// Mapping into TokenBreakdown keeps Tokcat's total identical to ZCode's
// computed_total_tokens: the cache-read portion is moved out of `input`
// into `cacheRead`, so total = (input - cacheRead) + output + cacheRead +
// cacheCreation + reasoning == computed_total_tokens.

enum ZCodeParser: UsageParser {
    static let clientName = "zcode"

    static func parse(_ cache: UsageCache?) -> [UsageMessage] {
        guard let home = homeDir() else { return [] }
        return parse(cache: cache, home: home)
    }

    /// Testable core: `home` is the agent home (usually ~).
    static func parse(cache: UsageCache?, home: String) -> [UsageMessage] {
        let dbPath = joinPath(joinPath(joinPath(home, ".zcode"), "cli"), "db/db.sqlite")
        guard isFile(dbPath), let db = SQLiteDatabase(readOnlyAtPath: dbPath) else { return [] }
        let columns = sqliteTableColumns(db, table: "model_usage")
        guard columns.contains("input_tokens"), columns.contains("output_tokens") else { return [] }

        let query = """
            SELECT id, logical_request_id, provider_id, model_id, status,
                   completed_at, input_tokens, output_tokens, reasoning_tokens,
                   cache_creation_input_tokens, cache_read_input_tokens,
                   computed_total_tokens
            FROM model_usage
            ORDER BY id
            """
        guard let stmt = db.prepare(query) else { return [] }

        var out: [UsageMessage] = []
        while stmt.step() {
            guard let id = stmt.text(0), let model = stmt.text(3) else { continue }
            let provider = stmt.text(2) ?? "z.ai"
            let input = stmt.i64(6) ?? 0
            let output = stmt.i64(7) ?? 0
            let reasoning = stmt.i64(8) ?? 0
            let cacheWrite = stmt.i64(9) ?? 0
            let cacheRead = stmt.i64(10) ?? 0
            let tokens = TokenBreakdown(
                input: max(input - cacheRead, 0),
                output: max(output, 0),
                cacheRead: max(cacheRead, 0),
                cacheWrite: max(cacheWrite, 0),
                reasoning: max(reasoning, 0)
            )
            if tokens.total <= 0 { continue } // failed attempts carry no usage
            let ts = stmt.i64(5) ?? 0
            var msg = UsageMessage(
                client: "zcode", modelId: model, providerId: provider,
                timestampMs: ts, tokens: tokens, cost: 0.0
            )
            msg.dedupKey = "zcode:" + id
            out.append(msg)
        }
        return out
    }
}

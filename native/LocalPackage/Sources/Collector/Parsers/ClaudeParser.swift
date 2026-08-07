import DataSource
import Foundation

// Port of parse_claude / parse_claude_file (usage_graph.rs:406-488).

enum ClaudeParser: UsageParser {
    static let clientName = "claude"

    static func parse(_ cache: UsageCache?) -> [UsageMessage] {
        guard let home = homeDir() else { return [] }
        let roots = [
            joinPath(joinPath(home, ".claude"), "projects"),
            joinPath(joinPath(home, ".claude"), "transcripts"),
        ]
        // Files parse independently (the merge map below is per-file), so
        // parse concurrently; parseFilesInOrder keeps the roots-then-sorted
        // concatenation order the downstream first-wins dedup depends on.
        var files: [String] = []
        for root in roots {
            files.append(contentsOf: collectFiles(root) { p in
                let ext = rustExtension(p)
                return ext == "jsonl" || ext == "json"
            })
        }
        return parseFilesInOrder(files, cache: cache, parseClaudeFile)
    }
}

@Sendable func parseClaudeFile(_ path: String) -> [UsageMessage] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    let fallbackTs = fileModifiedTimestampMs(path)
    var out: [UsageMessage] = []
    var dedup: [String: Int] = [:]
    forEachJSONLLine(data) { line in
        guard let value = parseTrimmedJSONLine(line) else { return }
        guard value["type"]?.asString == "assistant" else { return }
        guard let message = value["message"] else { return }
        guard let usage = message["usage"] else { return }
        guard let model = stringValue(message["model"]) else { return }
        let tokens = TokenBreakdown(
            input: max(i64Value(usage["input_tokens"]) ?? 0, 0),
            output: max(i64Value(usage["output_tokens"]) ?? 0, 0),
            cacheRead: max(i64Value(usage["cache_read_input_tokens"]) ?? 0, 0),
            cacheWrite: max(i64Value(usage["cache_creation_input_tokens"]) ?? 0, 0),
            reasoning: 0
        )
        if tokens.total <= 0 { return }
        let ts = timestampMsFromValue(value["timestamp"]) ?? fallbackTs
        var msg = UsageMessage(
            client: "claude", modelId: model, providerId: "anthropic",
            timestampMs: ts, tokens: tokens, cost: 0.0)
        if let id = stringValue(message["id"]), let req = stringValue(value["requestId"]) {
            let key = "claude:\(id):\(req)"
            if let index = dedup[key] {
                // Per-field max merge; the first row keeps its timestamp
                // and model (usage_graph.rs:469-484).
                out[index].tokens.input = max(out[index].tokens.input, msg.tokens.input)
                out[index].tokens.output = max(out[index].tokens.output, msg.tokens.output)
                out[index].tokens.cacheRead = max(
                    out[index].tokens.cacheRead, msg.tokens.cacheRead)
                out[index].tokens.cacheWrite = max(
                    out[index].tokens.cacheWrite, msg.tokens.cacheWrite)
                return
            }
            dedup[key] = out.count
            msg.dedupKey = key
        }
        out.append(msg)
    }
    return out
}

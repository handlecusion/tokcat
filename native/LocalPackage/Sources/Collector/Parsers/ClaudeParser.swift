import DataSource
import Foundation

// Port of parse_claude / parse_claude_file (usage_graph.rs:406-488).

enum ClaudeParser: UsageParser {
    static let clientName = "claude"

    static func parse() -> [UsageMessage] {
        guard let home = homeDir() else { return [] }
        var out: [UsageMessage] = []
        let roots = [
            joinPath(joinPath(home, ".claude"), "projects"),
            joinPath(joinPath(home, ".claude"), "transcripts"),
        ]
        for root in roots {
            let files = collectFiles(root) { p in
                let ext = rustExtension(p)
                return ext == "jsonl" || ext == "json"
            }
            for file in files {
                out.append(contentsOf: parseClaudeFile(file))
            }
        }
        return out
    }
}

func parseClaudeFile(_ path: String) -> [UsageMessage] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    let fallbackTs = fileModifiedTimestampMs(path)
    var out: [UsageMessage] = []
    var dedup: [String: Int] = [:]
    for line in jsonlLines(data) {
        guard let value = JSONValue.parse(rustTrim(line)) else { continue }
        guard value["type"]?.asString == "assistant" else { continue }
        guard let message = value["message"] else { continue }
        guard let usage = message["usage"] else { continue }
        guard let model = stringValue(message["model"]) else { continue }
        let tokens = TokenBreakdown(
            input: max(i64Value(usage["input_tokens"]) ?? 0, 0),
            output: max(i64Value(usage["output_tokens"]) ?? 0, 0),
            cacheRead: max(i64Value(usage["cache_read_input_tokens"]) ?? 0, 0),
            cacheWrite: max(i64Value(usage["cache_creation_input_tokens"]) ?? 0, 0),
            reasoning: 0
        )
        if tokens.total <= 0 { continue }
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
                continue
            }
            dedup[key] = out.count
            msg.dedupKey = key
        }
        out.append(msg)
    }
    return out
}

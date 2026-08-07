import DataSource
import Foundation

// Port of parse_copilot / parse_copilot_file and the OTel attr helpers
// (usage_graph.rs:1328-1425, 2431-2455).

enum CopilotParser: UsageParser {
    static let clientName = "copilot"

    static func parse(_ cache: UsageCache?) -> [UsageMessage] {
        guard let home = homeDir() else { return [] }
        var files = collectFiles(joinPath(joinPath(home, ".copilot"), "otel")) {
            rustExtension($0) == "jsonl"
        }
        if let path = ProcessInfo.processInfo.environment["COPILOT_OTEL_FILE_EXPORTER_PATH"],
            isFile(path)
        {
            files.append(path)
        }
        return files.flatMap(parseCopilotFile)
    }
}

/// Port of attr_i64 (usage_graph.rs:2431-2436): first alias that yields a
/// number wins, else 0.
func attrI64(_ attrs: JSONValue, _ names: [String]) -> Int64 {
    for name in names {
        if let v = i64Value(attrs[name]) { return v }
    }
    return 0
}

/// Port of attr_string (usage_graph.rs:2438-2440).
func attrString(_ attrs: JSONValue, _ names: [String]) -> String? {
    for name in names {
        if let v = stringValue(attrs[name]) { return v }
    }
    return nil
}

/// Port of copilot_timestamp_ms (usage_graph.rs:2442-2455): hrTime-style
/// [sec, nanos] arrays first (an array whose first element is not numeric
/// aborts the whole lookup, like the Rust `?`), then scalar fallbacks.
func copilotTimestampMs(_ value: JSONValue) -> Int64? {
    for key in ["endTime", "startTime", "hrTime", "_hrTime", "time"] {
        if case .array(let parts)? = value[key] {
            guard let sec = i64Value(parts.first) else { return nil }
            let nanos = parts.count > 1 ? (i64Value(parts[1]) ?? 0) : 0
            return satMul(sec, 1000) + nanos / 1_000_000
        }
    }
    if let ts = timestampMsFromValue(value["timestamp"]) { return ts }
    if let ts = timestampMsFromValue(value["observedTimestamp"]) { return ts }
    if let n = i64Value(value["timeUnixNano"]), n > 0 { return n / 1_000_000 }
    return nil
}

/// Port of parse_copilot_file (usage_graph.rs:1347-1425).
func parseCopilotFile(_ path: String) -> [UsageMessage] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    let fallbackTs = fileModifiedTimestampMs(path)
    var out: [UsageMessage] = []
    for (index, line) in jsonlLines(data).enumerated() {
        guard let value = JSONValue.parse(rustTrim(line)) else { continue }
        guard let attrs = value["attributes"] else { continue }
        let input = attrI64(attrs, ["gen_ai.usage.input_tokens"])
        let output = attrI64(attrs, ["gen_ai.usage.output_tokens"])
        let cacheRead = attrI64(attrs, ["gen_ai.usage.cache_read.input_tokens"])
        let cacheWrite = attrI64(
            attrs,
            [
                "gen_ai.usage.cache_write.input_tokens",
                "gen_ai.usage.cache_creation.input_tokens",
            ])
        let reasoning = attrI64(
            attrs,
            [
                "gen_ai.usage.reasoning.output_tokens",
                "gen_ai.usage.reasoning_tokens",
            ])
        // Cache-read tokens are included in input; subtract the overlap.
        let cacheForInput = min(max(cacheRead, 0), max(input, 0))
        let tokens = TokenBreakdown(
            input: max(satSub(input, cacheForInput), 0),
            output: max(output, 0),
            cacheRead: max(cacheRead, 0),
            cacheWrite: max(cacheWrite, 0),
            reasoning: max(reasoning, 0))
        if tokens.total <= 0 { continue }
        let model =
            attrString(attrs, ["gen_ai.response.model", "gen_ai.request.model"]) ?? "unknown"
        let session =
            attrString(
                attrs,
                [
                    "gen_ai.conversation.id",
                    "copilot_chat.session_id",
                    "gen_ai.response.id",
                    "session.id",
                ]) ?? "unknown-session"
        let ts = copilotTimestampMs(value) ?? fallbackTs
        var msg = UsageMessage(
            client: "copilot", modelId: model, providerId: inferProvider(model),
            timestampMs: ts, tokens: tokens, cost: 0.0)
        let trace =
            stringValue(value["traceId"])
            ?? (value["spanContext"]).flatMap { stringValue($0["traceId"]) }
        let span =
            stringValue(value["spanId"])
            ?? (value["spanContext"]).flatMap { stringValue($0["spanId"]) }
        if let trace, let span {
            msg.dedupKey = "copilot:\(trace):\(span)"
        } else {
            msg.dedupKey = "copilot:\(session):\(ts):\(index)"
        }
        out.append(msg)
    }
    return out
}

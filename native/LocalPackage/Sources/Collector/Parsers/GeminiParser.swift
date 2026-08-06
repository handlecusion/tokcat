import DataSource
import Foundation

// Port of parse_gemini / parse_gemini_file / parse_gemini_jsonl /
// parse_gemini_value / build_gemini_message / build_gemini_stats_messages /
// build_gemini_stats_message (usage_graph.rs:1121-1326).

enum GeminiParser: UsageParser {
    static let clientName = "gemini"

    static func parse() -> [UsageMessage] {
        guard let home = homeDir() else { return [] }
        return collectFiles(joinPath(joinPath(home, ".gemini"), "tmp")) { p in
            let ext = rustExtension(p)
            return ext == "json" || ext == "jsonl"
        }
        .flatMap(parseGeminiFile)
    }
}

func parseGeminiFile(_ path: String) -> [UsageMessage] {
    let fallbackTs = fileModifiedTimestampMs(path)
    if rustExtension(path) == "jsonl" {
        return parseGeminiJSONL(path, fallbackTs: fallbackTs)
    }
    guard let data = readToString(path), let value = JSONValue.parse(data) else { return [] }
    return parseGeminiValue(value, fallbackTs: fallbackTs)
}

/// Port of parse_gemini_jsonl (usage_graph.rs:1150-1203). Per-message
/// type=="gemini" entries REPLACE earlier entries with the same id in place
/// (later wins — opposite of the global first-wins dedup).
func parseGeminiJSONL(_ path: String, fallbackTs: Int64) -> [UsageMessage] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    var out: [UsageMessage] = []
    var currentModel: String?
    var sessionId = rustFileStem(path) ?? "gemini"
    var directById: [String: Int] = [:]
    for line in jsonlLines(data) {
        guard let value = JSONValue.parse(rustTrim(line)) else { continue }
        if let id = stringValue(value["session_id"] ?? value["sessionId"]) {
            sessionId = id
        }
        if let model = stringValue(value["model"]) {
            currentModel = model
        }
        if value["type"]?.asString == "gemini" {
            if var msg = buildGeminiMessage(value, modelHint: currentModel, fallbackTs: fallbackTs)
            {
                msg.dedupKey = stringValue(value["id"]).map { "gemini:\($0)" }
                if let key = msg.dedupKey {
                    if let idx = directById[key] {
                        out[idx] = msg
                    } else {
                        directById[key] = out.count
                        out.append(msg)
                    }
                } else {
                    msg.dedupKey = "gemini:\(sessionId):\(out.count)"
                    out.append(msg)
                }
            }
            continue
        }
        if let stats = value["stats"] ?? value["result"]?["stats"] {
            out.append(
                contentsOf: buildGeminiStatsMessages(
                    stats, modelHint: currentModel, fallbackTs: fallbackTs))
        }
    }
    return out
}

/// Port of parse_gemini_value (usage_graph.rs:1205-1223).
func parseGeminiValue(_ value: JSONValue, fallbackTs: Int64) -> [UsageMessage] {
    if case .array(let messages)? = value["messages"] {
        return messages
            .filter { $0["type"]?.asString == "gemini" }
            .compactMap { buildGeminiMessage($0, modelHint: nil, fallbackTs: fallbackTs) }
    }
    if let message = buildGeminiMessage(value, modelHint: nil, fallbackTs: fallbackTs) {
        return [message]
    }
    if let stats = value["stats"] ?? value["result"]?["stats"] {
        return buildGeminiStatsMessages(
            stats, modelHint: stringValue(value["model"]), fallbackTs: fallbackTs)
    }
    return []
}

/// Port of build_gemini_message (usage_graph.rs:1225-1260). Cache tokens are
/// subtracted from input ONLY when the reported total equals
/// input+output+thoughts+tool (i.e. total is cache-inclusive); tool tokens
/// are folded into input.
func buildGeminiMessage(
    _ value: JSONValue, modelHint: String?, fallbackTs: Int64
) -> UsageMessage? {
    guard let tokens = value["tokens"] else { return nil }
    guard let model = stringValue(value["model"]) ?? modelHint else { return nil }
    let output = max(i64Value(tokens["output"]) ?? 0, 0)
    let reasoning = max(i64Value(tokens["thoughts"]) ?? 0, 0)
    let tool = max(i64Value(tokens["tool"]) ?? 0, 0)
    let cacheRead = max(i64Value(tokens["cached"]) ?? 0, 0)
    let inputRaw = max(i64Value(tokens["input"]) ?? 0, 0)
    let total = i64Value(tokens["total"])
    let inclusiveTotal = inputRaw + output + reasoning + tool
    let input: Int64
    if cacheRead > 0, total == inclusiveTotal {
        input = inputRaw - min(cacheRead, inputRaw)  // saturating_sub on non-negatives
    } else {
        input = inputRaw
    }
    let ts = timestampMsFromValue(value["timestamp"] ?? value["created_at"]) ?? fallbackTs
    return UsageMessage(
        client: "gemini", modelId: model, providerId: "google",
        timestampMs: ts,
        tokens: TokenBreakdown(
            input: input + tool,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: 0,
            reasoning: reasoning),
        cost: 0.0)
}

/// Port of build_gemini_stats_messages (usage_graph.rs:1262-1284): aggregate
/// stats.models entries, falling back to the flat stats shape with the
/// current model hint.
func buildGeminiStatsMessages(
    _ stats: JSONValue, modelHint: String?, fallbackTs: Int64
) -> [UsageMessage] {
    var out: [UsageMessage] = []
    if case .object(let models)? = stats["models"] {
        // serde_json objects preserve insertion order only with a feature
        // flag Tokcat does not enable, so Map iteration is BTreeMap-ordered
        // (sorted by key) — replicate that.
        for model in models.keys.sorted(by: utf8Less) {
            if let msg = buildGeminiStatsMessage(model, models[model]!, fallbackTs: fallbackTs) {
                out.append(msg)
            }
        }
        if !out.isEmpty {
            return out
        }
    }
    if let model = modelHint {
        if let msg = buildGeminiStatsMessage(model, stats, fallbackTs: fallbackTs) {
            out.append(msg)
        }
    }
    return out
}

/// Port of build_gemini_stats_message (usage_graph.rs:1286-1326): stamped at
/// the file mtime (fallback_ts).
func buildGeminiStatsMessage(
    _ model: String, _ value: JSONValue, fallbackTs: Int64
) -> UsageMessage? {
    let tokens = value["tokens"] ?? value
    let inputRaw =
        i64Value(tokens["prompt"]) ?? i64Value(tokens["input_tokens"])
        ?? i64Value(tokens["prompt_tokens"]) ?? i64Value(tokens["input"]) ?? 0
    let output =
        i64Value(tokens["candidates"]) ?? i64Value(tokens["output"])
        ?? i64Value(tokens["output_tokens"]) ?? 0
    let cacheRead = i64Value(tokens["cached"]) ?? i64Value(tokens["cached_tokens"]) ?? 0
    let reasoning =
        i64Value(tokens["thoughts"]) ?? i64Value(tokens["thoughts_tokens"])
        ?? i64Value(tokens["reasoning"]) ?? i64Value(tokens["reasoning_tokens"]) ?? 0
    if inputRaw == 0, output == 0, cacheRead == 0, reasoning == 0 {
        return nil
    }
    return UsageMessage(
        client: "gemini", modelId: model, providerId: "google",
        timestampMs: fallbackTs,
        tokens: TokenBreakdown(
            input: max(satSub(inputRaw, cacheRead), 0),
            output: max(output, 0),
            cacheRead: max(cacheRead, 0),
            cacheWrite: 0,
            reasoning: max(reasoning, 0)),
        cost: 0.0)
}

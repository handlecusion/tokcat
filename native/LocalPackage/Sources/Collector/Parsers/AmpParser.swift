import DataSource
import Foundation

// Port of parse_amp / parse_amp_file (usage_graph.rs:1427-1531).

enum AmpParser: UsageParser {
    static let clientName = "amp"

    static func parse() -> [UsageMessage] {
        guard let home = homeDir() else { return [] }
        let root = joinPath(joinPath(xdgDataHome(home), "amp"), "threads")
        return collectFiles(root) { p in
            guard let name = rustFileName(p) else { return false }
            return name.hasPrefix("T-") && name.hasSuffix(".json")
        }
        .flatMap(parseAmpFile)
    }
}

/// Port of parse_amp_file (usage_graph.rs:1442-1531): usageLedger.events wins
/// outright when it yields any messages; otherwise fall back to assistant
/// messages with a synthetic timestamp of thread_created + messageId*1000.
func parseAmpFile(_ path: String) -> [UsageMessage] {
    guard let data = readToString(path), let value = JSONValue.parse(data) else { return [] }
    let fallbackTs = fileModifiedTimestampMs(path)
    let threadCreated = i64Value(value["created"]) ?? fallbackTs
    let threadId = stringValue(value["id"]) ?? rustFileStem(path) ?? "amp"

    if case .array(let events)? = value["usageLedger"]?["events"] {
        var out: [UsageMessage] = []
        for (index, event) in events.enumerated() {
            guard let model = stringValue(event["model"]) else { continue }
            let tokensValue = event["tokens"] ?? .null
            let ts = timestampMsFromValue(event["timestamp"]) ?? threadCreated
            var msg = UsageMessage(
                client: "amp", modelId: model, providerId: inferProvider(model),
                timestampMs: ts,
                tokens: TokenBreakdown(
                    input: max(i64Value(tokensValue["input"]) ?? 0, 0),
                    output: max(i64Value(tokensValue["output"]) ?? 0, 0),
                    cacheRead: max(i64Value(tokensValue["cacheReadInputTokens"]) ?? 0, 0),
                    cacheWrite: max(i64Value(tokensValue["cacheCreationInputTokens"]) ?? 0, 0),
                    reasoning: 0),
                cost: f64Value(event["credits"]) ?? 0.0)
            msg.dedupKey = "amp:\(threadId):ledger:\(index)"
            out.append(msg)
        }
        if !out.isEmpty {
            return out
        }
    }

    guard case .array(let messages)? = value["messages"] else { return [] }
    return messages
        .filter { $0["role"]?.asString == "assistant" }
        .compactMap { m -> UsageMessage? in
            guard let usage = m["usage"] else { return nil }
            guard let model = stringValue(usage["model"]) else { return nil }
            let messageId = i64Value(m["messageId"]) ?? 0
            var msg = UsageMessage(
                client: "amp", modelId: model, providerId: inferProvider(model),
                timestampMs: satAdd(threadCreated, satMul(messageId, 1000)),
                tokens: TokenBreakdown(
                    input: max(i64Value(usage["inputTokens"]) ?? 0, 0),
                    output: max(i64Value(usage["outputTokens"]) ?? 0, 0),
                    cacheRead: max(i64Value(usage["cacheReadInputTokens"]) ?? 0, 0),
                    cacheWrite: max(i64Value(usage["cacheCreationInputTokens"]) ?? 0, 0),
                    reasoning: 0),
                cost: f64Value(usage["credits"]) ?? 0.0)
            msg.dedupKey = "amp:\(threadId):message:\(messageId)"
            return msg
        }
}

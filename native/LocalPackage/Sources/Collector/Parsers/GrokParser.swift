import DataSource
import Foundation

// Port of the Grok Build session parser (usage_graph.rs:1591-2074).
//
// Grok writes JSON-RPC session updates under
// `$GROK_HOME/sessions/<urlencoded-workspace>/<session-id>/updates.jsonl`
// (default home: `~/.grok`). Logs expose a cumulative `totalTokens` counter
// without a stable input/output split, so per-turn positive total-token
// deltas are recorded as INPUT tokens. Sibling `signals.json` may report
// totals that include compaction history; any remainder is reconciled as a
// separate message so compacted sessions are not under-counted.

enum GrokParser: UsageParser {
    static let clientName = "grok"

    static func parse() -> [UsageMessage] {
        guard let home = grokHome() else { return [] }
        let sessions = joinPath(home, "sessions")
        guard isDirectory(sessions) else { return [] }
        return collectFiles(sessions) { rustFileName($0) == "updates.jsonl" }
            .flatMap(parseGrokUpdatesFile)
    }
}

/// Port of grok_home (usage_graph.rs:1619-1628).
func grokHome() -> String? {
    if let home = ProcessInfo.processInfo.environment["GROK_HOME"], isDirectory(home) {
        return home
    }
    guard let home = homeDir() else { return nil }
    let p = joinPath(home, ".grok")
    return isDirectory(p) ? p : nil
}

let grokUnknownModel = "grok-unknown"

struct GrokMetadata {
    var sessionId: String
    /// Percent-encoded workspace directory name under `sessions/`, used in
    /// dedup keys so the same session id under different cwd roots does not
    /// collide globally.
    var workspaceKey: String
    var modelId: String?
    var timestampMs: Int64
}

struct GrokActiveTurn {
    var baselineTotal: Int64
    var maxTotal: Int64
    var timestampMs: Int64
    var modelId: String
    var turnIndex: Int

    init(baselineTotal: Int64, timestampMs: Int64, modelId: String, turnIndex: Int) {
        self.baselineTotal = baselineTotal
        self.maxTotal = baselineTotal
        self.timestampMs = timestampMs
        self.modelId = modelId
        self.turnIndex = turnIndex
    }

    mutating func observeTotal(_ total: Int64, timestampMs: Int64) {
        if total > maxTotal {
            maxTotal = total
            self.timestampMs = timestampMs
        }
    }

    func intoMessage(_ metadata: GrokMetadata) -> UsageMessage? {
        let tokenDelta = satSub(maxTotal, baselineTotal)
        if tokenDelta <= 0 { return nil }
        let modelId = rustTrim(self.modelId).isEmpty ? grokUnknownModel : self.modelId
        var msg = UsageMessage(
            client: "grok", modelId: modelId, providerId: "xai",
            timestampMs: timestampMs,
            tokens: TokenBreakdown(
                input: tokenDelta, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0),
            cost: 0.0)
        msg.dedupKey = "grok:\(metadata.workspaceKey):\(metadata.sessionId):\(turnIndex)"
        return msg
    }
}

/// Port of parse_grok_updates_file (usage_graph.rs:1702-1822): a turn is the
/// high-water-mark delta between user_message_chunk boundaries; dips never
/// lower the mark; a whole-file aggregate stands in when no turns emerged.
func parseGrokUpdatesFile(_ path: String) -> [UsageMessage] {
    guard rustFileName(path) == "updates.jsonl" else { return [] }

    let metadata = readGrokMetadata(path)
    guard let data = FileManager.default.contents(atPath: path) else { return [] }

    var messages: [UsageMessage] = []
    var currentModel = metadata.modelId ?? grokUnknownModel
    var lastTotal: Int64?
    var lastTotalTimestamp = metadata.timestampMs
    var activeTurn: GrokActiveTurn?
    var turnIndex = 0

    for line in jsonlLines(data) {
        if rustTrim(line).isEmpty { continue }
        guard let value = JSONValue.parse(line) else { continue }

        if let modelId = extractGrokModelId(value) {
            currentModel = modelId
            // Mid-file model discovery backfills an active unknown-model turn.
            if activeTurn?.modelId == grokUnknownModel {
                activeTurn?.modelId = currentModel
            }
        }

        let timestamp = extractGrokTimestampMs(value) ?? metadata.timestampMs
        if isGrokUserMessageChunk(value) {
            if let turn = activeTurn {
                activeTurn = nil
                if let message = turn.intoMessage(metadata) {
                    messages.append(message)
                }
            }
            activeTurn = GrokActiveTurn(
                baselineTotal: lastTotal ?? 0,
                timestampMs: timestamp,
                modelId: currentModel,
                turnIndex: turnIndex)
            turnIndex += 1
        }

        guard let totalTokens = extractGrokTotalTokens(value) else { continue }
        if totalTokens < 0 { continue }

        switch lastTotal {
        case .some(let previous) where totalTokens < previous:
            // Transient stream rewinds can dip below the high-water mark.
            // Keep last_total so recovering totals are not double-counted;
            // compaction remainder is reconciled via signals.json.
            continue
        case .some(let previous) where totalTokens == previous:
            lastTotalTimestamp = timestamp
        case .some(let previous):
            if activeTurn == nil {
                activeTurn = GrokActiveTurn(
                    baselineTotal: previous,
                    timestampMs: timestamp,
                    modelId: currentModel,
                    turnIndex: turnIndex)
                turnIndex += 1
            }
            activeTurn?.observeTotal(totalTokens, timestampMs: timestamp)
            lastTotalTimestamp = timestamp
            lastTotal = totalTokens
        case .none:
            activeTurn?.observeTotal(totalTokens, timestampMs: timestamp)
            lastTotalTimestamp = timestamp
            lastTotal = totalTokens
        }
    }

    if let turn = activeTurn {
        if let message = turn.intoMessage(metadata) {
            messages.append(message)
        }
    }

    if messages.isEmpty, let totalTokens = lastTotal, totalTokens > 0 {
        // Whole-file aggregate fallback when no turns were detected.
        var aggregateTurn = GrokActiveTurn(
            baselineTotal: 0,
            timestampMs: lastTotalTimestamp,
            modelId: currentModel,
            turnIndex: 0)
        aggregateTurn.maxTotal = totalTokens
        if let message = aggregateTurn.intoMessage(metadata) {
            messages.append(message)
        }
    }

    appendGrokSignalsReconciliation(
        updatesPath: path, metadata: metadata, messages: &messages,
        fallbackModel: currentModel)
    return messages
}

/// Port of read_grok_metadata (usage_graph.rs:1824-1864): metadata ladder
/// summary.json -> events.jsonl (first 500 lines) -> signals.json.
func readGrokMetadata(_ path: String) -> GrokMetadata {
    let sessionDir = parentPath(path)
    let sessionId =
        sessionDir.flatMap(rustFileName).flatMap { !rustTrim($0).isEmpty ? $0 : nil }
        ?? "unknown"
    // sessions/<urlencoded-workspace>/<session-id>/updates.jsonl
    let workspaceKey =
        sessionDir.flatMap(parentPath).flatMap(rustFileName)
            .flatMap { !rustTrim($0).isEmpty ? $0 : nil }
        ?? "unknown"

    var metadata = GrokMetadata(
        sessionId: sessionId,
        workspaceKey: workspaceKey,
        modelId: nil,
        timestampMs: fileModifiedTimestampMs(path))

    if let summaryPath = grokSibling(path, "summary.json") {
        readGrokSummaryMetadata(summaryPath, &metadata)
    }
    // events.jsonl is a compact session journal; use it only as a fallback
    // when summary is missing model/session identity (tokscale parity).
    if metadata.modelId == nil || metadata.sessionId == "unknown" {
        if let eventsPath = grokSibling(path, "events.jsonl") {
            readGrokEventsMetadata(eventsPath, &metadata)
        }
    }
    if let signalsPath = grokSibling(path, "signals.json") {
        readGrokSignalsMetadata(signalsPath, &metadata)
    }

    return metadata
}

/// Port of read_grok_events_metadata (usage_graph.rs:1866-1894).
func readGrokEventsMetadata(_ path: String, _ metadata: inout GrokMetadata) {
    guard let data = FileManager.default.contents(atPath: path) else { return }
    for line in jsonlLines(data).prefix(500) {
        guard let value = JSONValue.parse(line) else { continue }
        if metadata.modelId == nil {
            metadata.modelId =
                stringValue(value["model_id"]) ?? stringValue(value["modelId"])
        }
        if metadata.sessionId == "unknown" {
            if let sessionId = stringValue(value["session_id"]) ?? stringValue(value["sessionId"])
            {
                metadata.sessionId = sessionId
            }
        }
        if let timestamp = timestampMsFromValue(value["ts"])
            ?? timestampMsFromValue(value["timestamp"])
        {
            metadata.timestampMs = timestamp
        }
        if metadata.modelId != nil, metadata.sessionId != "unknown" {
            break
        }
    }
}

/// Port of read_grok_summary_metadata (usage_graph.rs:1896-1914).
func readGrokSummaryMetadata(_ path: String, _ metadata: inout GrokMetadata) {
    guard let data = readToString(path), let value = JSONValue.parse(data) else { return }
    if metadata.modelId == nil {
        metadata.modelId =
            stringValue(value["current_model_id"]) ?? stringValue(value["model_id"])
    }
    if let timestamp = timestampMsFromValue(value["updated_at"])
        ?? timestampMsFromValue(value["created_at"])
        ?? timestampMsFromValue(value["last_active_at"])
    {
        metadata.timestampMs = timestamp
    }
}

/// Port of read_grok_signals_metadata (usage_graph.rs:1916-1926).
func readGrokSignalsMetadata(_ path: String, _ metadata: inout GrokMetadata) {
    guard let data = readToString(path), let value = JSONValue.parse(data) else { return }
    if metadata.modelId == nil {
        metadata.modelId = modelIdFromGrokSignals(value)
    }
}

/// Port of model_id_from_grok_signals (usage_graph.rs:1928-1936).
func modelIdFromGrokSignals(_ value: JSONValue) -> String? {
    if let primary = stringValue(value["primaryModelId"]) { return primary }
    if case .array(let models)? = value["modelsUsed"], let first = models.first {
        return stringValue(first)
    }
    return nil
}

func nonNegativeI64(_ value: JSONValue?) -> Int64 {
    max(i64Value(value) ?? 0, 0)
}

/// Port of effective_total_from_grok_signals (usage_graph.rs:1942-1949):
/// before+total when contextTokensUsed is absent, else
/// max(total, before+context).
func effectiveTotalFromGrokSignals(_ value: JSONValue) -> Int64 {
    let before = nonNegativeI64(value["totalTokensBeforeCompaction"])
    let total = nonNegativeI64(value["totalTokens"])
    switch value["contextTokensUsed"] {
    case .none:
        return satAdd(before, total)
    case .some(let ctx):
        return max(total, satAdd(before, nonNegativeI64(ctx)))
    }
}

/// Port of append_grok_signals_reconciliation (usage_graph.rs:1951-2010):
/// synthetic `...:signals` message timestamped at the MAX update timestamp
/// (NOT signals.json mtime) so live rewrites do not migrate the extra onto a
/// new day each rescan.
func appendGrokSignalsReconciliation(
    updatesPath: String, metadata: GrokMetadata, messages: inout [UsageMessage],
    fallbackModel: String
) {
    guard let signalsPath = grokSibling(updatesPath, "signals.json"),
        let data = readToString(signalsPath),
        let value = JSONValue.parse(data)
    else { return }

    let signalsTotal = effectiveTotalFromGrokSignals(value)
    if signalsTotal <= 0 { return }

    let updatesTotal = messages.reduce(Int64(0)) { $0 + $1.tokens.input }
    let extra = satSub(signalsTotal, updatesTotal)
    if extra <= 0 { return }

    let modelId =
        modelIdFromGrokSignals(value).flatMap { rustTrim($0).isEmpty ? nil : $0 }
        ?? metadata.modelId
        ?? fallbackModel
    let timestamp = messages.map(\.timestampMs).max() ?? metadata.timestampMs

    var msg = UsageMessage(
        client: "grok", modelId: modelId, providerId: "xai",
        timestampMs: timestamp,
        tokens: TokenBreakdown(input: extra, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0),
        cost: 0.0)
    msg.dedupKey = "grok:\(metadata.workspaceKey):\(metadata.sessionId):signals"
    messages.append(msg)
}

/// `Path::parent()` for the absolute paths used here.
func parentPath(_ path: String) -> String? {
    guard let slash = path.lastIndex(of: "/") else { return nil }
    if slash == path.startIndex { return path == "/" ? nil : "/" }
    return String(path[..<slash])
}

func grokSibling(_ path: String, _ fileName: String) -> String? {
    parentPath(path).map { joinPath($0, fileName) }
}

func jsonPath(_ value: JSONValue, _ path: [String]) -> JSONValue? {
    var current: JSONValue? = value
    for key in path {
        current = current?[key]
        if current == nil { return nil }
    }
    return current
}

/// Port of extract_grok_model_id (usage_graph.rs:2021-2038).
func extractGrokModelId(_ value: JSONValue) -> String? {
    let paths: [[String]] = [
        ["params", "update", "content", "_meta", "modelId"],
        ["params", "update", "_meta", "modelId"],
        ["params", "_meta", "modelId"],
        ["params", "modelId"],
        ["model_id"],
        ["modelId"],
        ["model"],
    ]
    for path in paths {
        if let modelId = stringValue(jsonPath(value, path)), !rustTrim(modelId).isEmpty {
            return modelId
        }
    }
    return nil
}

/// Port of extract_grok_total_tokens (usage_graph.rs:2040-2054).
func extractGrokTotalTokens(_ value: JSONValue) -> Int64? {
    let paths: [[String]] = [
        ["params", "_meta", "totalTokens"],
        ["params", "update", "_meta", "totalTokens"],
        ["params", "update", "totalTokens"],
        ["params", "totalTokens"],
        ["usage", "totalTokens"],
        ["totalTokens"],
    ]
    for path in paths {
        if let total = i64Value(jsonPath(value, path)) {
            return total
        }
    }
    return nil
}

/// Port of extract_grok_timestamp_ms (usage_graph.rs:2056-2069).
func extractGrokTimestampMs(_ value: JSONValue) -> Int64? {
    let paths: [[String]] = [
        ["params", "_meta", "agentTimestampMs"],
        ["params", "update", "_meta", "agentTimestampMs"],
        ["params", "timestamp"],
        ["timestamp"],
        ["ts"],
    ]
    for path in paths {
        if let timestamp = timestampMsFromValue(jsonPath(value, path)) {
            return timestamp
        }
    }
    return nil
}

/// Port of is_grok_user_message_chunk (usage_graph.rs:2071-2074).
func isGrokUserMessageChunk(_ value: JSONValue) -> Bool {
    jsonPath(value, ["params", "update", "sessionUpdate"])?.asString == "user_message_chunk"
}

import DataSource
import Foundation

// Port of parse_codex / CodexTotals / parse_codex_file and the forked-child
// baseline helpers (usage_graph.rs:490-811).

enum CodexParser: UsageParser {
    static let clientName = "codex"

    static func parse(_ cache: UsageCache?) -> [UsageMessage] {
        guard let home = homeDir() else { return [] }
        let env = ProcessInfo.processInfo.environment

        var codexHomes = [env["CODEX_HOME"] ?? joinPath(home, ".codex")]
        // Orca runs Codex with CODEX_HOME redirected to its own runtime home;
        // scan Orca's known Codex homes so sessions started inside Orca count.
        codexHomes.append(contentsOf: orcaCodexHomes(home))
        // Extra homes can be listed (path-separated) for other launchers.
        if let extra = env["TOKCAT_CODEX_HOMES"] {
            codexHomes.append(
                contentsOf: extra.split(separator: ":", omittingEmptySubsequences: false)
                    .map(String.init))
        }

        var roots: [String] = []
        for codexHome in codexHomes {
            roots.append(joinPath(codexHome, "sessions"))
            roots.append(joinPath(codexHome, "archived_sessions"))
        }
        // Legacy env var kept so existing headless exports remain counted.
        if let headless = env["TOKSCALE_HEADLESS_DIR"] {
            roots.append(joinPath(headless, "codex"))
        }

        // Drop duplicate roots (a launcher-provided CODEX_HOME may already
        // point at an Orca home); content dedup also runs downstream.
        var seen = Set<String>()
        var files: [String] = []
        for root in roots {
            guard seen.insert(root).inserted else { continue }
            files.append(contentsOf: collectFiles(root) { rustExtension($0) == "jsonl" })
        }
        // The delta state machine below is per-file, so files parse
        // independently; parseFilesInOrder keeps the root/path order the
        // downstream first-wins dedup depends on.
        return parseFilesInOrder(files, cache: cache, parseCodexFile)
    }
}

struct CodexTotals: Equatable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cached: Int64 = 0
    var reasoning: Int64 = 0

    static func fromUsage(_ value: JSONValue) -> CodexTotals {
        CodexTotals(
            input: max(i64Value(value["input_tokens"]) ?? 0, 0),
            output: max(i64Value(value["output_tokens"]) ?? 0, 0),
            cached: max(
                max(
                    i64Value(value["cached_input_tokens"]) ?? 0,
                    i64Value(value["cache_read_input_tokens"]) ?? 0),
                0),
            reasoning: max(i64Value(value["reasoning_output_tokens"]) ?? 0, 0)
        )
    }

    func deltaFrom(_ previous: CodexTotals) -> CodexTotals? {
        if input < previous.input || output < previous.output || cached < previous.cached
            || reasoning < previous.reasoning
        {
            return nil
        }
        return CodexTotals(
            input: input - previous.input,
            output: output - previous.output,
            cached: cached - previous.cached,
            reasoning: reasoning - previous.reasoning)
    }

    func saturatingAdd(_ other: CodexTotals) -> CodexTotals {
        CodexTotals(
            input: satAdd(input, other.input),
            output: satAdd(output, other.output),
            cached: satAdd(cached, other.cached),
            reasoning: satAdd(reasoning, other.reasoning))
    }

    var total: Int64 {
        satAdd(satAdd(satAdd(input, output), cached), reasoning)
    }

    /// Stale-regression heuristic (usage_graph.rs:593-604):
    /// `current*100 >= previous*98 || current + last*2 >= previous`.
    func looksLikeStaleRegression(previous: CodexTotals, last: CodexTotals) -> Bool {
        let previousTotal = previous.total
        let currentTotal = total
        let lastTotal = last.total
        if previousTotal <= 0 || currentTotal <= 0 || lastTotal <= 0 { return false }
        return satMul(currentTotal, 100) >= satMul(previousTotal, 98)
            || satAdd(currentTotal, satMul(lastTotal, 2)) >= previousTotal
    }

    /// cached counts are a subset of input; subtract to avoid double count
    /// (usage_graph.rs:606-615).
    func intoTokens() -> TokenBreakdown {
        let cacheRead = max(min(cached, input), 0)
        return TokenBreakdown(
            input: max(input - cacheRead, 0),
            output: max(output, 0),
            cacheRead: cacheRead,
            cacheWrite: 0,
            reasoning: max(reasoning, 0))
    }
}

@Sendable func parseCodexFile(_ path: String) -> [UsageMessage] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    let fallbackTs = fileModifiedTimestampMs(path)
    var currentModel: String?
    var previousTotals: CodexTotals?
    var provider = "openai"
    var forkedChildWaitingForTurnContext = false
    var forkedChildInheritedBaseline: CodexTotals?
    var forkedChildInheritedReportedTotal: Int64?
    var out: [UsageMessage] = []

    forEachJSONLLine(data) { line in
        guard let value = parseTrimmedJSONLine(line) else { return }
        let entryType = value["type"]?.asString ?? ""
        let payload = value["payload"] ?? .null

        if entryType == "session_meta" {
            if let p = stringValue(payload["model_provider"]) {
                provider = p
            }
            if stringValue(payload["forked_from_id"]) != nil {
                forkedChildWaitingForTurnContext = true
                forkedChildInheritedBaseline = nil
                forkedChildInheritedReportedTotal = nil
            }
        }

        if forkedChildWaitingForTurnContext {
            if entryType == "turn_context" {
                forkedChildWaitingForTurnContext = false
            } else {
                if entryType == "event_msg",
                    payload["type"]?.asString == "token_count",
                    let info = payload["info"]
                {
                    rememberCodexForkedChildInheritedBaseline(
                        info: info,
                        previousTotals: &previousTotals,
                        forkedChildInheritedBaseline: &forkedChildInheritedBaseline,
                        forkedChildInheritedReportedTotal: &forkedChildInheritedReportedTotal)
                }
                return
            }
        }

        if entryType == "turn_context" {
            // NOTE: the or-chain picks the first PRESENT key even if its
            // value later fails string_value, exactly like the Rust
            // Option<&Value> chain.
            let candidate =
                payload["model_info"]?["slug"] ?? payload["model"] ?? payload["model_name"]
            if let model = stringValue(candidate) {
                currentModel = model
            }
            return
        }

        guard entryType == "event_msg", payload["type"]?.asString == "token_count" else {
            return
        }
        guard let info = payload["info"] else { return }
        let model =
            stringValue(info["model"]) ?? stringValue(info["model_name"]) ?? currentModel
            ?? "unknown"
        if model != "unknown" {
            currentModel = model
        }
        let totalUsageValue = info["total_token_usage"]
        let totalUsage = totalUsageValue.map(CodexTotals.fromUsage)
        let lastUsage = info["last_token_usage"].map(CodexTotals.fromUsage)

        if codexForkedChildMatchesInheritedBaseline(
            totalUsageValue: totalUsageValue,
            totalUsage: totalUsage,
            forkedChildInheritedBaseline: forkedChildInheritedBaseline,
            forkedChildInheritedReportedTotal: forkedChildInheritedReportedTotal)
        {
            if let total = totalUsage {
                previousTotals = total
            }
            forkedChildInheritedBaseline = nil
            forkedChildInheritedReportedTotal = nil
            return
        }
        forkedChildInheritedBaseline = nil
        forkedChildInheritedReportedTotal = nil

        // The 7-branch delta state machine (usage_graph.rs:723-753), ported
        // as a literal switch.
        let tokens: TokenBreakdown
        let nextTotals: CodexTotals?
        switch (totalUsage, lastUsage, previousTotals) {
        case (.some(let total), .some(let last), .some(let previous)):
            if total == previous { return }
            if total.deltaFrom(previous) == nil,
                total.looksLikeStaleRegression(previous: previous, last: last)
            {
                return
            }
            tokens = last.intoTokens()
            nextTotals = total
        case (.some(let total), .some(let last), .none):
            tokens = last.intoTokens()
            nextTotals = total
        case (.some(let total), .none, .some(let previous)):
            if total == previous { return }
            if let delta = total.deltaFrom(previous) {
                tokens = delta.intoTokens()
                nextTotals = total
            } else {
                previousTotals = total
                return
            }
        case (.some(let total), .none, .none):
            tokens = total.intoTokens()
            nextTotals = total
        case (.none, .some(let last), .some(let previous)):
            tokens = last.intoTokens()
            nextTotals = previous.saturatingAdd(last)
        case (.none, .some(let last), .none):
            tokens = last.intoTokens()
            nextTotals = nil
        case (.none, .none, _):
            return
        }
        if tokens.total <= 0 { return }
        previousTotals = nextTotals
        let ts = timestampMsFromValue(value["timestamp"]) ?? fallbackTs
        var msg = UsageMessage(
            client: "codex", modelId: model, providerId: provider,
            timestampMs: ts, tokens: tokens, cost: 0.0)
        msg.dedupKey =
            "codex:\(msg.timestampMs):\(msg.modelId):\(msg.tokens.input):"
            + "\(msg.tokens.output):\(msg.tokens.cacheRead)"
        out.append(msg)
    }
    return out
}

func rememberCodexForkedChildInheritedBaseline(
    info: JSONValue,
    previousTotals: inout CodexTotals?,
    forkedChildInheritedBaseline: inout CodexTotals?,
    forkedChildInheritedReportedTotal: inout Int64?
) {
    guard let totalUsage = info["total_token_usage"] else { return }
    let totals = CodexTotals.fromUsage(totalUsage)
    previousTotals = totals
    forkedChildInheritedBaseline = totals
    forkedChildInheritedReportedTotal = codexReportedTotalTokens(totalUsage)
}

func codexForkedChildMatchesInheritedBaseline(
    totalUsageValue: JSONValue?,
    totalUsage: CodexTotals?,
    forkedChildInheritedBaseline: CodexTotals?,
    forkedChildInheritedReportedTotal: Int64?
) -> Bool {
    if let usage = totalUsageValue, let baseline = forkedChildInheritedReportedTotal {
        if codexReportedTotalTokens(usage) == baseline {
            return true
        }
    }
    if let totals = totalUsage, let baseline = forkedChildInheritedBaseline {
        return totals == baseline
    }
    return false
}

func codexReportedTotalTokens(_ usage: JSONValue) -> Int64? {
    guard let total = i64Value(usage["total_tokens"]), total >= 0 else { return nil }
    return total
}

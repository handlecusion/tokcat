import DataSource
import Foundation

// omnirush harness. Swift-only client: there is no Rust counterpart in
// src-tauri, so "omnirush" is deliberately absent from the parity rosters
// (scripts/parity-check.sh, tokcat-dump's default --clients) — same as omp.
//
// omnirush is the oh-my-pi engine under a different brand and writes the same
// entry logs (see OmpParser):
//
//   <agent-dir>/sessions/<encoded-cwd>/<timestamp>_<sessionId>.jsonl
//   <agent-dir>/sessions/<encoded-cwd>/subagents/<timestamp>_<sessionId>.jsonl
//
// The second form is a subagent transcript, collected into a `subagents/`
// directory beside its parent session (omp nests `<sessionId>/<agent>.jsonl`
// instead, and omnirush records only the parent session id in the
// `omnirush-subagent` custom entry — never the child's agent name).
//
// Only `type == "message"` entries with an assistant `message.usage` object
// carry spend; each one is a single API response, so the values are per-call
// deltas (never cumulative) and are summed as-is. omnirush also records the
// price it computed for the call, which is authoritative — the bundled price
// table cannot know the account's provider routing, and omnirush's own models
// (`gpt-6-astra`, `gpt-6-sol`, `muse-spark-*`) are absent from LiteLLM — so it
// is passed through and `collectMessages` leaves it alone.

enum OmnirushParser: UsageParser {
    static let clientName = "omnirush"

    static func parse(_ cache: UsageCache?) -> [UsageMessage] {
        var files: [String] = []
        var seen = Set<String>()
        for root in omnirushSessionRoots() {
            guard seen.insert(root).inserted else { continue }
            files.append(contentsOf: collectFiles(root) { rustExtension($0) == "jsonl" })
        }
        // Every entry is self-contained, so per-file parsing is pure and
        // cacheable; parseFilesInOrder keeps root order for first-wins dedup.
        return parseFilesInOrder(files, cache: cache, parseOmnirushFile)
    }
}

/// omnirush's agent directories. `OMNIRUSH_AGENT_DIR` overrides the whole agent
/// dir and `OMNIRUSH_DIR` moves the state root it sits under; both are
/// documented by `omnirush --help` ("agent data dir override (default
/// ~/.omnirush/agent)", "state dir override (default ~/.omnirush)"). The engine
/// also reads the `OMNIRUSH_CODING_AGENT_DIR` spelling of the first, so accept
/// it as a fallback rather than silently dropping every session.
/// `TOKCAT_OMNIRUSH_HOMES` is a colon-separated list of extra agent dirs,
/// matching the `TOKCAT_CODEX_HOMES`/`TOKCAT_OMP_HOMES` escape hatches.
func omnirushAgentHomes() -> [String] {
    let env = ProcessInfo.processInfo.environment
    // Env values are trimmed, not just emptiness-checked: a stray space from a
    // shell export or a dotenv file would otherwise build a path that never
    // resolves and silently drop every omnirush session.
    func trimmedEnv(_ key: String) -> String? {
        guard let raw = env[key] else { return nil }
        let value = rustTrim(raw)
        return value.isEmpty ? nil : value
    }
    var homes: [String] = []
    if let dir = trimmedEnv("OMNIRUSH_AGENT_DIR") ?? trimmedEnv("OMNIRUSH_CODING_AGENT_DIR") {
        homes.append(dir)
    } else if let home = homeDir() {
        let configRoot = trimmedEnv("OMNIRUSH_DIR") ?? ".omnirush"
        // Documented as a path under home, but an absolute path is the obvious
        // misreading of "state dir override" — honor it rather than
        // concatenating it onto $HOME.
        let root = configRoot.hasPrefix("/") ? configRoot : joinPath(home, configRoot)
        homes.append(joinPath(root, "agent"))
    }
    if let extra = env["TOKCAT_OMNIRUSH_HOMES"] {
        homes.append(
            contentsOf: extra.split(separator: ":", omittingEmptySubsequences: true)
                .map { rustTrim(String($0)) }
                .filter { !$0.isEmpty })
    }
    return homes
}

func omnirushSessionRoots() -> [String] {
    omnirushAgentHomes().map { joinPath($0, "sessions") }
}

@Sendable func parseOmnirushFile(_ path: String) -> [UsageMessage] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    let fallbackTs = fileModifiedTimestampMs(path)
    // Session id from the file stem for the main transcript, prefixed by the
    // `subagents` bucket for a nested subagent transcript — either way it is
    // the part that makes an 8-char entry id unique across the machine.
    let scope = omnirushFileScope(path)
    var out: [UsageMessage] = []

    forEachJSONLLine(data) { line in
        guard let value = parseTrimmedJSONLine(line) else { return }
        guard value["type"]?.asString == "message" else { return }
        guard let message = value["message"] else { return }
        guard message["role"]?.asString == "assistant" else { return }
        guard let usage = message["usage"] else { return }

        let tokens = TokenBreakdown(
            input: max(i64Value(usage["input"]) ?? 0, 0),
            output: max(i64Value(usage["output"]) ?? 0, 0),
            cacheRead: max(i64Value(usage["cacheRead"]) ?? 0, 0),
            cacheWrite: max(i64Value(usage["cacheWrite"]) ?? 0, 0))
        if tokens.total <= 0 { return }

        let model = stringValue(message["model"]) ?? "unknown"
        // `provider` is omnirush's routing id ("omnirush" for its own gateway,
        // or the upstream the engine proxies). Leaving it empty for anything
        // the pricing table does not key on lets collectMessages infer it from
        // the model.
        let provider = omnirushProvider(stringValue(message["provider"]))
        // Entry timestamps are RFC3339; the inner message timestamp is epoch
        // millis and is the one omnirush treats as the response time.
        let ts =
            timestampMsFromValue(message["timestamp"])
            ?? timestampMsFromValue(value["timestamp"])
            ?? fallbackTs
        let cost = max(f64Value(usage["cost"]?["total"]) ?? 0.0, 0.0)

        var msg = UsageMessage(
            client: "omnirush", modelId: model, providerId: provider,
            timestampMs: ts, tokens: tokens, cost: cost)
        // responseId is the provider's own id and is unique per call; entry
        // ids are only unique within a session, hence the scope prefix.
        if let responseId = stringValue(message["responseId"]), !responseId.isEmpty {
            msg.dedupKey = "omnirush:\(responseId)"
        } else if let entryId = stringValue(value["id"]), !entryId.isEmpty {
            msg.dedupKey = "omnirush:\(scope):\(entryId)"
        }
        out.append(msg)
    }
    return out
}

/// `<session-id>` for a main transcript, `<cwd-bucket>/subagents/<session-id>`
/// for a subagent one. Used only to scope entry ids, so a missing stem is fine.
func omnirushFileScope(_ path: String) -> String {
    let stem = rustFileStem(path) ?? path
    let parent = (path as NSString).deletingLastPathComponent
    guard let bucket = rustFileName(parent), omnirushIsSubagentDirName(bucket) else {
        return stem
    }
    let grandparent = (parent as NSString).deletingLastPathComponent
    if let cwd = rustFileName(grandparent), cwd.hasPrefix("-") {
        return "\(cwd)/\(bucket)/\(stem)"
    }
    return "\(bucket)/\(stem)"
}

/// Subagent transcripts live in a `subagents` directory under the cwd bucket
/// (cwd buckets themselves always start with `-`, the encoded-path scheme the
/// engine shares with oh-my-pi).
func omnirushIsSubagentDirName(_ name: String) -> Bool {
    name == "subagents"
}

/// Map omnirush's routing provider onto the ids `bundledPrice`/`inferProvider`
/// understand. Its own gateway and the aggregators it proxies are left blank so
/// the model string decides, which is what the pricing table keys on anyway.
func omnirushProvider(_ raw: String?) -> String {
    guard let raw else { return "" }
    let provider = rustTrim(raw).lowercased()
    switch provider {
    case "anthropic", "anthropic-messages", "claude": return "anthropic"
    case "openai", "azure", "azure-openai": return "openai"
    case "google", "google-vertex", "google-gemini", "gemini": return "google"
    case "xai": return "xai"
    default: return ""
    }
}

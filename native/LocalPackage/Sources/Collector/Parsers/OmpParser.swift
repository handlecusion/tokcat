import DataSource
import Foundation

// oh-my-pi (omp) harness. Swift-only client: there is no Rust counterpart in
// src-tauri, so "omp" is deliberately absent from the parity rosters
// (scripts/parity-check.sh, tokcat-dump's default --clients).
//
// Sessions are JSONL entry logs (docs: omp://session.md):
//
//   <agent-dir>/sessions/<encoded-cwd>/<timestamp>_<sessionId>.jsonl
//   <agent-dir>/sessions/<encoded-cwd>/<timestamp>_<sessionId>/<agent>.jsonl
//
// The second form is a subagent transcript nested beside its parent session.
// Only `type == "message"` entries with an assistant `message.usage` object
// carry spend; each one is a single API response, so the values are per-call
// deltas (never cumulative) and are summed as-is. omp also records the price
// it computed for the call, which is authoritative — the bundled price table
// cannot know the user's provider routing — so it is passed through and
// `collectMessages` leaves it alone.

enum OmpParser: UsageParser {
    static let clientName = "omp"

    static func parse(_ cache: UsageCache?) -> [UsageMessage] {
        var files: [String] = []
        var seen = Set<String>()
        for root in ompSessionRoots() {
            guard seen.insert(root).inserted else { continue }
            files.append(contentsOf: collectFiles(root) { rustExtension($0) == "jsonl" })
        }
        // Every entry is self-contained, so per-file parsing is pure and
        // cacheable; parseFilesInOrder keeps root order for first-wins dedup.
        return parseFilesInOrder(files, cache: cache, parseOmpFile)
    }
}

/// omp's agent directories. `PI_CODING_AGENT_DIR` overrides the whole agent
/// dir (default profile only) and `PI_CONFIG_DIR` renames the config root
/// under home; both are documented in omp://environment-variables.md.
/// `TOKCAT_OMP_HOMES` is a colon-separated list of extra agent dirs, matching
/// the `TOKCAT_CODEX_HOMES` escape hatch.
func ompAgentHomes() -> [String] {
    let env = ProcessInfo.processInfo.environment
    // Env values are trimmed, not just emptiness-checked: a stray space from a
    // shell export or a dotenv file would otherwise build a path that never
    // resolves and silently drop every omp session.
    func trimmedEnv(_ key: String) -> String? {
        guard let raw = env[key] else { return nil }
        let value = rustTrim(raw)
        return value.isEmpty ? nil : value
    }
    var homes: [String] = []
    if let dir = trimmedEnv("PI_CODING_AGENT_DIR") {
        homes.append(dir)
    } else if let home = homeDir() {
        let configRoot = trimmedEnv("PI_CONFIG_DIR") ?? ".omp"
        // Documented as a name under home, but an absolute path is the
        // obvious misreading of "config dir" — honor it rather than
        // concatenating it onto $HOME.
        let root = configRoot.hasPrefix("/") ? configRoot : joinPath(home, configRoot)
        homes.append(joinPath(root, "agent"))
    }
    if let extra = env["TOKCAT_OMP_HOMES"] {
        homes.append(
            contentsOf: extra.split(separator: ":", omittingEmptySubsequences: true)
                .map { rustTrim(String($0)) }
                .filter { !$0.isEmpty })
    }
    return homes
}

func ompSessionRoots() -> [String] {
    ompAgentHomes().map { joinPath($0, "sessions") }
}

@Sendable func parseOmpFile(_ path: String) -> [UsageMessage] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    let fallbackTs = fileModifiedTimestampMs(path)
    // Session id from the file stem for the main transcript, from the parent
    // directory for a nested subagent transcript — either way it is the part
    // that makes an 8-char entry id unique across the machine.
    let scope = ompFileScope(path)
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
        // `provider` is omp's routing id ("anthropic", "openrouter",
        // "google-vertex", …). Leaving it empty for anything the pricing
        // table does not key on lets collectMessages infer it from the model.
        let provider = ompProvider(stringValue(message["provider"]))
        // Entry timestamps are RFC3339; the inner message timestamp is epoch
        // millis and is the one omp treats as the response time.
        let ts =
            timestampMsFromValue(message["timestamp"])
            ?? timestampMsFromValue(value["timestamp"])
            ?? fallbackTs
        let cost = max(f64Value(usage["cost"]?["total"]) ?? 0.0, 0.0)

        var msg = UsageMessage(
            client: "omp", modelId: model, providerId: provider,
            timestampMs: ts, tokens: tokens, cost: cost)
        // responseId is the provider's own id and is unique per call; entry
        // ids are only unique within a session, hence the scope prefix.
        if let responseId = stringValue(message["responseId"]), !responseId.isEmpty {
            msg.dedupKey = "omp:\(responseId)"
        } else if let entryId = stringValue(value["id"]), !entryId.isEmpty {
            msg.dedupKey = "omp:\(scope):\(entryId)"
        }
        out.append(msg)
    }
    return out
}

/// `<session-id>` for a main transcript, `<session-id>/<agent>` for a nested
/// subagent one. Used only to scope entry ids, so a missing stem is fine.
func ompFileScope(_ path: String) -> String {
    let stem = rustFileStem(path) ?? path
    let parent = (path as NSString).deletingLastPathComponent
    if let bucket = rustFileName(parent), ompIsSessionDirName(bucket) {
        return "\(bucket)/\(stem)"
    }
    return stem
}

/// Session directories are `<ISO-timestamp>_<uuid>`; cwd buckets always start
/// with `-` (the encoded-path scheme in omp://session.md).
func ompIsSessionDirName(_ name: String) -> Bool {
    !name.hasPrefix("-") && name.contains("_")
}

/// Map omp's routing provider onto the ids `bundledPrice`/`inferProvider`
/// understand. Aggregators and gateways are left blank so the model string
/// decides, which is what the pricing table keys on anyway.
func ompProvider(_ raw: String?) -> String {
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

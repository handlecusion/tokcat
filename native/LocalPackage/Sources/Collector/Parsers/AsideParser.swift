import DataSource
import Foundation

// Aside browser (asidehq.com). Swift-only client: there is no Rust
// counterpart in src-tauri, so "aside" is deliberately absent from the parity
// rosters (scripts/parity-check.sh, tokcat-dump's default --clients).
//
// Sessions are flat JSONL transcripts, one per browser-agent session:
//
//   ~/.aside/u/<account-id>/sessions/<YYYY-MM-DD>_<sessionId>/messages.jsonl
//
// There are no nested subagent transcripts — a session's sibling `artifacts/`
// directory only holds downloads and screenshots.
//
// Entries are flat (no `type`/`message` envelope): only `role == "assistant"`
// records carry a `usage` object, and each one is a single API response, so
// the values are per-call deltas (never cumulative) and are summed as-is.
// `usage.totalTokens` is exactly input+output+cacheRead+cacheWrite, which
// makes `usage.reasoning` a SUBSET of output — adding it would double-bill it
// at the output rate in estimateCost, so it is dropped like omp does.
//
// Aside records the price it computed for the call, which is authoritative for
// the models it prices (the bundled table cannot know Aside's routing), so it
// is passed through and `collectMessages` leaves it alone. Calls routed
// through Aside's own gateway carry `cost.total == 0`, which falls through to
// the bundled price table.

enum AsideParser: UsageParser {
    static let clientName = "aside"

    static func parse(_ cache: UsageCache?) -> [UsageMessage] {
        var files: [String] = []
        for root in asideSessionRoots() {
            // Only `messages.jsonl` carries usage, but the predicate stays on
            // the extension: the walk is already recursive and the sibling
            // `artifacts/` payloads never end in .jsonl.
            files.append(contentsOf: collectFiles(root) { rustExtension($0) == "jsonl" })
        }
        // Every entry is self-contained, so per-file parsing is pure and
        // cacheable; parseFilesInOrder keeps root order for first-wins dedup.
        return parseFilesInOrder(files, cache: cache, parseAsideFile)
    }
}

/// Aside's data root. The CLI exposes no home override (only daemon URLs and
/// tokens), so this is `~/.aside`; `TOKCAT_ASIDE_HOMES` is a colon-separated
/// list of extra roots, matching the `TOKCAT_CODEX_HOMES` escape hatch.
func asideHomes() -> [String] {
    let env = ProcessInfo.processInfo.environment
    var homes: [String] = []
    if let home = homeDir() {
        homes.append(joinPath(home, ".aside"))
    }
    if let extra = env["TOKCAT_ASIDE_HOMES"] {
        homes.append(
            contentsOf: extra.split(separator: ":", omittingEmptySubsequences: true)
                .map { rustTrim(String($0)) }
                .filter { !$0.isEmpty })
    }
    return homes
}

/// One sessions root per signed-in account (`accounts.json` ids the account
/// dirs numerically: `u/0`, `u/1`, …). Rooting at the account's `sessions`
/// rather than at `u/` keeps the walk off the sibling `memory/` and
/// `passwords/` trees, which hold no usage and are far larger.
func asideSessionRoots() -> [String] {
    asideSessionRoots(in: asideHomes())
}

/// The same enumeration over explicit roots, so the tailer's `simulatedHome`
/// replays can re-root it.
func asideSessionRoots(in homes: [String]) -> [String] {
    var roots: [String] = []
    // A duplicated home (TOKCAT_ASIDE_HOMES repeating ~/.aside) would
    // otherwise walk the same transcripts twice.
    var seen = Set<String>()
    for home in homes {
        let accounts = joinPath(home, "u")
        for entry in scanDirectory(accounts) where entry.isDir {
            let sessions = joinPath(joinPath(accounts, entry.name), "sessions")
            guard seen.insert(sessions).inserted else { continue }
            if isDirectory(sessions) { roots.append(sessions) }
        }
    }
    // scanDirectory yields entries in directory order; sort so the file order
    // (and therefore first-wins dedup) does not depend on the filesystem.
    return roots.sorted(by: pathComponentsLess)
}

@Sendable func parseAsideFile(_ path: String) -> [UsageMessage] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    let fallbackTs = fileModifiedTimestampMs(path)
    var out: [UsageMessage] = []

    forEachJSONLLine(data) { line in
        guard let value = parseTrimmedJSONLine(line) else { return }
        guard value["role"]?.asString == "assistant" else { return }
        guard let usage = value["usage"] else { return }

        let tokens = TokenBreakdown(
            input: max(i64Value(usage["input"]) ?? 0, 0),
            output: max(i64Value(usage["output"]) ?? 0, 0),
            cacheRead: max(i64Value(usage["cacheRead"]) ?? 0, 0),
            cacheWrite: max(i64Value(usage["cacheWrite"]) ?? 0, 0))
        if tokens.total <= 0 { return }

        let model = stringValue(value["model"]) ?? "unknown"
        // `provider` is Aside's routing id ("claude-code" for a Claude Code
        // subscription, "aside" for its own gateway). Leaving it empty for
        // anything the pricing table does not key on lets collectMessages
        // infer it from the model.
        let provider = asideProvider(stringValue(value["provider"]))
        let ts = timestampMsFromValue(value["timestamp"]) ?? fallbackTs
        let cost = max(f64Value(usage["cost"]?["total"]) ?? 0.0, 0.0)

        var msg = UsageMessage(
            client: "aside", modelId: model, providerId: provider,
            timestampMs: ts, tokens: tokens, cost: cost)
        // responseId is the provider's own id and is unique per call. Entries
        // carry no id of their own, so a record without one (an Aside-gateway
        // response) falls back to dedupMessages' content key.
        if let responseId = stringValue(value["responseId"]), !responseId.isEmpty {
            msg.dedupKey = "aside:\(responseId)"
        }
        out.append(msg)
    }
    return out
}

/// Map Aside's routing provider onto the ids `bundledPrice`/`inferProvider`
/// understand. Its own gateway is left blank so the model string decides,
/// which is what the pricing table keys on anyway.
func asideProvider(_ raw: String?) -> String {
    guard let raw else { return "" }
    let provider = rustTrim(raw).lowercased()
    switch provider {
    case "anthropic", "claude", "claude-code": return "anthropic"
    case "openai", "openai-codex", "azure", "azure-openai": return "openai"
    case "google", "google-vertex", "gemini": return "google"
    case "xai": return "xai"
    default: return ""
    }
}

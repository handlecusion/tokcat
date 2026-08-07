import DataSource
import Foundation

// Port of parse_opencode / discover_opencode_dbs / parse_opencode_sqlite /
// parse_opencode_json_file / parse_opencode_json (usage_graph.rs:987-1119).

enum OpenCodeParser: UsageParser {
    static let clientName = "opencode"

    static func parse(_ cache: UsageCache?) -> [UsageMessage] {
        var out: [UsageMessage] = []
        guard let home = homeDir() else { return out }
        let dataRoot = joinPath(xdgDataHome(home), "opencode")
        for dbPath in discoverOpenCodeDBs(dataRoot) {
            out.append(contentsOf: parseOpenCodeSQLite(dbPath))
        }
        // Legacy JSON store: one message per file under storage/message.
        let legacy = joinPath(joinPath(dataRoot, "storage"), "message")
        for file in collectFiles(legacy, { rustExtension($0) == "json" }) {
            if let msg = parseOpenCodeJSONFile(file) {
                out.append(msg)
            }
        }
        return out
    }
}

/// Port of discover_opencode_dbs (usage_graph.rs:1008-1024): opencode.db and
/// opencode-*.db directly under the root, sorted PathBuf-style.
func discoverOpenCodeDBs(_ root: String) -> [String] {
    var out: [String] = []
    if let entries = try? FileManager.default.contentsOfDirectory(atPath: root) {
        for name in entries {
            let path = joinPath(root, name)
            if isFile(path),
                name == "opencode.db" || (name.hasPrefix("opencode-") && name.hasSuffix(".db"))
            {
                out.append(path)
            }
        }
    }
    out.sort { pathComponentsLess($0, $1) }
    return out
}

/// Port of parse_opencode_sqlite (usage_graph.rs:1026-1073). Fail-soft to
/// empty on ANY error (open, prepare, query); the session-JOIN query falls
/// back to the legacy message-only query when `session` is missing.
func parseOpenCodeSQLite(_ path: String) -> [UsageMessage] {
    guard let db = SQLiteDatabase(readOnlyAtPath: path) else { return [] }
    let queryWithSession = """
        SELECT m.id, m.session_id, m.data
        FROM message m
        LEFT JOIN session s ON s.id = m.session_id
        ORDER BY m.id, m.session_id
        """
    let queryLegacy = "SELECT id, session_id, data FROM message ORDER BY id, session_id"
    guard let stmt = db.prepare(queryWithSession) ?? db.prepare(queryLegacy) else {
        return []
    }

    var out: [UsageMessage] = []
    while stmt.step() {
        // id and data must be TEXT (row skipped otherwise, like rusqlite);
        // session_id falls back to "" on NULL/mismatch (unwrap_or_default).
        guard let id = stmt.text(0), let data = stmt.text(2) else { continue }
        let sessionId = stmt.text(1) ?? ""
        guard var msg = parseOpenCodeJSON(data) else { continue }
        if msg.dedupKey == nil {
            msg.dedupKey = id
        }
        if !sessionId.isEmpty, msg.dedupKey == "unknown" {
            msg.dedupKey = sessionId
        }
        out.append(msg)
    }
    return out
}

/// Port of parse_opencode_json_file (usage_graph.rs:1075-1085): legacy JSON
/// store entries keyed by their file stem when the payload lacks an id.
func parseOpenCodeJSONFile(_ path: String) -> UsageMessage? {
    guard let data = readToString(path) else { return nil }
    guard var msg = parseOpenCodeJSON(data) else { return nil }
    if msg.dedupKey == nil {
        msg.dedupKey = rustFileStem(path)
    }
    return msg
}

/// Port of parse_opencode_json (usage_graph.rs:1087-1119): assistant role
/// only, cost from the JSON `cost` field, time.created -> created -> now_ms.
func parseOpenCodeJSON(_ data: String) -> UsageMessage? {
    guard let value = JSONValue.parse(data) else { return nil }
    guard value["role"]?.asString == "assistant" else { return nil }
    guard let tokens = value["tokens"] else { return nil }
    let cache = tokens["cache"] ?? .null
    guard let model = stringValue(value["modelID"]) ?? stringValue(value["model"]) else {
        return nil
    }
    let provider = stringValue(value["providerID"]) ?? inferProvider(model)
    let ts =
        (value["time"]?["created"]).flatMap { timestampMsFromValue($0) }
        ?? timestampMsFromValue(value["created"])
        ?? nowMs()
    var msg = UsageMessage(
        client: "opencode", modelId: model, providerId: provider,
        timestampMs: ts,
        tokens: TokenBreakdown(
            input: max(i64Value(tokens["input"]) ?? 0, 0),
            output: max(i64Value(tokens["output"]) ?? 0, 0),
            cacheRead: max(i64Value(cache["read"]) ?? 0, 0),
            cacheWrite: max(i64Value(cache["write"]) ?? 0, 0),
            reasoning: max(i64Value(tokens["reasoning"]) ?? 0, 0)),
        cost: f64Value(value["cost"]) ?? 0.0)
    msg.dedupKey = stringValue(value["id"]).map { "opencode:\($0)" }
    return msg
}

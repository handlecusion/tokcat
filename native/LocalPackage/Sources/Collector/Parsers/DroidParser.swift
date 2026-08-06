import DataSource
import Foundation

// Port of parse_droid / parse_droid_file / normalize_droid_model /
// default_model_for_provider (usage_graph.rs:1533-1582, 2496-2552).

enum DroidParser: UsageParser {
    static let clientName = "droid"

    static func parse() -> [UsageMessage] {
        guard let home = homeDir() else { return [] }
        return collectFiles(joinPath(joinPath(home, ".factory"), "sessions")) { p in
            rustFileName(p)?.hasSuffix(".settings.json") == true
        }
        .compactMap(parseDroidFile)
    }
}

/// Port of parse_droid_file (usage_graph.rs:1547-1582): one message per
/// settings file, keyed by the file stem.
func parseDroidFile(_ path: String) -> UsageMessage? {
    guard let data = readToString(path), let value = JSONValue.parse(data) else { return nil }
    guard let usage = value["tokenUsage"] else { return nil }
    let provider =
        stringValue(value["providerLock"])
        ?? stringValue(value["model"]).map(inferProvider)
        ?? "unknown"
    let model =
        stringValue(value["model"]).map(normalizeDroidModel)
        ?? defaultModelForProvider(provider)
    let ts =
        timestampMsFromValue(value["providerLockTimestamp"])
        ?? fileModifiedTimestampMs(path)
    var msg = UsageMessage(
        client: "droid", modelId: model, providerId: provider,
        timestampMs: ts,
        tokens: TokenBreakdown(
            input: max(i64Value(usage["inputTokens"]) ?? 0, 0),
            output: max(i64Value(usage["outputTokens"]) ?? 0, 0),
            cacheRead: max(i64Value(usage["cacheReadTokens"]) ?? 0, 0),
            cacheWrite: max(i64Value(usage["cacheCreationTokens"]) ?? 0, 0),
            reasoning: max(i64Value(usage["thinkingTokens"]) ?? 0, 0)),
        cost: 0.0)
    msg.dedupKey = rustFileStem(path).map { "droid:\($0)" }
    return msg
}

/// Port of normalize_droid_model (usage_graph.rs:2496-2513): strip a
/// `custom:` prefix, drop bracketed spans, map `.`/`_`/space to `-`,
/// lowercase, squeeze dash runs, trim dashes.
func normalizeDroidModel(_ model: String) -> String {
    let withoutPrefix = model.hasPrefix("custom:") ? String(model.dropFirst(7)) : model
    var out = ""
    var inBracket = false
    for c in withoutPrefix {
        switch c {
        case "[": inBracket = true
        case "]": inBracket = false
        case _ where inBracket: break
        case ".", "_", " ": out.append("-")
        default:
            // char::to_ascii_lowercase — ASCII-only lowercasing.
            if let ascii = c.asciiValue, ascii >= UInt8(ascii: "A"), ascii <= UInt8(ascii: "Z") {
                out.append(Character(UnicodeScalar(ascii + 32)))
            } else {
                out.append(c)
            }
        }
    }
    while out.contains("--") {
        out = out.replacingOccurrences(of: "--", with: "-")
    }
    // str::trim_matches('-')
    var bytes = Array(out.utf8)[...]
    while bytes.first == UInt8(ascii: "-") { bytes = bytes.dropFirst() }
    while bytes.last == UInt8(ascii: "-") { bytes = bytes.dropLast() }
    return String(decoding: bytes, as: UTF8.self)
}

/// Port of default_model_for_provider (usage_graph.rs:2543-2552).
func defaultModelForProvider(_ provider: String) -> String {
    switch provider {
    case "anthropic": return "claude-unknown"
    case "openai": return "gpt-unknown"
    case "google": return "gemini-unknown"
    case "xai": return "grok-unknown"
    default: return "unknown"
    }
}

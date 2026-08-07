import DataSource
import Foundation

// Port of parse_cursor / parse_cursor_cache_json / parse_cursor_file and the
// hand-rolled CSV helpers (usage_graph.rs:840-985, 2457-2490).

enum CursorParser: UsageParser {
    static let clientName = "cursor"

    static func parse(_ cache: UsageCache?) -> [UsageMessage] {
        guard let home = homeDir() else { return [] }
        let root = joinPath(joinPath(joinPath(home, ".config"), "tokscale"), "cursor-cache")
        // Preferred source: the JSON cache written by the opt-in cursor_usage
        // fetcher. When present and non-empty it supersedes the legacy CSV.
        let jsonCache = joinPath(root, "tokcat-events.json")
        if isFile(jsonCache) {
            let msgs = parseCursorCacheJSON(jsonCache)
            if !msgs.isEmpty { return msgs }
        }
        // Fallback: the local compatibility CSV cache (usage.csv / usage.*.csv).
        return collectFiles(root) { p in
            guard let name = rustFileName(p) else { return false }
            return name == "usage.csv" || (name.hasPrefix("usage.") && name.hasSuffix(".csv"))
        }
        .flatMap(parseCursorFile)
    }
}

/// Port of parse_cursor_cache_json (usage_graph.rs:868-914). The Rust side
/// uses a strict serde derive: any missing/mistyped field in ANY event fails
/// the whole cache (falling back to CSV), so this port is all-or-nothing too.
func parseCursorCacheJSON(_ path: String) -> [UsageMessage] {
    guard let content = readToString(path), let value = JSONValue.parse(content),
        case .array(let events)? = value["events"]
    else { return [] }

    // serde i64: JSON integer only (no floats, no strings).
    func strictI64(_ v: JSONValue?) -> Int64? {
        if case .int(let i)? = v { return i }
        return nil
    }
    // serde f64: any JSON number.
    func strictF64(_ v: JSONValue?) -> Double? {
        switch v {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d
        default: return nil
        }
    }

    var out: [UsageMessage] = []
    for event in events {
        guard let timestampMs = strictI64(event["timestamp_ms"]),
            let model = event["model"]?.asString,
            let inputTokens = strictI64(event["input_tokens"]),
            let outputTokens = strictI64(event["output_tokens"]),
            let cacheReadTokens = strictI64(event["cache_read_tokens"]),
            let cost = strictF64(event["cost"])
        else { return [] }
        if timestampMs <= 0 { continue }
        var msg = UsageMessage(
            client: "cursor", modelId: model, providerId: inferProvider(model),
            timestampMs: timestampMs,
            tokens: TokenBreakdown(
                input: max(inputTokens, 0),
                output: max(outputTokens, 0),
                cacheRead: max(cacheReadTokens, 0),
                cacheWrite: 0,
                reasoning: 0),
            cost: max(cost, 0.0))
        msg.dedupKey = "cursor:\(timestampMs):\(inputTokens):\(outputTokens)"
        out.append(msg)
    }
    return out
}

/// Port of parse_cursor_file (usage_graph.rs:916-985): three header layouts
/// selected by the presence of a "Kind" column plus column count.
func parseCursorFile(_ path: String) -> [UsageMessage] {
    guard let content = readToString(path) else { return [] }
    var lines = rustLines(content)
    guard !lines.isEmpty else { return [] }
    let header = lines.removeFirst()
    let headerFields = parseCSVLine(header)
    let hasKind = headerFields.contains { trimMatchesQuote($0) == "Kind" }
    let columnCount = headerFields.count
    let (modelIdx, inputWithCacheIdx, inputNoCacheIdx, cacheReadIdx, outputIdx, costIdx):
        (Int, Int, Int, Int, Int, Int)
    if hasKind && columnCount >= 12 {
        (modelIdx, inputWithCacheIdx, inputNoCacheIdx, cacheReadIdx, outputIdx, costIdx) =
            (4, 6, 7, 8, 9, 11)
    } else if hasKind && columnCount >= 10 {
        (modelIdx, inputWithCacheIdx, inputNoCacheIdx, cacheReadIdx, outputIdx, costIdx) =
            (2, 4, 5, 6, 7, 9)
    } else {
        (modelIdx, inputWithCacheIdx, inputNoCacheIdx, cacheReadIdx, outputIdx, costIdx) =
            (1, 2, 3, 4, 5, 7)
    }

    let account = rustFileStem(path) ?? "usage"
    var out: [UsageMessage] = []
    for line in lines {
        let fields = parseCSVLine(line)
        if fields.count <= costIdx { continue }
        let date = cleanCSV(fields[0])
        let model = cleanCSV(fields[modelIdx])
        if model.isEmpty { continue }
        let inputWithCache = Int64(cleanCSV(fields[inputWithCacheIdx])) ?? 0
        let inputWithoutCache = Int64(cleanCSV(fields[inputNoCacheIdx])) ?? 0
        let cacheRead = Int64(cleanCSV(fields[cacheReadIdx])) ?? 0
        let output = Int64(cleanCSV(fields[outputIdx])) ?? 0
        let cost = parseCost(cleanCSV(fields[costIdx]))
        let ts = parseDateToTimestampMs(cleanCSV(fields[0]))
        if ts <= 0 { continue }
        var msg = UsageMessage(
            client: "cursor", modelId: model, providerId: inferProvider(model),
            timestampMs: ts,
            tokens: TokenBreakdown(
                input: max(inputWithoutCache, 0),
                output: max(output, 0),
                cacheRead: max(cacheRead, 0),
                cacheWrite: max(inputWithCache - inputWithoutCache, 0),
                reasoning: 0),
            cost: cost)
        msg.dedupKey = "cursor:\(account):\(date)"
        out.append(msg)
    }
    return out
}

/// Port of parse_csv_line (usage_graph.rs:2457-2472): the hand-rolled
/// quote-toggle splitter, NOT an RFC-CSV parser. Quotes toggle in/out; commas
/// split only outside quotes; quote characters are kept in the field text.
func parseCSVLine(_ line: String) -> [String] {
    var fields: [String] = []
    let bytes = Array(line.utf8)
    var start = 0
    var inQuotes = false
    var i = 0
    while i < bytes.count {
        let c = bytes[i]
        if c == UInt8(ascii: "\"") {
            inQuotes.toggle()
        } else if c == UInt8(ascii: ","), !inQuotes {
            fields.append(String(decoding: bytes[start..<i], as: UTF8.self))
            start = i + 1
        }
        i += 1
    }
    fields.append(String(decoding: bytes[start...], as: UTF8.self))
    return fields
}

/// `str::trim_matches('"')`: strip ALL leading and trailing quote chars.
func trimMatchesQuote(_ s: String) -> String {
    var bytes = Array(s.utf8)[...]
    while bytes.first == UInt8(ascii: "\"") { bytes = bytes.dropFirst() }
    while bytes.last == UInt8(ascii: "\"") { bytes = bytes.dropLast() }
    return String(decoding: bytes, as: UTF8.self)
}

/// Port of clean_csv (usage_graph.rs:2474-2476): trim whitespace, then strip
/// surrounding quote characters.
func cleanCSV(_ value: String) -> String {
    trimMatchesQuote(rustTrim(value))
}

/// Port of parse_cost (usage_graph.rs:2478-2490).
func parseCost(_ value: String) -> Double {
    let cleaned = value.replacingOccurrences(of: "$", with: "")
        .replacingOccurrences(of: ",", with: "")
    let trimmed = rustTrim(cleaned)
    if trimmed.isEmpty || trimmed.lowercased() == "nan" || trimmed.lowercased() == "included"
        || trimmed == "-"
    {
        return 0.0
    }
    return Double(trimmed) ?? 0.0
}

/// Port of parse_date_to_timestamp_ms (usage_graph.rs:2392-2402): RFC3339
/// first, then a plain %Y-%m-%d date anchored at 12:00:00 UTC, else 0.
func parseDateToTimestampMs(_ date: String) -> Int64 {
    if let ms = rfc3339ToTimestampMs(date) { return ms }
    let parts = date.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
        parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }),
        parts[0].utf8.count == 4, parts[1].utf8.count <= 2, parts[2].utf8.count <= 2,
        let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
        month >= 1, month <= 12, day >= 1, day <= daysInMonth(year: year, month: month)
    else { return 0 }
    let days = Int64(daysFromCivil(year: year, month: month, day: day))
    return (days * 86_400 + 12 * 3600) * 1000
}

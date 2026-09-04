import Foundation

// Ports of the lenient value coercion helpers in usage_graph.rs (:2320-2402).
// These encode serde_json coercion semantics exactly; parsers must go through
// them instead of Codable.

/// `str::trim()` — Unicode whitespace on both ends.
func rustTrim(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Rust `f64 as i64` cast semantics: NaN -> 0, truncate toward zero,
/// saturate at the i64 bounds.
func rustAsI64(_ d: Double) -> Int64 {
    if d.isNaN { return 0 }
    if d >= 9_223_372_036_854_775_808.0 { return Int64.max }
    if d < -9_223_372_036_854_775_808.0 { return Int64.min }
    return Int64(d)
}

public func satAdd(_ a: Int64, _ b: Int64) -> Int64 {
    let (r, overflow) = a.addingReportingOverflow(b)
    if overflow { return b > 0 ? Int64.max : Int64.min }
    return r
}

func satSub(_ a: Int64, _ b: Int64) -> Int64 {
    let (r, overflow) = a.subtractingReportingOverflow(b)
    if overflow { return b > 0 ? Int64.min : Int64.max }
    return r
}

func satMul(_ a: Int64, _ b: Int64) -> Int64 {
    let (r, overflow) = a.multipliedReportingOverflow(by: b)
    if overflow { return (a > 0) == (b > 0) ? Int64.max : Int64.min }
    return r
}

/// Port of i64_value (usage_graph.rs:2385-2394): ints as-is, u64 wrapped
/// (handled at parse time), f64 via `as i64` truncation, numeric strings
/// via `str::parse::<i64>()` after trimming.
func i64Value(_ value: JSONValue?) -> Int64? {
    switch value {
    case .int(let i): return i
    case .double(let d): return rustAsI64(d)
    case .string(let s): return Int64(rustTrim(s))
    default: return nil
    }
}

/// Port of f64_value (usage_graph.rs:2396-2402).
func f64Value(_ value: JSONValue?) -> Double? {
    switch value {
    case .int(let i): return Double(i)
    case .double(let d): return d
    case .string(let s): return Double(rustTrim(s))
    default: return nil
    }
}

/// Port of string_value (usage_graph.rs:2377-2383): non-empty trimmed
/// strings, plus numbers rendered with `Number::to_string()`.
func stringValue(_ value: JSONValue?) -> String? {
    switch value {
    case .string(let s):
        let t = rustTrim(s)
        return t.isEmpty ? nil : t
    case .int(let i):
        return String(i)
    case .double(let d):
        // serde_json prints f64 via ryu shortest round-trip; Swift's
        // description is also shortest round-trip and matches for the
        // value shapes that appear in usage logs.
        return "\(d)"
    default:
        return nil
    }
}

/// Port of timestamp_ms_from_value (usage_graph.rs:2320-2337).
/// Strings try RFC3339 first, then a raw i64 parse (no trim, like Rust).
/// Integers go through the magnitude sniff; floats are truncated `as i64`
/// first (NOT rounded — normalize_epoch_ms_f64 is a separate path).
func timestampMsFromValue(_ value: JSONValue?) -> Int64? {
    guard let value else { return nil }
    switch value {
    case .string(let s):
        if let ms = rfc3339ToTimestampMs(s) { return ms }
        return Int64(s).map(normalizeEpochMs)
    case .int(let i):
        return normalizeEpochMs(i)
    case .double(let d):
        if d.isFinite { return normalizeEpochMs(rustAsI64(d)) }
        return nil
    default:
        return nil
    }
}

/// Port of normalize_epoch_ms (usage_graph.rs:2339-2346): magnitude sniff
/// with truncating integer division (nanos/micros/millis/seconds).
func normalizeEpochMs(_ raw: Int64) -> Int64 {
    let mag = raw.magnitude
    if mag >= 100_000_000_000_000_000 { return raw / 1_000_000 }
    if mag >= 100_000_000_000_000 { return raw / 1_000 }
    if mag >= 100_000_000_000 { return raw }
    return satMul(raw, 1000)
}

/// Port of normalize_epoch_ms_f64 (usage_graph.rs:2348-2363). Unlike the
/// integer path this ROUNDS (half away from zero) after scaling, and it
/// rejects non-finite and non-positive inputs.
func normalizeEpochMsF64(_ raw: Double) -> Int64? {
    guard raw.isFinite, raw > 0.0 else { return nil }
    let magnitude = abs(raw)
    let millis: Double
    if magnitude >= 100_000_000_000_000_000.0 {
        millis = raw / 1_000_000.0
    } else if magnitude >= 100_000_000_000_000.0 {
        millis = raw / 1_000.0
    } else if magnitude >= 100_000_000_000.0 {
        millis = raw
    } else {
        millis = raw * 1000.0
    }
    return rustAsI64(millis.rounded(.toNearestOrAwayFromZero))
}

/// RFC3339 parser matching chrono's `DateTime::parse_from_rfc3339` tolerance:
/// fixed-width date, 'T'/'t'/' ' separator, optional fractional seconds
/// ('.' + 1+ digits, first 9 kept), offset 'Z'/'z' or ±HH:MM (colon
/// required, |offset| < 24h). Whole string must be consumed. Returns epoch
/// milliseconds (`timestamp_millis()` — fractional truncated to ms).
func rfc3339ToTimestampMs(_ s: String) -> Int64? {
    let b = Array(s.utf8)
    var i = 0

    func digits(_ n: Int) -> Int? {
        guard i + n <= b.count else { return nil }
        var v = 0
        for _ in 0..<n {
            let c = b[i]
            guard c >= 0x30, c <= 0x39 else { return nil }
            v = v * 10 + Int(c - 0x30)
            i += 1
        }
        return v
    }
    func expect(_ ch: UInt8) -> Bool {
        if i < b.count, b[i] == ch {
            i += 1
            return true
        }
        return false
    }

    guard let year = digits(4), expect(UInt8(ascii: "-")),
        let month = digits(2), expect(UInt8(ascii: "-")),
        let day = digits(2)
    else { return nil }
    guard i < b.count,
        b[i] == UInt8(ascii: "T") || b[i] == UInt8(ascii: "t") || b[i] == UInt8(ascii: " ")
    else { return nil }
    i += 1
    guard let hour = digits(2), expect(UInt8(ascii: ":")),
        let minute = digits(2), expect(UInt8(ascii: ":")),
        var second = digits(2)
    else { return nil }

    var nanos: Int64 = 0
    if i < b.count, b[i] == UInt8(ascii: ".") {
        i += 1
        guard i < b.count, b[i] >= 0x30, b[i] <= 0x39 else { return nil }
        var count = 0
        while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
            if count < 9 {
                nanos = nanos * 10 + Int64(b[i] - 0x30)
                count += 1
            }
            i += 1
        }
        while count < 9 {
            nanos *= 10
            count += 1
        }
    }

    var offsetSeconds = 0
    guard i < b.count else { return nil }
    switch b[i] {
    case UInt8(ascii: "Z"), UInt8(ascii: "z"):
        i += 1
    case UInt8(ascii: "+"), UInt8(ascii: "-"):
        let negative = b[i] == UInt8(ascii: "-")
        i += 1
        guard let oh = digits(2), expect(UInt8(ascii: ":")), let om = digits(2) else {
            return nil
        }
        let total = oh * 3600 + om * 60
        guard total < 86_400 else { return nil }
        offsetSeconds = negative ? -total : total
    default:
        return nil
    }
    guard i == b.count else { return nil }

    guard month >= 1, month <= 12, day >= 1, day <= daysInMonth(year: year, month: month)
    else { return nil }
    guard hour <= 23, minute <= 59, second <= 60 else { return nil }
    if second == 60 {
        // chrono represents a leap second as :59 plus >=1e9 nanos, so
        // timestamp_millis lands in the following second.
        second = 59
        nanos += 1_000_000_000
    }

    let days = Int64(daysFromCivil(year: year, month: month, day: day))
    let secs =
        days * 86_400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offsetSeconds)
    return secs * 1000 + nanos / 1_000_000
}

func isLeapYear(_ y: Int) -> Bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

func daysInMonth(year: Int, month: Int) -> Int {
    switch month {
    case 1, 3, 5, 7, 8, 10, 12: return 31
    case 4, 6, 9, 11: return 30
    case 2: return isLeapYear(year) ? 29 : 28
    default: return 0
    }
}

/// Howard Hinnant's days_from_civil: days since 1970-01-01 for a civil date.
func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
    var y = year
    if month <= 2 { y -= 1 }
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
}

/// Inverse: civil date from days since 1970-01-01.
func civilFromDays(_ z0: Int) -> (year: Int, month: Int, day: Int) {
    let z = z0 + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp + (mp < 10 ? 3 : -9)
    return (y + (m <= 2 ? 1 : 0), m, d)
}

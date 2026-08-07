import Foundation

// Port of date_from_timestamp_ms (usage_graph.rs:2310-2318).
//
// chrono's `Local.timestamp_millis_opt(ms)` maps a UTC instant into the local
// timezone; that mapping is always unambiguous (single() never fails for an
// instant), so the `.single().or(earliest())` chain reduces to a plain
// instant->local conversion. We replicate it with the system timezone's
// GMT offset at that instant plus civil-date math, so no Calendar/DateFormatter
// locale behavior can leak in.

/// The process-local timezone, like chrono's `Local` (honors $TZ, then the
/// system zone). Captured once; parity runs must use identical env for both
/// binaries anyway.
private let localTimeZone = TimeZone.current

func dateFromTimestampMs(_ timestampMs: Int64) -> String {
    let instant = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)
    let offset = Int64(localTimeZone.secondsFromGMT(for: instant))
    let localSecs = floorDiv(timestampMs, 1000) + offset
    let days = floorDiv(localSecs, 86_400)
    let (y, m, d) = civilFromDays(Int(days))
    return String(format: "%04d-%02d-%02d", y, m, d)
}

func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    if (a % b != 0) && ((a < 0) != (b < 0)) { return q - 1 }
    return q
}

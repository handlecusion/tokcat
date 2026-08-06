import Foundation

// Port of src/lib/format.ts. All date math is calendar-day arithmetic in the
// local time zone — the Rust side buckets by chrono::Local and the TS side by
// JS local Dates, so the Swift port must stay local too (never UTC).

public enum Formatters {
    // JS `toFixed(1)` rounds the EXACT binary value of the double, ties to
    // the larger n — e.g. 1.95 (binary ≈1.9499…) → "1.9". Neither printf
    // (half-even) nor a naive ×10-then-round (the multiply itself re-rounds
    // across the tie: 1.95*10 == 19.5 in IEEE) reproduces that, so round the
    // correctly-printed 31-significant-digit decimal expansion instead.
    private static func fixed1(_ x: Double) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        guard var d = Decimal(string: String(format: "%.30e", x), locale: posix) else {
            return String(format: "%.1f", x)
        }
        var r = Decimal()
        NSDecimalRound(&r, &d, 1, .plain)  // .plain = half away from zero
        return String(format: "%.1f", NSDecimalNumber(decimal: r).doubleValue)
    }

    public static func humanizeTokens(_ n: Int64) -> String {
        humanizeTokens(Double(n))
    }

    public static func humanizeTokens(_ n: Double) -> String {
        if n < 1_000 { return String(Int64(n)) }
        if n < 1_000_000 { return "\(fixed1(n / 1_000))K" }
        if n < 1_000_000_000 { return "\(fixed1(n / 1_000_000))M" }
        if n < 1_000_000_000_000 { return "\(fixed1(n / 1_000_000_000))B" }
        return "\(fixed1(n / 1_000_000_000_000))T"
    }

    private static let costFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = true
        return f
    }()

    // JS toLocaleString — unlike toFixed — rounds the SHORTEST round-trip
    // decimal representation half-away-from-zero (12.345 → "12.35" even
    // though the double is 12.34499…). "\(n)" is Swift's shortest repr, so
    // round that as a Decimal first, then let NumberFormatter add grouping.
    public static func formatCost(_ n: Double) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        guard var d = Decimal(string: "\(n)", locale: posix) else {
            return "$" + String(format: "%.2f", n)
        }
        var r = Decimal()
        NSDecimalRound(&r, &d, 2, .plain)
        let s = costFormatter.string(from: NSDecimalNumber(decimal: r))
        return "$" + (s ?? String(format: "%.2f", n))
    }

    // Fixed gregorian calendar in the local zone: JS Dates are always
    // gregorian regardless of the user's preferred calendar setting.
    public static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal
    }

    private static let monthsShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    // Parse YYYY-MM-DD as a local date (avoid TZ shift).
    public static func parseISODate(_ s: String) -> Date? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = parts[2]
        return calendar.date(from: comps)
    }

    public static func isoDate(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func formatMonthDay(_ s: String) -> String {
        guard let d = parseISODate(s) else { return s }
        let c = calendar.dateComponents([.month, .day], from: d)
        return "\(monthsShort[c.month! - 1]) \(c.day!)"
    }

    public static func formatMMDD(_ s: String) -> String {
        guard let d = parseISODate(s) else { return s }
        let c = calendar.dateComponents([.month, .day], from: d)
        return String(format: "%02d/%02d", c.month!, c.day!)
    }

    public static func addDays(_ d: Date, _ n: Int) -> Date {
        calendar.date(byAdding: .day, value: n, to: d)!
    }

    // Rounded day difference, DST-safe: a 23h/25h day still counts as 1.
    public static func diffDays(_ a: Date, _ b: Date) -> Int {
        Int((a.timeIntervalSince(b) / 86_400).rounded())
    }
}

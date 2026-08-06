import Foundation

// Shared helpers for the OAuth quota providers, ported from agent_usage.rs.

struct QuotaError: Error, CustomStringConvertible, ExpressibleByStringInterpolation {
    let message: String
    var description: String { message }

    init(_ message: String) { self.message = message }
    init(stringLiteral value: String) { self.message = value }
}

// MARK: - HTTP

enum QuotaHTTP {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Per-request timeouts are set on the URLRequest; keep the resource
        // ceiling near the request ceiling so a stalled body read cannot
        // hang a refresh cycle.
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    /// Send a request, returning (statusCode, body). Throws the transport
    /// error text on failure (the callers wrap it in their own messages).
    static func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}

// MARK: - Dates

enum QuotaDates {
    // Formatters are built per call: DateFormatter/ISO8601DateFormatter are
    // not Sendable, and the quota paths format a handful of dates per
    // 30-minute refresh, so caching would buy nothing but a lock.

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    /// `to_rfc3339_opts(SecondsFormat::Millis, true)` — "2026-08-01T00:00:00.000Z".
    static func rfc3339Millis(_ date: Date) -> String {
        formatter("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").string(from: date)
    }

    /// `DateTime::to_rfc3339()` default — "2026-08-01T00:00:00+00:00".
    static func rfc3339Seconds(_ date: Date) -> String {
        formatter("yyyy-MM-dd'T'HH:mm:ss'+00:00'").string(from: date)
    }

    /// `parse_datetime`: RFC3339 with or without fractional seconds.
    static func parse(_ value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}

/// Port of `reset_text` (:1488-1512).
func quotaResetText(reset: Date, now: Date) -> String {
    let seconds = Int64(reset.timeIntervalSince(now).rounded(.down))
    if seconds <= 0 { return "Resets now" }
    let minutes = (seconds + 59) / 60
    if minutes < 60 { return "Resets in \(minutes)m" }
    let hours = minutes / 60
    let mins = minutes % 60
    if hours < 48 {
        if mins > 0 { return "Resets in \(hours)h \(mins)m" }
        return "Resets in \(hours)h"
    }
    let days = hours / 24
    let remHours = hours % 24
    if remHours > 0 { return "Resets in \(days)d \(remHours)h" }
    return "Resets in \(days)d"
}

// MARK: - Strings

/// Port of `first_non_empty`.
func firstNonEmpty(_ values: [String?]) -> String? {
    for value in values {
        guard let value else { continue }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
    }
    return nil
}

/// Port of `clean_plan`: split on `_`/`-`, capitalize each piece.
func cleanPlan(_ value: String) -> String {
    value
        .split(whereSeparator: { $0 == "_" || $0 == "-" })
        .filter { !$0.isEmpty }
        .map { part -> String in
            let first = part.prefix(1).uppercased()
            return first + part.dropFirst()
        }
        .joined(separator: " ")
}

/// Port of `clean_limit_label`: also normalizes separators to spaces and
/// upcases GPT / Codex tokens.
func cleanLimitLabel(_ value: String) -> String {
    value
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .split(separator: " ")
        .filter { !$0.isEmpty }
        .map { part -> String in
            if part.lowercased() == "gpt" { return "GPT" }
            if part.lowercased() == "codex" { return "Codex" }
            let first = part.prefix(1).uppercased()
            return first + part.dropFirst()
        }
        .joined(separator: " ")
}

/// Port of `format_currency_minor_units`.
func formatCurrencyMinorUnits(_ value: Double, currency: String?) -> String {
    let major = value / 100.0
    let code = (currency ?? "USD").trimmingCharacters(in: .whitespaces).uppercased()
    if code == "USD" || code.isEmpty {
        return String(format: "$%.2f", major)
    }
    return String(format: "%.2f %@", major, code)
}

// MARK: - JWT

/// Port of `jwt_payload` (:2251-2262): payload segment, base64url with
/// manual `=` padding, decoded as JSON.
func jwtPayload(_ token: String) -> JSONValue? {
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count > 1 else { return nil }
    var encoded = String(segments[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while encoded.count % 4 != 0 {
        encoded.append("=")
    }
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return JSONValue.parse(data)
}

/// Port of `jwt_email`: top-level `email` or the OpenAI profile claim.
func jwtEmail(_ token: String) -> String? {
    guard let payload = jwtPayload(token) else { return nil }
    let value = payload["email"]?.asString
        ?? payload["https://api.openai.com/profile"]?["email"]?.asString
    return value
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .flatMap { $0.isEmpty ? nil : $0 }
}

/// Port of `jwt_plan`: `chatgpt_plan_type` directly or under the auth claim.
func jwtPlan(_ token: String) -> String? {
    guard let payload = jwtPayload(token) else { return nil }
    let value = payload["chatgpt_plan_type"]?.asString
        ?? payload["https://api.openai.com/auth"]?["chatgpt_plan_type"]?.asString
    return value
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .flatMap { $0.isEmpty ? nil : $0 }
}

// MARK: - Lenient JSON decoding

/// serde's `deserialize_optional_f64`: number, or string parsed as number;
/// any other type (bool, object, …) quietly becomes nil — never an error.
struct LenientDouble: Decodable {
    let value: Double?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Double(text)
        } else {
            value = nil
        }
    }
}

/// serde's `deserialize_optional_i64`.
struct LenientInt64: Decodable {
    let value: Int64?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int64.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Int64(text)
        } else {
            value = nil
        }
    }
}

extension KeyedDecodingContainer {
    func lenientDouble(_ key: Key) -> Double? {
        (try? decodeIfPresent(LenientDouble.self, forKey: key))??.value
    }

    func lenientInt64(_ key: Key) -> Int64? {
        (try? decodeIfPresent(LenientInt64.self, forKey: key))??.value
    }
}

// MARK: - Environment / paths

func quotaHomeDirectory() -> String? {
    let home = ProcessInfo.processInfo.environment["HOME"]
    return (home?.isEmpty == false) ? home : nil
}

/// `codex_home()`: $CODEX_HOME, else ~/.codex.
func codexHome() -> URL {
    let env = ProcessInfo.processInfo.environment["CODEX_HOME"]
    if let env, !env.isEmpty {
        return URL(fileURLWithPath: env)
    }
    if let home = quotaHomeDirectory() {
        return URL(fileURLWithPath: home).appendingPathComponent(".codex")
    }
    return URL(fileURLWithPath: ".codex")
}

/// `grok_home()`: $GROK_HOME, else ~/.grok.
func grokHome() -> URL {
    let env = ProcessInfo.processInfo.environment["GROK_HOME"]
    if let env, !env.isEmpty {
        return URL(fileURLWithPath: env)
    }
    if let home = quotaHomeDirectory() {
        return URL(fileURLWithPath: home).appendingPathComponent(".grok")
    }
    return URL(fileURLWithPath: ".grok")
}

func claudeCredentialsPath() -> URL {
    if let home = quotaHomeDirectory() {
        return URL(fileURLWithPath: home).appendingPathComponent(".claude/.credentials.json")
    }
    return URL(fileURLWithPath: ".claude/.credentials.json")
}

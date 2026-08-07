import DataSource
import Foundation

// Port of the Codex OAuth quota provider in agent_usage.rs
// (:573-657, 744-812, 997-1055, 1102-1190, 2202-2207, 2251-2296).

private let codexUsageURL = "https://chatgpt.com/backend-api/wham/usage"
private let codexRefreshURL = "https://auth.openai.com/oauth/token"
private let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

struct CodexCredentials {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var accountId: String?
    var lastRefresh: Date?
    var authPath: URL
    /// The original parsed auth.json object — the write-back mutates this
    /// in place so unknown keys survive (mirror of `raw_json`).
    var rawJSON: [String: Any]
}

// MARK: - Response shapes (serde mirror)

struct CodexUsageResponse: Decodable {
    var planType: String?
    var rateLimit: CodexRateLimit?
    var additionalRateLimits: [CodexAdditionalRateLimit]?
    var credits: CodexCredits?
    var spendControl: CodexSpendControl?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
        case spendControl = "spend_control"
    }
}

struct CodexRateLimit: Decodable {
    var primaryWindow: CodexWindow?
    var secondaryWindow: CodexWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct CodexWindow: Decodable {
    var usedPercent: Double
    var resetAt: Int64
    var limitWindowSeconds: Int64

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }

    init(usedPercent: Double, resetAt: Int64, limitWindowSeconds: Int64) {
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.limitWindowSeconds = limitWindowSeconds
    }
}

struct CodexAdditionalRateLimit: Decodable {
    var limitName: String?
    var meteredFeature: String?
    var rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }

    init(limitName: String?, meteredFeature: String?, rateLimit: CodexRateLimit?) {
        self.limitName = limitName
        self.meteredFeature = meteredFeature
        self.rateLimit = rateLimit
    }
}

struct CodexCredits: Decodable {
    var unlimited: Bool
    var balance: Double?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unlimited = (try? container.decodeIfPresent(Bool.self, forKey: .unlimited)) ?? false
        balance = container.lenientDouble(.balance)
    }

    enum CodingKeys: String, CodingKey {
        case unlimited
        case balance
    }
}

struct CodexSpendControl: Decodable {
    var individualLimit: CodexSpendLimit?

    enum CodingKeys: String, CodingKey {
        case individualLimit = "individual_limit"
    }

    init(individualLimit: CodexSpendLimit?) {
        self.individualLimit = individualLimit
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        individualLimit = try container.decodeIfPresent(CodexSpendLimit.self, forKey: .individualLimit)
    }
}

struct CodexSpendLimit: Decodable {
    var limit: Double?
    var used: Double?
    var usedPercent: Double?
    var remainingPercent: Double?
    var resetAt: Int64?

    enum CodingKeys: String, CodingKey {
        case limit
        case used
        case usedPercent = "used_percent"
        case remainingPercent = "remaining_percent"
        case resetAt = "reset_at"
    }

    init(limit: Double?, used: Double?, usedPercent: Double?,
         remainingPercent: Double?, resetAt: Int64?) {
        self.limit = limit
        self.used = used
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limit = container.lenientDouble(.limit)
        used = container.lenientDouble(.used)
        usedPercent = container.lenientDouble(.usedPercent)
        remainingPercent = container.lenientDouble(.remainingPercent)
        resetAt = container.lenientInt64(.resetAt)
    }
}

// MARK: - Provider

public enum CodexQuotaProvider {
    /// Whether Codex OAuth has been set up at all. A missing auth.json means
    /// Codex isn't installed / logged in, so the tile is hidden rather than
    /// showing a perpetual "not found" error.
    public static var isConfigured: Bool {
        FileManager.default.fileExists(
            atPath: codexHome().appendingPathComponent("auth.json").path)
    }

    public static func fetch() async -> AgentUsageSnapshot {
        do {
            return try await fetchInner()
        } catch {
            return AgentUsageSnapshot(
                clientId: "codex", source: "oauth",
                updatedAt: QuotaDates.rfc3339Millis(Date()),
                identity: nil, windows: [], credits: nil,
                error: "\(error)")
        }
    }

    static func fetchInner() async throws -> AgentUsageSnapshot {
        var credentials = try loadCodexCredentials()
        if codexCredentialsNeedRefresh(lastRefresh: credentials.lastRefresh) {
            let refreshToken = credentials.refreshToken ?? ""
            if refreshToken.isEmpty {
                throw QuotaError(
                    "Codex OAuth token needs refresh but auth.json has no refresh token.")
            }
            credentials = try await refreshCodexCredentials(credentials)
        }

        var request = URLRequest(url: URL(string: codexUsageURL)!)
        request.timeoutInterval = 30
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tokcat", forHTTPHeaderField: "User-Agent")
        if let accountId = credentials.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let status: Int
        let body: Data
        do {
            (status, body) = try await QuotaHTTP.send(request)
        } catch {
            throw QuotaError("Codex OAuth request failed: \(error.localizedDescription)")
        }

        if status == 401 || status == 403 {
            throw QuotaError("Codex OAuth token expired or invalid. Run `codex` to log in again.")
        }
        if !(200..<300).contains(status) {
            throw QuotaError("Codex usage API returned \(status).")
        }

        let usage: CodexUsageResponse
        do {
            usage = try JSONDecoder().decode(CodexUsageResponse.self, from: body)
        } catch {
            throw QuotaError("decode Codex usage response: \(error)")
        }

        let now = Date()
        let identity = AgentIdentity(
            email: credentials.idToken.flatMap(jwtEmail),
            plan: usage.planType.map(cleanPlan)
                ?? credentials.idToken.flatMap(jwtPlan).map(cleanPlan))
        let windows = codexWindows(
            rateLimit: usage.rateLimit,
            additionalRateLimits: usage.additionalRateLimits,
            spendControl: usage.spendControl,
            now: now)
        if windows.isEmpty && usage.credits?.balance == nil {
            throw QuotaError("Codex usage API returned no rate-limit windows.")
        }

        return AgentUsageSnapshot(
            clientId: "codex", source: "oauth",
            updatedAt: QuotaDates.rfc3339Millis(now),
            identity: identity,
            windows: windows,
            credits: usage.credits.map {
                CreditsSnapshot(remaining: $0.balance, unlimited: $0.unlimited)
            },
            error: nil)
    }

    // MARK: Credentials

    static func loadCodexCredentials() throws -> CodexCredentials {
        let authPath = codexHome().appendingPathComponent("auth.json")
        guard let raw = try? Data(contentsOf: authPath) else {
            throw QuotaError("Codex auth.json not found. Run `codex` to log in.")
        }
        guard
            let parsed = try? JSONSerialization.jsonObject(with: raw),
            let rawJSON = parsed as? [String: Any]
        else {
            throw QuotaError("decode Codex auth.json: not a JSON object")
        }
        return try codexCredentials(fromRawJSON: rawJSON, authPath: authPath)
    }

    static func codexCredentials(
        fromRawJSON rawJSON: [String: Any], authPath: URL
    ) throws -> CodexCredentials {
        if let apiKey = rawJSON["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            throw QuotaError(
                "Codex is using API-key auth; OAuth usage limits require `codex login`.")
        }

        guard let tokens = rawJSON["tokens"] as? [String: Any] else {
            throw QuotaError("Codex auth.json exists but contains no OAuth tokens.")
        }
        guard let accessToken = stringKey(tokens, "access_token", "accessToken") else {
            throw QuotaError("Codex auth.json has no access token.")
        }
        let lastRefresh = (rawJSON["last_refresh"] as? String).flatMap(QuotaDates.parse)

        return CodexCredentials(
            accessToken: accessToken,
            refreshToken: stringKey(tokens, "refresh_token", "refreshToken"),
            idToken: stringKey(tokens, "id_token", "idToken"),
            accountId: stringKey(tokens, "account_id", "accountId"),
            lastRefresh: lastRefresh,
            authPath: authPath,
            rawJSON: rawJSON)
    }

    /// `string_key`: snake_case key first, camelCase fallback, trimmed and
    /// non-empty.
    static func stringKey(
        _ map: [String: Any], _ snakeCase: String, _ camelCase: String
    ) -> String? {
        let value = (map[snakeCase] as? String) ?? (map[camelCase] as? String)
        return value
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `credentials_needs_refresh`: missing → true; older than 8 whole days.
    static func codexCredentialsNeedRefresh(lastRefresh: Date?, now: Date = Date()) -> Bool {
        guard let lastRefresh else { return true }
        let days = Int64(now.timeIntervalSince(lastRefresh) / 86_400)
        return days > 8
    }

    static func refreshCodexCredentials(
        _ credentials: CodexCredentials
    ) async throws -> CodexCredentials {
        guard let refreshToken = credentials.refreshToken else {
            throw QuotaError("Codex auth.json has no refresh token.")
        }
        var request = URLRequest(url: URL(string: codexRefreshURL)!)
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_id": codexClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ])

        let status: Int
        let body: Data
        do {
            (status, body) = try await QuotaHTTP.send(request)
        } catch {
            throw QuotaError("Codex token refresh failed: \(error.localizedDescription)")
        }
        if !(200..<300).contains(status) {
            throw QuotaError("Codex OAuth refresh failed. Run `codex` to log in again.")
        }
        guard
            let parsed = try? JSONSerialization.jsonObject(with: body),
            let json = parsed as? [String: Any]
        else {
            throw QuotaError("decode Codex refresh response: not a JSON object")
        }

        var refreshed = credentials
        refreshed.accessToken = (json["access_token"] as? String) ?? credentials.accessToken
        refreshed.refreshToken = (json["refresh_token"] as? String) ?? credentials.refreshToken
        refreshed.idToken = (json["id_token"] as? String) ?? credentials.idToken
        refreshed.lastRefresh = Date()
        try saveCodexCredentials(refreshed)
        return refreshed
    }

    /// `save_codex_credentials`: plain (non-atomic) write of pretty JSON,
    /// updating the token fields inside the original parsed object so
    /// unknown keys are preserved. Mirrors the Rust behavior exactly —
    /// including the non-atomic write.
    static func saveCodexCredentials(_ credentials: CodexCredentials) throws {
        var raw = credentials.rawJSON
        var tokens = (raw["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = credentials.accessToken
        if let refreshToken = credentials.refreshToken {
            tokens["refresh_token"] = refreshToken
        }
        if let idToken = credentials.idToken {
            tokens["id_token"] = idToken
        }
        if let accountId = credentials.accountId {
            tokens["account_id"] = accountId
        }
        raw["tokens"] = tokens
        raw["last_refresh"] = QuotaDates.rfc3339Millis(Date())
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        else {
            throw QuotaError("encode Codex auth.json: serialization failed")
        }
        do {
            // fs::write — intentionally not atomic, mirroring the Rust code.
            try data.write(to: credentials.authPath)
        } catch {
            throw QuotaError("save Codex auth.json: \(error.localizedDescription)")
        }
    }

    // MARK: Window mapping

    /// Port of `codex_windows` (:1120-1166), including the primary/secondary
    /// role swap when the primary is the weekly window.
    static func codexWindows(
        rateLimit: CodexRateLimit?,
        additionalRateLimits: [CodexAdditionalRateLimit]?,
        spendControl: CodexSpendControl?,
        now: Date
    ) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        if let rateLimit {
            var primary = rateLimit.primaryWindow
            var secondary = rateLimit.secondaryWindow
            if windowRole(primary) == "weekly" && windowRole(secondary) != "weekly" {
                swap(&primary, &secondary)
            }
            if let window = primary {
                windows.append(mapCodexWindow(label: "Session", window: window, now: now))
            }
            if let window = secondary {
                windows.append(mapCodexWindow(label: "Weekly", window: window, now: now))
            }
        }

        var seen = Set(windows.map(\.label))
        for extra in additionalRateLimits ?? [] {
            guard let rateLimit = extra.rateLimit else { continue }
            guard let window = rateLimit.primaryWindow ?? rateLimit.secondaryWindow else {
                continue
            }
            let label = additionalLimitLabel(extra)
            if seen.insert(label).inserted {
                windows.append(mapCodexWindow(label: label, window: window, now: now))
            }
        }
        if let window = codexSpendControlWindow(spendControl, now: now) {
            windows.append(window)
        }
        return windows
    }

    /// Port of `codex_spend_control_window` (:1168-1190).
    static func codexSpendControlWindow(
        _ spendControl: CodexSpendControl?, now: Date
    ) -> UsageWindow? {
        guard let limit = spendControl?.individualLimit else { return nil }
        let usedPercent: Double? = limit.usedPercent
            ?? limit.remainingPercent.map { 100.0 - $0 }
            ?? {
                guard let used = limit.used, let total = limit.limit, total > 0 else {
                    return nil
                }
                return (used / total) * 100.0
            }()
        guard let usedPercent else { return nil }
        return mapCodexWindow(
            label: "Monthly spend",
            window: CodexWindow(
                usedPercent: usedPercent,
                resetAt: limit.resetAt ?? 0,
                limitWindowSeconds: 0),
            now: now)
    }

    /// Port of `map_window` (:1464-1478).
    static func mapCodexWindow(label: String, window: CodexWindow, now: Date) -> UsageWindow {
        let resetsAt: Date? = window.resetAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(window.resetAt))
            : nil
        let used = min(100.0, max(0.0, window.usedPercent))
        return UsageWindow(
            label: label,
            usedPercent: used,
            remainingPercent: max(100.0 - used, 0.0),
            resetsAt: resetsAt.map(QuotaDates.rfc3339Millis),
            resetText: resetsAt.map { quotaResetText(reset: $0, now: now) })
    }

    /// Port of `role` (:1480-1486): 18000s → session, 604800s → weekly.
    static func windowRole(_ window: CodexWindow?) -> String? {
        switch window?.limitWindowSeconds {
        case 18_000: return "session"
        case 604_800: return "weekly"
        default: return nil
        }
    }

    /// Port of `additional_limit_label` (:1422-1433).
    static func additionalLimitLabel(_ limit: CodexAdditionalRateLimit) -> String {
        let source = firstNonEmpty([limit.limitName, limit.meteredFeature])
            ?? "Codex extra limit"
        if source.lowercased().contains("spark") {
            return "Codex Spark"
        }
        return cleanLimitLabel(source)
    }
}

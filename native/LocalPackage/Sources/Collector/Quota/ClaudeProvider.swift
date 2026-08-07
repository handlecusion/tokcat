import DataSource
import Foundation

// Port of the Claude OAuth quota provider in agent_usage.rs
// (:659-742, 786-863, 957-995, 1057-1100, 1192-1315, 2209-2236).

private let claudeUsageURL = "https://api.anthropic.com/api/oauth/usage"
private let claudeRefreshURL = "https://platform.claude.com/v1/oauth/token"
private let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
private let claudeKeychainService = "Claude Code-credentials"

struct ClaudeCredentials {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: [String]
    var rateLimitTier: String?
    var subscriptionType: String?
}

// MARK: - Response shapes

struct ClaudeWindow: Decodable, Equatable {
    var utilization: Double?
    var resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(utilization: Double?, resetsAt: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = container.lenientDouble(.utilization)
        resetsAt = try? container.decodeIfPresent(String.self, forKey: .resetsAt)
    }
}

struct ClaudeExtraUsage: Decodable {
    var isEnabled: Bool
    var monthlyLimit: Double?
    var usedCredits: Double?
    var utilization: Double?
    var currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }

    init(isEnabled: Bool, monthlyLimit: Double?, usedCredits: Double?,
         utilization: Double?, currency: String?) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.utilization = utilization
        self.currency = currency
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? false
        monthlyLimit = container.lenientDouble(.monthlyLimit)
        usedCredits = container.lenientDouble(.usedCredits)
        utilization = container.lenientDouble(.utilization)
        currency = try? container.decodeIfPresent(String.self, forKey: .currency)
    }
}

/// Mirror of the Rust struct with every alias field; the first-non-nil
/// chains live in `designWindow` / `routinesWindow` (:1212-1242).
struct ClaudeUsageResponse: Decodable {
    var fiveHour: ClaudeWindow?
    var sevenDay: ClaudeWindow?
    var sevenDayOauthApps: ClaudeWindow?
    var sevenDayOpus: ClaudeWindow?
    var sevenDaySonnet: ClaudeWindow?
    var sevenDayDesign: ClaudeWindow?
    var sevenDayClaudeDesign: ClaudeWindow?
    var claudeDesign: ClaudeWindow?
    var design: ClaudeWindow?
    var sevenDayOmelette: ClaudeWindow?
    var omelette: ClaudeWindow?
    var omelettePromotional: ClaudeWindow?
    var sevenDayRoutines: ClaudeWindow?
    var sevenDayClaudeRoutines: ClaudeWindow?
    var claudeRoutines: ClaudeWindow?
    var routines: ClaudeWindow?
    var routine: ClaudeWindow?
    var sevenDayCowork: ClaudeWindow?
    var cowork: ClaudeWindow?
    var extraUsage: ClaudeExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayDesign = "seven_day_design"
        case sevenDayClaudeDesign = "seven_day_claude_design"
        case claudeDesign = "claude_design"
        case design
        case sevenDayOmelette = "seven_day_omelette"
        case omelette
        case omelettePromotional = "omelette_promotional"
        case sevenDayRoutines = "seven_day_routines"
        case sevenDayClaudeRoutines = "seven_day_claude_routines"
        case claudeRoutines = "claude_routines"
        case routines
        case routine
        case sevenDayCowork = "seven_day_cowork"
        case cowork
        case extraUsage = "extra_usage"
    }

    init(fiveHour: ClaudeWindow? = nil, sevenDay: ClaudeWindow? = nil,
         sevenDayOauthApps: ClaudeWindow? = nil, sevenDayOpus: ClaudeWindow? = nil,
         sevenDaySonnet: ClaudeWindow? = nil, sevenDayDesign: ClaudeWindow? = nil,
         sevenDayClaudeDesign: ClaudeWindow? = nil, claudeDesign: ClaudeWindow? = nil,
         design: ClaudeWindow? = nil, sevenDayOmelette: ClaudeWindow? = nil,
         omelette: ClaudeWindow? = nil, omelettePromotional: ClaudeWindow? = nil,
         sevenDayRoutines: ClaudeWindow? = nil, sevenDayClaudeRoutines: ClaudeWindow? = nil,
         claudeRoutines: ClaudeWindow? = nil, routines: ClaudeWindow? = nil,
         routine: ClaudeWindow? = nil, sevenDayCowork: ClaudeWindow? = nil,
         cowork: ClaudeWindow? = nil, extraUsage: ClaudeExtraUsage? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOauthApps = sevenDayOauthApps
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.sevenDayDesign = sevenDayDesign
        self.sevenDayClaudeDesign = sevenDayClaudeDesign
        self.claudeDesign = claudeDesign
        self.design = design
        self.sevenDayOmelette = sevenDayOmelette
        self.omelette = omelette
        self.omelettePromotional = omelettePromotional
        self.sevenDayRoutines = sevenDayRoutines
        self.sevenDayClaudeRoutines = sevenDayClaudeRoutines
        self.claudeRoutines = claudeRoutines
        self.routines = routines
        self.routine = routine
        self.sevenDayCowork = sevenDayCowork
        self.cowork = cowork
        self.extraUsage = extraUsage
    }

    /// First-non-nil alias chain for the Designs window.
    var designWindow: ClaudeWindow? {
        sevenDayDesign ?? sevenDayClaudeDesign ?? claudeDesign ?? design
            ?? sevenDayOmelette ?? omelette ?? omelettePromotional
    }

    /// First-non-nil alias chain for the Daily Routines window.
    var routinesWindow: ClaudeWindow? {
        sevenDayRoutines ?? sevenDayClaudeRoutines ?? claudeRoutines ?? routines
            ?? routine ?? sevenDayCowork ?? cowork
    }
}

// MARK: - Provider

public enum ClaudeQuotaProvider {
    /// Whether Claude OAuth has been set up at all, mirroring the lookup
    /// order in loadClaudeCredentials (env override, Keychain, file).
    public static var isConfigured: Bool {
        if environmentToken() != nil { return true }
        switch loadCredentialsFromKeychain() {
        case .success(.some): return true
        // A stalled Keychain read tells us nothing. Treat it as configured
        // so the tile stays and surfaces the error, rather than vanishing
        // as if Claude had never been set up.
        case .failure: return true
        case .success(.none): break
        }
        return FileManager.default.fileExists(atPath: claudeCredentialsPath().path)
    }

    public static func fetch() async -> AgentUsageSnapshot {
        do {
            return try await fetchInner()
        } catch {
            return AgentUsageSnapshot(
                clientId: "claude", source: "oauth",
                updatedAt: QuotaDates.rfc3339Millis(Date()),
                identity: nil, windows: [], credits: nil,
                error: "\(error)")
        }
    }

    static func fetchInner() async throws -> AgentUsageSnapshot {
        var credentials = try loadClaudeCredentials()
        if claudeCredentialsExpired(credentials) {
            credentials = try await refreshClaudeCredentials(credentials)
        }

        if !credentials.scopes.isEmpty && !credentials.scopes.contains("user:profile") {
            throw QuotaError(
                "Claude OAuth token lacks the user:profile scope. Run `claude logout && claude login`.")
        }

        var request = URLRequest(url: URL(string: claudeUsageURL)!)
        request.timeoutInterval = 30
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(claudeUserAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let status: Int
        let body: Data
        do {
            (status, body) = try await QuotaHTTP.send(request)
        } catch {
            throw QuotaError("Claude OAuth request failed: \(error.localizedDescription)")
        }

        switch status {
        case 401:
            throw QuotaError(
                "Claude OAuth token expired or invalid. Run `claude` to re-authenticate.")
        case 403:
            throw QuotaError(
                "Claude OAuth usage was denied. Run `claude logout && claude login` to grant user:profile.")
        case 429:
            throw QuotaError(
                "Claude OAuth usage endpoint is rate limited. Try Refresh again later.")
        case 200..<300:
            break
        default:
            throw QuotaError("Claude usage API returned \(status).")
        }

        let usage: ClaudeUsageResponse
        do {
            usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: body)
        } catch {
            throw QuotaError("decode Claude usage response: \(error)")
        }
        let now = Date()
        let windows = claudeWindows(usage, now: now)
        if windows.isEmpty {
            throw QuotaError("Claude usage API returned no rate-limit windows.")
        }

        return AgentUsageSnapshot(
            clientId: "claude", source: "oauth",
            updatedAt: QuotaDates.rfc3339Millis(now),
            identity: AgentIdentity(
                email: nil,
                plan: firstNonEmpty([
                    credentials.subscriptionType,
                    credentials.rateLimitTier,
                ]).map(cleanPlan)),
            windows: windows,
            credits: claudeCredits(usage.extraUsage),
            error: nil)
    }

    // MARK: Credentials

    static func environmentToken() -> String? {
        let env = ProcessInfo.processInfo.environment
        let token = env["TOKCAT_CLAUDE_OAUTH_TOKEN"] ?? env["CODEXBAR_CLAUDE_OAUTH_TOKEN"]
        return token
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static func loadClaudeCredentials() throws -> ClaudeCredentials {
        if let credentials = loadCredentialsFromEnvironment() {
            return credentials
        }

        switch loadCredentialsFromKeychain() {
        case .success(.some(let raw)):
            return try parseClaudeCredentialsData(raw)
        case .failure(let error):
            throw error
        case .success(.none):
            break
        }

        let credentialsPath = claudeCredentialsPath()
        if FileManager.default.fileExists(atPath: credentialsPath.path) {
            do {
                let raw = try String(contentsOf: credentialsPath, encoding: .utf8)
                return try parseClaudeCredentialsData(raw)
            } catch let error as QuotaError {
                throw error
            } catch {
                throw QuotaError(
                    "read Claude credentials file \(credentialsPath.path): \(error.localizedDescription)")
            }
        }

        throw QuotaError("Claude OAuth credentials not found. Run `claude` to authenticate.")
    }

    static func loadCredentialsFromEnvironment() -> ClaudeCredentials? {
        guard let accessToken = environmentToken() else { return nil }
        let env = ProcessInfo.processInfo.environment
        let rawScopes = env["TOKCAT_CLAUDE_OAUTH_SCOPES"]
            ?? env["CODEXBAR_CLAUDE_OAUTH_SCOPES"] ?? ""
        let scopes = rawScopes
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ClaudeCredentials(
            accessToken: accessToken, refreshToken: nil, expiresAt: nil,
            scopes: scopes, rateLimitTier: nil, subscriptionType: nil)
    }

    /// Keychain lookup through the subprocess guard. `.success(nil)` means
    /// the item genuinely isn't there (fall through to the file);
    /// `.failure` is a spawn error or a stall — surfaced, not swallowed.
    static func loadCredentialsFromKeychain() -> Result<String?, QuotaError> {
        #if os(macOS)
        let result = outputWithTimeout(
            "/usr/bin/security",
            ["find-generic-password", "-s", claudeKeychainService, "-w"],
            timeout: subprocessTimeout)
        switch result {
        case .failure(let error):
            return .failure("read Claude Keychain credentials: \(error)")
        case .success(.failed):
            // The item genuinely isn't there — fall through to the file.
            return .success(nil)
        case .success(.timedOut):
            // Reported as an error, not as absence: `security` stalls when
            // its ACL no longer matches the caller, and treating that as
            // "Claude isn't set up" would drop the card instead of saying
            // what went wrong.
            return .failure(QuotaError(
                "Claude Keychain read timed out after \(Int(subprocessTimeout))s. "
                    + "If macOS is prompting for keychain access, allow it and refresh."))
        case .success(.ok(let stdout)):
            guard let raw = String(data: stdout, encoding: .utf8) else {
                return .failure("Claude Keychain credentials are not UTF-8 JSON.")
            }
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            if trimmed.trimmingCharacters(in: .whitespaces).isEmpty {
                return .success(nil)
            }
            return .success(trimmed)
        }
        #else
        return .success(nil)
        #endif
    }

    static func parseClaudeCredentialsData(_ raw: String) throws -> ClaudeCredentials {
        guard let root = JSONValue.parse(raw) else {
            throw QuotaError("decode Claude OAuth credentials: invalid JSON")
        }
        guard let oauth = root["claudeAiOauth"], oauth.asObject != nil else {
            throw QuotaError("Claude OAuth credentials are missing claudeAiOauth.")
        }
        guard
            let accessToken = oauth["accessToken"]?.asString
                .map({ $0.trimmingCharacters(in: .whitespaces) }),
            !accessToken.isEmpty
        else {
            throw QuotaError("Claude OAuth credentials have no access token.")
        }
        let expiresAt = oauth["expiresAt"]?.asDouble.map {
            Date(timeIntervalSince1970: TimeInterval(Int64($0)) / 1000.0)
        }
        let scopes: [String]
        if case .array(let items)? = oauth["scopes"] {
            scopes = items.compactMap(\.asString)
        } else {
            scopes = []
        }
        return ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"]?.asString
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 },
            expiresAt: expiresAt,
            scopes: scopes,
            rateLimitTier: oauth["rateLimitTier"]?.asString,
            subscriptionType: oauth["subscriptionType"]?.asString)
    }

    static func claudeCredentialsExpired(_ credentials: ClaudeCredentials,
                                         now: Date = Date()) -> Bool {
        guard let expiresAt = credentials.expiresAt else { return false }
        return now >= expiresAt
    }

    /// Refreshed credentials are NOT persisted (mirror: the Rust code never
    /// writes Claude credentials back anywhere).
    static func refreshClaudeCredentials(
        _ credentials: ClaudeCredentials
    ) async throws -> ClaudeCredentials {
        guard let refreshToken = credentials.refreshToken else {
            throw QuotaError(
                "Claude OAuth token is expired and has no refresh token. Run `claude`.")
        }
        var request = URLRequest(url: URL(string: claudeRefreshURL)!)
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": claudeClientID,
        ])

        let status: Int
        let body: Data
        do {
            (status, body) = try await QuotaHTTP.send(request)
        } catch {
            throw QuotaError("Claude OAuth refresh failed: \(error.localizedDescription)")
        }
        if !(200..<300).contains(status) {
            throw QuotaError("Claude OAuth refresh failed. Run `claude` to re-authenticate.")
        }
        guard
            let json = JSONValue.parse(body),
            let accessToken = json["access_token"]?.asString,
            let expiresIn = json["expires_in"]?.asInt64
        else {
            throw QuotaError("decode Claude refresh response: missing fields")
        }
        return ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: json["refresh_token"]?.asString ?? credentials.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            scopes: credentials.scopes,
            rateLimitTier: credentials.rateLimitTier,
            subscriptionType: credentials.subscriptionType)
    }

    /// `claude_user_agent`: `claude --version` through the subprocess guard,
    /// falling back to a pinned version string. Resolved via /usr/bin/env
    /// because Foundation.Process does not do PATH lookup itself.
    static func claudeUserAgent() -> String {
        let result = outputWithTimeout(
            "/usr/bin/env", ["claude", "--version"], timeout: subprocessTimeout)
        if case .success(.ok(let stdout)) = result,
           let text = String(data: stdout, encoding: .utf8),
           let version = text.split(whereSeparator: { $0.isWhitespace }).first,
           !version.isEmpty {
            return "claude-code/\(version)"
        }
        return "claude-code/2.1.0"
    }

    // MARK: Window mapping

    /// Port of `claude_windows` (:1192-1210).
    static func claudeWindows(_ usage: ClaudeUsageResponse, now: Date) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        appendWindow(&windows, label: "Session", window: usage.fiveHour, now: now)
        appendWindow(&windows, label: "Weekly", window: usage.sevenDay, now: now)
        appendWindow(&windows, label: "OAuth Apps", window: usage.sevenDayOauthApps, now: now)
        appendWindow(&windows, label: "Sonnet", window: usage.sevenDaySonnet, now: now)
        appendWindow(&windows, label: "Opus", window: usage.sevenDayOpus, now: now)
        appendWindow(&windows, label: "Designs", window: usage.designWindow, now: now)
        appendWindow(&windows, label: "Daily Routines", window: usage.routinesWindow, now: now)
        if let extra = claudeExtraUsageWindow(usage.extraUsage) {
            windows.append(extra)
        }
        return windows
    }

    private static func appendWindow(
        _ windows: inout [UsageWindow], label: String, window: ClaudeWindow?, now: Date
    ) {
        if let mapped = window.flatMap({ mapClaudeWindow(label: label, window: $0, now: now) }) {
            windows.append(mapped)
        }
    }

    /// Port of `map_claude_window` (:1255-1269).
    static func mapClaudeWindow(label: String, window: ClaudeWindow, now: Date) -> UsageWindow? {
        guard let utilization = window.utilization else { return nil }
        let used = min(100.0, max(0.0, utilization))
        let resetsAt = window.resetsAt.flatMap(QuotaDates.parse)
        return UsageWindow(
            label: label,
            usedPercent: used,
            remainingPercent: max(100.0 - used, 0.0),
            resetsAt: resetsAt.map(QuotaDates.rfc3339Millis),
            resetText: resetsAt.map { quotaResetText(reset: $0, now: now) })
    }

    /// Port of `claude_extra_usage_window` (:1271-1300).
    static func claudeExtraUsageWindow(_ extra: ClaudeExtraUsage?) -> UsageWindow? {
        guard let extra, extra.isEnabled else { return nil }
        let used: Double? = extra.utilization ?? {
            guard let usedCredits = extra.usedCredits,
                  let limit = extra.monthlyLimit, limit > 0 else {
                return nil
            }
            return (usedCredits / limit) * 100.0
        }()
        guard let used else { return nil }
        var resetText: String?
        if let usedCredits = extra.usedCredits, let limit = extra.monthlyLimit {
            resetText = "Monthly cap: "
                + formatCurrencyMinorUnits(usedCredits, currency: extra.currency)
                + " / "
                + formatCurrencyMinorUnits(limit, currency: extra.currency)
        }
        return UsageWindow(
            label: "Extra usage",
            usedPercent: min(100.0, max(0.0, used)),
            remainingPercent: max(100.0 - used, 0.0),
            resetsAt: nil,
            resetText: resetText)
    }

    /// Port of `claude_credits` (:1302-1315).
    static func claudeCredits(_ extra: ClaudeExtraUsage?) -> CreditsSnapshot? {
        guard let extra, extra.isEnabled else { return nil }
        var remaining: Double?
        if let limit = extra.monthlyLimit, let used = extra.usedCredits {
            remaining = max((limit - used) / 100.0, 0.0)
        }
        return CreditsSnapshot(remaining: remaining, unlimited: false)
    }
}

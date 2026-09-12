import DataSource
import Foundation

// Codex Cloud usage, from the same authenticated backend the app uses.
//
// `codex cloud list` reports what tasks exist but no usage; the per-thread
// usage endpoint (`/wham/usage/thread_usage/query`) answers 403 with the CLI's
// OAuth token. What does answer is the account's daily breakdown:
//
//   GET /backend-api/wham/usage/daily-token-usage-breakdown
//       ?start_date=YYYY-MM-DD&end_date=YYYY-MM-DD&group_by=day
//
// one entry per day, each with `product_surface_usage_values` split by where
// the work ran — `web`/`work_web`/`mobile` are cloud surfaces, `cli`/`vscode`/
// `desktop_app`/`exec` are this Mac. Units are percent of the plan's allowance
// (`units: "percent"`), not tokens: the same number the account's own usage
// page shows, so a cloud row here is comparable with the quota card rather
// than with the token graph.
//
// Verified against the app's own call shape (ChatGPT.app app.asar):
// `safeGet('/wham/usage/daily-token-usage-breakdown', {parameters: {query:
// {start_date, end_date, group_by: 'day'}}})`.

private let codexDailyUsageURL = "https://chatgpt.com/backend-api/wham/usage/daily-token-usage-breakdown"

/// Surfaces that are not this Mac: Codex Cloud web/mobile, integrations, and
/// background agents. Everything else ran through a local client Tokcat
/// already reads from disk.
public let codexCloudSurfaces: Set<String> = [
    "web", "work_web", "mobile", "work_mobile",
    "slack", "linear", "jetbrains", "github", "github_code_review",
    "agent_identity", "sdk",
]

public struct CodexDailyModel: Sendable, Codable, Equatable {
    public var model: String
    public var speed: String?
    public var credits: Double
}

public struct CodexDailyUsage: Sendable, Codable, Equatable {
    public var date: String
    public var surfaces: [String: Double]
    public var models: [CodexDailyModel]
    /// Sum of the cloud surfaces in `surfaces`.
    public var cloudPercent: Double
    /// Sum of the local surfaces in `surfaces`.
    public var localPercent: Double
}

public struct CodexCloudUsageReport: Sendable, Codable {
    /// Always "percent" today: the breakdown is plan consumption, not tokens.
    public var units: String
    public var groupBy: String
    public var days: [CodexDailyUsage]
    public var cloudTotalPercent: Double
    public var localTotalPercent: Double
    /// Days where any cloud surface was non-zero.
    public var cloudDays: Int
}

public enum CodexCloudUsageError: Error, CustomStringConvertible {
    case notConfigured
    case http(Int)
    case decode(String)

    public var description: String {
        switch self {
        case .notConfigured:
            return "Codex OAuth credentials not found. Run `codex` to authenticate."
        case .http(let status):
            return "Codex daily usage API returned \(status)."
        case .decode(let detail):
            return "decode Codex daily usage response: \(detail)"
        }
    }
}

/// Wire shape of the endpoint (snake_case, like the rest of the Codex API).
struct CodexDailyUsageResponse: Decodable {
    var units: String?
    var groupBy: String?
    var data: [CodexDailyUsageEntry]

    enum CodingKeys: String, CodingKey {
        case units
        case groupBy = "group_by"
        case data
    }
}

struct CodexDailyUsageEntry: Decodable {
    var date: String
    var productSurfaceUsageValues: [String: Double]
    var models: [CodexDailyUsageEntryModel]

    enum CodingKeys: String, CodingKey {
        case date
        case productSurfaceUsageValues = "product_surface_usage_values"
        case models
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? container.decode(String.self, forKey: .date)) ?? ""
        // Lenient: an unseen surface must not fail the whole breakdown.
        productSurfaceUsageValues =
            (try? container.decode([String: Double].self, forKey: .productSurfaceUsageValues))
            ?? [:]
        models =
            (try? container.decode([CodexDailyUsageEntryModel].self, forKey: .models)) ?? []
    }
}

struct CodexDailyUsageEntryModel: Decodable {
    var model: String
    var speed: String?
    var credits: Double?
}

public enum CodexCloudUsageProvider {
    public static var isConfigured: Bool {
        FileManager.default.fileExists(
            atPath: codexHome().appendingPathComponent("auth.json").path)
    }

    /// `YYYY-MM-DD` in UTC — the endpoint's date parameters.
    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Daily plan consumption for the last `days` days, split by surface.
    public static func fetch(days: Int = 30, now: Date = Date()) async throws
        -> CodexCloudUsageReport
    {
        guard isConfigured else { throw CodexCloudUsageError.notConfigured }
        var credentials = try CodexQuotaProvider.loadCodexCredentials()
        if CodexQuotaProvider.codexCredentialsNeedRefresh(lastRefresh: credentials.lastRefresh) {
            let refreshToken = credentials.refreshToken ?? ""
            if refreshToken.isEmpty {
                throw QuotaError(
                    "Codex OAuth token needs refresh but auth.json has no refresh token.")
            }
            credentials = try await CodexQuotaProvider.refreshCodexCredentials(credentials)
        }

        let end = dateString(now)
        let start = dateString(
            Calendar(identifier: .gregorian).date(byAdding: .day, value: -(max(days, 1) - 1), to: now)
                ?? now)
        var components = URLComponents(string: codexDailyUsageURL)!
        components.queryItems = [
            URLQueryItem(name: "start_date", value: start),
            URLQueryItem(name: "end_date", value: end),
            URLQueryItem(name: "group_by", value: "day"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tokcat", forHTTPHeaderField: "User-Agent")
        if let accountId = credentials.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (status, body) = try await QuotaHTTP.send(request)
        if status == 401 || status == 403 {
            throw QuotaError("Codex OAuth token expired or invalid. Run `codex` to log in again.")
        }
        guard (200..<300).contains(status) else { throw CodexCloudUsageError.http(status) }
        let response: CodexDailyUsageResponse
        do {
            response = try JSONDecoder().decode(CodexDailyUsageResponse.self, from: body)
        } catch {
            throw CodexCloudUsageError.decode("\(error)")
        }
        return report(from: response)
    }

    /// Split each day into cloud vs local surfaces. Pure, so the tests can pin
    /// the classification without a network round trip.
    static func report(from response: CodexDailyUsageResponse) -> CodexCloudUsageReport {
        var days: [CodexDailyUsage] = []
        var cloudTotal = 0.0
        var localTotal = 0.0
        var cloudDays = 0
        for entry in response.data where !entry.date.isEmpty {
            var cloud = 0.0
            var local = 0.0
            for (surface, value) in entry.productSurfaceUsageValues {
                if codexCloudSurfaces.contains(surface) {
                    cloud += max(value, 0)
                } else {
                    local += max(value, 0)
                }
            }
            if cloud > 0 { cloudDays += 1 }
            cloudTotal += cloud
            localTotal += local
            days.append(
                CodexDailyUsage(
                    date: entry.date,
                    surfaces: entry.productSurfaceUsageValues,
                    models: entry.models.map {
                        CodexDailyModel(
                            model: $0.model, speed: $0.speed, credits: $0.credits ?? 0)
                    },
                    cloudPercent: cloud,
                    localPercent: local))
        }
        days.sort { $0.date < $1.date }
        return CodexCloudUsageReport(
            units: response.units ?? "percent",
            groupBy: response.groupBy ?? "day",
            days: days,
            cloudTotalPercent: cloudTotal,
            localTotalPercent: localTotal,
            cloudDays: cloudDays)
    }
}

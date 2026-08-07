import DataSource
import Foundation

// Port of the Cursor quota provider in agent_usage.rs (:20-24, 260-291,
// 352-359, 493-571, 1317-1411).
//
// Cursor current-period usage. A Connect RPC (not one of the cookie-authed
// cursor.com dashboard endpoints), so the session token from Cursor's state
// DB goes straight in as a bearer token — no WorkOS cookie or CSRF headers.

private let cursorUsageURL =
    "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"

/// `GetCurrentPeriodUsage` response. Every field is optional: Cursor changes
/// this payload with its billing model, and a missing field must degrade to
/// "no window" rather than fail the whole snapshot.
struct CursorPeriodUsage: Decodable {
    var billingCycleEnd: String?
    var planUsage: CursorPlanUsage?

    enum CodingKeys: String, CodingKey {
        case billingCycleEnd
        case planUsage
    }

    init(billingCycleEnd: String? = nil, planUsage: CursorPlanUsage? = nil) {
        self.billingCycleEnd = billingCycleEnd
        self.planUsage = planUsage
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        billingCycleEnd = try? container.decodeIfPresent(String.self, forKey: .billingCycleEnd)
        planUsage = try container.decodeIfPresent(CursorPlanUsage.self, forKey: .planUsage)
    }
}

/// Money fields are minor units (cents); percentages are already 0-100.
/// Connect encodes int64 as JSON strings, so every number is lenient.
struct CursorPlanUsage: Decodable {
    var limit: Double?
    var used: Double?
    var remaining: Double?
    var totalPercentUsed: Double?
    /// Cursor's own (auto-routed) model pool.
    var autoPercentUsed: Double?
    /// Third-party model pool billed at API rates.
    var apiPercentUsed: Double?

    enum CodingKeys: String, CodingKey {
        case limit
        case used
        case remaining
        case totalPercentUsed
        case autoPercentUsed
        case apiPercentUsed
    }

    init(limit: Double? = nil, used: Double? = nil, remaining: Double? = nil,
         totalPercentUsed: Double? = nil, autoPercentUsed: Double? = nil,
         apiPercentUsed: Double? = nil) {
        self.limit = limit
        self.used = used
        self.remaining = remaining
        self.totalPercentUsed = totalPercentUsed
        self.autoPercentUsed = autoPercentUsed
        self.apiPercentUsed = apiPercentUsed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limit = container.lenientDouble(.limit)
        used = container.lenientDouble(.used)
        remaining = container.lenientDouble(.remaining)
        totalPercentUsed = container.lenientDouble(.totalPercentUsed)
        autoPercentUsed = container.lenientDouble(.autoPercentUsed)
        apiPercentUsed = container.lenientDouble(.apiPercentUsed)
    }
}

public enum CursorQuotaProvider {
    /// Whether Cursor is installed *and* signed in. An absent token means
    /// "not set up" and the tile stays hidden rather than showing a
    /// permanent sign-in error.
    ///
    /// Note this is independent of the `cursorUsage` opt-in, which gates the
    /// historical event fetch feeding the contribution graph. Plan quota is
    /// read here on the same terms as every other agent's limits.
    public static var isConfigured: Bool {
        CursorState.readStateValue("cursorAuth/accessToken") != nil
    }

    public static func fetch() async -> AgentUsageSnapshot {
        do {
            return try await fetchInner()
        } catch {
            return AgentUsageSnapshot(
                clientId: "cursor", source: "oauth",
                updatedAt: QuotaDates.rfc3339Millis(Date()),
                identity: nil, windows: [], credits: nil,
                error: "\(error)")
        }
    }

    static func fetchInner() async throws -> AgentUsageSnapshot {
        let token: String
        switch CursorState.readAccessToken() {
        case .failure(let error): throw error
        case .success(let value): token = value
        }

        var request = URLRequest(url: URL(string: cursorUsageURL)!)
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Connect RPC over plain JSON; without this header the server
        // answers with a protobuf frame instead.
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tokcat", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let status: Int
        let body: Data
        do {
            (status, body) = try await QuotaHTTP.send(request)
        } catch {
            throw QuotaError("Cursor usage request failed: \(error.localizedDescription)")
        }

        if status == 401 || status == 403 {
            throw QuotaError("Cursor session expired. Open Cursor and sign in again.")
        }
        if !(200..<300).contains(status) {
            throw QuotaError("Cursor usage API returned \(status).")
        }

        let usage: CursorPeriodUsage
        do {
            usage = try JSONDecoder().decode(CursorPeriodUsage.self, from: body)
        } catch {
            throw QuotaError("decode Cursor usage response: \(error)")
        }
        let now = Date()
        let windows = cursorWindows(
            plan: usage.planUsage,
            billingCycleEnd: usage.billingCycleEnd,
            now: now)
        if windows.isEmpty {
            throw QuotaError("Cursor usage API returned no plan windows.")
        }

        return AgentUsageSnapshot(
            clientId: "cursor",
            // Cursor's session token is an OAuth access token issued by
            // authentication.cursor.sh; the tile renders this verbatim as
            // its badge, and "SESSION" there reads like a session-length
            // quota.
            source: "oauth",
            updatedAt: QuotaDates.rfc3339Millis(now),
            // Both read locally: Cursor caches them in the same state DB the
            // token comes from, so the plan label survives even when the API
            // call fails.
            identity: AgentIdentity(
                email: CursorState.readStateValue("cursorAuth/cachedEmail"),
                plan: CursorState.readStateValue("cursorAuth/stripeMembershipType")
                    .map(cleanPlan)),
            windows: windows,
            credits: cursorCredits(plan: usage.planUsage),
            error: nil)
    }

    // MARK: Window mapping

    /// Map the current billing period onto usage windows, mirroring what
    /// Cursor's own Plan & Usage page shows: one bar per model pool, and no
    /// combined bar.
    ///
    /// `totalPercentUsed` blends the pools by dollars, so on a plan whose
    /// pools differ wildly in size it reads far below the pool that's
    /// actually running out — a fallback for accounts that don't report the
    /// split, never the headline.
    static func cursorWindows(
        plan: CursorPlanUsage?, billingCycleEnd: String?, now: Date
    ) -> [UsageWindow] {
        guard let plan else { return [] }
        let resetsAt = billingCycleEnd.flatMap(parseCursorDatetime)
        // Labels match Cursor's own vocabulary so the rows can be read
        // straight against its dashboard.
        let pools: [UsageWindow] = [
            ("Cursor Models", plan.autoPercentUsed),
            ("Other Models", plan.apiPercentUsed),
        ].compactMap { label, percent in
            percent.flatMap {
                cursorWindow(label: label, usedPercent: $0, resetsAt: resetsAt, now: now)
            }
        }
        if !pools.isEmpty { return pools }

        let total: Double? = plan.totalPercentUsed ?? {
            // Older payloads report only the dollar figures; derive the
            // percentage from whichever pair is present.
            guard let limit = plan.limit, limit > 0 else { return nil }
            guard let used = plan.used ?? plan.remaining.map({ limit - $0 }) else {
                return nil
            }
            return (used / limit) * 100.0
        }()
        guard let total,
              let window = cursorWindow(
                label: "Monthly", usedPercent: total, resetsAt: resetsAt, now: now)
        else { return [] }
        return [window]
    }

    static func cursorWindow(
        label: String, usedPercent: Double, resetsAt: Date?, now: Date
    ) -> UsageWindow? {
        guard usedPercent.isFinite else { return nil }
        let used = min(100.0, max(0.0, usedPercent))
        return UsageWindow(
            label: label,
            usedPercent: used,
            remainingPercent: max(100.0 - used, 0.0),
            resetsAt: resetsAt.map(QuotaDates.rfc3339Millis),
            resetText: resetsAt.map { quotaResetText(reset: $0, now: now) })
    }

    /// Dollars left in the monthly included-usage allowance. Cursor reports
    /// money in cents; `CreditsSnapshot.remaining` is major units.
    /// A missing or zero limit means "not reported", not "unlimited" —
    /// claiming unlimited on a plan we can't read would be worse than
    /// showing nothing.
    static func cursorCredits(plan: CursorPlanUsage?) -> CreditsSnapshot? {
        guard let plan, let limit = plan.limit, limit > 0 else { return nil }
        guard
            let remaining = plan.remaining ?? plan.used.map({ limit - $0 }),
            remaining.isFinite
        else { return nil }
        return CreditsSnapshot(remaining: max(remaining / 100.0, 0.0), unlimited: false)
    }

    /// `billingCycleEnd` shows up as both an RFC3339 timestamp and epoch
    /// millis (string-encoded, as Connect does with int64) — accept either.
    static func parseCursorDatetime(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if let parsed = QuotaDates.parse(trimmed) { return parsed }
        guard let millis = Int64(trimmed) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000.0)
    }
}

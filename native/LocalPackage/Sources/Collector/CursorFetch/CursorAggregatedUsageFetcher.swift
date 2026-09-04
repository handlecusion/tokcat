import Foundation

// Connect RPC used by the live-session poller. Same auth shape as
// CursorQuotaProvider (bearer + Connect-Protocol-Version) — not the
// cookie/CSRF dashboard path used by the historical event cache.

private let aggregatedUsageURL =
    "https://api2.cursor.sh/aiserver.v1.DashboardService/GetAggregatedUsageEvents"
private let dayMs: Int64 = 86_400_000

public enum CursorAggregatedUsageFetcher {
    /// Fetch one aggregated snapshot for `[startMs, endMs]`.
    /// `endMs` should sit a day past "now" so in-flight events stay inside
    /// the window; `startMs` must stay pinned across polls so the totals
    /// remain a safe high-water mark.
    public static func fetch(startMs: Int64, endMs: Int64) async throws -> CursorAggregatePayload {
        let token: String
        switch CursorState.readAccessToken() {
        case .failure(let error): throw error
        case .success(let value): token = value
        }

        var request = URLRequest(url: URL(string: aggregatedUsageURL)!)
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tokcat", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "teamId": 0,
            "startDate": String(startMs),
            "endDate": String(endMs),
        ])

        let status: Int
        let body: Data
        do {
            (status, body) = try await QuotaHTTP.send(request)
        } catch {
            throw QuotaError("Cursor live usage request failed: \(error.localizedDescription)")
        }
        if status == 401 || status == 403 {
            throw CursorLiveHTTPError.status(status)
        }
        if status == 429 {
            throw CursorLiveHTTPError.status(429)
        }
        if !(200..<300).contains(status) {
            throw CursorLiveHTTPError.status(status)
        }
        var payload = try parseCursorAggregateResponse(body)
        // Non-secret JWT `sub` binds the baseline to one Cursor account so
        // a mid-session account switch cannot look like a usage burst.
        if let sub = try? CursorUsageFetcher.jwtSubject(token) {
            payload.accountKey = sub
        }
        return payload
    }

    /// Default pinned lookback: six hours behind the first poll attempt.
    /// Long enough to cover a working session; short enough that a cycle
    /// rollover mid-run is still visible as a total decrease (rebaseline).
    public static let pinnedLookbackMs: Int64 = 6 * 60 * 60 * 1000

    public static func defaultEndMs(nowMs: Int64) -> Int64 {
        nowMs + dayMs
    }

    public static func defaultStartMs(nowMs: Int64) -> Int64 {
        nowMs - pinnedLookbackMs
    }
}

/// Transport-level failures the poller uses to pick a backoff. 401/403
/// suspend HTTP until Cursor is quit and relaunched (the token is re-read
/// from state.vscdb on the next fetch). 429 means "slow down".
public enum CursorLiveHTTPError: Error, Equatable, Sendable {
    case status(Int)
}

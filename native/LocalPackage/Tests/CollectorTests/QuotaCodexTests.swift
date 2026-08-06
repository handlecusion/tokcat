import DataSource
import Foundation
import Testing

@testable import Collector

// Ports of the Codex mapping tests in agent_usage.rs (:2549-2677) plus
// JWT-decode fixtures for the identity path.

private func date(_ epochSeconds: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(epochSeconds))
}

/// Build an unsigned JWT with the given payload object (base64url, no
/// padding — the decoder must re-pad manually).
private func fakeJWT(payload: [String: Any]) -> String {
    let header = Data("{\"alg\":\"none\"}".utf8)
    let body = try! JSONSerialization.data(withJSONObject: payload)
    func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64url(header)).\(b64url(body)).sig"
}

@Suite(.serialized) struct QuotaCodexTests {
    @Test func mapsPrimaryAndSecondaryWindows() {
        let now = date(1_700_000_000)
        let rateLimit = CodexRateLimit(from: (
            primary: CodexWindow(usedPercent: 8, resetAt: 1_700_005_400,
                                 limitWindowSeconds: 18_000),
            secondary: CodexWindow(usedPercent: 35, resetAt: 1_700_172_800,
                                   limitWindowSeconds: 604_800)))
        let windows = CodexQuotaProvider.codexWindows(
            rateLimit: rateLimit, additionalRateLimits: nil, spendControl: nil, now: now)
        #expect(windows.count == 2)
        #expect(windows[0].label == "Session")
        #expect(windows[0].remainingPercent == 92)
        #expect(windows[1].label == "Weekly")
        #expect(windows[1].remainingPercent == 65)
    }

    @Test func swapsRolesWhenPrimaryIsWeekly() {
        // The server sometimes reports the weekly window first; the labels
        // are positional, so the pair must swap (:1128-1139).
        let now = date(1_700_000_000)
        let rateLimit = CodexRateLimit(from: (
            primary: CodexWindow(usedPercent: 35, resetAt: 1_700_172_800,
                                 limitWindowSeconds: 604_800),
            secondary: CodexWindow(usedPercent: 8, resetAt: 1_700_005_400,
                                   limitWindowSeconds: 18_000)))
        let windows = CodexQuotaProvider.codexWindows(
            rateLimit: rateLimit, additionalRateLimits: nil, spendControl: nil, now: now)
        #expect(windows.count == 2)
        #expect(windows[0].label == "Session")
        #expect(windows[0].usedPercent == 8)
        #expect(windows[1].label == "Weekly")
        #expect(windows[1].usedPercent == 35)
    }

    @Test func doesNotSwapWhenBothAreWeekly() {
        let now = date(1_700_000_000)
        let rateLimit = CodexRateLimit(from: (
            primary: CodexWindow(usedPercent: 35, resetAt: 1_700_172_800,
                                 limitWindowSeconds: 604_800),
            secondary: CodexWindow(usedPercent: 8, resetAt: 1_700_005_400,
                                   limitWindowSeconds: 604_800)))
        let windows = CodexQuotaProvider.codexWindows(
            rateLimit: rateLimit, additionalRateLimits: nil, spendControl: nil, now: now)
        #expect(windows[0].label == "Session")
        #expect(windows[0].usedPercent == 35)
    }

    @Test func mapsAdditionalModelLimits() {
        let now = date(1_700_000_000)
        let extra = CodexAdditionalRateLimit(
            limitName: "gpt-5.2-codex-spark",
            meteredFeature: nil,
            rateLimit: CodexRateLimit(from: (
                primary: CodexWindow(usedPercent: 41, resetAt: 1_700_003_600,
                                     limitWindowSeconds: 18_000),
                secondary: nil)))
        let windows = CodexQuotaProvider.codexWindows(
            rateLimit: nil, additionalRateLimits: [extra], spendControl: nil, now: now)
        #expect(windows.count == 1)
        #expect(windows[0].label == "Codex Spark")
        #expect(windows[0].remainingPercent == 59)
    }

    @Test func mapsBusinessSpendControl() throws {
        // Recorded-shape fixture: string-encoded money fields, integer
        // percents — the lenient decode has to take both.
        let raw = """
            {
                "plan_type": "business",
                "rate_limit": null,
                "additional_rate_limits": null,
                "credits": { "has_credits": true, "unlimited": false, "balance": "910" },
                "spend_control": {
                    "reached": false,
                    "individual_limit": {
                        "source": "account_user_spend_controls",
                        "limit": "1000",
                        "used": "90",
                        "remaining": "910",
                        "used_percent": 9,
                        "remaining_percent": 91,
                        "reset_after_seconds": 1426374,
                        "reset_at": 1785542400
                    }
                }
            }
            """
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(raw.utf8))
        #expect(usage.credits?.balance == 910)
        #expect(usage.credits?.unlimited == false)
        let windows = CodexQuotaProvider.codexWindows(
            rateLimit: usage.rateLimit,
            additionalRateLimits: usage.additionalRateLimits,
            spendControl: usage.spendControl,
            now: date(1_768_435_200))
        #expect(windows.count == 1)
        #expect(windows[0].label == "Monthly spend")
        #expect(windows[0].usedPercent == 9)
        #expect(windows[0].remainingPercent == 91)
        #expect(windows[0].resetsAt == "2026-08-01T00:00:00.000Z")
    }

    @Test func derivesSpendPercentWhenAPIOmitsPercentages() {
        let spendControl = CodexSpendControl(
            individualLimit: CodexSpendLimit(
                limit: 200, used: 50, usedPercent: nil,
                remainingPercent: nil, resetAt: nil))
        let window = CodexQuotaProvider.codexSpendControlWindow(
            spendControl, now: date(1_700_000_000))
        #expect(window?.usedPercent == 25)
        #expect(window?.remainingPercent == 75)
        #expect(window?.resetsAt == nil)
        #expect(window?.resetText == nil)
    }

    @Test func decodesJWTIdentityWithManualPadding() {
        // Payload length chosen so the base64url form needs padding.
        let token = fakeJWT(payload: [
            "email": " user@example.com ",
            "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"],
        ])
        #expect(jwtEmail(token) == "user@example.com")
        #expect(jwtPlan(token) == "plus")
        #expect(cleanPlan(jwtPlan(token)!) == "Plus")
    }

    @Test func jwtReadsNestedProfileEmail() {
        let token = fakeJWT(payload: [
            "https://api.openai.com/profile": ["email": "nested@example.com"],
            "chatgpt_plan_type": "pro",
        ])
        #expect(jwtEmail(token) == "nested@example.com")
        #expect(jwtPlan(token) == "pro")
        #expect(jwtEmail("not-a-jwt") == nil)
        #expect(jwtEmail("a.!!!.c") == nil)
    }

    @Test func credentialsRejectAPIKeyAuth() {
        let raw: [String: Any] = ["OPENAI_API_KEY": "sk-123"]
        #expect(throws: (any Error).self) {
            _ = try CodexQuotaProvider.codexCredentials(
                fromRawJSON: raw, authPath: URL(fileURLWithPath: "/tmp/auth.json"))
        }
    }

    @Test func credentialsReadSnakeAndCamelKeys() throws {
        let raw: [String: Any] = [
            "tokens": [
                "accessToken": " at ",
                "refresh_token": "rt",
                "idToken": "it",
                "account_id": "acc",
            ],
            "last_refresh": "2026-08-01T00:00:00.000Z",
        ]
        let credentials = try CodexQuotaProvider.codexCredentials(
            fromRawJSON: raw, authPath: URL(fileURLWithPath: "/tmp/auth.json"))
        #expect(credentials.accessToken == "at")
        #expect(credentials.refreshToken == "rt")
        #expect(credentials.idToken == "it")
        #expect(credentials.accountId == "acc")
        #expect(credentials.lastRefresh != nil)
    }

    @Test func needsRefreshAfterEightDays() {
        let now = date(1_700_000_000)
        #expect(CodexQuotaProvider.codexCredentialsNeedRefresh(lastRefresh: nil, now: now))
        #expect(!CodexQuotaProvider.codexCredentialsNeedRefresh(
            lastRefresh: now.addingTimeInterval(-8 * 86_400), now: now))
        #expect(CodexQuotaProvider.codexCredentialsNeedRefresh(
            lastRefresh: now.addingTimeInterval(-9 * 86_400), now: now))
    }

    @Test func configuredGateFollowsAuthJSONPresence() throws {
        // Port of codex_tile_gated_on_auth_json_presence (:2549-2571).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokcat-codex-cfg-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            unsetenv("CODEX_HOME")
            try? FileManager.default.removeItem(at: dir)
        }
        setenv("CODEX_HOME", dir.path, 1)
        #expect(!CodexQuotaProvider.isConfigured)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("auth.json"))
        #expect(CodexQuotaProvider.isConfigured)
    }
}

// Test-only convenience: CodexRateLimit is Decodable with no memberwise
// init, so build one through JSON-free construction.
extension CodexRateLimit {
    fileprivate init(from pair: (primary: CodexWindow?, secondary: CodexWindow?)) {
        self.init(primaryWindow: pair.primary, secondaryWindow: pair.secondary)
    }
}

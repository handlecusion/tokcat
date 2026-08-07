import DataSource
import Foundation
import Testing

@testable import Collector

// Ports of the Claude credential/window tests in agent_usage.rs
// (:2679-2753) plus decode coverage for the recorded response shape.

private func date(_ epochSeconds: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(epochSeconds))
}

@Suite struct QuotaClaudeTests {
    @Test func parsesCredentialsFile() throws {
        let raw = """
            {
                "claudeAiOauth": {
                    "accessToken": "access",
                    "refreshToken": "refresh",
                    "expiresAt": 1700000000000,
                    "scopes": ["user:profile"],
                    "rateLimitTier": "max",
                    "subscriptionType": "pro"
                }
            }
            """
        let credentials = try ClaudeQuotaProvider.parseClaudeCredentialsData(raw)
        #expect(credentials.accessToken == "access")
        #expect(credentials.refreshToken == "refresh")
        #expect(credentials.scopes == ["user:profile"])
        #expect(credentials.subscriptionType == "pro")
        #expect(credentials.expiresAt == date(1_700_000_000))
    }

    @Test func credentialParsingErrors() {
        #expect(throws: (any Error).self) {
            _ = try ClaudeQuotaProvider.parseClaudeCredentialsData("{}")
        }
        #expect(throws: (any Error).self) {
            _ = try ClaudeQuotaProvider.parseClaudeCredentialsData(
                #"{"claudeAiOauth":{"accessToken":"  "}}"#)
        }
    }

    @Test func expiryComparesAgainstNow() {
        let credentials = ClaudeCredentials(
            accessToken: "a", refreshToken: nil,
            expiresAt: date(1_700_000_000), scopes: [],
            rateLimitTier: nil, subscriptionType: nil)
        #expect(ClaudeQuotaProvider.claudeCredentialsExpired(
            credentials, now: date(1_700_000_000)))
        #expect(!ClaudeQuotaProvider.claudeCredentialsExpired(
            credentials, now: date(1_699_999_999)))
        var noExpiry = credentials
        noExpiry.expiresAt = nil
        #expect(!ClaudeQuotaProvider.claudeCredentialsExpired(
            noExpiry, now: date(1_800_000_000)))
    }

    @Test func mapsOAuthWindows() {
        let now = date(1_700_000_000)
        let usage = ClaudeUsageResponse(
            fiveHour: ClaudeWindow(utilization: 8, resetsAt: "2023-11-14T23:13:20Z"),
            sevenDay: ClaudeWindow(utilization: 23, resetsAt: "2023-11-17T22:13:20Z"),
            sevenDaySonnet: ClaudeWindow(utilization: 3, resetsAt: nil),
            sevenDayDesign: ClaudeWindow(utilization: 0, resetsAt: nil))
        let windows = ClaudeQuotaProvider.claudeWindows(usage, now: now)
        #expect(windows.count == 4)
        #expect(windows[0].label == "Session")
        #expect(windows[0].remainingPercent == 92)
        #expect(windows[1].label == "Weekly")
        #expect(windows[1].remainingPercent == 77)
        #expect(windows[2].label == "Sonnet")
        #expect(windows[2].remainingPercent == 97)
        #expect(windows[3].label == "Designs")
        #expect(windows[3].remainingPercent == 100)
        // reset_text derives from resets_at
        #expect(windows[0].resetText != nil)
        #expect(windows[2].resetText == nil)
    }

    @Test func decodesAliasWindowsWithoutDuplicates() throws {
        // Recorded-shape fixture: aliased design/routines keys must decode
        // side by side and collapse via the first-non-nil chains.
        let raw = """
            {
                "five_hour": { "utilization": 5, "resets_at": "2026-05-28T14:00:00Z" },
                "seven_day": { "utilization": 23, "resets_at": "2026-05-31T14:00:00Z" },
                "seven_day_sonnet": { "utilization": 3, "resets_at": null },
                "seven_day_omelette": { "utilization": 0, "resets_at": null },
                "omelette_promotional": { "utilization": 0, "resets_at": null },
                "seven_day_cowork": { "utilization": 0, "resets_at": null }
            }
            """
        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(raw.utf8))
        let windows = ClaudeQuotaProvider.claudeWindows(usage, now: date(1_700_000_000))
        #expect(windows.map(\.label)
            == ["Session", "Weekly", "Sonnet", "Designs", "Daily Routines"])
    }

    @Test func extraUsageWindowAndCredits() throws {
        let raw = """
            {
                "five_hour": { "utilization": 1, "resets_at": null },
                "extra_usage": {
                    "is_enabled": true,
                    "monthly_limit": 5000,
                    "used_credits": "1250",
                    "currency": "usd"
                }
            }
            """
        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(raw.utf8))
        let windows = ClaudeQuotaProvider.claudeWindows(usage, now: date(1_700_000_000))
        #expect(windows.count == 2)
        #expect(windows[1].label == "Extra usage")
        #expect(windows[1].usedPercent == 25)
        #expect(windows[1].resetText == "Monthly cap: $12.50 / $50.00")
        let credits = ClaudeQuotaProvider.claudeCredits(usage.extraUsage)
        #expect(credits?.remaining == 37.5)
        #expect(credits?.unlimited == false)
        // Disabled extra usage yields neither window nor credits.
        let disabled = ClaudeExtraUsage(
            isEnabled: false, monthlyLimit: 100, usedCredits: 10,
            utilization: nil, currency: nil)
        #expect(ClaudeQuotaProvider.claudeExtraUsageWindow(disabled) == nil)
        #expect(ClaudeQuotaProvider.claudeCredits(disabled) == nil)
    }

    @Test func environmentScopesSplitOnCommasAndSpaces() {
        setenv("TOKCAT_CLAUDE_OAUTH_TOKEN", " tok ", 1)
        setenv("TOKCAT_CLAUDE_OAUTH_SCOPES", "user:profile, user:inference", 1)
        defer {
            unsetenv("TOKCAT_CLAUDE_OAUTH_TOKEN")
            unsetenv("TOKCAT_CLAUDE_OAUTH_SCOPES")
        }
        let credentials = ClaudeQuotaProvider.loadCredentialsFromEnvironment()
        #expect(credentials?.accessToken == "tok")
        #expect(credentials?.scopes == ["user:profile", "user:inference"])
        // Env token alone marks Claude as configured.
        #expect(ClaudeQuotaProvider.isConfigured)
    }

    @Test func userAgentFallsBackWhenClaudeIsMissing() {
        // Whatever the machine has, the result is always claude-code/<semver-ish>.
        let userAgent = ClaudeQuotaProvider.claudeUserAgent()
        #expect(userAgent.hasPrefix("claude-code/"))
        #expect(userAgent.count > "claude-code/".count)
    }
}

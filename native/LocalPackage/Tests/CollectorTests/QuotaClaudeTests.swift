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
        // A blob carrying a refreshToken still parses; the token itself is not
        // lifted into ClaudeCredentials, which has no field for it (#55).
        let credentials = try ClaudeQuotaProvider.parseClaudeCredentialsData(raw)
        #expect(credentials.accessToken == "access")
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
            accessToken: "a",
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

    /// An expired token must be reported, never renewed: redeeming the refresh
    /// token rotates it server-side and Tokcat cannot write the replacement
    /// back into the Keychain, which would log Claude Code out (#55).
    ///
    /// The message is asserted verbatim because it is the whole remedy the
    /// user gets: it has to send them to `claude` to refresh, and must not
    /// imply the login is gone and needs re-authenticating.
    @Test func expiredCredentialsAreReportedNotRefreshed() {
        let expired = ClaudeCredentials(
            accessToken: "a",
            expiresAt: date(1_700_000_000), scopes: ["user:profile"],
            rateLimitTier: nil, subscriptionType: nil)
        let error = #expect(throws: QuotaError.self) {
            try ClaudeQuotaProvider.validateCredentials(
                expired, now: date(1_700_000_001))
        }
        #expect(error?.message == "Claude access token expired. Run `claude` to refresh it.")
    }

    /// Expiry is checked before scopes, so a credential that is both expired
    /// and under-scoped reports the expiry — the actionable one, since running
    /// `claude` is what refreshes it.
    @Test func expiryIsReportedBeforeScope() {
        let credentials = ClaudeCredentials(
            accessToken: "a",
            expiresAt: date(1_700_000_000), scopes: ["user:inference"],
            rateLimitTier: nil, subscriptionType: nil)
        let error = #expect(throws: QuotaError.self) {
            try ClaudeQuotaProvider.validateCredentials(
                credentials, now: date(1_700_000_001))
        }
        #expect(error?.message == "Claude access token expired. Run `claude` to refresh it.")
    }

    @Test func validateAcceptsLiveCredentials() throws {
        let live = ClaudeCredentials(
            accessToken: "a",
            expiresAt: date(1_700_000_000), scopes: ["user:profile"],
            rateLimitTier: nil, subscriptionType: nil)
        try ClaudeQuotaProvider.validateCredentials(live, now: date(1_699_999_999))

        // No expiry recorded is not treated as expired.
        var noExpiry = live
        noExpiry.expiresAt = nil
        try ClaudeQuotaProvider.validateCredentials(noExpiry, now: date(1_800_000_000))

        // Scopes are only enforced when the credential actually lists them.
        var noScopes = live
        noScopes.scopes = []
        try ClaudeQuotaProvider.validateCredentials(noScopes, now: date(1_699_999_999))
    }

    @Test func validateRejectsMissingProfileScope() {
        let credentials = ClaudeCredentials(
            accessToken: "a",
            expiresAt: nil, scopes: ["user:inference"],
            rateLimitTier: nil, subscriptionType: nil)
        let error = #expect(throws: QuotaError.self) {
            try ClaudeQuotaProvider.validateCredentials(
                credentials, now: date(1_700_000_000))
        }
        #expect(error?.message == "Claude OAuth token lacks the user:profile scope. "
            + "Run `claude logout && claude login`.")
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

    /// The shape the endpoint returns for an account whose only per-model
    /// weekly limit is a newer model: the fixed per-model fields are null and
    /// the limit exists only as a `weekly_scoped` row in `limits`.
    @Test func scopedModelLimitBecomesAWindow() throws {
        let raw = """
            {
                "five_hour": null,
                "seven_day": { "utilization": 27.0, "resets_at": "2026-05-31T14:00:00.401948+00:00" },
                "seven_day_opus": null,
                "seven_day_sonnet": null,
                "extra_usage": { "is_enabled": false, "monthly_limit": null },
                "limits": [
                    {
                        "kind": "weekly_all", "group": "weekly", "percent": 27,
                        "severity": "normal",
                        "resets_at": "2026-05-31T14:00:00.401948+00:00",
                        "scope": null, "is_active": true
                    },
                    {
                        "kind": "weekly_scoped", "group": "weekly", "percent": 24,
                        "severity": "normal",
                        "resets_at": "2026-05-31T14:00:00.402098+00:00",
                        "scope": {
                            "model": { "id": null, "display_name": "Fable" },
                            "surface": null
                        },
                        "is_active": false
                    }
                ],
                "weekly_scoped_shares": [
                    { "limit_index": 1, "used_percent_of_weekly": 12 }
                ]
            }
            """
        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(raw.utf8))
        // 2026-05-30T14:00:00Z, one day before the reset.
        let windows = ClaudeQuotaProvider.claudeWindows(usage, now: date(1_780_149_600))
        #expect(windows.map(\.label) == ["Weekly", "Fable"])
        #expect(windows[1].usedPercent == 24)
        #expect(windows[1].remainingPercent == 76)
        #expect(windows[1].resetsAt == "2026-05-31T14:00:00.402Z")
        #expect(windows[1].resetText != nil)
    }

    /// Scoped rows sit with the other per-model rows, in the server's order,
    /// and never repeat a row the fixed fields already produced.
    @Test func scopedModelLimitsAreOrderedAndDeduplicated() throws {
        let raw = """
            {
                "five_hour": { "utilization": 5, "resets_at": null },
                "seven_day": { "utilization": 23, "resets_at": null },
                "seven_day_sonnet": { "utilization": 3, "resets_at": null },
                "seven_day_omelette": { "utilization": 0, "resets_at": null },
                "limits": [
                    { "kind": "session", "percent": 5, "scope": null },
                    { "kind": "weekly_all", "percent": 23, "scope": null },
                    { "kind": "weekly_scoped", "percent": 90,
                      "scope": { "model": { "display_name": "sonnet" } } },
                    { "kind": "weekly_scoped", "percent": 40,
                      "scope": { "model": { "display_name": "Fable" } } },
                    { "kind": "weekly_scoped", "percent": 10,
                      "scope": { "model": { "display_name": " Saga " } } },
                    { "kind": "weekly_scoped", "percent": 99,
                      "scope": { "model": { "display_name": "FABLE" } } },
                    { "kind": "weekly_scoped", "percent": 50,
                      "scope": { "model": { "display_name": "Designs" } } }
                ]
            }
            """
        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(raw.utf8))
        let windows = ClaudeQuotaProvider.claudeWindows(usage, now: date(1_700_000_000))
        #expect(windows.map(\.label)
            == ["Session", "Weekly", "Sonnet", "Fable", "Saga", "Designs"])
        // The fixed field wins over a scoped row of the same name.
        #expect(windows[2].usedPercent == 3)
        // The first row of a repeated name wins.
        #expect(windows[3].usedPercent == 40)
        #expect(windows[4].usedPercent == 10)
        // "Designs" is the fixed design window, not the scoped row.
        #expect(windows[5].usedPercent == 0)
    }

    /// Every fixed row blocks a scoped row of its name, including the rows
    /// placed after the scoped ones, and names are compared by case folding.
    @Test func scopedModelLimitsNeverRepeatALabel() throws {
        let raw = """
            {
                "seven_day": { "utilization": 10, "resets_at": null },
                "seven_day_opus": { "utilization": 11, "resets_at": null },
                "seven_day_cowork": { "utilization": 12, "resets_at": null },
                "extra_usage": { "is_enabled": true, "utilization": 13 },
                "limits": [
                    { "kind": "weekly_scoped", "percent": 91,
                      "scope": { "model": { "display_name": "weekly" } } },
                    { "kind": "weekly_scoped", "percent": 92,
                      "scope": { "model": { "display_name": "OPUS" } } },
                    { "kind": "weekly_scoped", "percent": 93,
                      "scope": { "model": { "display_name": "daily routines" } } },
                    { "kind": "weekly_scoped", "percent": 94,
                      "scope": { "model": { "display_name": "Extra Usage" } } },
                    { "kind": "weekly_scoped", "percent": 20,
                      "scope": { "model": { "display_name": "Straße" } } },
                    { "kind": "weekly_scoped", "percent": 95,
                      "scope": { "model": { "display_name": "STRASSE" } } },
                    { "kind": "weekly_scoped", "percent": -5,
                      "scope": { "model": { "display_name": "Negative" } } }
                ]
            }
            """
        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(raw.utf8))
        let windows = ClaudeQuotaProvider.claudeWindows(usage, now: date(1_700_000_000))
        #expect(windows.map(\.label)
            == ["Weekly", "Opus", "Straße", "Negative", "Daily Routines", "Extra usage"])
        #expect(windows.map(\.usedPercent) == [10, 11, 20, 0, 12, 13])
        // A value below the bar's range is clamped like one above it.
        #expect(windows[3].remainingPercent == 100)
    }

    /// Rows this app cannot read are skipped one by one; they never fail the
    /// response or hide the windows that did decode.
    @Test func unreadableLimitRowsAreSkipped() throws {
        let raw = """
            {
                "seven_day": { "utilization": 10, "resets_at": null },
                "limits": [
                    "not a row",
                    42,
                    null,
                    { "kind": "weekly_scoped", "percent": 30, "scope": "Fable" },
                    { "kind": "weekly_scoped", "percent": 30, "scope": { "model": "Fable" } },
                    { "kind": "weekly_scoped", "percent": 30,
                      "scope": { "model": { "display_name": 7 } } },
                    { "kind": "weekly_scoped", "percent": 30,
                      "scope": { "model": { "display_name": "   " } } },
                    { "kind": "weekly_scoped", "percent": 30,
                      "scope": { "model": null,
                                 "surface": { "display_name": "Design" } } },
                    { "kind": "weekly_scoped", "percent": null,
                      "scope": { "model": { "display_name": "NoPercent" } } },
                    { "kind": "weekly_scoped", "percent": {},
                      "scope": { "model": { "display_name": "BadPercent" } } },
                    { "kind": "monthly_scoped", "percent": 30,
                      "scope": { "model": { "display_name": "OtherKind" } } },
                    { "kind": 3, "percent": 30,
                      "scope": { "model": { "display_name": "BadKind" } } },
                    { "kind": "weekly_scoped", "percent": "150", "resets_at": 12,
                      "scope": { "model": { "display_name": "Fable" } } }
                ]
            }
            """
        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(raw.utf8))
        #expect(usage.limits?.rows.count == 13)
        let windows = ClaudeQuotaProvider.claudeWindows(usage, now: date(1_700_000_000))
        #expect(windows.map(\.label) == ["Weekly", "Fable"])
        // A numeric string is read like the fixed fields read it, and the
        // value is clamped to the bar's range.
        #expect(windows[1].usedPercent == 100)
        #expect(windows[1].remainingPercent == 0)
        #expect(windows[1].resetsAt == nil)
    }

    /// `limits` of the wrong type, null or missing leaves the fixed windows
    /// exactly as they were before the field was read.
    @Test func limitsOfTheWrongTypeAreIgnored() throws {
        for limits in [#""limits": { "weekly_scoped": [] },"#, #""limits": "none","#,
                       #""limits": null,"#, #""limits": [],"#, ""] {
            let raw = """
                {
                    \(limits)
                    "five_hour": { "utilization": 8, "resets_at": null },
                    "seven_day_opus": { "utilization": 12, "resets_at": null }
                }
                """
            let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(raw.utf8))
            let windows = ClaudeQuotaProvider.claudeWindows(usage, now: date(1_700_000_000))
            #expect(windows == [
                UsageWindow(label: "Session", usedPercent: 8, remainingPercent: 92),
                UsageWindow(label: "Opus", usedPercent: 12, remainingPercent: 88),
            ])
        }
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

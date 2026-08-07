import DataSource
import Foundation
import Testing

@testable import Collector

// Live smoke harness — OFF by default. Run explicitly with:
//
//   TOKCAT_LIVE_SMOKE=1 swift test --filter QuotaLiveSmokeTests
//
// Hits the real Claude/Codex quota endpoints with this machine's own
// credentials and prints a redacted summary (identity/plan/window count —
// never token values). The Codex call is skipped when auth.json's
// last_refresh is over 8 days old, because fetching would then trigger the
// token refresh write-back and mutate the user's auth.json.

private var liveSmokeEnabled: Bool {
    ProcessInfo.processInfo.environment["TOKCAT_LIVE_SMOKE"] == "1"
}

private func redactEmail(_ email: String?) -> String {
    guard let email, !email.isEmpty else { return "<none>" }
    return email.prefix(3) + "…"
}

private func describeSnapshot(_ name: String, _ snapshot: AgentUsageSnapshot) {
    if let error = snapshot.error {
        print("[live-smoke] \(name): ERROR \(error)")
        return
    }
    let windows = snapshot.windows
        .map { "\($0.label)=\(Int($0.usedPercent.rounded()))%" }
        .joined(separator: ", ")
    print("[live-smoke] \(name): email=\(redactEmail(snapshot.identity?.email)) "
        + "plan=\(snapshot.identity?.plan ?? "<none>") "
        + "windows=\(snapshot.windows.count) [\(windows)]")
}

@Suite struct QuotaLiveSmokeTests {
    @Test(.enabled(if: liveSmokeEnabled, "set TOKCAT_LIVE_SMOKE=1 to run"))
    func claudeLive() async {
        guard ClaudeQuotaProvider.isConfigured else {
            print("[live-smoke] claude: not configured, skipping")
            return
        }
        let snapshot = await ClaudeQuotaProvider.fetch()
        describeSnapshot("claude", snapshot)
        #expect(snapshot.error == nil)
        #expect(!snapshot.windows.isEmpty)
    }

    @Test(.enabled(if: liveSmokeEnabled, "set TOKCAT_LIVE_SMOKE=1 to run"))
    func codexLive() async throws {
        guard CodexQuotaProvider.isConfigured else {
            print("[live-smoke] codex: not configured, skipping")
            return
        }
        // Check the refresh age FIRST: a fetch on stale credentials would
        // refresh and write back to the user's auth.json.
        let credentials = try CodexQuotaProvider.loadCodexCredentials()
        if CodexQuotaProvider.codexCredentialsNeedRefresh(lastRefresh: credentials.lastRefresh) {
            print("[live-smoke] codex: last_refresh > 8 days — skipping live call "
                + "to avoid mutating auth.json")
            return
        }
        let snapshot = await CodexQuotaProvider.fetch()
        describeSnapshot("codex", snapshot)
        #expect(snapshot.error == nil)
        #expect(!snapshot.windows.isEmpty || snapshot.credits != nil)
    }
}

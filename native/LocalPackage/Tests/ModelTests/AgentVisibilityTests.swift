import DataSource
import Foundation
import Testing

@testable import Model

// Agent visibility has two independent dimensions, because the dashboard's two
// surfaces answer different questions: usage ("what did I spend" — the chart,
// the totals it feeds, the streaks) and limits ("how much of my plan is left" —
// the quota tile and the menubar percentage). An agent can be worth watching in
// one and pure noise in the other, and whichever surface is filtered has to
// stay self-consistent: a total that still counted a hidden agent would
// contradict its own bars.

@MainActor
private func makeStore() -> (DashboardStore, UserDefaults, String) {
    let suite = "tokcat.tests.agent-visibility.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (DashboardStore(defaults: defaults), defaults, suite)
}

private func client(_ id: String, tokens: Int64, cost: Double) -> ContributionClient {
    ContributionClient(client: id, modelId: "m", providerId: "p",
                       tokens: TokenBreakdown(input: tokens), cost: cost, messages: 1)
}

/// A payload dated inside the store's default (current) year, so the year
/// filter keeps it without the test having to pin a year.
private func payload(_ perDay: [(String, [ContributionClient])]) -> UsagePayload {
    let year = String(Formatters.calendar.component(.year, from: Date()))
    return datedPayload(perDay.map { ("\(year)-\($0.0)", $0.1) })
}

/// Days relative to today, for the trailing-window tests: `-0` is today.
private func daysAgoPayload(
    _ perDay: [(Int, [ContributionClient])]
) -> UsagePayload {
    datedPayload(perDay.map {
        (Formatters.isoDate(Formatters.addDays(Date(), -$0.0)), $0.1)
    })
}

private func datedPayload(_ perDay: [(String, [ContributionClient])]) -> UsagePayload {
    let contributions = perDay.map { date, clients in
        Contribution(
            date: date,
            totals: ContributionTotals(tokens: 0, cost: 0, messages: 0),
            intensity: 1,
            tokenBreakdown: TokenBreakdown(),
            clients: clients)
    }
    return UsagePayload(
        meta: UsageMeta(
            generatedAt: "", version: "test",
            dateRange: DateRange(start: contributions.first?.date ?? "",
                                 end: contributions.last?.date ?? "")),
        summary: UsageSummary(
            totalTokens: 0, totalCost: 0, totalDays: 0, activeDays: 0,
            averagePerDay: 0, maxCostInSingleDay: 0, clients: [], models: []),
        years: [],
        contributions: contributions)
}

private func snapshot(_ id: String, used: Double) -> AgentUsageSnapshot {
    AgentUsageSnapshot(
        clientId: id, source: "oauth", updatedAt: "2026-01-01T00:00:00.000Z",
        windows: [UsageWindow(label: "Session", usedPercent: used,
                              remainingPercent: 100 - used)])
}

@Suite struct AgentVisibilityTests {
    @Test @MainActor func switchingAnAgentOffExcludesItFromClientsStatsAndBars() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 100, cost: 1.0),
                       client("grok", tokens: 40, cost: 0.4)]),
        ]))

        #expect(store.presentClients == ["claude", "grok"])
        #expect(store.overviewStats?.totalTokens == 140)

        store.setAgentHidden("grok", true)

        #expect(store.presentClients == ["claude"])
        #expect(store.dashboardClients == ["claude"])
        #expect(store.overviewStats?.totalTokens == 100)
        #expect(store.overviewStats?.totalCost == 1.0)
        let segments = store.overviewBars.flatMap { $0.segments.map(\.clientId) }
        #expect(!segments.contains("grok"))

        store.setAgentHidden("grok", false)
        #expect(store.presentClients == ["claude", "grok"])
        #expect(store.overviewStats?.totalTokens == 140)
    }

    /// "Usage only": the agent's history still counts, but its quota tile and
    /// the menubar percentage let it go — the shape of an agent whose limits
    /// endpoint is useless.
    @Test @MainActor func usageOnlyKeepsTheHistoryAndDropsTheQuota() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.settings.trayMode = .planPercent
        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 100, cost: 1.0),
                       client("grok", tokens: 40, cost: 0.4)]),
        ]))
        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:00.000Z",
            agents: [snapshot("claude", used: 40), snapshot("grok", used: 90)])
        #expect(store.trayTitle == "⚠ Grok 90%")

        store.setAgentScope("grok", .usageOnly)

        #expect(store.presentClients == ["claude", "grok"])
        #expect(store.overviewStats?.totalTokens == 140)
        #expect(store.dashboardClients.contains("grok"))
        // The limits card seeds its tiles from its own client list, so a
        // quota-less agent cannot sneak a "No quota" tile back in.
        #expect(store.limitsClients == ["claude"])
        #expect(store.visibleAgentUsage?.agents.map(\.clientId) == ["claude"])
        #expect(store.trayTitle == "Claude 40%")
        #expect(store.agentsHiddenFromLimits == ["grok"])
        #expect(store.agentsHiddenFromUsage.isEmpty)
    }

    /// "Limits only": the quota tile stays — tab included — while the chart
    /// and every total it feeds forget the agent.
    @Test @MainActor func limitsOnlyKeepsTheQuotaAndDropsTheHistory() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 100, cost: 1.0),
                       client("grok", tokens: 40, cost: 0.4)]),
        ]))
        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:00.000Z", agents: [snapshot("grok", used: 90)])

        store.setAgentScope("grok", .limitsOnly)

        #expect(store.presentClients == ["claude"])
        #expect(store.limitsClients == ["claude", "grok"])
        #expect(store.overviewStats?.totalTokens == 100)
        let segments = store.overviewBars.flatMap { $0.segments.map(\.clientId) }
        #expect(!segments.contains("grok"))
        // The quota snapshot is what keeps the tab alive.
        #expect(store.visibleAgentUsage?.agents.map(\.clientId) == ["grok"])
        #expect(store.dashboardClients == ["claude", "grok"])
        #expect(store.agentsHiddenFromUsage == ["grok"])
        #expect(store.agentsHiddenFromLimits.isEmpty)
    }

    /// The scope is a separate setting, not a memory of the last time the
    /// switch was off: flipping the agent off and on again has to land on the
    /// scope the user picked, not back on the default.
    @Test @MainActor func theScopeSurvivesTheMasterSwitchBeingFlipped() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 100, cost: 1.0),
                       client("grok", tokens: 40, cost: 0.4)]),
        ]))
        store.setAgentScope("grok", .limitsOnly)

        store.setAgentHidden("grok", true)
        #expect(store.isAgentHiddenFromUsage("grok"))
        #expect(store.isAgentHiddenFromLimits("grok"))
        #expect(store.agentScope("grok") == .limitsOnly)

        store.setAgentHidden("grok", false)
        #expect(store.agentScope("grok") == .limitsOnly)
        #expect(store.isAgentHiddenFromUsage("grok"))
        #expect(!store.isAgentHiddenFromLimits("grok"))
    }

    @Test @MainActor func aHiddenAgentLosesItsTabAndTheActiveTabSnapsBack() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 10, cost: 0.1),
                       client("grok", tokens: 30, cost: 0.3)]),
        ]))
        store.activeTab = "grok"
        #expect(store.activeTab == "grok")

        store.setAgentHidden("grok", true)

        #expect(store.activeTab == DashboardStore.overviewTab)
        #expect(!store.dashboardClients.contains("grok"))
    }

    @Test @MainActor func aHiddenAgentDropsOutOfQuotaAndTheTrayPlanTitle() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.settings.trayMode = .planPercent
        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:00.000Z",
            agents: [snapshot("claude", used: 40), snapshot("grok", used: 90)])

        // Auto mode picks the most constrained window — Grok's, for now.
        #expect(store.trayTitle == "⚠ Grok 90%")
        #expect(store.visibleAgentUsage?.agents.count == 2)

        store.setAgentHidden("grok", true)

        #expect(store.visibleAgentUsage?.agents.map(\.clientId) == ["claude"])
        #expect(store.trayTitle == "Claude 40%")
    }

    @Test @MainActor func takingThePinnedPlanProviderOffTheLimitsSurfaceFallsBackToAuto() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.settings.trayMode = .planPercent
        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 10, cost: 0.1),
                       client("grok", tokens: 10, cost: 0.1)]),
        ]))
        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:00.000Z",
            agents: [snapshot("claude", used: 40), snapshot("grok", used: 90)])

        // Either route out of the limits surface strands the pinned provider,
        // and a pin left dangling reads "—" in the menubar forever.
        store.settings.planProvider = .grok
        store.setAgentHidden("grok", true)
        #expect(store.settings.planProvider == .auto)
        #expect(store.trayTitle == "Claude 40%")

        store.setAgentHidden("grok", false)
        store.settings.planProvider = .grok
        store.setAgentScope("grok", .usageOnly)
        #expect(store.settings.planProvider == .auto)
        #expect(store.trayTitle == "Claude 40%")
    }

    @Test @MainActor func showAllRestoresEveryAgentOnBothSurfaces() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 10, cost: 0.1),
                       client("codex", tokens: 20, cost: 0.2),
                       client("grok", tokens: 30, cost: 0.3)]),
        ]))

        store.setAgentHidden("grok", true)
        store.setAgentScope("codex", .limitsOnly)
        #expect(store.presentClients == ["claude"])
        #expect(store.overviewStats?.totalTokens == 10)

        store.showAllAgents()
        #expect(store.settings.hiddenAgents.isEmpty)
        #expect(store.settings.agentScopes.isEmpty)
        #expect(store.presentClients == ["claude", "codex", "grok"])
        #expect(store.overviewStats?.totalTokens == 60)
    }

    /// A scope naming a surface the agent cannot reach would blank it while
    /// its switch still reads on, with nothing on screen to explain it. So a
    /// log-only agent is never offered the limits surface, a quota-only agent
    /// is never offered usage, and a stored scope that says otherwise is
    /// ignored rather than obeyed.
    @Test @MainActor func anAgentIsNeverScopedToASurfaceItCannotReach() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        // "omp" parses logs only; "grok" is plan-capable but has no history;
        // "claude" has both and keeps the full choice.
        store.seedPayload(payload([
            ("08-05", [client("omp", tokens: 40, cost: 0.4),
                       client("claude", tokens: 100, cost: 1.0)]),
        ]))
        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:00.000Z", agents: [snapshot("grok", used: 10)])

        #expect(store.availableScopes(for: "omp") == [.usageOnly])
        #expect(store.availableScopes(for: "grok") == [.limitsOnly])
        #expect(store.availableScopes(for: "claude") == AgentSurfaceScope.allCases)

        store.setAgentScope("omp", .limitsOnly)
        store.setAgentScope("grok", .usageOnly)
        #expect(store.settings.agentScopes.isEmpty)
        #expect(store.presentClients == ["claude", "omp"])
        #expect(store.visibleAgentUsage?.agents.map(\.clientId) == ["grok"])

        // The surfaces an agent never had do not count as hidden, or the cards
        // claim something was filtered out of them that was never there.
        #expect(store.agentsHiddenFromUsage.isEmpty)
        #expect(store.agentsHiddenFromLimits.isEmpty)
    }

    /// A limits-only agent whose provider is signed out has no snapshot but
    /// still owns a placeholder tile, and the tab that would explain that tile
    /// must not be the one that disappears.
    @Test @MainActor func aLimitsOnlyAgentWithNoSnapshotKeepsItsTabAndTile() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 100, cost: 1.0),
                       client("codex", tokens: 40, cost: 0.4)]),
        ]))
        store.activeTab = "claude"
        #expect(store.agentUsage == nil)

        store.setAgentScope("claude", .limitsOnly)

        #expect(store.presentClients == ["codex"])
        #expect(store.limitsClients == ["claude", "codex"])
        #expect(store.dashboardClients == ["claude", "codex"])
        #expect(store.activeTab == "claude")
        #expect(store.agentsHiddenFromUsage == ["claude"])
    }

    /// Cursor is opted out of the whole UI while its own fetch is off, so a
    /// setting made earlier must not drag a row back into a list where there
    /// is no Cursor on the dashboard to configure — while still being kept for
    /// when the opt-in returns.
    @Test @MainActor func aDormantCursorSettingStaysOutOfTheListButIsRemembered() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.settings.cursorUsage = true
        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:00.000Z", agents: [snapshot("cursor", used: 10)])
        store.setAgentHidden("cursor", true)
        #expect(store.knownAgents == ["cursor"])
        #expect(store.agentsHiddenFromLimits == ["cursor"])

        store.settings.cursorUsage = false

        #expect(store.knownAgents.isEmpty)
        #expect(store.agentsHiddenFromLimits.isEmpty)
        #expect(store.settings.hiddenAgents == ["cursor"])

        store.settings.cursorUsage = true
        #expect(store.knownAgents == ["cursor"])
        #expect(store.isAgentHidden("cursor"))
    }

    /// The visibility list answers "am I still using this?", so it counts the
    /// trailing window and orders by it. An agent with a huge lifetime total
    /// and a quiet week has to sink below a smaller agent that is still busy,
    /// or the row the user came to switch off is not the one at the bottom.
    @Test @MainActor func recentTokensCountTheTrailingWindowAndDriveTheOrder() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = DashboardStore.recentWindowDays
        store.seedPayload(daysAgoPayload([
            // Retired: everything it has is just outside the window.
            (window, [client("claude", tokens: 5_000, cost: 5.0)]),
            // The window is inclusive of today and of its oldest day.
            (window - 1, [client("codex", tokens: 30, cost: 0.3)]),
            (0, [client("codex", tokens: 7, cost: 0.07),
                 client("grok", tokens: 20, cost: 0.2)]),
        ]))

        #expect(store.recentTokens == ["codex": 37, "grok": 20])
        #expect(store.allTimeTokens["claude"] == 5_000)
        #expect(store.knownAgents == ["codex", "grok", "claude"])

        store.seedPayload(daysAgoPayload([
            (-3, [client("hermes", tokens: 9_000, cost: 9.0)]),
            (0, [client("grok", tokens: 1, cost: 0.01)]),
        ]))
        #expect(store.recentTokens["hermes"] == nil)
        #expect((store.recentTokens["grok"] ?? 0) == 1)
    }

    @Test @MainActor func knownAgentsKeepsNarrowedAndQuotaOnlyAgentsListable() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 100, cost: 1.0),
                       client("codex", tokens: 5, cost: 0.05)]),
        ]))
        // Quota-only agent with no local logs, plus two agents that have
        // dropped out of the payload entirely — every row the user has
        // touched must stay reachable, or the setting cannot be undone.
        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:00.000Z", agents: [snapshot("grok", used: 10)])
        store.setAgentHidden("hermes", true)

        #expect(store.knownAgents == ["claude", "codex", "grok", "hermes"])
        #expect(store.allTimeTokens["claude"] == 100)
        #expect(store.allTimeTokens["grok"] == nil)
    }

    /// Local Cursor history keeps the settings row and a usage tab while the
    /// fetch is off, but it must not keep a limits surface: offering
    /// `Limits only` then would leave a placeholder tile on Overview whose
    /// tab `dashboardClients` refuses to create.
    @Test @MainActor func cursorWithoutItsOptInHasUsageOnly() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.seedPayload(payload([
            ("08-05", [client("cursor", tokens: 50, cost: 0.5),
                       client("claude", tokens: 10, cost: 0.1)]),
        ]))
        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:00.000Z", agents: [snapshot("cursor", used: 10)])
        #expect(store.settings.cursorUsage == false)

        #expect(store.knownAgents == ["cursor", "claude"])
        #expect(store.availableScopes(for: "cursor") == [.usageOnly])
        #expect(store.effectiveScope("cursor") == .usageOnly)
        #expect(!store.hasLimitsSurface("cursor"))

        store.setAgentScope("cursor", .limitsOnly)
        #expect(store.settings.agentScopes["cursor"] == nil)
        #expect(store.presentClients == ["claude", "cursor"])
        #expect(!store.limitsClients.contains("cursor"))
        #expect(store.dashboardClients == ["claude", "cursor"])
        #expect(store.visibleAgentUsage?.agents.map(\.clientId) == [])
        #expect(store.agentsHiddenFromLimits.isEmpty)

        // A scope stored while the fetch was on must clamp, not blank the tab.
        store.settings.cursorUsage = true
        store.setAgentScope("cursor", .limitsOnly)
        #expect(store.dashboardClients.contains("cursor"))
        store.settings.cursorUsage = false
        #expect(store.effectiveScope("cursor") == .usageOnly)
        #expect(store.presentClients.contains("cursor"))
        #expect(store.dashboardClients.contains("cursor"))
        #expect(!store.limitsClients.contains("cursor"))
    }

    /// Turning the cursor.com fetch off has to un-pin Cursor from the
    /// menubar: `visibleAgentUsage` already drops the snapshot, and a pin
    /// left behind reads "—" forever. The Settings toggle writes
    /// `settings.cursorUsage` directly, so the clamp cannot live only in
    /// `apply`.
    @Test @MainActor func turningCursorFetchOffUnpinsACursorPlanSource() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.settings.trayMode = .planPercent
        store.settings.cursorUsage = true
        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:00.000Z",
            agents: [snapshot("claude", used: 40), snapshot("cursor", used: 90)])
        store.settings.planProvider = .cursor
        #expect(store.trayTitle == "⚠ Cursor 90%")

        store.settings.cursorUsage = false

        #expect(store.settings.planProvider == .auto)
        #expect(store.trayTitle == "Claude 40%")
        #expect(!store.hasLimitsSurface("cursor"))
    }

    /// A plan-capable agent whose only logs are outside the selected year is
    /// still offered Limits only; without a snapshot, that used to mean a
    /// switch that read on and a dashboard with no tile and no tab.
    @Test @MainActor func limitsOnlyKeepsATabWhenHistoryIsInAnotherYear() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let thisYear = String(Formatters.calendar.component(.year, from: Date()))
        let lastYear = String((Int(thisYear) ?? 2026) - 1)
        store.seedPayload(datedPayload([
            ("\(lastYear)-12-01", [client("claude", tokens: 100, cost: 1.0)]),
            ("\(thisYear)-08-05", [client("codex", tokens: 40, cost: 0.4)]),
        ]))
        store.selectedYear = thisYear
        #expect(store.agentUsage == nil)
        #expect(store.hasUsageSurface("claude"))
        #expect(store.availableScopes(for: "claude") == AgentSurfaceScope.allCases)

        store.setAgentScope("claude", .limitsOnly)

        #expect(store.presentClients == ["codex"])
        #expect(store.limitsClients.contains("claude"))
        #expect(store.dashboardClients.contains("claude"))
        #expect(store.agentsHiddenFromUsage.contains("claude"))
    }

    /// A later quota fetch that drops a quota-only provider has to take the
    /// Settings row, the Overview tile, and the tab together. Refreshing
    /// `agentUsage` without recomputing `limitsClients` left a placeholder
    /// that outlived the row.
    @Test @MainActor func aDroppedQuotaSnapshotRemovesTheTileAndTheTab() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 10, cost: 0.1)]),
        ]))
        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:00.000Z", agents: [snapshot("grok", used: 10)])
        #expect(store.knownAgents.contains("grok"))
        #expect(store.limitsClients.contains("grok"))
        #expect(store.dashboardClients.contains("grok"))

        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T01:00:00.000Z", agents: [])

        #expect(!store.knownAgents.contains("grok"))
        #expect(!store.limitsClients.contains("grok"))
        #expect(!store.dashboardClients.contains("grok"))
    }

    /// Until the first collection finishes, do not offer every surface: a
    /// tap would persist a scope the agent cannot honor once inventory
    /// arrives, and the chip would silently change underneath the user.
    @Test @MainActor func scopesCannotBeNarrowedBeforeInventoryArrives() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.fullPayload == nil)
        #expect(store.availableScopes(for: "grok") == [.usageAndLimits])
        store.setAgentScope("grok", .usageOnly)
        #expect(store.settings.agentScopes["grok"] == nil)
        #expect(store.agentScope("grok") == .usageAndLimits)
    }

    /// A stored `usage_only` that inventory later clamps onto limits must
    /// still be pinnable: Settings offers the provider, and accepting the
    /// pin must not immediately bounce back to Auto.
    @Test @MainActor func aClampedUsageOnlyProviderCanStillBePinned() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.settings.trayMode = .planPercent
        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 10, cost: 0.1),
                       client("grok", tokens: 10, cost: 0.1)]),
        ]))
        store.setAgentScope("grok", .usageOnly)
        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 10, cost: 0.1)]),
        ]))
        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:00.000Z",
            agents: [snapshot("claude", used: 40), snapshot("grok", used: 90)])
        #expect(store.agentScope("grok") == .usageOnly)
        #expect(store.effectiveScope("grok") == .limitsOnly)
        #expect(store.hasLimitsSurface("grok"))

        store.settings.planProvider = .grok

        #expect(store.settings.planProvider == .grok)
        #expect(store.trayTitle == "⚠ Grok 90%")

        // Logs coming back honour the stored `usage_only` again — the pin
        // has to fall off in the same recompute, not wait for a settings tap.
        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 10, cost: 0.1),
                       client("grok", tokens: 10, cost: 0.1)]),
        ]))
        #expect(store.effectiveScope("grok") == .usageOnly)
        #expect(store.settings.planProvider == .auto)
        #expect(store.trayTitle == "Claude 40%")
    }

    /// The app may persist `planProvider=grok` plus `usage_only` after the
    /// clamp-to-limits path. Restart must not drop that pin in `loadSettings`
    /// and then wait for a settings tap — collection decides.
    @Test @MainActor func aClampedLimitsPinSurvivesRestartUntilInventoryArrives() {
        let suite = "tokcat.tests.agent-visibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let blob = """
        {"trayMode":"plan_percent","planProvider":"grok",\
        "agentScopes":{"grok":"usage_only"}}
        """
        defaults.set(Data(blob.utf8), forKey: "tokcat.settings.v1")

        let store = DashboardStore(defaults: defaults)
        #expect(store.settings.planProvider == .grok)

        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 10, cost: 0.1)]),
        ]))
        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:00.000Z",
            agents: [snapshot("claude", used: 40), snapshot("grok", used: 90)])
        #expect(store.effectiveScope("grok") == .limitsOnly)
        #expect(store.settings.planProvider == .grok)
        #expect(store.trayTitle == "⚠ Grok 90%")

        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 10, cost: 0.1),
                       client("grok", tokens: 10, cost: 0.1)]),
        ]))
        #expect(store.effectiveScope("grok") == .usageOnly)
        #expect(store.settings.planProvider == .auto)
        #expect(store.trayTitle == "Claude 40%")
    }

    @Test @MainActor func cursorIsOnlyListedWhileItsOwnOptInIsOn() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:00.000Z", agents: [snapshot("cursor", used: 10)])

        // With the cursor.com fetch off, Cursor is already out of the UI; a
        // second switch for it would be a contradiction waiting to happen.
        #expect(store.settings.cursorUsage == false)
        #expect(store.knownAgents.isEmpty)

        store.settings.cursorUsage = true
        #expect(store.knownAgents == ["cursor"])
    }

    @Test @MainActor func visibilitySurvivesARestartAndIsNormalizedOnLoad() {
        let suite = "tokcat.tests.agent-visibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = DashboardStore(defaults: defaults)
        first.seedPayload(payload([
            ("08-05", [client("codex", tokens: 1, cost: 0.01),
                       client("grok", tokens: 1, cost: 0.01)]),
        ]))
        first.setAgentHidden("grok", true)
        first.setAgentHidden("hermes", true)
        first.setAgentScope("codex", .usageOnly)
        first.settings.planProvider = .grok
        first.setAgentScope("grok", .usageOnly)
        #expect(first.settings.planProvider == .auto)

        let second = DashboardStore(defaults: defaults)
        #expect(second.settings.hiddenAgents == ["grok", "hermes"])
        #expect(second.isAgentHidden("grok"))
        #expect(second.agentScope("codex") == .usageOnly)
        #expect(second.settings.planProvider == .auto)

        // A hand-edited or imported blob may carry duplicates in any order,
        // and a scope name this build does not know; everything downstream
        // assumes a sorted, deduplicated list, and an unreadable scope must
        // fall back to showing the agent rather than hiding it somewhere the
        // user cannot see why.
        // Hidden grok is stranded without inventory; a usage_only pin on an
        // agent that is still on must survive load and wait for collection.
        let blob = """
        {"planProvider":"grok","hiddenAgents":["hermes","grok","hermes",""],\
        "agentScopes":{"codex":"limits_only","droid":"usage_only",\
        "grok":"usage_only","bogus":"nonsense","":"usage_only"}}
        """
        defaults.set(Data(blob.utf8), forKey: "tokcat.settings.v1")
        let third = DashboardStore(defaults: defaults)
        #expect(third.settings.hiddenAgents == ["grok", "hermes"])
        #expect(third.settings.agentScopes == ["codex": .limitsOnly,
                                              "droid": .usageOnly,
                                              "grok": .usageOnly])
        #expect(third.agentScope("bogus") == .usageAndLimits)
        // The pin is reconciled on load, not only on the next visibility tap.
        #expect(third.settings.planProvider == .auto)
        // Every agent the settings mention stays listable, or the setting
        // cannot be undone.
        #expect(third.knownAgents.contains("droid"))
        #expect(third.knownAgents.contains("hermes"))
    }
}

// `clientsHiddenFromUsage` is the live-tail exclusion set (LiveTraceStore
// filters the menubar's tokens/min through it). It is deliberately not
// `agentsHiddenFromUsage`, which is the *display* count and lists only agents
// with history to hide — an agent with no logs at all can still be burning
// tokens right now.
@Suite struct HiddenClientSetTests {
    @Test @MainActor func theMasterSwitchLandsInTheLiveSetWithNoHistory() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.setAgentHidden("codex", true)

        #expect(store.clientsHiddenFromUsage == ["codex"])
        // Nothing collected, so nothing has a usage surface to count as
        // hidden for the card's note.
        #expect(store.agentsHiddenFromUsage.isEmpty)
    }

    @Test @MainActor func limitsOnlyHidesTheLiveRateOnceInventoryHonoursIt() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 100, cost: 1.0)]),
        ]))
        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:00.000Z",
            agents: [snapshot("claude", used: 40)])

        store.setAgentScope("claude", .limitsOnly)

        #expect(store.clientsHiddenFromUsage.contains("claude"))
        #expect(!store.presentClients.contains("claude"))
    }

    @Test @MainActor func usageOnlyLeavesTheLiveRateAlone() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.seedPayload(payload([
            ("08-05", [client("claude", tokens: 100, cost: 1.0)]),
        ]))
        store.agentUsage = AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:00.000Z",
            agents: [snapshot("claude", used: 40)])

        store.setAgentScope("claude", .usageOnly)

        #expect(!store.clientsHiddenFromUsage.contains("claude"))
    }

    // A stored scope that inventory clamps away must not leak into the live
    // filter either — the menubar and the chart agree on one predicate.
    @Test @MainActor func aClampedScopeDoesNotHideTheLiveRate() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        // A log-only client: not a quota-tile provider and reporting no
        // snapshot, so `limits_only` is unreachable and clamps back onto
        // usage.
        store.seedPayload(payload([
            ("08-05", [client("opencode", tokens: 40, cost: 0.4)]),
        ]))
        store.setAgentScope("opencode", .limitsOnly)

        #expect(!store.clientsHiddenFromUsage.contains("opencode"))
        #expect(store.presentClients.contains("opencode"))
    }

    // Turning the switch back off has to clear the set, or the menubar keeps
    // dropping an agent the user restored.
    @Test @MainActor func unhidingClearsTheLiveSet() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setAgentHidden("codex", true)
        #expect(store.clientsHiddenFromUsage == ["codex"])

        store.setAgentHidden("codex", false)
        #expect(store.clientsHiddenFromUsage.isEmpty)
    }

    // The set is seeded in `init`, before the first collector pass: the
    // tailer publishes rates within seconds of launch and a hidden agent
    // must not get a free window in the menubar.
    @Test @MainActor func theSetSurvivesARestartBeforeAnyRefresh() {
        let suite = "tokcat.tests.hidden-clients.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        DashboardStore(defaults: defaults).setAgentHidden("codex", true)

        let restarted = DashboardStore(defaults: defaults)

        #expect(restarted.clientsHiddenFromUsage == ["codex"])
    }
}

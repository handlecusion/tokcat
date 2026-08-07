import DataSource
import Foundation
import Testing

@testable import Model

// Tests for the UsageBarGraph2D.tsx dayFromContribution / series port.

@Suite struct UsageBarsTests {
    private func client(_ id: String, model: String = "m", tokens: TokenBreakdown,
                        cost: Double) -> ContributionClient {
        ContributionClient(client: id, modelId: model, providerId: "p",
                           tokens: tokens, cost: cost, messages: 1)
    }

    private func contribution(_ date: String,
                              _ clients: [ContributionClient]) -> Contribution {
        Contribution(
            date: date,
            totals: ContributionTotals(tokens: 0, cost: 0, messages: 0),
            intensity: 0,
            tokenBreakdown: TokenBreakdown(),
            clients: clients)
    }

    private func payload(_ contributions: [Contribution]) -> UsagePayload {
        UsagePayload(
            meta: UsageMeta(
                generatedAt: "", version: "test",
                dateRange: DateRange(
                    start: contributions.first?.date ?? "",
                    end: contributions.last?.date ?? "")),
            summary: UsageSummary(
                totalTokens: 0, totalCost: 0, totalDays: 0, activeDays: 0,
                averagePerDay: 0, maxCostInSingleDay: 0, clients: [], models: []),
            years: [],
            contributions: contributions)
    }

    @Test func groupsClientEntriesAndSortsSegments() {
        // claude appears twice (two models) and must collapse into one
        // segment; segments sort by client id (codex after claude).
        let day = contribution("2026-08-05", [
            client("codex", tokens: TokenBreakdown(input: 5), cost: 0.5),
            client("claude", model: "a", tokens: TokenBreakdown(input: 10, output: 2), cost: 1.0),
            client("claude", model: "b", tokens: TokenBreakdown(cacheRead: 3), cost: 0.25),
        ])
        let bar = UsageBars.dayFromContribution(day, allowed: ["claude", "codex"])
        #expect(bar.date == "2026-08-05")
        #expect(bar.segments.count == 2)
        #expect(bar.segments[0] == BarSegment(clientId: "claude", tokens: 15, cost: 1.25))
        #expect(bar.segments[1] == BarSegment(clientId: "codex", tokens: 5, cost: 0.5))
        #expect(bar.totalTokens == 20)
        #expect(bar.totalCost == 1.75)
    }

    @Test func filtersDisallowedAndEmptyClients() {
        let day = contribution("2026-08-05", [
            client("claude", tokens: TokenBreakdown(input: 10), cost: 1.0),
            client("codex", tokens: TokenBreakdown(input: 7), cost: 0.7),
            // Zero tokens AND zero cost → dropped even when allowed.
            client("gemini", tokens: TokenBreakdown(), cost: 0),
            // Zero tokens but positive cost → kept (matches the TS guard).
            client("cursor", tokens: TokenBreakdown(), cost: 0.3),
        ])
        let bar = UsageBars.dayFromContribution(
            day, allowed: ["claude", "gemini", "cursor"])
        #expect(bar.segments.map(\.clientId) == ["claude", "cursor"])
        #expect(bar.totalTokens == 10)
        #expect(abs(bar.totalCost - 1.3) < 1e-9)
    }

    @Test func buildsFixedWindowAnchoredAtRangeEnd() {
        let p = payload([
            contribution("2026-07-10", [client("claude", tokens: TokenBreakdown(input: 4), cost: 0.4)]),
            contribution("2026-08-05", [client("claude", tokens: TokenBreakdown(input: 9), cost: 0.9)]),
        ])
        let bars = UsageBars.buildDayBars(payload: p, clientIds: ["claude"])
        #expect(bars.count == 30)
        // Window is the 30 days ending at the payload's range end.
        #expect(bars.last?.date == "2026-08-05")
        #expect(bars.first?.date == "2026-07-07")
        #expect(bars.last?.totalTokens == 9)
        // 2026-07-10 falls inside the window with its data intact.
        let jul10 = bars.first { $0.date == "2026-07-10" }
        #expect(jul10?.totalTokens == 4)
        // Every other day is a padded empty bar.
        let active = bars.filter { $0.totalTokens > 0 }
        #expect(active.count == 2)
    }

    @Test func emptyPayloadAnchorsAtNow() {
        let p = payload([])
        let now = Formatters.parseISODate("2026-08-06")!
        let bars = UsageBars.buildDayBars(payload: p, clientIds: [], now: now)
        #expect(bars.count == 30)
        #expect(bars.last?.date == "2026-08-06")
        #expect(bars.allSatisfy { $0.totalTokens == 0 && $0.segments.isEmpty })
    }
}

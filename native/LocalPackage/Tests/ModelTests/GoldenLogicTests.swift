import DataSource
import Foundation
import Testing

@testable import Model

// Golden tests: expected values in Resources/golden.json were produced by
// running the ORIGINAL TypeScript implementations (src/lib/*.ts) via
// scratchpad/golden.ts. If these fail, the Swift port diverges from the
// shipped frontend behavior — fix the port, not the fixture.

private struct Golden: Decodable {
    struct StatsOut: Decodable {
        var totalTokens: Int64
        var totalCost: Double
        var activeDays: Int
        var bestDay: Best?
        var averagePerDay: Double
        var perDay: [Day]
        var streaks: Streak
        var presentClients: [String]
        var maxTokens: Int64

        struct Best: Decodable { var date: String; var cost: Double }
        struct Day: Decodable { var date: String; var tokens: Int64; var cost: Double; var intensity: Int }
        struct Streak: Decodable { var longest: Int; var current: Int }
    }
    struct GridOut: Decodable {
        var cols: Int
        var maxTokens: Int64
        var nCells: Int
        var first: Cell
        var last: Cell
        var cell100: Cell
        var activeDates: [String]

        struct Cell: Decodable {
            var col: Int; var row: Int; var date: String
            var inYear: Bool; var active: Bool
            var tokens: Int64; var cost: Double
        }
    }
    var humanize: [[HumanizeEntry]]
    var costs: [[HumanizeEntry]]
    var statsAll: StatsOut
    var statsClaude: StatsOut
    var streakCases: [String: StatsOut.Streak]
    var grids: [String: GridOut]
    var trayCases: [String: String]

    enum HumanizeEntry: Decodable {
        case number(Double)
        case string(String)

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .number(d); return }
            self = .string(try c.decode(String.self))
        }

        var asDouble: Double? { if case .number(let d) = self { return d }; return nil }
        var asString: String? { if case .string(let s) = self { return s }; return nil }
    }
}

private func loadGolden() throws -> Golden {
    let url = Bundle.module.url(forResource: "golden", withExtension: "json")!
    return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
}

private func tb(_ input: Int64, _ output: Int64 = 0, _ cacheRead: Int64 = 0,
                _ cacheWrite: Int64 = 0, _ reasoning: Int64 = 0) -> TokenBreakdown {
    TokenBreakdown(input: input, output: output, cacheRead: cacheRead,
                   cacheWrite: cacheWrite, reasoning: reasoning)
}

private func contribution(_ date: String, _ intensity: Int,
                          _ clients: [ContributionClient]) -> Contribution {
    Contribution(date: date,
                 totals: ContributionTotals(tokens: 0, cost: 0, messages: 0),
                 intensity: intensity, tokenBreakdown: tb(0), clients: clients)
}

private func client(_ id: String, _ provider: String, _ tokens: TokenBreakdown,
                    _ cost: Double, _ messages: Int64) -> ContributionClient {
    ContributionClient(client: id, modelId: "m", providerId: provider,
                       tokens: tokens, cost: cost, messages: messages)
}

// Mirrors the payload constructed in golden.ts.
private func fixturePayload() -> UsagePayload {
    UsagePayload(
        meta: UsageMeta(generatedAt: "x", version: "1",
                        dateRange: DateRange(start: "2025-12-28", end: "2026-01-06")),
        summary: UsageSummary(totalTokens: 0, totalCost: 0, totalDays: 10, activeDays: 0,
                              averagePerDay: 0, maxCostInSingleDay: 0, clients: [], models: []),
        years: [
            YearMeta(year: "2025", totalTokens: 100, totalCost: 1,
                     range: DateRange(start: "2025-12-28", end: "2025-12-31")),
            YearMeta(year: "2026", totalTokens: 200, totalCost: 2,
                     range: DateRange(start: "2026-01-01", end: "2026-01-06")),
        ],
        contributions: [
            contribution("2025-12-28", 1, [
                client("claude", "anthropic", tb(100, 50, 25, 10, 5), 1.25, 3),
                client("codex", "openai", tb(10, 5), 0.5, 1),
            ]),
            contribution("2025-12-29", 0, []),
            contribution("2025-12-30", 2, [
                client("gemini", "google", tb(7, 3), 0.05, 1),
            ]),
            contribution("2025-12-31", 3, [
                client("claude", "anthropic", tb(1000, 200), 9.75, 4),
            ]),
            contribution("2026-01-01", 4, [
                client("claude", "anthropic", tb(50), 0.4, 1),
                client("droid", "factory", tb(0, 0), 0, 1),
            ]),
            contribution("2026-01-05", 1, [
                client("codex", "openai", tb(11, 22, 33), 0.9, 2),
            ]),
            contribution("2026-01-06", 1, [
                client("claude", "anthropic", tb(5, 5), 0.1, 1),
            ]),
        ]
    )
}

private func fixtureAgentUsage() -> AgentUsagePayload {
    AgentUsagePayload(generatedAt: "x", agents: [
        AgentUsageSnapshot(clientId: "claude", source: "oauth", updatedAt: "x", windows: [
            UsageWindow(label: "Session", usedPercent: 42.4, remainingPercent: 57.6),
            UsageWindow(label: "Weekly", usedPercent: 79.5, remainingPercent: 20.5),
        ]),
        AgentUsageSnapshot(clientId: "codex", source: "oauth", updatedAt: "x", windows: [
            UsageWindow(label: "Session", usedPercent: 80.2, remainingPercent: 19.8),
        ]),
        AgentUsageSnapshot(clientId: "gemini", source: "oauth", updatedAt: "x", windows: [
            UsageWindow(label: "Pro", usedPercent: 99, remainingPercent: 1),
        ]),
        AgentUsageSnapshot(clientId: "grok", source: "oauth", updatedAt: "x", windows: []),
    ])
}

private func assertStats(_ s: Stats, _ g: Golden.StatsOut) {
    #expect(s.totalTokens == g.totalTokens)
    #expect(s.totalCost == g.totalCost)
    #expect(s.activeDays == g.activeDays)
    #expect(s.bestDay?.date == g.bestDay?.date)
    #expect(s.bestDay?.cost == g.bestDay?.cost)
    #expect(s.averagePerDay == g.averagePerDay)
    #expect(s.maxTokens == g.maxTokens)
    #expect(s.presentClients == g.presentClients)
    #expect(s.streaks.longest == g.streaks.longest)
    #expect(s.streaks.current == g.streaks.current)
    #expect(s.perDay.count == g.perDay.count)
    for (a, b) in zip(s.perDay, g.perDay) {
        #expect(a.date == b.date)
        #expect(a.tokens == b.tokens)
        #expect(a.cost == b.cost)
        #expect(a.intensity == b.intensity)
    }
}

@Suite struct GoldenLogicTests {
    @Test func humanizeTokens() throws {
        let g = try loadGolden()
        for pair in g.humanize {
            let n = pair[0].asDouble!
            let expected = pair[1].asString!
            #expect(Formatters.humanizeTokens(n / 1) == expected, "n=\(n)")
            // Integer entry point must agree when representable.
            if n == n.rounded() && n < 9e15 {
                #expect(Formatters.humanizeTokens(Int64(n)) == expected, "int n=\(n)")
            }
        }
        // The divisions below reproduce JS operand doubles exactly, so the
        // Decimal-based tie-breaking must match toFixed: 1950/1000 = 1.95
        // (binary just under) → "1.9K", not "2.0K".
        #expect(Formatters.humanizeTokens(Int64(1950)) == "1.9K")
        #expect(Formatters.humanizeTokens(Int64(1_250_000)) == "1.3M")
    }

    @Test func formatCost() throws {
        let g = try loadGolden()
        for pair in g.costs {
            let n = pair[0].asDouble!
            let expected = pair[1].asString!
            #expect(Formatters.formatCost(n) == expected, "n=\(n)")
        }
    }

    @Test func computeStatsAllClients() throws {
        let g = try loadGolden()
        let stats = StatsBuilder.computeStats(fixturePayload(),
                                              selectedClients: ["claude", "codex", "gemini", "droid"])
        assertStats(stats, g.statsAll)
    }

    @Test func computeStatsClaudeOnly() throws {
        let g = try loadGolden()
        let stats = StatsBuilder.computeStats(fixturePayload(), selectedClients: ["claude"])
        assertStats(stats, g.statsClaude)
    }

    @Test func streakEdgeCases() throws {
        let g = try loadGolden()
        let sparse: [String: PerDay] = [
            "2026-01-01": PerDay(date: "2026-01-01", tokens: 5, cost: 0, intensity: 0),
            "2026-01-02": PerDay(date: "2026-01-02", tokens: 1, cost: 0, intensity: 0),
            "2026-01-04": PerDay(date: "2026-01-04", tokens: 2, cost: 0, intensity: 0),
        ]
        let cases: [(String, [String: PerDay], String, String)] = [
            ("sparse", sparse, "2025-12-30", "2026-01-04"),
            ("empty", [:], "2026-01-01", "2026-01-10"),
            ("inverted", sparse, "2026-01-10", "2026-01-01"),
            ("zeroTokens", ["2026-01-02": PerDay(date: "2026-01-02", tokens: 0, cost: 0, intensity: 0)],
             "2026-01-01", "2026-01-02"),
        ]
        for (name, map, start, end) in cases {
            let got = Streaks.compute(perDayMap: map, rangeStart: start, rangeEnd: end)
            let want = g.streakCases[name]!
            #expect(got.longest == want.longest, "case \(name)")
            #expect(got.current == want.current, "case \(name)")
        }
    }

    @Test func gridLayouts() throws {
        let g = try loadGolden()
        let pd: [String: PerDay] = [
            "2026-01-01": PerDay(date: "2026-01-01", tokens: 10, cost: 0.1, intensity: 1),
            "2026-12-31": PerDay(date: "2026-12-31", tokens: 99, cost: 0.9, intensity: 2),
            "2025-12-31": PerDay(date: "2025-12-31", tokens: 7, cost: 0.05, intensity: 1),
        ]
        for (key, want) in g.grids {
            let year = String(key.dropFirst())  // "y2024" -> "2024"
            let grid = ContributionGrid.buildGrid(year: year, perDayMap: pd)
            #expect(grid.cols == want.cols, "year \(year)")
            #expect(grid.maxTokens == want.maxTokens, "year \(year)")
            #expect(grid.cells.count == want.nCells, "year \(year)")
            for (cell, wantCell) in [(grid.cells.first!, want.first),
                                     (grid.cells.last!, want.last),
                                     (grid.cells[100], want.cell100)] {
                #expect(cell.col == wantCell.col, "year \(year)")
                #expect(cell.row == wantCell.row, "year \(year)")
                #expect(cell.date == wantCell.date, "year \(year)")
                #expect(cell.inYear == wantCell.inYear, "year \(year)")
                #expect(cell.active == wantCell.active, "year \(year)")
                #expect(cell.tokens == wantCell.tokens, "year \(year)")
                #expect(cell.cost == wantCell.cost, "year \(year)")
            }
            let activeDates = grid.cells.filter(\.active).map(\.date)
            #expect(activeDates == want.activeDates, "year \(year)")
        }
    }

    @Test func trayTitles() throws {
        let g = try loadGolden()
        let stats = StatsBuilder.computeStats(fixturePayload(),
                                              selectedClients: ["claude", "codex", "gemini", "droid"])
        let usage = fixtureAgentUsage()
        // A date outside the fixture's perDay range, mirroring "today" when
        // golden.ts ran (its today-cases assume no entry for today).
        let now = Formatters.parseISODate("2026-08-06")!

        var got: [String: String] = [:]
        got["hidden"] = PlanLogic.computeTrayTitle(mode: .hidden, stats: stats, now: now)
        got["noStats"] = PlanLogic.computeTrayTitle(mode: .totalTokens, stats: nil, now: now)
        got["totalTokens"] = PlanLogic.computeTrayTitle(mode: .totalTokens, stats: stats, now: now)
        got["totalCost"] = PlanLogic.computeTrayTitle(mode: .totalCost, stats: stats, now: now)
        got["todayTokensMiss"] = PlanLogic.computeTrayTitle(mode: .todayTokens, stats: stats, now: now)
        got["todayCostMiss"] = PlanLogic.computeTrayTitle(mode: .todayCost, stats: stats, now: now)
        got["tpmNull"] = PlanLogic.computeTrayTitle(mode: .tokensPerMin, stats: stats, tokensPerMin: nil, now: now)
        got["tpm"] = PlanLogic.computeTrayTitle(mode: .tokensPerMin, stats: stats, tokensPerMin: 12444.6, now: now)
        got["tpmNeg"] = PlanLogic.computeTrayTitle(mode: .tokensPerMin, stats: stats, tokensPerMin: -5, now: now)
        got["planAuto"] = PlanLogic.computeTrayTitle(mode: .planPercent, stats: nil, agentUsage: usage, now: now)
        got["planAutoLeft"] = PlanLogic.computeTrayTitle(
            mode: .planPercent, stats: nil, agentUsage: usage,
            plan: PlanSelection(provider: .auto, window: "Session", displayMode: .left), now: now)
        got["planPinned"] = PlanLogic.computeTrayTitle(
            mode: .planPercent, stats: nil, agentUsage: usage,
            plan: PlanSelection(provider: .claude, window: "Session", displayMode: .used), now: now)
        got["planPinnedGoneLabel"] = PlanLogic.computeTrayTitle(
            mode: .planPercent, stats: nil, agentUsage: usage,
            plan: PlanSelection(provider: .claude, window: "Nope", displayMode: .used), now: now)
        got["planPinnedNoWindows"] = PlanLogic.computeTrayTitle(
            mode: .planPercent, stats: nil, agentUsage: usage,
            plan: PlanSelection(provider: .grok, window: "Session", displayMode: .used), now: now)
        got["planNoData"] = PlanLogic.computeTrayTitle(mode: .planPercent, stats: nil, agentUsage: nil, now: now)

        for (name, want) in g.trayCases {
            #expect(got[name] == want, "case \(name)")
        }
    }

    @Test func todayHit() {
        // Not covered by golden.ts (it depends on the run date); verified
        // against a hand-check of the TS logic instead.
        let stats = StatsBuilder.computeStats(fixturePayload(),
                                              selectedClients: ["claude", "codex", "gemini", "droid"])
        let now = Formatters.parseISODate("2026-01-05")!
        #expect(PlanLogic.computeTrayTitle(mode: .todayTokens, stats: stats, now: now) == "66")
        #expect(PlanLogic.computeTrayTitle(mode: .todayCost, stats: stats, now: now) == "$0.90")
    }
}

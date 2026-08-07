import DataSource
import Foundation

// Ports of src/lib/stats.ts and src/lib/streaks.ts.

public struct PerDay: Sendable, Equatable {
    public var date: String
    public var tokens: Int64
    public var cost: Double
    public var intensity: Int

    public init(date: String, tokens: Int64, cost: Double, intensity: Int) {
        self.date = date
        self.tokens = tokens
        self.cost = cost
        self.intensity = intensity
    }
}

public struct BestDay: Sendable, Equatable {
    public var date: String
    public var cost: Double
}

public struct StreakSummary: Sendable, Equatable {
    public var longest: Int
    public var current: Int

    public init(longest: Int, current: Int) {
        self.longest = longest
        self.current = current
    }
}

public struct Stats: Sendable, Equatable {
    public var totalTokens: Int64
    public var totalCost: Double
    public var activeDays: Int
    public var bestDay: BestDay?
    public var averagePerDay: Double
    public var dateRange: DateRange
    public var perDay: [PerDay]
    public var perDayMap: [String: PerDay]
    public var streaks: StreakSummary
    public var presentClients: [String]
    public var years: [YearMeta]
    public var maxTokens: Int64
}

public enum StatsBuilder {
    public static func computeStats(_ payload: UsagePayload,
                                    selectedClients: Set<String>) -> Stats {
        var perDay: [PerDay] = []
        var perDayMap: [String: PerDay] = [:]
        var present = Set<String>()

        var totalTokens: Int64 = 0
        var totalCost = 0.0
        var bestDay: BestDay?
        var maxTokens: Int64 = 0

        for c in payload.contributions {
            var dayTokens: Int64 = 0
            var dayCost = 0.0
            for cc in c.clients {
                present.insert(cc.client)
                guard selectedClients.contains(cc.client) else { continue }
                dayTokens += cc.tokens.total
                dayCost += cc.cost
            }
            if dayTokens == 0 && dayCost == 0 { continue }
            let entry = PerDay(date: c.date, tokens: dayTokens, cost: dayCost,
                               intensity: c.intensity)
            perDay.append(entry)
            perDayMap[c.date] = entry
            totalTokens += dayTokens
            totalCost += dayCost
            if dayTokens > maxTokens { maxTokens = dayTokens }
            if bestDay == nil || dayCost > bestDay!.cost {
                bestDay = BestDay(date: c.date, cost: dayCost)
            }
        }

        let activeDays = perDay.count
        let averagePerDay = activeDays > 0 ? totalCost / Double(activeDays) : 0
        let dateRange = payload.meta.dateRange
        let streaks = Streaks.compute(perDayMap: perDayMap,
                                      rangeStart: dateRange.start,
                                      rangeEnd: dateRange.end)

        return Stats(
            totalTokens: totalTokens,
            totalCost: totalCost,
            activeDays: activeDays,
            bestDay: bestDay,
            averagePerDay: averagePerDay,
            dateRange: dateRange,
            perDay: perDay,
            perDayMap: perDayMap,
            streaks: streaks,
            presentClients: present.sorted(),
            years: payload.years,
            maxTokens: maxTokens
        )
    }
}

public enum Streaks {
    public static func compute(perDayMap: [String: PerDay],
                               rangeStart: String,
                               rangeEnd: String) -> StreakSummary {
        guard let start = Formatters.parseISODate(rangeStart),
              let end = Formatters.parseISODate(rangeEnd) else {
            return StreakSummary(longest: 0, current: 0)
        }
        let total = Formatters.diffDays(end, start) + 1
        if total <= 0 { return StreakSummary(longest: 0, current: 0) }

        var longest = 0
        var run = 0
        var current = 0
        for i in 0..<total {
            let key = Formatters.isoDate(Formatters.addDays(start, i))
            let active = (perDayMap[key]?.tokens ?? 0) > 0
            if active {
                run += 1
                if run > longest { longest = run }
            } else {
                run = 0
            }
        }
        // Current streak: count back from the range end.
        for i in stride(from: total - 1, through: 0, by: -1) {
            let key = Formatters.isoDate(Formatters.addDays(start, i))
            let active = (perDayMap[key]?.tokens ?? 0) > 0
            if active { current += 1 } else { break }
        }
        return StreakSummary(longest: longest, current: current)
    }
}

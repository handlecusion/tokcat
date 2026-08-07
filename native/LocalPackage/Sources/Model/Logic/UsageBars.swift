import DataSource
import Foundation

// Port of the day-bar aggregation in src/components/UsageBarGraph2D.tsx
// (dayFromContribution + the 30-day series builder). Pure logic so the
// SwiftUI chart stays view-only and the aggregation is unit-testable.

public struct BarSegment: Sendable, Equatable, Identifiable {
    public var clientId: String
    public var tokens: Int64
    public var cost: Double

    public var id: String { clientId }

    public init(clientId: String, tokens: Int64, cost: Double) {
        self.clientId = clientId
        self.tokens = tokens
        self.cost = cost
    }
}

public struct DayBar: Sendable, Equatable, Identifiable {
    public var date: String
    public var totalTokens: Int64
    public var totalCost: Double
    public var segments: [BarSegment]

    public var id: String { date }

    public init(date: String, totalTokens: Int64, totalCost: Double,
                segments: [BarSegment]) {
        self.date = date
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.segments = segments
    }
}

public enum UsageBars {
    public static let defaultDays = 30

    // Port of dayFromContribution: group a day's client entries by client id
    // (a client appears once per model/provider combination), drop empty
    // entries, and sort segments by client id for a stable stacking order.
    public static func dayFromContribution(_ contribution: Contribution,
                                           allowed: Set<String>) -> DayBar {
        var grouped: [String: BarSegment] = [:]
        for client in contribution.clients {
            guard allowed.contains(client.client) else { continue }
            let tokens = client.tokens.total
            if tokens <= 0 && client.cost <= 0 { continue }
            var slot = grouped[client.client]
                ?? BarSegment(clientId: client.client, tokens: 0, cost: 0)
            slot.tokens += tokens
            slot.cost += client.cost
            grouped[client.client] = slot
        }
        let segments = grouped.values.sorted { $0.clientId < $1.clientId }
        return DayBar(
            date: contribution.date,
            totalTokens: segments.reduce(0) { $0 + $1.tokens },
            totalCost: segments.reduce(0) { $0 + $1.cost },
            segments: segments
        )
    }

    // The trailing `days`-day series anchored at the payload's range end
    // (falling back to `now` when the payload is empty), padded with empty
    // bars so the chart always shows a fixed window.
    public static func buildDayBars(payload: UsagePayload,
                                    clientIds: [String],
                                    days: Int = defaultDays,
                                    now: Date = Date()) -> [DayBar] {
        let allowed = Set(clientIds)
        var byDate: [String: DayBar] = [:]
        for contribution in payload.contributions {
            let day = dayFromContribution(contribution, allowed: allowed)
            if day.totalTokens > 0 || day.totalCost > 0 {
                byDate[day.date] = day
            }
        }

        let end = payload.meta.dateRange.end.isEmpty
            ? Formatters.isoDate(now)
            : payload.meta.dateRange.end
        guard days > 0, let endDate = Formatters.parseISODate(end) else { return [] }
        let startDate = Formatters.addDays(endDate, -(days - 1))
        var series: [DayBar] = []
        series.reserveCapacity(days)
        for i in 0..<days {
            let date = Formatters.isoDate(Formatters.addDays(startDate, i))
            series.append(
                byDate[date]
                    ?? DayBar(date: date, totalTokens: 0, totalCost: 0, segments: []))
        }
        return series
    }
}

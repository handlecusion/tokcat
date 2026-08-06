import Model
import SwiftUI

// Port of TokenUsageCard.tsx (bare form): the three-cell stats row shown at
// the top of the usage card — total cost + range, tokens + active days,
// best day.
struct StatsRow: View {
    let stats: Stats

    var body: some View {
        HStack(spacing: 0) {
            cell(
                num: Formatters.formatCost(stats.totalCost),
                label: "Total",
                sub: "\(Formatters.formatMMDD(stats.dateRange.start)) → "
                    + Formatters.formatMMDD(stats.dateRange.end))
            divider
            cell(
                num: Formatters.humanizeTokens(stats.totalTokens),
                label: "Tokens",
                sub: "\(stats.activeDays) active days")
            divider
            cell(
                num: stats.bestDay.map { Formatters.formatCost($0.cost) } ?? "$0.00",
                label: "Best day",
                sub: stats.bestDay.map { Formatters.formatMonthDay($0.date) } ?? "—")
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 34)
    }

    private func cell(num: String, label: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(num)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(sub)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

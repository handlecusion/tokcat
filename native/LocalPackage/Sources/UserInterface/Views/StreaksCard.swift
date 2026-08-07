import Model
import SwiftUI

// The AgentLimitsCard placeholder that used to live at the bottom of this
// file moved to Views/AgentLimitsCard.swift as the real quota card.

// Port of StreaksCard.tsx: longest / current streak in days.
struct StreaksCard: View {
    let streaks: StreakSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeading(text: "Streaks")
            HStack(spacing: 0) {
                item(value: streaks.longest, label: "Longest")
                item(value: streaks.current, label: "Current")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func item(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("days")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

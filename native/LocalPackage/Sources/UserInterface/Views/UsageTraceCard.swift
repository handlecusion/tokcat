import Model
import SwiftUI

// Port of src/components/UsageTraceCard.tsx: the "Live session" card showing
// the top live-rate rows over the last 10 minutes, one proportional bar per
// (client, agent, model) bucket — or one per client when the detailed trace
// setting is off.
public struct UsageTraceCard: View {
    let buckets: [TraceRow]
    let windowSecs: Int64
    let detailed: Bool
    let title: String

    public init(buckets: [TraceRow], windowSecs: Int64 = 600,
                detailed: Bool, title: String = "Live session") {
        self.buckets = buckets
        self.windowSecs = windowSecs
        self.detailed = detailed
        self.title = title
    }

    // Tail client ids ("claude-code", "codex-cli") → registry ids used by
    // the graph/tabs, so the card reuses the same brand colors and names.
    private static let registryIds: [String: String] = [
        "claude-code": "claude",
        "codex-cli": "codex",
        "cursor": "cursor",
    ]

    private func style(for tailClientId: String) -> ClientStyle {
        ClientRegistry.style(for: Self.registryIds[tailClientId] ?? tailClientId)
    }

    public var body: some View {
        let rows = detailed ? buckets : TraceCollapse.collapseByClient(buckets)
        let top = Array(rows.prefix(5))
        let maxRate = top.map(\.tokensPerMin).max() ?? 0
        let totalRate = rows.map(\.tokensPerMin).reduce(0, +)
        let windowMin = max(1, Int((Double(windowSecs) / 60).rounded()))

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                CardHeading(text: title)
                Spacer()
                Text("last \(windowMin)m · \(Formatters.humanizeTokens(totalRate.rounded()))/m total")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if top.isEmpty {
                Text("No activity in this window")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 8) {
                    ForEach(top) { row in
                        traceRow(row, maxRate: maxRate)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func traceRow(_ row: TraceRow, maxRate: Double) -> some View {
        let clientStyle = style(for: row.client)
        // Same clamp as the TSX: max(4, rate/max*100), 0 when max is 0.
        let pct = maxRate > 0 ? max(4, row.tokensPerMin / maxRate * 100) : 0

        // Two-line label: client on top, agent · model below — a single
        // line truncated all three fields into "Claude Co… main claude-f…".
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(clientStyle.displayName)
                    .font(.system(size: 11, weight: .semibold))
                HStack(spacing: 4) {
                    Text(row.agent)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(row.model)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: 168, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(clientStyle.color)
                        .frame(width: proxy.size.width * pct / 100)
                }
            }
            .frame(height: 6)
            .frame(maxWidth: .infinity)

            Text("\(Formatters.humanizeTokens(row.tokensPerMin.rounded()))/m")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

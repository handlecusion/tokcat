import DataSource
import SwiftUI

// Port of src/components/AgentLimitsCard.tsx: per-agent OAuth quota tiles.
//
// The card is a pure view: the orchestrator passes the dashboard's client
// list, the latest AgentUsagePayload (QuotaStore.payload) and the set of
// clients currently live in the trace (normalized ids — "claude", not
// "claude-code"). Every parameter has a default so the pre-wiring call
// sites keep compiling and render the empty state.
struct AgentLimitsCard: View {
    var clients: [String] = []
    var agentUsage: AgentUsagePayload?
    /// Clients with tokens flowing right now (drives the "Live" status).
    var liveClientIds: Set<String> = []
    var title: String = "Agent limits"
    var note: String = "OAuth quota"
    /// Client tabs show only their own agent; the overview also folds in
    /// agents that report quota but have no local logs yet.
    var includeUnlistedAgents: Bool = true

    /// Placeholder rows while OAuth quota is loading; real windows come from
    /// the providers (mirror of LIMIT_ROWS in AgentLimitsCard.tsx:21-31).
    private static let limitRows: [String: [String]] = [
        "codex": ["Session", "Weekly"],
        "claude": ["Session", "Weekly"],
        "gemini": ["Pro", "Flash"],
        "grok": ["Monthly"],
        "cursor": ["Cursor Models", "Other Models"],
    ]

    private var snapshots: [String: AgentUsageSnapshot] {
        var map: [String: AgentUsageSnapshot] = [:]
        for agent in agentUsage?.agents ?? [] {
            map[agent.clientId] = agent
        }
        return map
    }

    private var visibleClients: [String] {
        var seen = Set<String>()
        var result: [String] = []
        let known = snapshots
        for id in clients
        where Self.limitRows[id] != nil || known[id] != nil
            || ["codex", "claude", "gemini", "grok"].contains(id) {
            if seen.insert(id).inserted { result.append(id) }
        }
        guard includeUnlistedAgents else { return result }
        for agent in agentUsage?.agents ?? [] {
            if seen.insert(agent.clientId).inserted { result.append(agent.clientId) }
        }
        return result
    }

    var body: some View {
        let visible = visibleClients
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                CardHeading(text: title)
                Spacer()
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if visible.isEmpty {
                Text("No supported agents yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                // Tiles stretch to fill the row: two agents get two
                // half-width columns, not two thirds plus a blank third.
                let columns = Array(
                    repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                    count: min(max(visible.count, 1), 3))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(visible, id: \.self) { id in
                        agentTile(id: id, snapshot: snapshots[id])
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    // MARK: - Tile

    private func agentTile(id: String, snapshot: AgentUsageSnapshot?) -> some View {
        let style = ClientRegistry.style(for: id)
        let isLive = liveClientIds.contains(id)
        let detail = snapshot?.error
            ?? [snapshot?.identity?.email, snapshot?.identity?.plan]
                .compactMap { $0 }
                .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    clientMark(style)
                    Text(style.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Text(statusText(snapshot: snapshot, isLive: isLive))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor(snapshot: snapshot, isLive: isLive))
            }
            .padding(.bottom, 8)

            if let snapshot,
               snapshot.error != nil || snapshot.identity?.email != nil
                   || snapshot.identity?.plan != nil,
               !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 24)
                    .padding(.top, -3)
                    .padding(.bottom, 8)
                    .help(snapshot.error ?? "")
            }

            VStack(alignment: .leading, spacing: 7) {
                if let windows = snapshot?.windows, !windows.isEmpty {
                    ForEach(windows, id: \.label) { window in
                        limitWindow(
                            label: window.label,
                            remaining: window.remainingPercent,
                            resetText: window.resetText,
                            color: style.color)
                    }
                } else {
                    ForEach(Self.limitRows[id] ?? ["Limit"], id: \.self) { label in
                        limitWindow(
                            label: label, remaining: nil, resetText: nil,
                            color: style.color)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.sRGB, red: 120 / 255, green: 120 / 255,
                            blue: 128 / 255, opacity: 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    /// Drawn brand glyph (clients.ts marks), falling back to the colored
    /// disc with the display name's initial — same as the tabs/legends.
    private func clientMark(_ style: ClientStyle) -> some View {
        ClientIconView(style: style, size: 18, cornerRadius: 5)
    }

    // MARK: - Window row

    private func limitWindow(
        label: String, remaining: Double?, resetText: String?, color: Color
    ) -> some View {
        let fill = min(100.0, max(0.0, remaining ?? 0))
        let leftText = remaining.map { "\(Int(max(0, $0).rounded()))% left" } ?? "No data"
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label)
                Spacer()
                Text(resetText ?? leftText)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 3)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.sRGB, red: 120 / 255, green: 120 / 255,
                                    blue: 128 / 255, opacity: 0.18))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * fill / 100.0)
                }
            }
            .frame(height: 6)

            if resetText != nil {
                Text(leftText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.75))
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Status

    private func statusText(snapshot: AgentUsageSnapshot?, isLive: Bool) -> String {
        if snapshot?.error != nil { return "Error" }
        if let windows = snapshot?.windows, !windows.isEmpty {
            return snapshot?.source.uppercased() ?? ""
        }
        if isLive { return "Live" }
        return "No quota"
    }

    private func statusColor(snapshot: AgentUsageSnapshot?, isLive: Bool) -> Color {
        if snapshot?.error != nil { return .red }
        if snapshot?.windows.isEmpty == false { return .secondary }
        if isLive { return .accentColor }
        return .secondary
    }
}

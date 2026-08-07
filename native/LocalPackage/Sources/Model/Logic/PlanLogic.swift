import DataSource
import Foundation

// Port of the tray-title / plan-window logic in src/lib/settings.ts.

public enum PlanLogic {
    struct PickedWindow: Equatable {
        var providerId: String
        var usedPercent: Double
        var remainingPercent: Double
    }

    static func clampPercent(_ value: Double) -> Int {
        Int(min(100, max(0, value)).rounded())
    }

    // The window closest to its cap. Used both for 'auto' mode and as the
    // fallback when a pinned label is gone: providers add and drop windows
    // over time, and the first window is an arbitrary pick that can easily
    // be the emptiest one. Nil for an empty list (public API — callers all
    // pre-check today, but a trap is a bad failure mode for a UI helper).
    // Ties keep the earliest window, matching the TS reduce.
    public static func mostConstrained(_ windows: [UsageWindow]) -> UsageWindow? {
        guard let first = windows.first else { return nil }
        return windows.dropFirst().reduce(first) { worst, w in
            w.usedPercent > worst.usedPercent ? w : worst
        }
    }

    // Resolve which provider/window the menubar should show. In 'auto' mode
    // pick the window closest to its cap across all plan-capable providers;
    // otherwise honor the pinned provider + window, falling back to that
    // provider's most-constrained window when the pinned label is gone.
    // Returns nil when no plan-capable provider has any windows yet.
    static func pickPlanWindow(agentUsage: AgentUsagePayload?,
                               provider: PlanProvider,
                               windowLabel: String) -> PickedWindow? {
        let candidates = (agentUsage?.agents ?? []).filter {
            planCapableProviders.contains($0.clientId) && !$0.windows.isEmpty
        }
        guard !candidates.isEmpty else { return nil }

        if provider == .auto {
            var best: PickedWindow?
            for agent in candidates {
                for w in agent.windows {
                    if best == nil || w.usedPercent > best!.usedPercent {
                        best = PickedWindow(providerId: agent.clientId,
                                            usedPercent: w.usedPercent,
                                            remainingPercent: w.remainingPercent)
                    }
                }
            }
            return best
        }

        guard let agent = candidates.first(where: { $0.clientId == provider.rawValue })
        else { return nil }
        guard let w = agent.windows.first(where: { $0.label == windowLabel })
            ?? mostConstrained(agent.windows) else { return nil }
        return PickedWindow(providerId: agent.clientId,
                            usedPercent: w.usedPercent,
                            remainingPercent: w.remainingPercent)
    }

    static func computePlanTitle(agentUsage: AgentUsagePayload?,
                                 plan: PlanSelection) -> String {
        guard let picked = pickPlanWindow(agentUsage: agentUsage,
                                          provider: plan.provider,
                                          windowLabel: plan.window)
        else { return "—" }
        let label = planProviderLabels[picked.providerId] ?? picked.providerId
        let used = clampPercent(picked.usedPercent)
        // Flag windows at/over 80% consumed so the menubar warns before you
        // run out.
        let warn = used >= 80 ? "⚠ " : ""
        if plan.displayMode == .left {
            return "\(warn)\(label) \(clampPercent(picked.remainingPercent))% left"
        }
        return "\(warn)\(label) \(used)%"
    }

    public static func computeTrayTitle(mode: TrayMode,
                                        stats: Stats?,
                                        tokensPerMin: Double? = nil,
                                        agentUsage: AgentUsagePayload? = nil,
                                        plan: PlanSelection = .default,
                                        now: Date = Date()) -> String {
        if mode == .hidden { return "" }
        // Plan percentage comes from OAuth quota, not the local token stats,
        // so it is resolved before the `stats == nil` guard the token/cost
        // modes depend on.
        if mode == .planPercent {
            return computePlanTitle(agentUsage: agentUsage, plan: plan)
        }
        guard let stats else { return "" }
        let today = Formatters.isoDate(now)
        let todayEntry = stats.perDayMap[today]
        switch mode {
        case .todayTokens:
            return todayEntry.map { Formatters.humanizeTokens($0.tokens) } ?? "0"
        case .todayCost:
            return todayEntry.map { Formatters.formatCost($0.cost) } ?? "$0.00"
        case .totalTokens:
            return Formatters.humanizeTokens(stats.totalTokens)
        case .totalCost:
            return Formatters.formatCost(stats.totalCost)
        case .tokensPerMin:
            guard let tokensPerMin else { return "—/m" }
            return "\(Formatters.humanizeTokens(max(0, tokensPerMin.rounded())))/m"
        case .planPercent, .hidden:
            return ""  // handled above
        }
    }
}

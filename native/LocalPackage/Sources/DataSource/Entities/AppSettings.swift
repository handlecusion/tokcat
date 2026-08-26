import Foundation

// Ports of the settings model in src/lib/settings.ts. Raw values match the
// TS string literals exactly — the first-run importer decodes the Tauri
// localStorage JSON straight into these enums.

public enum TrayMode: String, Sendable, Codable, CaseIterable {
    case todayTokens = "today_tokens"
    case todayCost = "today_cost"
    case totalTokens = "total_tokens"
    case totalCost = "total_cost"
    case tokensPerMin = "tokens_per_min"
    case planPercent = "plan_percent"
    case hidden
}

public enum AnimationStyle: String, Sendable, Codable, CaseIterable {
    case cat
    case parrot
}

public enum PlanProvider: String, Sendable, Codable, CaseIterable {
    case auto
    case claude
    case codex
    case grok
    case cursor
}

public enum PlanDisplayMode: String, Sendable, Codable, CaseIterable {
    case used
    case left
}

// Providers that expose a plan/quota cap, so a "% used / % left" is
// meaningful. Purely log-parsed clients (gemini, copilot, …) only report
// cumulative tokens and are intentionally excluded.
public let planCapableProviders: [String] = ["claude", "codex", "grok", "cursor"]

// Clients the Agent limits card gives a tile to before any snapshot arrives,
// so a signed-out or erroring provider still has a visible place to report
// from. Anything else only earns a tile while it is actually reporting quota.
public let quotaTileProviders: [String] = ["claude", "codex", "gemini", "grok", "cursor"]

// Short labels shown in the (text-only) menubar title.
public let planProviderLabels: [String: String] = [
    "claude": "Claude",
    "codex": "Codex",
    "grok": "Grok",
    "cursor": "Cursor",
]

/// Which dashboard surfaces an agent appears on. The two surfaces answer
/// different questions — "what did I spend" (the usage chart and the totals
/// it feeds) and "how much of my plan is left" (the OAuth quota tile) — and
/// an agent can be worth watching in one and pure noise in the other: a
/// provider whose quota endpoint keeps erroring still has real token history,
/// and a quota-only agent has no history at all.
public enum AgentSurfaceScope: String, Sendable, Codable, CaseIterable {
    case usageAndLimits = "usage_and_limits"
    case usageOnly = "usage_only"
    case limitsOnly = "limits_only"

    public static let `default` = AgentSurfaceScope.usageAndLimits

    public var includesUsage: Bool { self != .limitsOnly }
    public var includesLimits: Bool { self != .usageOnly }
}

public struct PlanSelection: Sendable, Equatable {
    public var provider: PlanProvider
    public var window: String
    public var displayMode: PlanDisplayMode

    public init(provider: PlanProvider = .auto, window: String = "Session",
                displayMode: PlanDisplayMode = .used) {
        self.provider = provider
        self.window = window
        self.displayMode = displayMode
    }

    public static let `default` = PlanSelection()
}

public struct AppSettings: Sendable, Equatable {
    public var trayMode: TrayMode
    public var autostart: Bool
    public var animateTray: Bool
    public var animationStyle: AnimationStyle
    public var detailedTrace: Bool
    public var cursorUsage: Bool
    public var planProvider: PlanProvider
    public var planWindow: String
    public var planDisplayMode: PlanDisplayMode
    /// Client ids switched off entirely: no tab, no bars, no totals, no
    /// limits tile. The master switch — `agentScopes` narrows an agent that
    /// is still on. Kept sorted so the persisted blob does not churn on
    /// every toggle.
    public var hiddenAgents: [String]
    /// Per-agent surface scope, for agents narrowed to one surface. Absent
    /// means `AgentSurfaceScope.default`, so the map only carries the agents
    /// the user actually narrowed, and it survives the master switch being
    /// flipped off and on again.
    public var agentScopes: [String: AgentSurfaceScope]

    public init(trayMode: TrayMode = .todayTokens, autostart: Bool = false,
                animateTray: Bool = true, animationStyle: AnimationStyle = .cat,
                detailedTrace: Bool = false, cursorUsage: Bool = false,
                planProvider: PlanProvider = .auto, planWindow: String = "Session",
                planDisplayMode: PlanDisplayMode = .used,
                hiddenAgents: [String] = [],
                agentScopes: [String: AgentSurfaceScope] = [:]) {
        self.trayMode = trayMode
        self.autostart = autostart
        self.animateTray = animateTray
        self.animationStyle = animationStyle
        self.detailedTrace = detailedTrace
        self.cursorUsage = cursorUsage
        self.planProvider = planProvider
        self.planWindow = planWindow
        self.planDisplayMode = planDisplayMode
        self.hiddenAgents = hiddenAgents
        self.agentScopes = agentScopes
    }

    public static let `default` = AppSettings()
}

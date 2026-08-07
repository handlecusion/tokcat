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

// Short labels shown in the (text-only) menubar title.
public let planProviderLabels: [String: String] = [
    "claude": "Claude",
    "codex": "Codex",
    "grok": "Grok",
    "cursor": "Cursor",
]

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

    public init(trayMode: TrayMode = .todayTokens, autostart: Bool = false,
                animateTray: Bool = true, animationStyle: AnimationStyle = .cat,
                detailedTrace: Bool = false, cursorUsage: Bool = false,
                planProvider: PlanProvider = .auto, planWindow: String = "Session",
                planDisplayMode: PlanDisplayMode = .used) {
        self.trayMode = trayMode
        self.autostart = autostart
        self.animateTray = animateTray
        self.animationStyle = animationStyle
        self.detailedTrace = detailedTrace
        self.cursorUsage = cursorUsage
        self.planProvider = planProvider
        self.planWindow = planWindow
        self.planDisplayMode = planDisplayMode
    }

    public static let `default` = AppSettings()
}

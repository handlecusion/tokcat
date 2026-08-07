import Collector
import Combine
import DataSource
import Foundation

// OAuth quota store — the native home of what the Tauri app split between
// spawn_refresh_loop (30-minute agent-usage emits), useAgentUsage.ts (the
// popover staleness top-up), and the set_cursor_usage_enabled command.
//
// Owns the AgentUsagePayload the AgentLimitsCard, SettingsSheet plan radios
// and the plan_percent tray title all read. macOS 13 target —
// ObservableObject + @Published, no @Observable.
@MainActor
public final class QuotaStore: ObservableObject {
    /// How stale the snapshot may be when the popover opens before we
    /// re-fetch. Mirrors POPOVER_MAX_AGE_MS in useAgentUsage.ts: five
    /// minutes, because a full refresh is four upstream calls plus three
    /// subprocess spawns, and the 30-minute cadence must keep meaning
    /// something during an active session.
    public static let staleAfterSeconds: TimeInterval = 5 * 60
    /// REFRESH_SECS — the backend refresh cadence.
    private static let autoRefreshInterval: TimeInterval = 30 * 60

    // MARK: - Published state

    /// The latest OAuth quota payload; nil until the first fetch lands.
    @Published public private(set) var payload: AgentUsagePayload?
    /// Wall-clock time of the newest payload (parsed from its own
    /// `generatedAt`, so machine sleep counts toward staleness).
    @Published public private(set) var fetchedAt: Date?
    /// True while a full provider fan-out is in flight. Also the re-entry
    /// guard: a refresh can outlive the staleness window when an upstream
    /// is timing out, and opening the popover then must not stack fetches.
    @Published public private(set) var isRefreshing = false
    /// Last Cursor usage-fetch failure (the settings toggle surfaces it and
    /// reverts, mirroring the App.tsx auto-revert effect).
    @Published public private(set) var cursorUsageError: String?

    private var autoRefreshTask: Task<Void, Never>?

    public init() {}

    /// Providers that currently have quota windows, keyed by clientId —
    /// what the plan-source radios key their enabled/disabled state off.
    public var planSnapshots: [String: AgentUsageSnapshot] {
        var map: [String: AgentUsageSnapshot] = [:]
        for agent in payload?.agents ?? [] where !agent.windows.isEmpty {
            map[agent.clientId] = agent
        }
        return map
    }

    // MARK: - Lifecycle

    /// Kick the initial fetch and the 30-minute loop. Separate from init so
    /// tests can construct the store inertly.
    public func start() {
        refresh()
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.autoRefreshInterval * 1_000_000_000))
                if Task.isCancelled { break }
                self?.refresh()
            }
        }
    }

    // MARK: - Refresh

    /// Run the four providers concurrently off-main and publish the result.
    public func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in
            let payload = await Task.detached(priority: .utility) {
                await AgentQuota.run()
            }.value
            guard let self else { return }
            self.apply(payload)
            self.isRefreshing = false
        }
    }

    /// Popover-open top-up: only re-fetch when the snapshot is older than
    /// the staleness window (age measured against the payload's own
    /// generatedAt, so a lid-close counts rather than being skipped).
    public func refreshIfStale(now: Date = Date()) {
        guard let fetchedAt else {
            refresh()
            return
        }
        if now.timeIntervalSince(fetchedAt) >= Self.staleAfterSeconds {
            refresh()
        }
    }

    private func apply(_ payload: AgentUsagePayload) {
        // A slow fetch must not walk the clock backwards past a newer one
        // (mirrors the generatedAtRef guard in useAgentUsage.ts).
        let stamp = Self.parseGeneratedAt(payload.generatedAt)
        if let stamp, let fetchedAt, stamp < fetchedAt { return }
        self.payload = payload
        self.fetchedAt = stamp ?? Date()
    }

    static func parseGeneratedAt(_ value: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: value)
    }

    // MARK: - Cursor usage opt-in

    /// Mirror of the `set_cursor_usage_enabled` command plus the App.tsx
    /// effect around it: enabling fetches the event cache once (an error
    /// here means the toggle should revert — the caller flips the setting
    /// back when this returns false); disabling drops the cache so stale
    /// Cursor data stops surfacing on the next graph rebuild.
    ///
    /// Returns true when the change stuck.
    @discardableResult
    public func setCursorUsageEnabled(_ enabled: Bool) async -> Bool {
        if enabled {
            do {
                try await Task.detached(priority: .utility) {
                    try await CursorUsageFetcher.refreshCache()
                }.value
                cursorUsageError = nil
                return true
            } catch {
                cursorUsageError = "\(error)"
                return false
            }
        } else {
            await Task.detached(priority: .utility) {
                CursorUsageFetcher.clearCache()
            }.value
            cursorUsageError = nil
            return true
        }
    }
}

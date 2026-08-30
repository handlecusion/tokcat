import Collector
import Combine
import DataSource
import Foundation
import ServiceManagement

// Saved 3D-graph camera pose (mirrors the web app's `tokcat:orbit:v1`
// localStorage blob, reshaped for the SceneKit orbit rig: yaw/pitch angles
// plus orthographic scale and the rig's pan offset).
public struct OrbitPose: Codable, Equatable, Sendable {
    public var azimuth: Double
    public var elevation: Double
    public var scale: Double
    public var panX: Double
    public var panY: Double
    public var panZ: Double

    public init(azimuth: Double, elevation: Double, scale: Double,
                panX: Double, panY: Double, panZ: Double) {
        self.azimuth = azimuth
        self.elevation = elevation
        self.scale = scale
        self.panX = panX
        self.panY = panY
        self.panZ = panZ
    }
}

// The dashboard's single source of truth: owns the collected UsagePayload,
// the selected year/tab, user settings, and everything derived from them
// (stats, bar series, tray title). SwiftUI views read it via
// @EnvironmentObject; the app shell observes trayTitle to feed the status
// item. macOS 13 target — ObservableObject + @Published, no @Observable.
@MainActor
public final class DashboardStore: ObservableObject {
    public static let overviewTab = "overview"
    /// Trailing window behind `recentTokens`, today inclusive.
    public static let recentWindowDays = 7

    // Mirrors src/lib/settings.ts (`tokcat:settings:v1` & friends), with the
    // "tokcat." prefix mandated for the native UserDefaults store.
    private enum Keys {
        static let settings = "tokcat.settings.v1"
        static let theme = "tokcat.theme.v1"
        static let usageView = "tokcat.usageView.v1"
        static let orbit = "tokcat.orbit.v1"
    }

    // Mirrors ONESHOT_MAX_AGE_SECS: a panel-show only triggers a refresh
    // when the last completed collection is older than this.
    public static let staleAfterSeconds: TimeInterval = 30
    private static let autoRefreshInterval: TimeInterval = 30 * 60

    // MARK: - Published state

    /// Unfiltered payload across all years (one collector pass feeds both
    /// the year picker and every year view).
    @Published public private(set) var fullPayload: UsagePayload?
    /// `fullPayload` narrowed to `selectedYear` — what the dashboard renders.
    @Published public private(set) var payload: UsagePayload?
    @Published public private(set) var overviewStats: Stats?
    @Published public private(set) var activeStats: Stats?
    @Published public private(set) var overviewBars: [DayBar] = []
    @Published public private(set) var activeBars: [DayBar] = []
    /// Clients in the selected year that reach the usage surface — the chart,
    /// its totals, the tab strip.
    @Published public private(set) var presentClients: [String] = []
    /// Client ids withheld from the usage surface, for consumers that filter
    /// a live stream instead of the year's history — the tray's tokens/min.
    /// `agentsHiddenFromUsage` is the *display* count and lists only agents
    /// that have history to hide; an agent with no stored logs can still be
    /// burning tokens right now, so the live filter needs the raw predicate.
    @Published public private(set) var clientsHiddenFromUsage: Set<String> = []
    /// The same year's clients as the limits surface sees them. A separate
    /// list because the two surfaces are filtered independently: an agent can
    /// count toward the chart yet have no business owning a quota tile, and
    /// the Agent limits card seeds its tiles from a client list rather than
    /// from quota snapshots alone (a signed-out provider has none).
    @Published public private(set) var limitsClients: [String] = []
    @Published public private(set) var years: [String] = []

    @Published public var selectedYear: String {
        didSet { if oldValue != selectedYear { recomputeDerived() } }
    }
    @Published public var activeTab: String = DashboardStore.overviewTab {
        didSet { if oldValue != activeTab { recomputeDerived() } }
    }
    @Published public var themeName: String {
        didSet { defaults.set(themeName, forKey: Keys.theme) }
    }
    @Published public var usageView: String {
        didSet { defaults.set(usageView, forKey: Keys.usageView) }
    }
    @Published public var settings: AppSettings {
        didSet {
            persistSettings()
            // Direct assignments (`settings.cursorUsage =`, an imported blob)
            // bypass `apply`, so the pin clamp has to live here too or a
            // Cursor plan source survives the fetch being turned off and the
            // menubar parks a permanent "—".
            if planPinIsStranded(settings) {
                var next = settings
                next.planProvider = .auto
                settings = next
                return
            }
            if oldValue.hiddenAgents != settings.hiddenAgents
                || oldValue.agentScopes != settings.agentScopes
                || oldValue.cursorUsage != settings.cursorUsage
                || oldValue.planProvider != settings.planProvider {
                // Agents hidden from usage are filtered out of
                // presentClients before the stats and the bar series are
                // built, so the whole derived layer (tray title included)
                // has to be rebuilt. `cursorUsage` is in here because it
                // turns Cursor's limits surface on and off, which can clamp
                // a stored `limits_only` back onto usage and resurrect the
                // tab from a stale `presentClients`.
                recomputeDerived()
            } else {
                trayTitle = computeTrayTitle()
            }
            // Cheap and unconditional: `recomputeDerived` covers the branch
            // above, but an import that rewrites settings wholesale can land
            // on either path.
            refreshHiddenClients()
            // cursorUsage gates the Cursor tab out of dashboardClients —
            // don't leave the user stranded on a tab that just vanished.
            revalidateActiveTab()
        }
    }

    /// Every agent the user could plausibly want to hide or bring back:
    /// clients seen in the logs across all years, agents reporting OAuth
    /// quota, plus the currently hidden ones (a hidden agent still has to be
    /// listable, or it could never be restored). Year-independent so the
    /// Settings list doesn't shrink when an old year is selected.
    @Published public private(set) var allTimeClients: [String] = []
    /// All-time tokens per client. Missing means "no local usage at all",
    /// which is what separates a quota-only agent from a retired one.
    @Published public private(set) var allTimeTokens: [String: Int64] = [:]
    /// Tokens per client over the trailing `recentWindowDays` — the "am I
    /// still using this?" signal the visibility list shows and sorts by. A
    /// lifetime total says nothing about that: an agent can carry billions of
    /// tokens from four months ago and be dead now.
    @Published public private(set) var recentTokens: [String: Int64] = [:]

    /// True until the first collection finishes (drives the loading state).
    @Published public private(set) var isLoading = true
    /// True while any collection is in flight (spins the refresh button).
    @Published public private(set) var isRefreshing = false
    @Published public var isSettingsPresented = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var trayTitle = ""

    // Live inputs to the tray title, fed by the app target from
    // LiveTraceStore (600s rate) and QuotaStore (OAuth quota payload).
    // The tray recomputes whenever either changes so tokens_per_min and
    // plan_percent modes stay current.
    @Published public var liveTokensPerMin: Double? {
        didSet { trayTitle = computeTrayTitle() }
    }
    @Published public var agentUsage: AgentUsagePayload? {
        didSet {
            // `limitsClients` and `hasLimitsSurface` read the live quota
            // payload. Recompute here so a provider that drops out of a later
            // fetch loses its Settings row, tile, and tab together — not a
            // stale placeholder that outlives the row.
            recomputeDerived()
            revalidateActiveTab()
        }
    }

    /// Snap back to Overview when the active tab's client is no longer in
    /// the tab list (mirrors the App.tsx effect keyed on dashboardClients).
    private func revalidateActiveTab() {
        if activeTab != Self.overviewTab && !dashboardClients.contains(activeTab) {
            activeTab = Self.overviewTab
        }
    }

    /// Tab list: the union of graph clients and quota clients, sorted
    /// (App.tsx `dashboardClients`) — except Cursor, which only earns a tab
    /// while the cursor.com usage fetch is enabled (or legacy CSV data
    /// exists): with the fetch off there is no quota surface to show, so a
    /// quota-only Cursor tab is an empty shell. Local history still keeps a
    /// usage tab.
    public var dashboardClients: [String] {
        var union = Set(presentClients)
        for agent in visibleAgentUsage?.agents ?? [] {
            union.insert(agent.clientId)
        }
        // A limits-only agent whose provider is signed out has no snapshot but
        // still owns a placeholder tile on Overview. Without this its tab
        // disappears while that tile stays, and the tab that would explain the
        // tile is the one the user cannot open. Cursor is already excluded
        // here when its fetch is off, because `hasLimitsSurface` is false.
        for id in limitsClients where hasLimitsSurface(id) {
            union.insert(id)
        }
        return union.sorted()
    }

    /// Quota payload as the dashboard should render it: agents switched off
    /// or narrowed to usage are dropped, and while the cursor.com usage
    /// fetch is off Cursor is opted out of the UI entirely, so its quota
    /// snapshot goes too (tab list, Agent limits card and the tray plan
    /// title all read this).
    public var visibleAgentUsage: AgentUsagePayload? {
        guard var payload = agentUsage else { return nil }
        payload.agents.removeAll { isAgentHiddenFromLimits($0.clientId) }
        if !settings.cursorUsage {
            payload.agents.removeAll { $0.clientId == "cursor" }
        }
        return payload
    }

    // MARK: - Agent visibility

    /// Master switch: off means the agent is gone from both surfaces.
    public func isAgentHidden(_ clientId: String) -> Bool {
        settings.hiddenAgents.contains(clientId)
    }

    /// The stored scope, which may name a surface this agent cannot reach —
    /// `effectiveScope` is what the dashboard obeys.
    public func agentScope(_ clientId: String) -> AgentSurfaceScope {
        settings.agentScopes[clientId] ?? .default
    }

    /// Whether the agent has local token history to chart at all. Year-blind,
    /// like the settings list, so an agent idle since January still counts.
    public func hasUsageSurface(_ clientId: String) -> Bool {
        allTimeTokens[clientId] != nil
    }

    /// Whether the Agent limits card would draw a tile for the agent: the
    /// listed providers always have one (placeholder rows while signed out),
    /// anything else only while it is actually reporting quota.
    public func hasLimitsSurface(_ clientId: String) -> Bool {
        hasLimitsSurface(clientId, cursorUsage: settings.cursorUsage)
    }

    private func hasLimitsSurface(_ clientId: String, cursorUsage: Bool) -> Bool {
        // The cursor.com opt-in is the limits surface for Cursor: with it off,
        // `visibleAgentUsage` drops the snapshot and the Agent limits card
        // must not keep a placeholder tile either, or Settings can still
        // offer `Limits only` and Overview shows a tile whose tab is gone.
        if clientId == "cursor" && !cursorUsage { return false }
        return quotaTileProviders.contains(clientId)
            || agentUsage?.agents.contains { $0.clientId == clientId } == true
    }

    /// Scopes worth offering for this agent. Narrowing an agent to a surface
    /// it cannot reach is a trap: the master switch still reads on while the
    /// agent vanishes from the whole dashboard, with nothing on screen to
    /// explain it. A log-only agent therefore has no scope choice to make —
    /// showing it is the switch's job.
    public func availableScopes(for clientId: String) -> [AgentSurfaceScope] {
        availableScopes(for: clientId, cursorUsage: settings.cursorUsage)
    }

    private func availableScopes(
        for clientId: String, cursorUsage: Bool
    ) -> [AgentSurfaceScope] {
        // Before the first collection every agent looks history-less. Keep
        // the stored choice (so a restart does not rewrite it) but do not
        // offer every surface: a pre-collection tap would persist
        // `usage_only` for a quota-only agent, then silently flip to
        // `limits_only` once the empty history arrives.
        guard fullPayload != nil else { return [agentScope(clientId)] }
        switch (hasUsageSurface(clientId),
                hasLimitsSurface(clientId, cursorUsage: cursorUsage)) {
        case (true, true): return AgentSurfaceScope.allCases
        case (true, false): return [.usageOnly]
        case (false, true): return [.limitsOnly]
        // Nothing to show either way (a stored id for an agent that has since
        // gone): keep the row listable and inert rather than claiming a scope.
        case (false, false): return [.default]
        }
    }

    /// The scope actually in force: the stored one when the agent can honor
    /// it, otherwise the only surface it has. Clamping here rather than
    /// rewriting settings means a provider that goes quiet for a day does not
    /// lose the choice the user made.
    public func effectiveScope(_ clientId: String) -> AgentSurfaceScope {
        effectiveScope(clientId, stored: agentScope(clientId),
                       cursorUsage: settings.cursorUsage)
    }

    /// Excluded from the usage chart, the totals it feeds, and its own tab's
    /// history.
    public func isAgentHiddenFromUsage(_ clientId: String) -> Bool {
        isAgentHidden(clientId) || !effectiveScope(clientId).includesUsage
    }

    /// Excluded from the Agent limits card, the quota payload, and the
    /// menubar's plan percentage.
    public func isAgentHiddenFromLimits(_ clientId: String) -> Bool {
        isAgentHidden(clientId) || !effectiveScope(clientId).includesLimits
    }

    /// Known agents currently withheld from each surface — what the cards
    /// count to say "N hidden", so a filtered total is never silently wrong.
    /// Only agents that could have appeared count: an agent with no plan quota
    /// to report was never missing from the limits card to begin with.
    public var agentsHiddenFromUsage: [String] {
        knownAgents.filter { hasUsageSurface($0) && isAgentHiddenFromUsage($0) }
    }

    public var agentsHiddenFromLimits: [String] {
        knownAgents.filter { hasLimitsSurface($0) && isAgentHiddenFromLimits($0) }
    }

    /// The agent inventory the visibility controls list, busiest week first so
    /// the ones the user has stopped feeding sink to the bottom — which is
    /// exactly the row they came to switch off. Ordered by the number the row
    /// actually shows; all-time tokens only break ties, so agents idle this
    /// week still sort by how much history they have instead of by name.
    /// Cursor only appears while its own opt-in is on (or it has local
    /// history): with the fetch off it is already out of the UI, and a second
    /// switch for it would just be a contradiction waiting to happen.
    public var knownAgents: [String] {
        var union = Set(allTimeClients)
        for agent in agentUsage?.agents ?? [] {
            union.insert(agent.clientId)
        }
        union.formUnion(settings.hiddenAgents)
        union.formUnion(settings.agentScopes.keys)
        // The Cursor gate has to be applied after the stored ids too, not just
        // to the live snapshots: a setting made while the opt-in was on would
        // otherwise drag a dormant Cursor row back into a list where Cursor
        // has no dashboard presence to configure. The setting itself is kept,
        // so turning the opt-in back on restores the row as the user left it.
        if !settings.cursorUsage && !allTimeClients.contains("cursor") {
            union.remove("cursor")
        }
        return union.sorted { lhs, rhs in
            let recent = (recentTokens[lhs] ?? 0, recentTokens[rhs] ?? 0)
            if recent.0 != recent.1 { return recent.0 > recent.1 }
            let all = (allTimeTokens[lhs] ?? 0, allTimeTokens[rhs] ?? 0)
            return all.0 == all.1 ? lhs < rhs : all.0 > all.1
        }
    }

    public func setAgentHidden(_ clientId: String, _ hidden: Bool) {
        var ids = Set(settings.hiddenAgents)
        if hidden { ids.insert(clientId) } else { ids.remove(clientId) }
        guard ids != Set(settings.hiddenAgents) else { return }
        var next = settings
        next.hiddenAgents = ids.sorted()
        apply(next)
    }

    public func setAgentScope(_ clientId: String, _ scope: AgentSurfaceScope) {
        // Never record a scope the agent cannot honor, whatever the caller
        // believes is on offer.
        guard availableScopes(for: clientId).contains(scope),
              agentScope(clientId) != scope
        else { return }
        var next = settings
        // Only narrowed agents are stored, so the map stays a list of
        // exceptions rather than a copy of every agent ever seen.
        if scope == .default {
            next.agentScopes.removeValue(forKey: clientId)
        } else {
            next.agentScopes[clientId] = scope
        }
        apply(next)
    }

    public func showAllAgents() {
        guard !settings.hiddenAgents.isEmpty || !settings.agentScopes.isEmpty
        else { return }
        var next = settings
        next.hiddenAgents = []
        next.agentScopes = [:]
        apply(next)
    }

    /// Commit a visibility change, first reconciling anything downstream that
    /// the new state would strand.
    private func apply(_ next: AppSettings) {
        var next = next
        if planPinIsStranded(next) {
            next.planProvider = .auto
        }
        settings = next
    }

    /// A provider that no longer reaches the limits surface cannot feed the
    /// menubar's plan percentage; leaving it pinned parks a permanent "—".
    /// After inventory is known this uses the same effective scope the
    /// dashboard and Settings radio use — a stored `usage_only` that has
    /// been clamped onto limits (the agent lost its logs) must still be
    /// pinnable. Before inventory, hidden and the Cursor fetch gate are
    /// the only stored fields that can strand a pin; a stored `usage_only`
    /// waits for collection so a restart does not drop a pin the app just
    /// persisted.
    private func planPinIsStranded(_ s: AppSettings) -> Bool {
        guard s.planProvider != .auto else { return false }
        let pinned = s.planProvider.rawValue
        if s.hiddenAgents.contains(pinned) { return true }
        if pinned == "cursor" && !s.cursorUsage { return true }
        let stored = s.agentScopes[pinned] ?? .default
        if fullPayload == nil {
            // Inventory is not here yet. A stored `usage_only` may become
            // limits-only once logs are gone; do not drop the pin and make
            // the app reject a state it just persisted. Hidden and the
            // Cursor fetch gate above do not need inventory.
            return false
        }
        return !effectiveScope(pinned, stored: stored, cursorUsage: s.cursorUsage)
            .includesLimits
    }

    /// Storage-only pin check for `loadSettings`, which runs before any
    /// inventory exists (init assigns `settings` without didSet). Hidden
    /// and the Cursor fetch gate are knowable from the blob; a stored
    /// `usage_only` is not — `recomputeDerived` decides after collection.
    private static func planPinIsStrandedByStorage(_ s: AppSettings) -> Bool {
        guard s.planProvider != .auto else { return false }
        let pinned = s.planProvider.rawValue
        if s.hiddenAgents.contains(pinned) { return true }
        if pinned == "cursor" && !s.cursorUsage { return true }
        return false
    }

    private func effectiveScope(
        _ clientId: String, stored: AgentSurfaceScope, cursorUsage: Bool
    ) -> AgentSurfaceScope {
        let available = availableScopes(
            for: clientId, cursorUsage: cursorUsage)
        return available.contains(stored) ? stored : (available.first ?? .default)
    }
    @Published public private(set) var autostartBusy = false
    @Published public private(set) var autostartError: String?

    public var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
    }

    // MARK: - Private

    private let defaults: UserDefaults
    /// Per-file parse cache shared across refreshes so the 30-minute
    /// auto-refresh and manual refreshes only re-parse changed log files.
    private let usageCache = UsageCache()
    private var lastRefreshCompletedAt: Date?
    private var autoRefreshTask: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedYear = String(
            Formatters.calendar.component(.year, from: Date()))
        // Unknown stored names (corrupt import, renamed theme) fall back to
        // Blue outright so the header chip never shows a bogus label.
        // Names duplicated from UserInterface's theme registry — Model
        // can't import it (one-way layering); keep in sync with themes.ts.
        let validThemes = ["Blue", "Purple", "Pink", "Orange", "Green", "Graphite"]
        let storedTheme = defaults.string(forKey: Keys.theme) ?? "Blue"
        self.themeName = validThemes.contains(storedTheme) ? storedTheme : "Blue"
        let view = defaults.string(forKey: Keys.usageView)
        self.usageView = (view == "3d") ? "3d" : "2d"
        self.settings = Self.loadSettings(from: defaults)
        // Assignment in init skips didSet, and the tailer starts publishing
        // before the first refresh lands — seed the live filter from storage
        // so a hidden agent never gets a free window in the menubar at launch.
        self.clientsHiddenFromUsage = Set(self.settings.hiddenAgents)
        // Debug/verification hook: force the 3D graph for this session only
        // (assignment in init skips didSet, so nothing is persisted).
        if ProcessInfo.processInfo.environment["TOKCAT_FORCE_3D"] == "1" {
            self.usageView = "3d"
        }
    }

    // MARK: - 3D orbit camera pose

    private var orbitSaveTask: Task<Void, Never>?

    public func loadOrbitPose() -> OrbitPose? {
        guard let data = defaults.data(forKey: Keys.orbit) else { return nil }
        return try? JSONDecoder().decode(OrbitPose.self, from: data)
    }

    /// Debounced (500ms) persistence — drags emit a pose per mouse event.
    public func saveOrbitPose(_ pose: OrbitPose) {
        orbitSaveTask?.cancel()
        orbitSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            if let data = try? JSONEncoder().encode(pose) {
                self.defaults.set(data, forKey: Keys.orbit)
            }
        }
    }

    public func clearOrbitPose() {
        orbitSaveTask?.cancel()
        orbitSaveTask = nil
        defaults.removeObject(forKey: Keys.orbit)
    }

    /// Kick the initial collection and the 30-minute auto-refresh loop.
    /// Separate from init so tests can construct the store inertly.
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

    /// Run the collector off-main and publish the result. Synchronous and
    /// seconds-long on big logs, so it always runs in a detached task.
    public func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let cursorEnabled = settings.cursorUsage
        Task { [weak self, usageCache] in
            let started = Date()
            let result = await Task.detached(priority: .userInitiated) {
                () -> Result<UsagePayload, any Error> in
                // Mirror refresh_graph/spawn_refresh_loop (lib.rs:92-94,
                // 306-307): with the opt-in enabled, top up the Cursor
                // events cache before the rebuild so the graph sees fresh
                // data. Best-effort — offline/signed-out must not block
                // the local collection.
                if cursorEnabled {
                    try? await CursorUsageFetcher.refreshCache()
                }
                do { return .success(try UsageGraph.run(year: "", cache: usageCache)) }
                catch { return .failure(error) }
            }.value
            // Keep the refreshing state visible for ~450ms (the Rust app's
            // floor): with the warm cache a collection takes ~0.1s, and a
            // sub-frame spinner reads as "⌘R did nothing".
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.45 {
                try? await Task.sleep(nanoseconds: UInt64((0.45 - elapsed) * 1_000_000_000))
            }
            guard let self else { return }
            switch result {
            case .success(let payload):
                self.fullPayload = payload
                self.lastError = nil
            case .failure(let error):
                self.lastError = "\(error)"
            }
            self.lastRefreshCompletedAt = Date()
            self.isLoading = false
            self.isRefreshing = false
            self.recomputeDerived()
        }
    }

    /// Seed a collected payload directly, so the derived layer (stats, bars,
    /// tabs, agent inventory) can be tested without a seconds-long collector
    /// pass over the machine's real logs. Not public — production always
    /// arrives here through `refresh()`.
    func seedPayload(_ payload: UsagePayload) {
        fullPayload = payload
        lastError = nil
        isLoading = false
        recomputeDerived()
    }

    /// Refresh on panel-show only when the data is stale (mirrors the Rust
    /// ONESHOT_MAX_AGE_SECS gate).
    public func refreshIfStale(now: Date = Date()) {
        guard let last = lastRefreshCompletedAt else {
            refresh()
            return
        }
        if now.timeIntervalSince(last) > Self.staleAfterSeconds {
            refresh()
        }
    }

    // MARK: - Derived state

    /// Recompute the live-tail exclusion set. Only ids the user has actually
    /// touched can be hidden, so this walks the stored switches rather than
    /// the whole inventory — it runs on every settings write.
    private func refreshHiddenClients() {
        var ids = Set(settings.hiddenAgents)
        for id in settings.agentScopes.keys where isAgentHiddenFromUsage(id) {
            ids.insert(id)
        }
        if clientsHiddenFromUsage != ids { clientsHiddenFromUsage = ids }
    }

    private func recomputeDerived() {
        // Ahead of the `fullPayload` guard: the tray keeps ticking with no
        // history loaded, and the switch still has to hold there.
        refreshHiddenClients()
        guard let full = fullPayload else {
            payload = nil
            overviewStats = nil
            activeStats = nil
            overviewBars = []
            activeBars = []
            presentClients = []
            limitsClients = []
            allTimeClients = []
            allTimeTokens = [:]
            recentTokens = [:]
            years = [selectedYear]
            trayTitle = computeTrayTitle()
            return
        }

        recomputeAgentInventory(full)
        // Inventory can flip an effective scope (a stored `usage_only`
        // becomes honoured once logs reappear). Re-clamp here or the
        // menubar stays pinned to a provider `visibleAgentUsage` just
        // dropped, and reads "—" until the next settings tap.
        if planPinIsStranded(settings) {
            var next = settings
            next.planProvider = .auto
            settings = next
            return
        }
        years = full.years.map(\.year)
        if years.isEmpty { years = [selectedYear] }
        if !years.contains(selectedYear) {
            // Payload has no data for the picked year (e.g. year rolled
            // over); fall back to the latest year with data.
            selectedYear = years.last ?? selectedYear
        }

        let filtered = Self.filterPayload(full, year: selectedYear)
        payload = filtered

        var present = Set<String>()
        for c in filtered.contributions {
            for cc in c.clients { present.insert(cc.client) }
        }
        // Agents withheld from the usage surface are subtracted here,
        // upstream of everything: the tabs, the chart, and — deliberately —
        // the totals. One that still counted toward "tokens used in 2026"
        // would make the headline disagree with the bars it sits above.
        let visible = present.filter { !isAgentHiddenFromUsage($0) }
        presentClients = visible.sorted()
        // Year-independent: a plan-capable agent whose only logs are in
        // another year is still offered Limits only, and a signed-out
        // provider has no snapshot to sneak in via `visibleAgentUsage`.
        // Seeding from this year's `present` would leave that agent on, with
        // a scope, and nowhere on the dashboard.
        limitsClients = knownAgents
            .filter { hasLimitsSurface($0) && !isAgentHiddenFromLimits($0) }
            .sorted()

        // Quota-only clients keep their tab too (dashboardClients union),
        // mirroring the App.tsx reset effect keyed on dashboardClients.
        if activeTab != Self.overviewTab && !dashboardClients.contains(activeTab) {
            activeTab = Self.overviewTab
            return  // didSet re-enters recomputeDerived with the fixed tab
        }

        overviewStats = StatsBuilder.computeStats(filtered, selectedClients: visible)
        overviewBars = UsageBars.buildDayBars(payload: filtered, clientIds: presentClients)
        if activeTab == Self.overviewTab {
            activeStats = overviewStats
            activeBars = overviewBars
        } else {
            activeStats = StatsBuilder.computeStats(filtered, selectedClients: [activeTab])
            activeBars = UsageBars.buildDayBars(payload: filtered, clientIds: [activeTab])
        }
        trayTitle = computeTrayTitle()
    }

    /// Client list and per-client token totals — lifetime and trailing week —
    /// from the unfiltered payload: the visibility controls have to keep
    /// listing an agent whose only activity is outside the selected year, and
    /// the trailing week can straddle a year boundary.
    private func recomputeAgentInventory(_ full: UsagePayload) {
        var totals: [String: Int64] = [:]
        var recent: [String: Int64] = [:]
        // Dates are zero-padded ISO days, so the window is a string compare.
        let today = Formatters.isoDate(Date())
        let cutoff = Formatters.isoDate(
            Formatters.addDays(Date(), -(Self.recentWindowDays - 1)))
        for contribution in full.contributions {
            // Closed interval [cutoff, today]: a future-dated row from clock
            // skew or an imported payload must not inflate "last 7d" or the
            // sort order the settings list shows.
            let isRecent = contribution.date >= cutoff && contribution.date <= today
            for client in contribution.clients {
                totals[client.client, default: 0] += client.tokens.total
                if isRecent {
                    recent[client.client, default: 0] += client.tokens.total
                }
            }
        }
        allTimeTokens = totals
        allTimeClients = totals.keys.sorted()
        recentTokens = recent
    }

    /// Narrow a full payload to one year on the client side. The collector
    /// filters messages before aggregation when given a year, but running it
    /// once unfiltered lets one seconds-long pass serve every year.
    static func filterPayload(_ full: UsagePayload, year: String) -> UsagePayload {
        let prefix = year + "-"
        let contributions = full.contributions.filter { $0.date.hasPrefix(prefix) }
        var filtered = full
        filtered.contributions = contributions
        filtered.meta.dateRange = DateRange(
            start: contributions.first?.date ?? "",
            end: contributions.last?.date ?? "")
        return filtered
    }

    private func computeTrayTitle() -> String {
        PlanLogic.computeTrayTitle(
            mode: settings.trayMode,
            stats: overviewStats,
            tokensPerMin: liveTokensPerMin,
            // Visible, not raw: a hidden agent must not drive the menubar
            // either — in `auto` mode its window could otherwise be the
            // most-constrained one and own the title.
            agentUsage: visibleAgentUsage,
            plan: PlanSelection(
                provider: settings.planProvider,
                window: settings.planWindow,
                displayMode: settings.planDisplayMode))
    }

    // MARK: - Autostart (launch at login)

    /// Reconcile the toggle with the real SMAppService state (the user can
    /// flip it in System Settings behind our back).
    public func syncAutostartFromSystem() {
        let enabled = SMAppService.mainApp.status == .enabled
        if settings.autostart != enabled {
            settings.autostart = enabled
        }
    }

    public func setAutostart(_ enabled: Bool) {
        guard !autostartBusy else { return }
        autostartBusy = true
        defer { autostartBusy = false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.autostart = enabled
            autostartError = nil
        } catch {
            autostartError = error.localizedDescription
        }
    }

    // MARK: - Settings persistence

    // JSON blob with the exact TS field names/values so the shape matches
    // src/lib/settings.ts (and the exported settings snapshot).
    private struct SettingsBlob: Codable {
        var trayMode: String?
        var autostart: Bool?
        var animateTray: Bool?
        var animationStyle: String?
        var detailedTrace: Bool?
        var cursorUsage: Bool?
        var planProvider: String?
        var planWindow: String?
        var planDisplayMode: String?
        var hiddenAgents: [String]?
        var agentScopes: [String: String]?
    }

    private static func loadSettings(from defaults: UserDefaults) -> AppSettings {
        var s = AppSettings.default
        guard let data = defaults.data(forKey: Keys.settings),
              let blob = try? JSONDecoder().decode(SettingsBlob.self, from: data)
        else { return s }
        if let raw = blob.trayMode, let mode = TrayMode(rawValue: raw) {
            s.trayMode = mode
        }
        s.autostart = blob.autostart ?? s.autostart
        s.animateTray = blob.animateTray ?? s.animateTray
        if var raw = blob.animationStyle {
            // Legacy migration mirrored from loadSettings(): cube/cat1/cat2
            // all collapse to 'cat'.
            if raw == "cube" || raw == "cat1" || raw == "cat2" { raw = "cat" }
            if let style = AnimationStyle(rawValue: raw) { s.animationStyle = style }
        }
        s.detailedTrace = blob.detailedTrace ?? s.detailedTrace
        s.cursorUsage = blob.cursorUsage ?? s.cursorUsage
        if let raw = blob.planProvider, let p = PlanProvider(rawValue: raw) {
            s.planProvider = p
        }
        s.planWindow = blob.planWindow ?? s.planWindow
        if let raw = blob.planDisplayMode, let m = PlanDisplayMode(rawValue: raw) {
            s.planDisplayMode = m
        }
        if let hidden = blob.hiddenAgents {
            // Normalized on the way in: a hand-edited or imported blob may
            // carry duplicates or an arbitrary order, and everything
            // downstream assumes a sorted, deduplicated list.
            s.hiddenAgents = Set(hidden.filter { !$0.isEmpty }).sorted()
        }
        if let scopes = blob.agentScopes {
            var decoded: [String: AgentSurfaceScope] = [:]
            for (id, raw) in scopes {
                // Unknown scope names (a newer build, a hand-edited blob)
                // fall back to showing the agent everywhere rather than
                // hiding it somewhere the user cannot see why.
                guard !id.isEmpty, let scope = AgentSurfaceScope(rawValue: raw),
                      scope != .default
                else { continue }
                decoded[id] = scope
            }
            s.agentScopes = decoded
        }
        // Imported / hand-edited blobs can name a plan provider the rest of
        // the blob has already taken off the limits surface. Init assigns
        // `settings` without didSet, so the clamp has to happen here or the
        // menubar starts as "—" and stays there until the next visibility tap.
        if planPinIsStrandedByStorage(s) {
            s.planProvider = .auto
        }
        return s
    }

    private func persistSettings() {
        let blob = SettingsBlob(
            trayMode: settings.trayMode.rawValue,
            autostart: settings.autostart,
            animateTray: settings.animateTray,
            animationStyle: settings.animationStyle.rawValue,
            detailedTrace: settings.detailedTrace,
            cursorUsage: settings.cursorUsage,
            planProvider: settings.planProvider.rawValue,
            planWindow: settings.planWindow,
            planDisplayMode: settings.planDisplayMode.rawValue,
            hiddenAgents: settings.hiddenAgents,
            agentScopes: settings.agentScopes.mapValues(\.rawValue))
        if let data = try? JSONEncoder().encode(blob) {
            defaults.set(data, forKey: Keys.settings)
        }
    }
}

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
    @Published public private(set) var presentClients: [String] = []
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
            trayTitle = computeTrayTitle()
        }
    }

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
        didSet { trayTitle = computeTrayTitle() }
    }

    /// Tab list: the union of graph clients and quota clients, sorted
    /// (App.tsx `dashboardClients`). A client with only quota data — e.g.
    /// Cursor before the usage-history opt-in — still gets a tab, showing
    /// its limits card over an empty chart.
    public var dashboardClients: [String] {
        var union = Set(presentClients)
        for agent in agentUsage?.agents ?? [] { union.insert(agent.clientId) }
        return union.sorted()
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
        self.themeName = defaults.string(forKey: Keys.theme) ?? "Blue"
        let view = defaults.string(forKey: Keys.usageView)
        self.usageView = (view == "3d") ? "3d" : "2d"
        self.settings = Self.loadSettings(from: defaults)
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
        Task { [weak self, usageCache] in
            let result = await Task.detached(priority: .userInitiated) {
                () -> Result<UsagePayload, any Error> in
                do { return .success(try UsageGraph.run(year: "", cache: usageCache)) }
                catch { return .failure(error) }
            }.value
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

    private func recomputeDerived() {
        guard let full = fullPayload else {
            payload = nil
            overviewStats = nil
            activeStats = nil
            overviewBars = []
            activeBars = []
            presentClients = []
            years = [selectedYear]
            trayTitle = computeTrayTitle()
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
        presentClients = present.sorted()

        // Quota-only clients keep their tab too (dashboardClients union),
        // mirroring the App.tsx reset effect keyed on dashboardClients.
        if activeTab != Self.overviewTab && !dashboardClients.contains(activeTab) {
            activeTab = Self.overviewTab
            return  // didSet re-enters recomputeDerived with the fixed tab
        }

        overviewStats = StatsBuilder.computeStats(filtered, selectedClients: present)
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
            agentUsage: agentUsage,
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
            planDisplayMode: settings.planDisplayMode.rawValue)
        if let data = try? JSONEncoder().encode(blob) {
            defaults.set(data, forKey: Keys.settings)
        }
    }
}

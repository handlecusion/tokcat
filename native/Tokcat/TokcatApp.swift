import AppKit
import Combine
import Model
import SwiftUI
import UserInterface

// LSUIElement menubar app: no scenes, no windows — everything lives in the
// status item and the tray panel. AppDelegate (in Model) owns the shell;
// this file only composes the layers Model can't see (UserInterface).
@main
final class AppMain {
    // Kept alive for the app's lifetime.
    @MainActor private static var store: DashboardStore?
    @MainActor private static var liveTrace: LiveTraceStore?
    @MainActor private static var quota: QuotaStore?
    @MainActor private static var updateService: UpdateService?
    @MainActor private static var cancellables: Set<AnyCancellable> = []

    static func main() {
        // Import Tauri-era state (localStorage settings, LaunchAgent
        // autostart) before anything reads UserDefaults. One-shot.
        TauriMigration.runIfNeeded()

        let app = NSApplication.shared
        let delegate = AppDelegate()
        let store = DashboardStore()
        let updates = UpdateService()
        MainActor.assumeIsolated { Self.updateService = updates }
        // Sparkle dialogs steal key status; shield the panel's blur-to-hide
        // while an update session is visible (paired push/pop guarded here).
        var updateShieldRaised = false
        updates.onUpdateSessionChange = { [weak delegate] active in
            guard active != updateShieldRaised else { return }
            updateShieldRaised = active
            if active {
                delegate?.panelController?.pushShield()
            } else {
                delegate?.panelController?.popShield()
            }
        }
        let liveTrace = LiveTraceStore()
        let quota = QuotaStore()
        MainActor.assumeIsolated {
            Self.store = store
            Self.liveTrace = liveTrace
            Self.quota = quota
        }

        delegate.makePanelContent = { onHeightChange in
            let hosting = NSHostingView(
                rootView: DashboardRootView()
                    .environmentObject(store)
                    .environmentObject(liveTrace)
                    .environmentObject(quota)
                    .environmentObject(updates)
                    .onPreferenceChange(ContentHeightKey.self) { height in
                        onHeightChange(height)
                    }
            )
            // The panel owns its size (ContentHeightKey → setContentHeight);
            // without this the hosting view's own min/ideal-size constraints
            // fight the borderless panel and can collapse it to zero.
            hosting.sizingOptions = []
            return hosting
        }
        delegate.onMenuAction = { action in
            switch action {
            case .about:
                // Accessory apps open windows behind the frontmost app
                // unless activated first — About looked like a no-op.
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            case .settings:
                store.isSettingsPresented = true
                delegate.panelController?.show(
                    under: delegate.statusItemController?.button)
            case .refreshNow:
                store.refresh()
                quota.refreshNow()
            case .checkForUpdates:
                updates.checkForUpdates()
            case .openTokcat:
                break  // handled by the shell
            }
        }
        delegate.onPanelWillShow = {
            // No graph refresh on open — the user found the per-open
            // refresh (spinner + tray bounce every click) noisy; the
            // 30-minute auto-refresh loop and manual ⌘R cover freshness.
            // Quota still tops up silently when older than 5 min
            // (useAgentUsage.ts popover-shown behavior).
            quota.refreshIfStale()
        }

        app.delegate = delegate

        // The status item exists only after didFinishLaunching; wire the
        // tray title stream (and the debug show-panel hook) then.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                updates.start()
                store.$trayTitle
                    .removeDuplicates()
                    .sink { [weak delegate] title in
                        delegate?.statusItemController?.setTitle(title)
                    }
                    .store(in: &Self.cancellables)
                // Animation settings → tray glyph. The style swap is cheap
                // and de-duped inside the controller, so a plain settings
                // sink is fine.
                store.$settings
                    .map { ($0.animateTray, $0.animationStyle) }
                    .removeDuplicates(by: ==)
                    .sink { [weak delegate] animate, style in
                        delegate?.statusItemController?.setAnimationStyle(style)
                        delegate?.statusItemController?.setAnimating(animate)
                    }
                    .store(in: &Self.cancellables)
                // Refresh in flight → freeze the spin + bounce the glyph.
                store.$isRefreshing
                    .removeDuplicates()
                    .sink { [weak delegate] refreshing in
                        delegate?.statusItemController?.setRefreshing(refreshing)
                    }
                    .store(in: &Self.cancellables)
                // Live tail → tray animation speed (60s rate) and tray
                // title (600s moving average, state.rs semantics).
                liveTrace.$tokensPerMin
                    .removeDuplicates()
                    .sink { [weak delegate] rate in
                        delegate?.statusItemController?.setRate(tokensPerMin: rate)
                    }
                    .store(in: &Self.cancellables)
                liveTrace.$rateInWindow600
                    .removeDuplicates()
                    .sink { rate in store.liveTokensPerMin = rate }
                    .store(in: &Self.cancellables)
                // Both live rates are usage readings, so an agent hidden from
                // usage must not move them. The set changes only when the
                // user flips a switch, so this costs nothing per tick.
                store.$clientsHiddenFromUsage
                    .removeDuplicates()
                    .sink { hidden in liveTrace.setHiddenClients(hidden) }
                    .store(in: &Self.cancellables)
                // OAuth quota → tray plan_percent input.
                quota.$payload
                    .sink { payload in store.agentUsage = payload }
                    .store(in: &Self.cancellables)
                // Settings → detailed-trace split.
                store.$settings
                    .map(\.detailedTrace)
                    .removeDuplicates()
                    .sink { detailed in liveTrace.setDetailedTrace(detailed) }
                    .store(in: &Self.cancellables)
                // Same Cursor opt-in as the historical event cache: live
                // polling is another cursor.com/api2.cursor.sh call.
                store.$settings
                    .map(\.cursorUsage)
                    .removeDuplicates()
                    .sink { enabled in liveTrace.setCursorLiveEnabled(enabled) }
                    .store(in: &Self.cancellables)

                store.start()
                liveTrace.start()
                quota.start()

                // Panel ⌘-shortcuts (App.tsx:206-301 parity; Esc/⌘W/⌘Q are
                // handled by the panel itself). Cmd-only — ctrl/alt/shift
                // combinations pass through.
                delegate.panelController?.keyEquivalentRouter = { event in
                    let flags = event.modifierFlags
                        .intersection(.deviceIndependentFlagsMask)
                    guard flags == .command,
                          let key = KeyShortcut.normalizedChar(for: event)
                    else { return false }
                    var tabs = [DashboardStore.overviewTab]
                    // Union of graph + quota clients — must match TabStrip's
                    // tab order so ⌘N hits the tab its pin points at.
                    tabs.append(contentsOf: store.dashboardClients)
                    switch key {
                    case ",":
                        store.isSettingsPresented = true
                        return true
                    case "r":
                        store.refresh()
                        quota.refreshNow()
                        return true
                    case "g":
                        store.usageView = store.usageView == "3d" ? "2d" : "3d"
                        return true
                    case "u":
                        updates.checkForUpdates()
                        return true
                    case "w" where store.isSettingsPresented:
                        // Close the topmost layer first (App.tsx:254-260);
                        // returning false lets the panel's own ⌘W hide it
                        // when settings are already closed.
                        store.isSettingsPresented = false
                        return true
                    case "[", "]":
                        guard let idx = tabs.firstIndex(of: store.activeTab)
                        else { return true }
                        let delta = key == "]" ? 1 : -1
                        let next = (idx + delta + tabs.count) % tabs.count
                        store.activeTab = tabs[next]
                        return true
                    case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                        let n = Int(String(key))! - 1
                        if n < tabs.count { store.activeTab = tabs[n] }
                        return true
                    default:
                        return false
                    }
                }

                // Debug/verification hook: show the panel immediately so the
                // dashboard can be screenshot without clicking the status item.
                if ProcessInfo.processInfo.environment["TOKCAT_SHOW_PANEL_ON_LAUNCH"] == "1" {
                    // Shield keeps the panel up even when it loses key
                    // status (this hook exists for automated screenshots).
                    // Delayed: right at didFinishLaunching the status bar
                    // window hasn't been positioned yet, so anchoring to the
                    // button would compute an off-screen frame.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        delegate.panelController?.pushShield()
                        delegate.panelController?.show(
                            under: delegate.statusItemController?.button)
                    }
                }
            }
        }

        app.run()
    }
}

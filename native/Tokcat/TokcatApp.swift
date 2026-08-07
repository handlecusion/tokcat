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
                NSApp.orderFrontStandardAboutPanel(nil)
            case .settings:
                store.isSettingsPresented = true
                delegate.panelController?.show(
                    under: delegate.statusItemController?.button)
            case .refreshNow:
                store.refresh()
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

                store.start()
                liveTrace.start()
                quota.start()

                // Panel ⌘-shortcuts (App.tsx:206-301 parity; Esc/⌘W/⌘Q are
                // handled by the panel itself). Cmd-only — ctrl/alt/shift
                // combinations pass through.
                delegate.panelController?.keyEquivalentRouter = { event in
                    let flags = event.modifierFlags
                        .intersection(.deviceIndependentFlagsMask)
                    guard flags == .command else { return false }
                    var tabs = [DashboardStore.overviewTab]
                    // Union of graph + quota clients — must match TabStrip's
                    // tab order so ⌘N hits the tab its pin points at.
                    tabs.append(contentsOf: store.dashboardClients)
                    // Key codes, not characters: with a Korean (or any
                    // non-Latin) input source, charactersIgnoringModifiers
                    // yields the IME character ("ㄱ" for R), which silently
                    // broke every letter shortcut.
                    switch event.keyCode {
                    case 43:  // ,
                        store.isSettingsPresented = true
                        return true
                    case 15:  // R
                        store.refresh()
                        return true
                    case 5:  // G
                        store.usageView = store.usageView == "3d" ? "2d" : "3d"
                        return true
                    case 32:  // U
                        updates.checkForUpdates()
                        return true
                    case 33, 30:  // [ / ]
                        guard let idx = tabs.firstIndex(of: store.activeTab)
                        else { return true }
                        let delta = event.keyCode == 30 ? 1 : -1
                        let next = (idx + delta + tabs.count) % tabs.count
                        store.activeTab = tabs[next]
                        return true
                    // ANSI digit key codes 1…9 (not contiguous).
                    case 18, 19, 20, 21, 23, 22, 26, 28, 25:
                        let digitByKeyCode: [UInt16: Int] = [
                            18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
                            22: 6, 26: 7, 28: 8, 25: 9,
                        ]
                        let n = digitByKeyCode[event.keyCode]! - 1
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

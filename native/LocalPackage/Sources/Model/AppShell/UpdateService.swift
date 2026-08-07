import Foundation
import Sparkle

// Sparkle 2 wrapper. The Tauri app checked every 30 minutes; Sparkle clamps
// scheduled checks to a 1-hour minimum, so we accept hourly (plus a check on
// every launch, which Sparkle does by default when automatic checks are on).
//
// Update feed configuration lives in Info.plist:
//   SUFeedURL      = https://github.com/handlecusion/tokcat/releases/latest/download/appcast.xml
//   SUPublicEDKey  = <Sparkle EdDSA public key — generated once, private half in CI>
//   SUEnableAutomaticChecks = YES
//
// The app is ad-hoc signed, so EdDSA is the sole integrity check for
// Sparkle-driven updates (Apple-signature matching only applies to
// Developer ID-signed apps). The minisign/latest.json channel for legacy
// Tauri clients is produced by CI, not by this class.
//
// If SUPublicEDKey is absent from Info.plist (dev builds before key
// generation), Sparkle refuses updates at install time; the menu item still
// works and reports feed errors through the standard UI.
@MainActor
public final class UpdateService: NSObject, ObservableObject {
    @Published public private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController?
    // Raised around Sparkle UI so the panel's blur-to-hide doesn't fire
    // underneath update dialogs (the Tauri app's "dialog shield").
    public var onUpdateSessionChange: ((Bool) -> Void)?

    public func start() {
        guard controller == nil else { return }
        let c = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil)
        controller = c
        c.updater.automaticallyChecksForUpdates = true
        c.updater.updateCheckInterval = 3600
        c.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    public func checkForUpdates() {
        // Raise the shield for the whole interactive session: Sparkle's
        // "Checking for updates…" window and the up-to-date alert take key
        // status before any delegate callback fires, and the panel would
        // blur-hide underneath them. didFinishUpdateCycleFor lowers it.
        onUpdateSessionChange?(true)
        controller?.checkForUpdates(nil)
    }
}

extension UpdateService: SPUUpdaterDelegate {
    public nonisolated func updater(_ updater: SPUUpdater,
                                    willScheduleUpdateCheckAfterDelay delay: TimeInterval) {}

    public nonisolated func updater(_ updater: SPUUpdater,
                                    didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in self.onUpdateSessionChange?(true) }
    }

    public nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.onUpdateSessionChange?(false) }
    }

    public nonisolated func updater(_ updater: SPUUpdater,
                                    didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                                    error: (any Error)?) {
        Task { @MainActor in self.onUpdateSessionChange?(false) }
    }
}

import Collector
import Combine
import Foundation

// Owns the live-rate tailer (the port of src-tauri/src/usage_tail.rs) and
// publishes the derived signals on the main actor:
//
//   tokensPerMin     — 60s window rate; feeds the tray cat's animation
//                      speed (StatusItemController.setRate).
//   rateInWindow600  — 10-minute moving average; the tray-title
//                      tokens-per-min input (PlanLogic.computeTrayTitle),
//                      mirroring state.rs::tokens_per_min_estimate.
//   trace            — raw (client, agent, model) buckets over the 600s
//                      window; the card collapses them per client unless
//                      detailedTrace is on.
//
// Both rates are net of `setHiddenClients` — the menubar is a usage reading
// and must not move for an agent the user switched off. `trace` is not: the
// card it draws is a live tail, deliberately unfiltered.
//
// Tick cadence mirrors TAIL_TICK_SECS (lib.rs:20): every 5 seconds, off the
// main actor (the tailer is an actor doing its own file IO).
@MainActor
public final class LiveTraceStore: ObservableObject {
    /// TAIL_TICK_SECS (src-tauri/src/lib.rs:20).
    public static let tickIntervalSeconds: UInt64 = 5
    /// Window used for the tray title and the trace card (state.rs:56-61,
    /// App.tsx passes windowSecs: 600).
    public static let traceWindowSecs: Int64 = 600

    @Published public private(set) var tokensPerMin: Double = 0
    @Published public private(set) var rateInWindow600: Double = 0
    @Published public private(set) var trace: [TraceRow] = []
    /// Mirrors settings.detailedTrace; the card reads it to decide whether
    /// to collapse rows per client.
    @Published public private(set) var detailedTrace: Bool = false

    private let tailer: UsageTailer
    private let cursorLive: CursorLiveProvider
    private var tickTask: Task<Void, Never>?
    private var hiddenClients: Set<String> = []
    /// Kept so a Settings change can recompute the rates without waiting for
    /// the next tick. One snapshot, not a history.
    private var lastSnapshot: LiveSnapshot?
    private var cursorLiveEnabled = false
    /// True after `start()` and until `stop()`. Independent of the
    /// opt-in so a store that has not started never polls.
    private var storeStarted = false
    private var cursorLiveRevision: UInt64 = 0

    public init(tailer: UsageTailer = UsageTailer()) {
        self.tailer = tailer
        self.cursorLive = CursorLiveProvider(tailer: tailer)
    }

    /// Test seam: inject a provider so enable/disable races can be observed.
    init(tailer: UsageTailer, cursorLive: CursorLiveProvider) {
        self.tailer = tailer
        self.cursorLive = cursorLive
    }

    public func setDetailedTrace(_ detailed: Bool) {
        detailedTrace = detailed
    }

    /// Dashboard client ids the user has hidden from the *usage* surface
    /// (DashboardStore.clientsHiddenFromUsage). Both published rates feed the
    /// menubar, which is a usage reading, so they honour the switch; `trace`
    /// stays unfiltered because the card below it is a live tail, not the
    /// usage surface.
    public func setHiddenClients(_ ids: Set<String>) {
        guard hiddenClients != ids else { return }
        hiddenClients = ids
        // Republish off the last snapshot: flipping a switch in Settings
        // should move the menubar now, not after up to 5 more seconds.
        if let lastSnapshot { publish(lastSnapshot) }
    }

    /// Same opt-in as the historical Cursor event cache. Off: no Cursor
    /// live polls. On: start the adaptive poller.
    ///
    /// Each call hops back to the main actor and re-reads the *latest*
    /// flags before talking to the provider, so a stale `start()` cannot
    /// outrun a later opt-out.
    public func setCursorLiveEnabled(_ enabled: Bool) {
        cursorLiveEnabled = enabled
        syncCursorLive()
    }

    /// Start the 5s tick loop (immediate first tick). Idempotent.
    public func start() {
        storeStarted = true
        syncCursorLive()
        guard tickTask == nil else { return }
        tickTask = Task { [weak self, tailer] in
            while !Task.isCancelled {
                await tailer.tick()
                // One actor hop, one walk of the event ring: the rates are
                // summed from the same totals the buckets are built from.
                let snapshot = await tailer.liveSnapshot(
                    windowSecs: Self.traceWindowSecs)
                guard let self else { return }
                self.apply(snapshot)
                try? await Task.sleep(
                    nanoseconds: Self.tickIntervalSeconds * 1_000_000_000)
            }
        }
    }

    /// The tick's publish step without the file IO — internal so tests can
    /// drive the store from a hand-built snapshot.
    func apply(_ snapshot: LiveSnapshot) {
        lastSnapshot = snapshot
        publish(snapshot)
    }

    private func publish(_ snapshot: LiveSnapshot) {
        let windowMin = Float(Self.traceWindowSecs) / 60.0
        // Float round-trips mirror UsageTailer.ratePerMin / rateInWindow so
        // the tray title is bit-for-bit what the three-call path produced.
        let rate60 = Double(Float(visibleTotal(snapshot.recentTokensByClient)))
        let rate600 = Double(
            Float(visibleTotal(snapshot.windowTokensByClient)) / windowMin)
        // Publish only on change — the 5s tick fires with the panel closed
        // too, and identical assignments still churn the (hidden) SwiftUI
        // hierarchy on the main thread.
        if tokensPerMin != rate60 { tokensPerMin = rate60 }
        if rateInWindow600 != rate600 { rateInWindow600 = rate600 }
        let rows = snapshot.buckets.map(TraceRow.init)
        if trace != rows { trace = rows }
    }

    private func visibleTotal(_ totals: [String: Int64]) -> Int64 {
        // Nothing hidden is the common case; skip the per-client normalize
        // rather than pay for it on every tick of an idle menubar.
        guard !hiddenClients.isEmpty else {
            return totals.values.reduce(0, +)
        }
        return totals.reduce(into: Int64(0)) { sum, entry in
            if !hiddenClients.contains(TraceClients.normalize(entry.key)) {
                sum += entry.value
            }
        }
    }

    public func stop() {
        storeStarted = false
        tickTask?.cancel()
        tickTask = nil
        syncCursorLive()
    }

    private func syncCursorLive() {
        cursorLiveRevision += 1
        let revision = cursorLiveRevision
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard revision == self.cursorLiveRevision else { return }
            let want = self.storeStarted && self.cursorLiveEnabled
            await self.cursorLive.setEnabled(want, revision: revision)
        }
    }
}

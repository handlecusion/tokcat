import Collector
import Combine
import Foundation

// Owns the live-rate tailer (the port of src-tauri/src/usage_tail.rs) and
// publishes the derived signals on the main actor:
//
//   tokensPerMin     — 60s window rate; feeds the tray cat's animation
//                      speed (StatusItemController.setRate).
//   rateInWindow600  — 10-minute moving average; the tray-title
//                      tokens-per-min input (PlanLogic.computeTrayTitle) and
//                      the trace card's "total" line, mirroring
//                      state.rs::tokens_per_min_estimate.
//   trace            — raw (client, agent, model) buckets over the 600s
//                      window; the card collapses them per client unless
//                      detailedTrace is on.
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
    private var tickTask: Task<Void, Never>?

    public init(tailer: UsageTailer = UsageTailer()) {
        self.tailer = tailer
    }

    public func setDetailedTrace(_ detailed: Bool) {
        detailedTrace = detailed
    }

    /// Start the 5s tick loop (immediate first tick). Idempotent.
    public func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self, tailer] in
            while !Task.isCancelled {
                await tailer.tick()
                let rate60 = await tailer.ratePerMin()
                let rate600 = await tailer.rateInWindow(Self.traceWindowSecs)
                let buckets = await tailer.trace(windowSecs: Self.traceWindowSecs)
                guard let self else { return }
                self.tokensPerMin = rate60
                self.rateInWindow600 = rate600
                self.trace = buckets.map(TraceRow.init)
                try? await Task.sleep(
                    nanoseconds: Self.tickIntervalSeconds * 1_000_000_000)
            }
        }
    }

    public func stop() {
        tickTask?.cancel()
        tickTask = nil
    }
}

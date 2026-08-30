import Foundation
import Testing

@testable import Collector
@testable import Model

// The menubar's tokens/min is a usage reading, so it honours the same
// per-agent switch the chart does (DashboardStore.clientsHiddenFromUsage).
// The trace card below it is a live tail and stays unfiltered — the PR note
// calls that out deliberately, so it is asserted here rather than assumed.

private func snapshot(recent: [String: Int64], window: [String: Int64],
                      buckets: [TraceBucket] = []) -> LiveSnapshot {
    LiveSnapshot(buckets: buckets, recentTokensByClient: recent,
                 windowTokensByClient: window)
}

@MainActor
@Suite struct LiveRateVisibilityTests {
    @Test func nothingHiddenSumsEveryClient() {
        let store = LiveTraceStore()
        store.apply(snapshot(recent: ["claude-code": 300, "codex-cli": 200],
                             window: ["claude-code": 3000, "codex-cli": 2000]))

        #expect(store.tokensPerMin == 500)
        // 5000 tokens over the 600s window = 500/min.
        #expect(store.rateInWindow600 == 500)
    }

    @Test func aHiddenClientDropsOutOfBothRates() {
        let store = LiveTraceStore()
        store.setHiddenClients(["codex"])
        store.apply(snapshot(recent: ["claude-code": 300, "codex-cli": 200],
                             window: ["claude-code": 3000, "codex-cli": 2000]))

        #expect(store.tokensPerMin == 300)
        #expect(store.rateInWindow600 == 300)
    }

    // Trace ids are "claude-code"/"codex-cli"; the settings switch stores the
    // dashboard id. Hiding by the raw tail id must not work by accident.
    @Test func hiddenIdsAreMatchedAfterNormalization() {
        let store = LiveTraceStore()
        store.setHiddenClients(["claude-code"])
        store.apply(snapshot(recent: ["claude-code": 300], window: [:]))

        #expect(store.tokensPerMin == 300)

        store.setHiddenClients(["claude"])
        #expect(store.tokensPerMin == 0)
    }

    // Flipping the switch must move the menubar now, not after up to 5 more
    // seconds of tick.
    @Test func togglingRepublishesWithoutWaitingForTheNextTick() {
        let store = LiveTraceStore()
        store.apply(snapshot(recent: ["claude-code": 300, "codex-cli": 200],
                             window: ["claude-code": 3000, "codex-cli": 2000]))
        #expect(store.tokensPerMin == 500)

        store.setHiddenClients(["claude"])
        #expect(store.tokensPerMin == 200)
        #expect(store.rateInWindow600 == 200)

        store.setHiddenClients([])
        #expect(store.tokensPerMin == 500)
        #expect(store.rateInWindow600 == 500)
    }

    // The Live activity card is a tail, not the usage surface.
    @Test func theTraceItselfStaysUnfiltered() {
        let store = LiveTraceStore()
        store.setHiddenClients(["codex"])
        let buckets = [
            TraceBucket(client: "claude-code", agent: "main", model: "sonnet",
                        tokens: 3000, messages: 3, tokensPerMin: 300),
            TraceBucket(client: "codex-cli", agent: "main", model: "gpt",
                        tokens: 2000, messages: 2, tokensPerMin: 200),
        ]
        store.apply(snapshot(recent: [:], window: [:], buckets: buckets))

        #expect(store.trace.map(\.client) == ["claude-code", "codex-cli"])
    }

    @Test func anUnknownHiddenIdChangesNothing() {
        let store = LiveTraceStore()
        store.setHiddenClients(["gemini"])
        store.apply(snapshot(recent: ["claude-code": 300], window: [:]))

        #expect(store.tokensPerMin == 300)
    }
}

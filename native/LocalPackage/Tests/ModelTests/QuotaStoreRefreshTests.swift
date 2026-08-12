import DataSource
import Foundation
import Testing

@testable import Model

// Refresh state machine of QuotaStore: which calls are allowed to be dropped
// while a fetch is in flight, and which are not.
//
// The distinction matters because an in-flight fetch reads its credentials
// before it finishes. A user who hits Refresh after fixing an expired Claude
// token (#55) would otherwise be answered by a fetch that had already read the
// broken credential, stranding the error until the 30-minute tick.

/// Sequences provider calls without sleeping: each `runProviders` invocation
/// records itself and hands control back through a payload the test supplies,
/// so the drain loop is exercised deterministically.
@MainActor
private final class ProviderProbe {
    private(set) var calls = 0
    /// Runs on the Nth provider call, before it returns — the seam used to
    /// simulate a button press landing mid-fetch.
    var onCall: ((Int) -> Void)?

    func payload() -> AgentUsagePayload {
        calls += 1
        onCall?(calls)
        return AgentUsagePayload(
            generatedAt: "2026-01-01T00:00:0\(min(calls, 9)).000Z", agents: [])
    }
}

/// Pumps the main-actor run loop until `condition` holds, without wall-clock
/// waits. Bounded so a regression fails the test instead of hanging CI.
@MainActor
private func settle(
    until condition: () -> Bool, _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("timed out waiting for \(label)", sourceLocation: sourceLocation)
}

@Suite @MainActor struct QuotaStoreRefreshTests {
    /// The pre-existing contract: automatic callers must not stack fetches.
    @Test func refreshIsDroppedWhileAFetchIsInFlight() async {
        let probe = ProviderProbe()
        let store = QuotaStore()
        store.runProviders = { await probe.payload() }

        probe.onCall = { call in
            // A second automatic refresh arriving mid-fetch is discarded.
            if call == 1 { store.refresh() }
        }
        store.refresh()

        await settle(until: { !store.isRefreshing }, "refresh to finish")
        #expect(probe.calls == 1)
        #expect(store.pendingUserRefresh == false)
    }

    /// The fix: an explicit press mid-fetch is queued, not dropped, and the
    /// store runs the providers a second time to answer it.
    @Test func refreshNowMidFetchRunsTheProvidersAgain() async {
        let probe = ProviderProbe()
        let store = QuotaStore()
        store.runProviders = { await probe.payload() }

        probe.onCall = { call in
            if call == 1 {
                store.refreshNow()
                #expect(store.pendingUserRefresh)
            }
        }
        store.refresh()

        await settle(until: { !store.isRefreshing }, "queued refresh to finish")
        #expect(probe.calls == 2)
        #expect(store.pendingUserRefresh == false)
    }

    /// Repeated presses during one fetch collapse into a single extra pass —
    /// the queue is a flag, not a backlog.
    @Test func repeatedPressesCoalesceIntoOneExtraPass() async {
        let probe = ProviderProbe()
        let store = QuotaStore()
        store.runProviders = { await probe.payload() }

        probe.onCall = { call in
            if call == 1 {
                store.refreshNow()
                store.refreshNow()
                store.refreshNow()
            }
        }
        store.refresh()

        await settle(until: { !store.isRefreshing }, "coalesced refresh to finish")
        #expect(probe.calls == 2)
    }

    /// isRefreshing must stay true across the hand-off, otherwise the header
    /// spinner blinks between the two passes.
    @Test func spinnerStaysUpAcrossTheHandOff() async {
        let probe = ProviderProbe()
        let store = QuotaStore()
        store.runProviders = { await probe.payload() }

        probe.onCall = { call in
            if call == 1 { store.refreshNow() }
            // True on both passes, including the moment the first one ends
            // and the queued one takes over.
            #expect(store.isRefreshing)
        }
        store.refresh()

        await settle(until: { !store.isRefreshing }, "hand-off to finish")
        #expect(probe.calls == 2)
    }

    /// When nothing is running, refreshNow just starts a fetch.
    @Test func refreshNowWhenIdleStartsAFetch() async {
        let probe = ProviderProbe()
        let store = QuotaStore()
        store.runProviders = { await probe.payload() }

        store.refreshNow()
        #expect(store.isRefreshing)
        #expect(store.pendingUserRefresh == false)

        await settle(until: { !store.isRefreshing }, "idle refreshNow to finish")
        #expect(probe.calls == 1)
    }
}

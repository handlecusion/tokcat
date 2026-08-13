import DataSource
import Foundation
import Testing

@testable import Model

// Carry-over of the last good quota reading when a provider starts failing.
//
// The tile used to blank when a provider errored: an expired Claude token
// (#55) took the numbers with it until the user ran `claude`. The store now
// keeps the previous reading, flagged stale and dated by its own updatedAt.

private func stamp(_ text: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: text)!
}

private func good(
    _ clientId: String, at updatedAt: String, remaining: Double = 40
) -> AgentUsageSnapshot {
    AgentUsageSnapshot(
        clientId: clientId, source: "oauth", updatedAt: updatedAt,
        identity: AgentIdentity(email: "a@b.c", plan: "max"),
        windows: [UsageWindow(
            label: "Session", usedPercent: 100 - remaining,
            remainingPercent: remaining)])
}

private func failed(
    _ clientId: String, at updatedAt: String, error: String = "token expired"
) -> AgentUsageSnapshot {
    AgentUsageSnapshot(
        clientId: clientId, source: "oauth", updatedAt: updatedAt,
        windows: [], error: error)
}

private func payload(_ generatedAt: String, _ agents: [AgentUsageSnapshot])
    -> AgentUsagePayload
{
    AgentUsagePayload(generatedAt: generatedAt, agents: agents)
}

@Suite struct QuotaStoreStaleCarryTests {
    @Test func keepsTheLastReadingWhenAProviderStartsFailing() {
        let previous = payload(
            "2026-01-01T00:00:00.000Z", [good("claude", at: "2026-01-01T00:00:00.000Z")])
        let now = stamp("2026-01-01T00:30:00.000Z")
        let merged = QuotaStore.carryingLastGood(
            payload("2026-01-01T00:30:00.000Z", [failed("claude", at: "2026-01-01T00:30:00.000Z")]),
            over: previous, now: now)

        let claude = merged.agents[0]
        #expect(claude.windows.first?.remainingPercent == 40)
        #expect(claude.stale == true)
        #expect(claude.error == "token expired")
        // Dates the numbers, not the failed attempt — this is what bounds
        // the carry and what the tile's "last reading" reads.
        #expect(claude.updatedAt == "2026-01-01T00:00:00.000Z")
        #expect(claude.identity?.email == "a@b.c")
    }

    @Test func aSuccessfulFetchReplacesTheCarriedReading() {
        let previous = payload(
            "2026-01-01T00:00:00.000Z",
            [{ var s = good("claude", at: "2026-01-01T00:00:00.000Z"); s.stale = true; s.error = "token expired"; return s }()])
        let fresh = good("claude", at: "2026-01-01T00:30:00.000Z", remaining: 12)
        let merged = QuotaStore.carryingLastGood(
            payload("2026-01-01T00:30:00.000Z", [fresh]),
            over: previous, now: stamp("2026-01-01T00:30:00.000Z"))

        #expect(merged.agents[0].windows.first?.remainingPercent == 12)
        #expect(merged.agents[0].stale == nil)
        #expect(merged.agents[0].error == nil)
    }

    /// Past the cap the old numbers describe windows that have rolled over,
    /// so the tile drops back to the bare error.
    @Test func stopsCarryingOnceTheReadingIsTooOld() {
        let previous = payload(
            "2026-01-01T00:00:00.000Z", [good("claude", at: "2026-01-01T00:00:00.000Z")])
        let justInside = QuotaStore.carryingLastGood(
            payload("2026-01-01T23:59:00.000Z", [failed("claude", at: "2026-01-01T23:59:00.000Z")]),
            over: previous, now: stamp("2026-01-01T23:59:00.000Z"))
        #expect(justInside.agents[0].stale == true)

        let pastCap = QuotaStore.carryingLastGood(
            payload("2026-01-02T00:01:00.000Z", [failed("claude", at: "2026-01-02T00:01:00.000Z")]),
            over: previous, now: stamp("2026-01-02T00:01:00.000Z"))
        #expect(pastCap.agents[0].windows.isEmpty)
        #expect(pastCap.agents[0].stale == nil)
        #expect(pastCap.agents[0].error == "token expired")
    }

    /// Repeated failures chain, but each carry keeps the original reading's
    /// date, so the cap still terminates the chain.
    @Test func chainedCarriesDoNotRefreshTheClock() {
        var carried = payload(
            "2026-01-01T00:00:00.000Z", [good("claude", at: "2026-01-01T00:00:00.000Z")])
        for hour in 1...23 {
            let at = String(format: "2026-01-01T%02d:00:00.000Z", hour)
            carried = QuotaStore.carryingLastGood(
                payload(at, [failed("claude", at: at)]), over: carried, now: stamp(at))
        }
        #expect(carried.agents[0].stale == true)
        #expect(carried.agents[0].updatedAt == "2026-01-01T00:00:00.000Z")

        let at = "2026-01-02T00:30:00.000Z"
        let expired = QuotaStore.carryingLastGood(
            payload(at, [failed("claude", at: at)]), over: carried, now: stamp(at))
        #expect(expired.agents[0].windows.isEmpty)
    }

    /// A client that stops reporting entirely (logged out, so the provider
    /// is no longer configured) must not be resurrected from the old payload.
    @Test func doesNotResurrectAClientThatStoppedReporting() {
        let previous = payload(
            "2026-01-01T00:00:00.000Z",
            [good("claude", at: "2026-01-01T00:00:00.000Z"),
             good("codex", at: "2026-01-01T00:00:00.000Z")])
        let merged = QuotaStore.carryingLastGood(
            payload("2026-01-01T00:30:00.000Z", [good("codex", at: "2026-01-01T00:30:00.000Z")]),
            over: previous, now: stamp("2026-01-01T00:30:00.000Z"))

        #expect(merged.agents.count == 1)
        #expect(merged.agents[0].clientId == "codex")
    }

    /// An error that still carries windows (a partial provider result) is
    /// its own reading and is left alone.
    @Test func leavesAnErrorThatStillReportsWindowsAlone() {
        let previous = payload(
            "2026-01-01T00:00:00.000Z", [good("claude", at: "2026-01-01T00:00:00.000Z")])
        var partial = good("claude", at: "2026-01-01T00:30:00.000Z", remaining: 7)
        partial.error = "weekly window unavailable"
        let merged = QuotaStore.carryingLastGood(
            payload("2026-01-01T00:30:00.000Z", [partial]),
            over: previous, now: stamp("2026-01-01T00:30:00.000Z"))

        #expect(merged.agents[0].windows.first?.remainingPercent == 7)
        #expect(merged.agents[0].stale == nil)
    }

    @Test func firstPayloadHasNothingToCarry() {
        let merged = QuotaStore.carryingLastGood(
            payload("2026-01-01T00:00:00.000Z", [failed("claude", at: "2026-01-01T00:00:00.000Z")]),
            over: nil, now: stamp("2026-01-01T00:00:00.000Z"))
        #expect(merged.agents[0].windows.isEmpty)
        #expect(merged.agents[0].stale == nil)
    }
}

/// Counts provider calls off the main actor, so the injected closure stays
/// `@Sendable` without capturing a mutable local.
private actor CallCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

@Suite @MainActor struct QuotaStoreStaleCarryIntegrationTests {
    /// End to end through refresh(): the published payload — the one the
    /// Agent limits card and the tray title read — keeps the numbers.
    @Test func publishedPayloadKeepsTheNumbersAcrossAFailure() async {
        let store = QuotaStore()
        let calls = CallCounter()
        store.runProviders = {
            await calls.next() == 1
                ? payload(
                    "2026-01-01T00:00:00.000Z", [good("claude", at: "2026-01-01T00:00:00.000Z")])
                : payload(
                    "2026-01-01T00:30:00.000Z", [failed("claude", at: "2026-01-01T00:30:00.000Z")])
        }

        store.refresh()
        for _ in 0..<10_000 where store.isRefreshing { await Task.yield() }
        #expect(store.payload?.agents.first?.stale == nil)

        store.refresh()
        for _ in 0..<10_000 where store.isRefreshing { await Task.yield() }
        let claude = store.payload?.agents.first
        #expect(claude?.stale == true)
        #expect(claude?.windows.first?.remainingPercent == 40)
        #expect(claude?.error == "token expired")
        // Still counted as a plan source, so the settings radios and the
        // tray percentage do not drop out mid-error.
        #expect(store.planSnapshots["claude"] != nil)
    }
}

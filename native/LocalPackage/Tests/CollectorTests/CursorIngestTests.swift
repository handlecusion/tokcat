import Foundation
import Testing

@testable import Collector

@Suite struct CursorIngestTests {
    @Test func ingestAddsEventsAndTraceSeesCursor() async {
        let now: Int64 = 1_700_000_000_000
        let tailer = UsageTailer(config: UsageTailerConfig(nowMs: { now }))
        let added = await tailer.ingest([
            UsageEvent(
                tsMs: now - 1_000, client: tailClientCursor, agent: "main",
                model: "claude-opus-5", input: 10, output: 20,
                cacheRead: 5, cacheWrite: 1)
        ])
        #expect(added == 1)
        let buckets = await tailer.trace(windowSecs: 600)
        #expect(buckets.count == 1)
        #expect(buckets[0].client == "cursor")
        #expect(buckets[0].model == "claude-opus-5")
        #expect(buckets[0].tokens == 36)
        #expect(buckets[0].messages == 1)
        #expect(await tailer.ratePerMin() == Double(Float(36)))
    }

    @Test func ingestSkipsEmptyAndTrimsExpired() async {
        let now: Int64 = 2_000_000_000_000
        let tailer = UsageTailer(config: UsageTailerConfig(nowMs: { now }))
        let added = await tailer.ingest([
            UsageEvent(
                tsMs: now, client: tailClientCursor, agent: "main",
                model: "a", input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            UsageEvent(
                tsMs: now - (eventWindowSecs + 10) * 1000,
                client: tailClientCursor, agent: "main",
                model: "old", input: 9, output: 0, cacheRead: 0, cacheWrite: 0),
            UsageEvent(
                tsMs: now - 1_000, client: tailClientCursor, agent: "main",
                model: "fresh", input: 3, output: 0, cacheRead: 0, cacheWrite: 0)
        ])
        #expect(added == 1)
        let snap = await tailer.eventsSnapshot()
        #expect(snap.count == 1)
        #expect(snap[0].model == "fresh")
    }

    @Test func manyCeilingEventsDoNotTrapWindowTotal() async {
        let now: Int64 = 3_000_000_000_000
        let tailer = UsageTailer(config: UsageTailerConfig(nowMs: { now }))
        // 2400 events × 4×10^15 exceeds Int64.max. Trapping `+` used to
        // SIGTRAP inside windowTotal / trace; satAdd must saturate.
        let incoming = (0..<2400).map { i in
            UsageEvent(
                tsMs: now - 1_000, client: tailClientCursor, agent: "main",
                model: "m\(i)", input: cursorTokenFieldMax,
                output: cursorTokenFieldMax, cacheRead: cursorTokenFieldMax,
                cacheWrite: cursorTokenFieldMax)
        }
        #expect(await tailer.ingest(incoming) == 2400)
        #expect(await tailer.ratePerMin() == Double(Float(Int64.max)))
        let buckets = await tailer.trace(windowSecs: 60)
        #expect(!buckets.isEmpty)
        let traced = buckets.reduce(Int64(0)) { satAdd($0, $1.tokens) }
        #expect(traced == Int64.max)
    }
}

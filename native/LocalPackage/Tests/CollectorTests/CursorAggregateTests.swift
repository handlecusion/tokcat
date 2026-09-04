import Foundation
import Testing

@testable import Collector

@Suite struct CursorAggregateParseTests {
    @Test func parsesPerModelAggregations() throws {
        let json = """
        {
          "aggregations": [
            {
              "modelIntent": "claude-opus-5-thinking-high",
              "inputTokens": "62",
              "outputTokens": 17769,
              "cacheWriteTokens": 34428,
              "cacheReadTokens": "4548472"
            }
          ],
          "totalInputTokens": 62,
          "totalOutputTokens": 17769,
          "totalCacheWriteTokens": 34428,
          "totalCacheReadTokens": 4548472
        }
        """
        let snap = try parseCursorAggregateResponse(Data(json.utf8))
        #expect(snap.models.count == 1)
        let totals = snap.models["claude-opus-5-thinking-high"]
        #expect(totals?.input == 62)
        #expect(totals?.output == 17769)
        #expect(totals?.cacheWrite == 34428)
        #expect(totals?.cacheRead == 4_548_472)
    }

    @Test func fallsBackToTopLevelTotalsWhenAggregationsEmpty() throws {
        let json = """
        {
          "aggregations": [],
          "totalInputTokens": 10,
          "totalOutputTokens": 20,
          "totalCacheWriteTokens": 3,
          "totalCacheReadTokens": 4
        }
        """
        let snap = try parseCursorAggregateResponse(Data(json.utf8))
        #expect(snap.models["cursor"]?.input == 10)
        #expect(snap.models["cursor"]?.output == 20)
        #expect(snap.models["cursor"]?.cacheWrite == 3)
        #expect(snap.models["cursor"]?.cacheRead == 4)
    }

    @Test func mergesDuplicateModelIntent() throws {
        let json = """
        {
          "aggregations": [
            {"modelIntent": "composer", "inputTokens": 1, "outputTokens": 2,
             "cacheWriteTokens": 0, "cacheReadTokens": 0},
            {"modelIntent": "composer", "inputTokens": 3, "outputTokens": 4,
             "cacheWriteTokens": 1, "cacheReadTokens": 5}
          ]
        }
        """
        let snap = try parseCursorAggregateResponse(Data(json.utf8))
        #expect(snap.models["composer"]?.input == 4)
        #expect(snap.models["composer"]?.output == 6)
        #expect(snap.models["composer"]?.cacheWrite == 1)
        #expect(snap.models["composer"]?.cacheRead == 5)
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: QuotaError.self) {
            try parseCursorAggregateResponse(Data("not-json".utf8))
        }
    }

    @Test func rejectsSchemaLessObject() {
        #expect(throws: QuotaError.self) {
            try parseCursorAggregateResponse(Data("{}".utf8))
        }
        #expect(throws: QuotaError.self) {
            try parseCursorAggregateResponse(Data(#"{"percentOfBurstUsed":1}"#.utf8))
        }
        #expect(throws: QuotaError.self) {
            try parseCursorAggregateResponse(Data(#"{"aggregations":null}"#.utf8))
        }
        #expect(throws: QuotaError.self) {
            try parseCursorAggregateResponse(Data(#"{"aggregations":[{}]}"#.utf8))
        }
    }

    @Test func rejectsOutOfRangeTokenField() {
        #expect(throws: QuotaError.self) {
            try parseCursorAggregateResponse(Data(#"{"aggregations":[{"modelIntent":"m","inputTokens":1e300}]}"#.utf8))
        }
        #expect(throws: QuotaError.self) {
            try parseCursorAggregateResponse(Data(#"{"aggregations":[{"modelIntent":"m","inputTokens":"1e19"}]}"#.utf8))
        }
        #expect(throws: QuotaError.self) {
            try parseCursorAggregateResponse(Data(#"{"aggregations":[{"modelIntent":"m","inputTokens":{"x":1}}]}"#.utf8))
        }
        // Exact Int64.max must not reach trapping `+` in merge or diff.
        #expect(throws: QuotaError.self) {
            try parseCursorAggregateResponse(Data(#"{"aggregations":[{"modelIntent":"m","inputTokens":9223372036854775807}]}"#.utf8))
        }
        #expect(throws: QuotaError.self) {
            try parseCursorAggregateResponse(Data(#"{"aggregations":[{"modelIntent":"m","inputTokens":9223372036854775807},{"modelIntent":"m","inputTokens":1}]}"#.utf8))
        }
        #expect(throws: QuotaError.self) {
            try parseCursorAggregateResponse(Data(#"{"aggregations":[{"modelIntent":"m","inputTokens":9223372036854775807,"outputTokens":1}]}"#.utf8))
        }
        // Shared parser bit-pattern-wraps u64-range ints; do not coerce to 0.
        #expect(throws: QuotaError.self) {
            try parseCursorAggregateResponse(Data(#"{"aggregations":[{"modelIntent":"m","inputTokens":18446744073709551615}]}"#.utf8))
        }
        #expect(throws: QuotaError.self) {
            try parseCursorAggregateResponse(Data(#"{"aggregations":[{"modelIntent":"m","inputTokens":-1}]}"#.utf8))
        }
        #expect(throws: QuotaError.self) {
            try parseCursorAggregateResponse(Data(#"{"aggregations":[{"modelIntent":"m","inputTokens":1000000000000001}]}"#.utf8))
        }
    }

    @Test func acceptsTokenFieldAtDomainCeiling() throws {
        let payload = try parseCursorAggregateResponse(
            Data(#"{"aggregations":[{"modelIntent":"m","inputTokens":1000000000000000}]}"#.utf8))
        #expect(payload.models["m"]?.input == cursorTokenFieldMax)
    }

    @Test func duplicateMergeOverflowThrows() {
        let a = CursorModelPartial(input: Int64.max)
        let b = CursorModelPartial(input: 1)
        #expect(throws: QuotaError.self) {
            _ = try a.merging(b)
        }
        #expect(throws: QuotaError.self) {
            try parseCursorAggregateResponse(Data(#"{"aggregations":[{"modelIntent":"m","inputTokens":1000000000000000},{"modelIntent":"m","inputTokens":1000000000000000}]}"#.utf8))
        }
    }

    @Test func omittedCountersStayNil() throws {
        let payload = try parseCursorAggregateResponse(
            Data(#"{"aggregations":[{"modelIntent":"m","inputTokens":100}]}"#.utf8))
        #expect(payload.models["m"]?.input == 100)
        #expect(payload.models["m"]?.output == nil)
        #expect(payload.models["m"]?.cacheRead == nil)
    }
}

@Suite struct CursorAggregateDifferTests {
    @Test func firstConsumeIsSilentBaseline() {
        var differ = CursorAggregateDiffer()
        let snap = CursorAggregateSnapshot(models: [
            "m": CursorModelTotals(input: 10, output: 20, cacheWrite: 1, cacheRead: 2)
        ])
        let events = differ.consume(snap, nowMs: 1_000)
        #expect(events.isEmpty)
        #expect(differ.didRebaseline)
        #expect(differ.baseline == snap)
    }

    @Test func positiveDeltaEmitsPerModelEvent() {
        var differ = CursorAggregateDiffer(baseline: CursorAggregateSnapshot(models: [
            "Claude-Opus-5-20260101": CursorModelTotals(
                input: 10, output: 20, cacheWrite: 1, cacheRead: 100)
        ]))
        let events = differ.consume(
            CursorAggregateSnapshot(models: [
                "Claude-Opus-5-20260101": CursorModelTotals(
                    input: 12, output: 25, cacheWrite: 3, cacheRead: 140)
            ]),
            nowMs: 5_000)
        #expect(events.count == 1)
        #expect(events[0].client == "cursor")
        #expect(events[0].agent == "main")
        #expect(events[0].model == "claude-opus-5")
        #expect(events[0].input == 2)
        #expect(events[0].output == 5)
        #expect(events[0].cacheWrite == 2)
        #expect(events[0].cacheRead == 40)
        #expect(events[0].tsMs == 5_000)
        #expect(!differ.didRebaseline)
    }

    @Test func newModelIsDeltaFromZero() {
        var differ = CursorAggregateDiffer(baseline: CursorAggregateSnapshot(models: [
            "a": CursorModelTotals(input: 1, output: 1, cacheWrite: 0, cacheRead: 0)
        ]))
        let events = differ.consume(
            CursorAggregateSnapshot(models: [
                "a": CursorModelTotals(input: 1, output: 1, cacheWrite: 0, cacheRead: 0),
                "b": CursorModelTotals(input: 4, output: 6, cacheWrite: 0, cacheRead: 0)
            ]),
            nowMs: 9)
        #expect(events.count == 1)
        #expect(events[0].model == "b")
        #expect(events[0].input == 4)
        #expect(events[0].output == 6)
    }

    @Test func oneDecreaseIsHeldSecondConfirmsRebaseline() {
        let previous = CursorAggregateSnapshot(models: [
            "m": CursorModelTotals(input: 100, output: 200, cacheWrite: 0, cacheRead: 0)
        ])
        var differ = CursorAggregateDiffer(baseline: previous)
        let low = CursorAggregateSnapshot(models: [
            "m": CursorModelTotals(input: 10, output: 20, cacheWrite: 0, cacheRead: 0)
        ])
        #expect(differ.consume(low, nowMs: 1).isEmpty)
        #expect(!differ.didRebaseline)
        #expect(differ.baseline == previous)

        #expect(differ.consume(low, nowMs: 2).isEmpty)
        #expect(differ.didRebaseline)
        #expect(differ.baseline == low)
    }

    @Test func flickerDecreaseThenRecoveryEmitsOnlyRealDelta() {
        let previous = CursorAggregateSnapshot(models: [
            "m": CursorModelTotals(input: 100, output: 0, cacheWrite: 0, cacheRead: 0)
        ])
        var differ = CursorAggregateDiffer(baseline: previous)
        let empty = CursorAggregateSnapshot()
        #expect(differ.consume(empty, nowMs: 1).isEmpty)
        #expect(differ.baseline == previous)

        let recovered = CursorAggregateSnapshot(models: [
            "m": CursorModelTotals(input: 101, output: 0, cacheWrite: 0, cacheRead: 0)
        ])
        let events = differ.consume(recovered, nowMs: 2)
        #expect(events.count == 1)
        #expect(events[0].input == 1)
        #expect(!differ.didRebaseline)
    }

    @Test func omittedOutputDoesNotFakeADecrease() {
        var differ = CursorAggregateDiffer(baseline: CursorAggregateSnapshot(models: [
            "m": CursorModelTotals(input: 100, output: 100, cacheWrite: 0, cacheRead: 0)
        ]))
        let partial = CursorAggregatePayload(models: [
            "m": CursorModelPartial(input: 100)
        ])
        #expect(differ.consume(payload: partial, nowMs: 1).isEmpty)
        #expect(!differ.didRebaseline)
        #expect(differ.baseline?.models["m"]?.output == 100)

        let recovered = CursorAggregatePayload(models: [
            "m": CursorModelPartial(input: 100, output: 101)
        ])
        let events = differ.consume(payload: recovered, nowMs: 2)
        #expect(events.count == 1)
        #expect(events[0].output == 1)
        #expect(events[0].input == 0)
    }

    @Test func overflowDeltaDoesNotTrapOrEmit() {
        var differ = CursorAggregateDiffer(baseline: CursorAggregateSnapshot(models: [
            "m": CursorModelTotals()
        ]))
        let events = differ.consume(
            CursorAggregateSnapshot(models: [
                "m": CursorModelTotals(input: Int64.max, output: 1)
            ]),
            nowMs: 1)
        #expect(events.isEmpty)
        #expect(!differ.didRebaseline)
    }

    @Test func domainCeilingDeltaEmits() {
        var differ = CursorAggregateDiffer(baseline: CursorAggregateSnapshot(models: [
            "m": CursorModelTotals()
        ]))
        let events = differ.consume(
            CursorAggregateSnapshot(models: [
                "m": CursorModelTotals(input: cursorTokenFieldMax)
            ]),
            nowMs: 1)
        #expect(events.count == 1)
        #expect(events[0].input == cursorTokenFieldMax)
    }

    @Test func unchangedSnapshotEmitsNothing() {
        let snap = CursorAggregateSnapshot(models: [
            "m": CursorModelTotals(input: 1, output: 2, cacheWrite: 3, cacheRead: 4)
        ])
        var differ = CursorAggregateDiffer(baseline: snap)
        #expect(differ.consume(snap, nowMs: 1).isEmpty)
        #expect(!differ.didRebaseline)
    }
}

@Suite struct CursorLiveScheduleTests {
    @Test func activeThenIdleThenLongIdle() {
        var schedule = CursorLiveSchedule()
        let t0 = Date(timeIntervalSince1970: 1_000)
        schedule.noteSuccess(hadDelta: false, now: t0)
        #expect(schedule.delay(now: t0, cursorRunning: true)
                == CursorLiveSchedule.activeSecs)

        let tIdle = t0.addingTimeInterval(CursorLiveSchedule.idleAfterSecs + 1)
        #expect(schedule.delay(now: tIdle, cursorRunning: true)
                == CursorLiveSchedule.idleSecs)

        let tLong = t0.addingTimeInterval(CursorLiveSchedule.longIdleAfterSecs + 1)
        #expect(schedule.delay(now: tLong, cursorRunning: true)
                == CursorLiveSchedule.idleLongSecs)
    }

    @Test func recentDeltaKeepsActiveCadence() {
        var schedule = CursorLiveSchedule()
        let t0 = Date(timeIntervalSince1970: 1_000)
        schedule.noteSuccess(hadDelta: false, now: t0)
        let later = t0.addingTimeInterval(CursorLiveSchedule.longIdleAfterSecs)
        schedule.noteSuccess(hadDelta: true, now: later)
        #expect(schedule.delay(now: later, cursorRunning: true)
                == CursorLiveSchedule.activeSecs)
    }

    @Test func processDownUsesProcessCheckInterval() {
        var schedule = CursorLiveSchedule()
        schedule.noteSuccess(hadDelta: true, now: Date(timeIntervalSince1970: 1))
        #expect(schedule.delay(
            now: Date(timeIntervalSince1970: 2), cursorRunning: false)
                == CursorLiveSchedule.processCheckSecs)
    }

    @Test func rateLimitEscalatesThenResetsOnSuccess() {
        var schedule = CursorLiveSchedule()
        let now = Date(timeIntervalSince1970: 1)
        schedule.noteRateLimited()
        #expect(schedule.delay(now: now, cursorRunning: true)
                == CursorLiveSchedule.rateLimitSecs)
        schedule.noteRateLimited()
        #expect(schedule.delay(now: now, cursorRunning: true)
                == CursorLiveSchedule.rateLimitLongSecs)
        schedule.noteSuccess(hadDelta: false, now: now)
        #expect(schedule.delay(now: now, cursorRunning: true)
                == CursorLiveSchedule.activeSecs)
    }
}

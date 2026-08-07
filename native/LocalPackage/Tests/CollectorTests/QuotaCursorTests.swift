import DataSource
import Foundation
import Testing

@testable import Collector

// Ports of the Cursor quota tests in agent_usage.rs (:2407-2546).

private func cursorNow() -> Date {
    Date(timeIntervalSince1970: 1_781_000_000)
}

@Suite struct QuotaCursorTests {
    @Test func windowsReportPoolsAndDropTheBlendedTotal() {
        // Numbers from the Ultra account in #22: the dashboard showed 0% and
        // 14% for the two pools while totalPercentUsed read 3%. Surfacing
        // that 3% hides the pool actually running out, so the pools win.
        let plan = CursorPlanUsage(
            limit: 186_700, used: 5600, remaining: 181_100,
            totalPercentUsed: 3, autoPercentUsed: 0, apiPercentUsed: 14)
        let windows = CursorQuotaProvider.cursorWindows(
            plan: plan, billingCycleEnd: "2026-08-22T00:00:00Z", now: cursorNow())
        #expect(windows.map(\.label) == ["Cursor Models", "Other Models"])
        #expect(windows[0].usedPercent == 0)
        #expect(windows[1].usedPercent == 14)
        #expect(abs(windows[1].remainingPercent - 86) < 1e-9)
        #expect(windows[1].resetsAt == "2026-08-22T00:00:00.000Z")
        #expect(windows[1].resetText != nil)
    }

    @Test func reportsASinglePoolWhenOnlyOneIsPresent() {
        let plan = CursorPlanUsage(totalPercentUsed: 3, apiPercentUsed: 14)
        let windows = CursorQuotaProvider.cursorWindows(
            plan: plan, billingCycleEnd: nil, now: cursorNow())
        #expect(windows.map(\.label) == ["Other Models"])
    }

    @Test func fallsBackToTheBlendedTotalWithoutAPoolSplit() {
        let plan = CursorPlanUsage(totalPercentUsed: 41)
        let windows = CursorQuotaProvider.cursorWindows(
            plan: plan, billingCycleEnd: nil, now: cursorNow())
        #expect(windows.count == 1)
        #expect(windows[0].label == "Monthly")
        #expect(windows[0].usedPercent == 41)
    }

    @Test func monthlyPercentFallsBackToDollarFigures() {
        // Older payloads carry only the money fields. `remaining` alone is
        // enough: used = limit - remaining.
        let plan = CursorPlanUsage(limit: 2000, remaining: 1500)
        let windows = CursorQuotaProvider.cursorWindows(
            plan: plan, billingCycleEnd: nil, now: cursorNow())
        #expect(windows.count == 1)
        #expect(windows[0].label == "Monthly")
        #expect(windows[0].usedPercent == 25)
        #expect(windows[0].resetsAt == nil)
    }

    @Test func windowsEmptyWithoutUsableFields() {
        // An Ultra/unlimited or unrecognized payload must yield no windows
        // so the caller surfaces "no plan windows" instead of a bogus 0%.
        #expect(CursorQuotaProvider.cursorWindows(
            plan: CursorPlanUsage(), billingCycleEnd: nil, now: cursorNow()).isEmpty)
        #expect(CursorQuotaProvider.cursorWindows(
            plan: nil, billingCycleEnd: nil, now: cursorNow()).isEmpty)
        let zeroLimit = CursorPlanUsage(limit: 0, used: 0)
        #expect(CursorQuotaProvider.cursorWindows(
            plan: zeroLimit, billingCycleEnd: nil, now: cursorNow()).isEmpty)
    }

    @Test func creditsReportDollarsLeftAndNeverGuessUnlimited() {
        let plan = CursorPlanUsage(limit: 2000, used: 812)
        let credits = CursorQuotaProvider.cursorCredits(plan: plan)
        #expect(abs((credits?.remaining ?? 0) - 11.88) < 1e-9)
        #expect(credits?.unlimited == false)
        // No limit reported => no credits row, rather than a false
        // "unlimited".
        #expect(CursorQuotaProvider.cursorCredits(plan: CursorPlanUsage()) == nil)
    }

    @Test func billingCycleEndAcceptsRFC3339AndEpochMillis() {
        let fromRFC = CursorQuotaProvider.parseCursorDatetime("2026-08-01T00:00:00Z")
        let fromMillis = CursorQuotaProvider.parseCursorDatetime("1785542400000")
        #expect(fromRFC?.timeIntervalSince1970 == 1_785_542_400)
        #expect(fromMillis == fromRFC)
        #expect(CursorQuotaProvider.parseCursorDatetime("  ") == nil)
        #expect(CursorQuotaProvider.parseCursorDatetime("not-a-date") == nil)
    }

    @Test func responseToleratesStringEncodedNumbers() throws {
        // Connect encodes int64 as JSON strings; percentages may arrive
        // either way. Both must decode rather than dropping the window.
        let raw = #"{"billingCycleEnd":"1785542400000","planUsage":{"limit":"2000","used":"500","totalPercentUsed":"25"}}"#
        let usage = try JSONDecoder().decode(CursorPeriodUsage.self, from: Data(raw.utf8))
        let windows = CursorQuotaProvider.cursorWindows(
            plan: usage.planUsage, billingCycleEnd: usage.billingCycleEnd, now: cursorNow())
        #expect(windows.count == 1)
        #expect(windows[0].usedPercent == 25)
        #expect(windows[0].resetsAt == "2026-08-01T00:00:00.000Z")
    }

    @Test func unknownFieldsDoNotBreakDecoding() throws {
        // Cursor adds fields as its billing model changes; unknown ones must
        // be ignored, and a payload with no planUsage must still decode.
        let raw = #"{"displayMessage":"hi","spendLimitUsage":{"limitType":"x"}}"#
        let usage = try JSONDecoder().decode(CursorPeriodUsage.self, from: Data(raw.utf8))
        #expect(usage.planUsage == nil)
    }
}

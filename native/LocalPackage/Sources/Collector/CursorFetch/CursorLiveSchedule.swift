import Foundation

// Adaptive poll cadence for Cursor live usage. 10s was the measurement
// resolution, not the product interval.
//
//   Cursor IDE+CLI quit  → local re-check only (no HTTP)
//   recent delta         → 15s
//   idle ≥ 2 min         → 60s
//   idle ≥ 10 min        → 120s
//   HTTP 429             → 120s, then 300s while 429s continue
//   HTTP 401/403         → provider suspends HTTP until Cursor is quit
//                          and relaunched (token is re-read each fetch)

public struct CursorLiveSchedule: Equatable, Sendable {
    public static let activeSecs: TimeInterval = 15
    public static let idleSecs: TimeInterval = 60
    public static let idleLongSecs: TimeInterval = 120
    public static let processCheckSecs: TimeInterval = 30
    public static let rateLimitSecs: TimeInterval = 120
    public static let rateLimitLongSecs: TimeInterval = 300
    public static let idleAfterSecs: TimeInterval = 2 * 60
    public static let longIdleAfterSecs: TimeInterval = 10 * 60

    public var lastDeltaAt: Date?
    public var startedAt: Date?
    public var consecutive429: Int = 0

    public init() {}

    public mutating func noteSuccess(hadDelta: Bool, now: Date) {
        consecutive429 = 0
        if startedAt == nil { startedAt = now }
        if hadDelta { lastDeltaAt = now }
    }

    public mutating func noteRateLimited() {
        consecutive429 += 1
    }

    public func delay(now: Date, cursorRunning: Bool) -> TimeInterval {
        if !cursorRunning { return Self.processCheckSecs }
        if consecutive429 >= 2 { return Self.rateLimitLongSecs }
        if consecutive429 >= 1 { return Self.rateLimitSecs }
        let anchor = lastDeltaAt ?? startedAt ?? now
        let idle = now.timeIntervalSince(anchor)
        if idle < Self.idleAfterSecs { return Self.activeSecs }
        if idle < Self.longIdleAfterSecs { return Self.idleSecs }
        return Self.idleLongSecs
    }
}

import Foundation

// Snapshot + diff for Cursor's DashboardService/GetAggregatedUsageEvents.
//
// Cursor keeps no local billed-token ledger. The aggregated endpoint returns
// monotonically growing totals for a pinned window (verified: 59 diffs / 0
// decreases over 10 minutes). Live rate is the Hermes pattern: first
// observation is a silent baseline, later ticks emit per-model positive
// deltas attributed to "now".

let tailClientCursor = "cursor"

/// Per-counter ceiling so four-way sums (duplicate merge, delta total,
/// `UsageEvent.total`) cannot trap Int64 `+`. 10^15 is far above billed
/// usage and below `Int64.max / 4`. Window aggregates still saturate via
/// `satAdd` — event count is unbounded.
let cursorTokenFieldMax: Int64 = 1_000_000_000_000_000

/// Per-model token totals from one aggregated-usage response.
public struct CursorModelTotals: Equatable, Sendable {
    public var input: Int64
    public var output: Int64
    public var cacheWrite: Int64
    public var cacheRead: Int64

    public init(input: Int64 = 0, output: Int64 = 0,
                cacheWrite: Int64 = 0, cacheRead: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    func decreasing(versus previous: CursorModelTotals) -> Bool {
        input < previous.input
            || output < previous.output
            || cacheWrite < previous.cacheWrite
            || cacheRead < previous.cacheRead
    }
}

/// One poll of GetAggregatedUsageEvents, keyed by `modelIntent`.
public struct CursorAggregateSnapshot: Equatable, Sendable {
    public var models: [String: CursorModelTotals]
    public var accountKey: String?

    public init(models: [String: CursorModelTotals] = [:], accountKey: String? = nil) {
        self.models = models
        self.accountKey = accountKey
    }

    public static let empty = CursorAggregateSnapshot()

    public var asPayload: CursorAggregatePayload {
        CursorAggregatePayload(
            models: models.mapValues {
                CursorModelPartial(
                    input: $0.input, output: $0.output,
                    cacheWrite: $0.cacheWrite, cacheRead: $0.cacheRead)
            },
            accountKey: accountKey)
    }
}

/// Wire-shape of one poll: missing counters stay nil so protobuf-style
/// omitted zeros are not treated as decreases against the previous mark.
public struct CursorModelPartial: Equatable, Sendable {
    public var input: Int64?
    public var output: Int64?
    public var cacheWrite: Int64?
    public var cacheRead: Int64?

    public init(input: Int64? = nil, output: Int64? = nil,
                cacheWrite: Int64? = nil, cacheRead: Int64? = nil) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    var hasAnyField: Bool {
        input != nil || output != nil || cacheWrite != nil || cacheRead != nil
    }

    func resolved(over previous: CursorModelTotals?) -> CursorModelTotals {
        CursorModelTotals(
            input: input ?? previous?.input ?? 0,
            output: output ?? previous?.output ?? 0,
            cacheWrite: cacheWrite ?? previous?.cacheWrite ?? 0,
            cacheRead: cacheRead ?? previous?.cacheRead ?? 0)
    }

    func merging(_ other: CursorModelPartial) throws -> CursorModelPartial {
        CursorModelPartial(
            input: try sumOpt(input, other.input),
            output: try sumOpt(output, other.output),
            cacheWrite: try sumOpt(cacheWrite, other.cacheWrite),
            cacheRead: try sumOpt(cacheRead, other.cacheRead))
    }
}

private func sumOpt(_ a: Int64?, _ b: Int64?) throws -> Int64? {
    switch (a, b) {
    case (nil, nil): return nil
    case (let x?, nil): return x
    case (nil, let y?): return y
    case (let x?, let y?):
        let (sum, overflow) = x.addingReportingOverflow(y)
        if overflow || sum > cursorTokenFieldMax {
            throw QuotaError("decode Cursor aggregate usage: token field overflow")
        }
        return sum
    }
}

public struct CursorAggregatePayload: Equatable, Sendable {
    public var models: [String: CursorModelPartial]
    public var accountKey: String?

    public init(models: [String: CursorModelPartial] = [:], accountKey: String? = nil) {
        self.models = models
        self.accountKey = accountKey
    }
}

/// Diffs successive snapshots into live-ring events. The first consume is
/// always a baseline (no events), matching Hermes `isCold`.
public struct CursorAggregateDiffer: Equatable, Sendable {
    public private(set) var baseline: CursorAggregateSnapshot?
    /// True after a consume that adopted a new baseline without emitting
    /// (first poll, or a confirmed billing-cycle / account reset).
    public private(set) var didRebaseline = false
    /// A one-poll decrease is held, not adopted. A second consecutive
    /// decrease confirms rollover; a recovery against the original
    /// baseline emits only the real delta (not the whole window).
    var awaitingDecreaseConfirm = false

    public init(baseline: CursorAggregateSnapshot? = nil) {
        self.baseline = baseline
    }

    /// Resolve omitted counters against the current baseline, then consume.
    public mutating func consume(
        payload: CursorAggregatePayload, nowMs: Int64
    ) -> [UsageEvent] {
        var resolved = CursorAggregateSnapshot(accountKey: payload.accountKey)
        var keys = Set(payload.models.keys)
        if let baseline {
            keys.formUnion(baseline.models.keys)
        }
        for key in keys {
            resolved.models[key] = (payload.models[key] ?? CursorModelPartial())
                .resolved(over: baseline?.models[key])
        }
        return consume(resolved, nowMs: nowMs)
    }

    /// Apply `current` and return events to ingest.
    public mutating func consume(
        _ current: CursorAggregateSnapshot, nowMs: Int64
    ) -> [UsageEvent] {
        didRebaseline = false
        guard let previous = baseline else {
            baseline = current
            didRebaseline = true
            awaitingDecreaseConfirm = false
            return []
        }

        if snapshotDecreased(current, versus: previous) {
            if awaitingDecreaseConfirm {
                baseline = current
                awaitingDecreaseConfirm = false
                didRebaseline = true
                return []
            }
            awaitingDecreaseConfirm = true
            return []
        }
        awaitingDecreaseConfirm = false

        var events: [UsageEvent] = []
        let keys = Set(previous.models.keys).union(current.models.keys)
        for key in keys.sorted() {
            let prev = previous.models[key] ?? CursorModelTotals()
            let next = current.models[key] ?? CursorModelTotals()
            let dIn = next.input - prev.input
            let dOut = next.output - prev.output
            let dCW = next.cacheWrite - prev.cacheWrite
            let dCR = next.cacheRead - prev.cacheRead
            // Skip a delta that cannot be summed or ingested without trapping.
            // Parse already rejects these; this guards constructed snapshots.
            guard dIn <= cursorTokenFieldMax, dOut <= cursorTokenFieldMax,
                  dCW <= cursorTokenFieldMax, dCR <= cursorTokenFieldMax,
                  let delta = cursorCheckedSum(dIn, dOut, dCW, dCR),
                  delta > 0
            else { continue }
            events.append(UsageEvent(
                tsMs: nowMs, client: tailClientCursor, agent: "main",
                model: tailNormalizeModel(key),
                input: dIn, output: dOut, cacheRead: dCR, cacheWrite: dCW))
        }
        baseline = current
        return events
    }
}

func snapshotDecreased(
    _ current: CursorAggregateSnapshot, versus previous: CursorAggregateSnapshot
) -> Bool {
    let keys = Set(previous.models.keys).union(current.models.keys)
    for key in keys {
        let prev = previous.models[key] ?? CursorModelTotals()
        let next = current.models[key] ?? CursorModelTotals()
        if next.decreasing(versus: prev) { return true }
    }
    return false
}

// MARK: - Parse

/// Decode a Connect-JSON GetAggregatedUsageEvents body. Int64 fields may
/// arrive as numbers or strings. Missing counters stay nil (omit-zero);
/// a present field with a bad type or out-of-range number fails the poll
/// so the previous baseline is held.
public func parseCursorAggregateResponse(_ body: Data) throws -> CursorAggregatePayload {
    guard let parsed = JSONValue.parse(body) else {
        throw QuotaError("decode Cursor aggregate usage: invalid JSON")
    }
    return try parseCursorAggregateValue(parsed)
}

func parseCursorAggregateValue(_ parsed: JSONValue) throws -> CursorAggregatePayload {
    let aggregationsNode = parsed["aggregations"]
    let hasTopLevelTotals =
        parsed["totalInputTokens"] != nil
        || parsed["totalOutputTokens"] != nil
        || parsed["totalCacheWriteTokens"] != nil
        || parsed["totalCacheReadTokens"] != nil
    if aggregationsNode == nil || aggregationsNode == .null {
        if !hasTopLevelTotals {
            throw QuotaError("decode Cursor aggregate usage: missing aggregations")
        }
    } else if aggregationsNode?.asArray == nil {
        throw QuotaError("decode Cursor aggregate usage: aggregations is not an array")
    }
    var models: [String: CursorModelPartial] = [:]
    for raw in aggregationsNode?.asArray ?? [] {
        let name = raw["modelIntent"]?.asString ?? raw["model"]?.asString
        let trimmed = name.map(rustTrim) ?? ""
        let partial = try cursorModelPartial(from: raw)
        if trimmed.isEmpty && !partial.hasAnyField {
            throw QuotaError("decode Cursor aggregate usage: empty aggregation row")
        }
        let key = trimmed.isEmpty ? "cursor" : trimmed
        if let existing = models[key] {
            models[key] = try existing.merging(partial)
        } else {
            models[key] = partial
        }
    }
    if models.isEmpty {
        let partial = try cursorModelPartial(
            input: parsed["totalInputTokens"],
            output: parsed["totalOutputTokens"],
            cacheWrite: parsed["totalCacheWriteTokens"],
            cacheRead: parsed["totalCacheReadTokens"])
        if partial.hasAnyField {
            models["cursor"] = partial
        }
    }
    return CursorAggregatePayload(models: models)
}

private func cursorModelPartial(from raw: JSONValue) throws -> CursorModelPartial {
    try cursorModelPartial(
        input: raw["inputTokens"],
        output: raw["outputTokens"],
        cacheWrite: raw["cacheWriteTokens"],
        cacheRead: raw["cacheReadTokens"])
}

private func cursorModelPartial(
    input: JSONValue?, output: JSONValue?,
    cacheWrite: JSONValue?, cacheRead: JSONValue?
) throws -> CursorModelPartial {
    CursorModelPartial(
        input: try cursorOptionalInt64(input),
        output: try cursorOptionalInt64(output),
        cacheWrite: try cursorOptionalInt64(cacheWrite),
        cacheRead: try cursorOptionalInt64(cacheRead))
}

/// Absent key → nil. Present but unusable → throw (do not coerce to 0).
/// Rejects negatives (including u64 bit-pattern wraps) and values above
/// `cursorTokenFieldMax` so later `+` cannot trap.
func cursorOptionalInt64(_ value: JSONValue?) throws -> Int64? {
    guard let value else { return nil }
    switch value {
    case .null:
        throw QuotaError("decode Cursor aggregate usage: null token field")
    case .int(let i):
        return try cursorAcceptTokenCount(i)
    case .double(let d):
        return try cursorAcceptTokenCount(fromDouble: d)
    case .string(let s):
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let i = Int64(trimmed) { return try cursorAcceptTokenCount(i) }
        if let d = Double(trimmed) { return try cursorAcceptTokenCount(fromDouble: d) }
        throw QuotaError("decode Cursor aggregate usage: invalid token string")
    default:
        throw QuotaError("decode Cursor aggregate usage: token field has wrong type")
    }
}

private func cursorAcceptTokenCount(_ i: Int64) throws -> Int64 {
    guard i >= 0, i <= cursorTokenFieldMax else {
        throw QuotaError("decode Cursor aggregate usage: token field out of range")
    }
    return i
}

private func cursorAcceptTokenCount(fromDouble d: Double) throws -> Int64 {
    guard d.isFinite else {
        throw QuotaError("decode Cursor aggregate usage: non-finite token field")
    }
    if d < 0 || d > Double(cursorTokenFieldMax) {
        throw QuotaError("decode Cursor aggregate usage: token field out of range")
    }
    return Int64(d)
}

private func cursorCheckedSum(_ values: Int64...) -> Int64? {
    var acc: Int64 = 0
    for value in values {
        let (next, overflow) = acc.addingReportingOverflow(value)
        if overflow { return nil }
        acc = next
    }
    return acc
}

import Foundation

// Port of src-tauri/src/usage_tail.rs — the incremental live-rate tailer.
//
// Incremental source of truth for the animation/rate signal. Tracks
// (file, offset, mtime), re-reads only growth, and dedups streaming retries
// by msgId:reqId with per-field max.
//
// Claude Code:  ~/.claude/projects/**/*.jsonl
// Codex CLI:    ~/.codex/sessions/**/*.jsonl (+ the extra Codex homes the
//               graph parser scans — Orca runtime homes, TOKCAT_CODEX_HOMES)
// Hermes:       ~/.hermes/state.db (SQLite aggregates, diffed per tick)
// Grok Build:   $GROK_HOME/sessions/**/updates.jsonl
// oh-my-pi:     ~/.omp/agent/sessions/**/*.jsonl (subagent transcripts are
//               nested one level deeper, inside the parent session's dir)

let tailClientClaude = "claude-code"
let tailClientCodex = "codex-cli"
let tailClientHermes = "hermes"
let tailClientGrok = "grok"
let tailClientOmp = "omp"
let eventWindowSecs: Int64 = 3600  // EVENT_WINDOW_SECS (:26)
let coldScanLookbackSecs: Int64 = 6 * 3600  // COLD_SCAN_LOOKBACK_SECS (:27)
/// A file touched this recently is re-stat'd on every tick even when its
/// directory is pruned from the walk (see `tick`).
let activeFileWindowSecs: Int64 = 600
/// How often the walk ignores directory-mtime pruning and visits everything.
public let defaultFullScanIntervalMs: Int64 = 60_000

enum TailClientKind: Equatable, Sendable {
    case claude
    case codex
    case grok
    case omp
}

/// One usage delta in the live event ring (usage_tail.rs:36-52).
public struct UsageEvent: Codable, Equatable, Sendable {
    public var tsMs: Int64
    public var client: String
    public var agent: String
    public var model: String
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64

    enum CodingKeys: String, CodingKey {
        case tsMs = "ts_ms"
        case client, agent, model, input, output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
    }

    var total: Int64 { input + output + cacheRead + cacheWrite }
}

/// Per-(client, agent, model) rollup over a trailing window
/// (usage_tail.rs:54-62, surfaced by state.rs `usage_trace`).
public struct TraceBucket: Codable, Equatable, Sendable {
    public var client: String
    public var agent: String
    public var model: String
    public var tokens: Int64
    public var messages: Int
    public var tokensPerMin: Double

    enum CodingKeys: String, CodingKey {
        case client, agent, model, tokens, messages
        case tokensPerMin = "tokens_per_min"
    }

    public init(client: String, agent: String, model: String,
                tokens: Int64, messages: Int, tokensPerMin: Double) {
        self.client = client
        self.agent = agent
        self.model = model
        self.tokens = tokens
        self.messages = messages
        self.tokensPerMin = tokensPerMin
    }
}

/// Per-file tail state (usage_tail.rs:64-91).
struct TailFileState {
    var offset: UInt64
    var mtimeMs: Int64
    // Codex's token_count events carry no model field; the most recent
    // `turn_context` line in the same file does. Threaded through file
    // state so a tick that lands mid-file still attributes correctly.
    var codexModel: String?
    // Grok's updates.jsonl carries a cumulative totalTokens counter and
    // occasional modelId tags; keep the high-water total and last model.
    var grokLastTotal: Int64?
    var grokModel: String?

    static func atEOF(size: UInt64, mtimeMs: Int64) -> TailFileState {
        TailFileState(offset: size, mtimeMs: mtimeMs,
                      codexModel: nil, grokLastTotal: nil, grokModel: nil)
    }
}

/// Per-session token totals last observed for a Hermes session row
/// (usage_tail.rs:93-102). Hermes stores aggregates that grow in place,
/// so there is no natural offset — we diff totals instead.
struct HermesTailSnapshot: Equatable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
}

/// Construction knobs for the tailer. The default configuration reads the
/// live environment; `simulatedHome` re-roots every source under one
/// directory (DIR/.claude/projects, DIR/.codex/sessions, DIR/.grok/sessions,
/// DIR/.hermes/state.db) for deterministic replays, and `nowMs` injects a
/// fixed clock so window math is reproducible.
public struct UsageTailerConfig: Sendable {
    public var simulatedHome: String?
    public var nowMs: (@Sendable () -> Int64)?
    /// Interval between unpruned walks. `0` makes every tick a full walk,
    /// which is what the pre-pruning tailer did.
    public var fullScanIntervalMs: Int64

    public init(simulatedHome: String? = nil, nowMs: (@Sendable () -> Int64)? = nil,
                fullScanIntervalMs: Int64 = defaultFullScanIntervalMs) {
        self.simulatedHome = simulatedHome
        self.nowMs = nowMs
        self.fullScanIntervalMs = fullScanIntervalMs
    }
}

public actor UsageTailer {
    var files: [String: TailFileState] = [:]  // internal for tests
    private(set) var events: [UsageEvent] = []
    private(set) var seen: [String: Int] = [:]
    private var cold = true
    private var hermesSnapshots: [String: HermesTailSnapshot] = [:]
    /// Last mtime seen for each directory, keyed by path — the walk's pruning
    /// signal. Nanoseconds, so two changes inside one millisecond can't cancel
    /// out into "unchanged".
    private var dirMtimes: [String: Int64] = [:]
    /// Files recently written to, re-stat'd every tick regardless of pruning.
    var activeFiles: [String: TailClientKind] = [:]  // internal for tests
    private var lastFullScanMs: Int64 = 0
    private let config: UsageTailerConfig

    public init(config: UsageTailerConfig = UsageTailerConfig()) {
        self.config = config
    }

    func now() -> Int64 {
        config.nowMs?() ?? nowMs()
    }

    // MARK: - Tick (usage_tail.rs:123-210)

    /// Scan all roots for growth, appending events. Returns events added.
    ///
    /// Two tiers, because walking every session root on the machine every 5
    /// seconds was the app's dominant energy cost:
    ///
    ///   - Every tick prunes the walk by directory mtime. A directory's mtime
    ///     moves when an entry is created, removed or renamed inside it, and
    ///     never when a file it already holds simply grows — so an unchanged
    ///     mtime proves there are no NEW session files below, and the walk can
    ///     skip that subtree. New files are still picked up within one tick.
    ///   - Growth of files we already know about is covered by re-stat'ing the
    ///     active set (anything touched in the last `activeFileWindowSecs`),
    ///     which is a handful of files rather than thousands.
    ///
    /// The one case neither tier catches is a dormant file that starts growing
    /// again — a resumed session idle for more than the active window. The
    /// unpruned walk every `fullScanIntervalMs` is the backstop for it: the
    /// growth is delayed, never lost, since `readGrowth` resumes from the
    /// stored offset.
    @discardableResult
    public func tick() -> Int {
        var added = 0
        let isCold = cold
        cold = false
        let nowMs = now()
        let coldCutoffMs = nowMs - coldScanLookbackSecs * 1000

        added += tickHermes(isCold: isCold)

        let isFullScan = isCold || nowMs - lastFullScanMs >= config.fullScanIntervalMs
        if isFullScan { lastFullScanMs = nowMs }
        // Only needed to keep the active pass from re-reading a file the walk
        // already handled, and the walk touches few files when it is pruned.
        var walked: Set<String> = []

        for (root, client) in tailRoots() {
            var stack = [root]
            while let dir = stack.popLast() {
                // One getattrlistbulk pass per directory instead of a
                // listing plus an lstat per entry. Symlinks are still
                // described as themselves, matching Rust's
                // DirEntry::file_type / DirEntry::metadata.
                for entry in scanDirectory(dir) {
                    if entry.isDir {
                        let subdir = joinPath(dir, entry.name)
                        if isFullScan || dirMtimes[subdir] != entry.mtimeNs {
                            stack.append(subdir)
                        }
                        dirMtimes[subdir] = entry.mtimeNs
                        continue
                    }
                    guard entry.isRegular else { continue }
                    // Filter on the bare name before building the full path:
                    // rustExtension/rustFileName each split the whole path
                    // into an array of components, and almost every entry
                    // here is discarded.
                    guard hasJSONLExtension(entry.name) else { continue }
                    // Grok session dirs also contain events.jsonl /
                    // chat_history.jsonl; only updates.jsonl carries
                    // cumulative totalTokens for the live rate signal.
                    if client == .grok, entry.name != "updates.jsonl" {
                        continue
                    }
                    let path = joinPath(dir, entry.name)
                    if !isFullScan { walked.insert(path) }
                    added += processFile(
                        path: path, client: client, size: entry.size,
                        mtimeMs: entry.mtimeMs, isCold: isCold,
                        coldCutoffMs: coldCutoffMs, nowMs: nowMs)
                }
            }
        }

        if !isFullScan {
            // Iterating the dictionary copies it, so processFile is free to
            // add and drop entries as it goes.
            for (path, client) in activeFiles where !walked.contains(path) {
                var sb = stat()
                guard lstat(path, &sb) == 0, (sb.st_mode & S_IFMT) == S_IFREG else {
                    // Deleted or replaced by a non-file; the next full scan
                    // rediscovers it if it comes back.
                    activeFiles[path] = nil
                    continue
                }
                added += processFile(
                    path: path, client: client, size: UInt64(max(sb.st_size, 0)),
                    mtimeMs: statMtimeMs(sb), isCold: false,
                    coldCutoffMs: coldCutoffMs, nowMs: nowMs)
            }
        }

        trimEvents()
        return added
    }

    /// Fold one observed (size, mtime) into the tail state, reading whatever
    /// the file grew by. Shared between the walk and the active-file pass.
    private func processFile(
        path: String, client: TailClientKind, size: UInt64, mtimeMs: Int64,
        isCold: Bool, coldCutoffMs: Int64, nowMs: Int64
    ) -> Int {
        if nowMs - mtimeMs <= activeFileWindowSecs * 1000 {
            activeFiles[path] = client
        } else {
            activeFiles[path] = nil
        }

        let prev = files[path].map { ($0.offset, $0.mtimeMs) }

        if isCold, prev == nil, mtimeMs < coldCutoffMs {
            // Cold scan: stamp old files at EOF without reading
            // (usage_tail.rs:175-179).
            files[path] = .atEOF(size: size, mtimeMs: mtimeMs)
            return 0
        }

        let startOffset = prev?.0 ?? 0
        if size == startOffset {
            // Preserve codex/grok thread state when only mtime refreshes
            // without growth (:183-193). The offset already equals `size`
            // here, so an unchanged mtime means there is nothing to write
            // back — and skipping the write matters: this is the branch every
            // dormant session file takes on every tick.
            if let existing = files[path] {
                if existing.mtimeMs != mtimeMs {
                    files[path]!.mtimeMs = mtimeMs
                }
            } else {
                files[path] = .atEOF(size: size, mtimeMs: mtimeMs)
            }
            return 0
        }
        if size < startOffset {
            // Truncated / rotated log — drop threaded counters so we
            // re-baseline instead of treating a new smaller total as a
            // negative delta (:196-200).
            files[path] = nil
            return readGrowth(path: path, client: client,
                              start: 0, end: size, mtimeMs: mtimeMs)
        }
        return readGrowth(path: path, client: client,
                          start: startOffset, end: size, mtimeMs: mtimeMs)
    }

    // MARK: - Growth reads (usage_tail.rs:212-294)

    func readGrowth(path: String, client: TailClientKind,
                    start: UInt64, end: UInt64, mtimeMs: Int64) -> Int {
        var added = 0
        guard let file = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? file.close() }
        guard (try? file.seek(toOffset: start)) != nil else { return 0 }
        let toRead = Int(end >= start ? end - start : 0)
        guard let buf = try? file.read(upToCount: toRead) ?? Data() else { return 0 }

        // Lift per-file threaded state; write it back when we're done.
        var codexModel = files[path]?.codexModel
        var grokLastTotal = files[path]?.grokLastTotal
        var grokModel = files[path]?.grokModel

        var consumed: UInt64 = 0
        for chunk in splitInclusiveNewline(buf) {
            let hasTerminator = chunk.last == UInt8(ascii: "\n")
            let line = hasTerminator ? chunk.dropLast() : chunk
            let trimmed = trimAsciiBytes(line)
            if trimmed.isEmpty {
                consumed += UInt64(chunk.count)
                continue
            }
            // Unterminated final line is kept for the next tick ONLY if it
            // does not parse as complete JSON (:259-261).
            if !hasTerminator, JSONValue.parse(Data(trimmed)) == nil {
                break
            }
            // Full-file reads (start==0) treat the first totalTokens as a
            // real delta so brand-new sessions contribute to the live rate.
            // Mid-file attaches keep first observation as baseline only.
            let grokEmitFirst = start == 0
            let recorded: Bool
            switch client {
            case .claude:
                recorded = parseClaudeLine(path: path, raw: trimmed)
            case .codex:
                recorded = parseCodexLine(raw: trimmed, codexModel: &codexModel)
            case .grok:
                recorded = parseGrokLine(raw: trimmed, lastTotal: &grokLastTotal,
                                         currentModel: &grokModel,
                                         emitFirstAsDelta: grokEmitFirst)
            case .omp:
                recorded = parseOmpLine(path: path, raw: trimmed)
            }
            if recorded { added += 1 }
            consumed += UInt64(chunk.count)
        }

        files[path] = TailFileState(
            offset: start + consumed, mtimeMs: mtimeMs,
            codexModel: codexModel, grokLastTotal: grokLastTotal, grokModel: grokModel)
        return added
    }

    // MARK: - Claude lines (usage_tail.rs:296-383)

    private func parseClaudeLine(path: String, raw: [UInt8]) -> Bool {
        guard let value = JSONValue.parse(Data(raw)) else { return false }
        guard value["type"]?.asString ?? "" == "assistant" else { return false }
        guard let message = value["message"] else { return false }
        guard let usage = message["usage"] else { return false }

        let input = strictI64(usage["input_tokens"]) ?? 0
        let output = strictI64(usage["output_tokens"]) ?? 0
        let cacheRead = strictI64(usage["cache_read_input_tokens"]) ?? 0
        let cacheWrite = strictI64(usage["cache_creation_input_tokens"]) ?? 0
        if input + output + cacheRead + cacheWrite <= 0 { return false }

        let model = tailNormalizeModel(message["model"]?.asString ?? "unknown")
        let tsMs = value["timestamp"]?.asString.flatMap(rfc3339ToTimestampMs) ?? now()

        let isSidechain = strictBool(value["isSidechain"]) ?? false
        let agentId = value["agentId"]?.asString

        let agent: String
        if isSidechain {
            if let id = agentId, !id.isEmpty {
                agent = "subagent:\(id)"
            } else {
                agent = sidechainLabelFromPath(path)
            }
        } else {
            agent = "main"
        }

        let msgId = message["id"]?.asString ?? ""
        let reqId = value["requestId"]?.asString ?? ""
        let dedupKey = msgId.isEmpty ? "" : "claude:\(msgId):\(reqId)"

        return pushEvent(
            UsageEvent(tsMs: tsMs, client: tailClientClaude, agent: agent, model: model,
                       input: input, output: output,
                       cacheRead: cacheRead, cacheWrite: cacheWrite),
            dedupKey: dedupKey)
    }

    // MARK: - Codex lines (usage_tail.rs:385-472)

    private func parseCodexLine(raw: [UInt8], codexModel: inout String?) -> Bool {
        guard let value = JSONValue.parse(Data(raw)) else { return false }
        let entryType = value["type"]?.asString ?? ""
        let payload = value["payload"]

        if entryType == "turn_context" {
            if let model = payload?["model"]?.asString {
                codexModel = model
            }
            return false
        }

        guard entryType == "event_msg", let payload else { return false }
        guard payload["type"]?.asString ?? "" == "token_count" else { return false }

        // Use last_token_usage (delta for this turn), not total_token_usage
        // (running counter — would inflate the rate every event). This is
        // deliberately NOT the graph parser's running-total state machine.
        guard let usage = payload["info"]?["last_token_usage"] else { return false }

        let rawInput = strictI64(usage["input_tokens"]) ?? 0
        let output = strictI64(usage["output_tokens"]) ?? 0
        // Codex reports cached input under cached_input_tokens; this is a
        // subset of input_tokens (not additive). Surface it as cache_read
        // for consistency with Claude's split, and subtract from input so
        // the bucket totals don't double-count.
        let cacheRead = strictI64(usage["cached_input_tokens"]) ?? 0
        let input = max(rawInput - cacheRead, 0)

        if input + output + cacheRead <= 0 { return false }

        let model = codexModel.map(tailNormalizeModel) ?? "unknown"
        let tsMs = value["timestamp"]?.asString.flatMap(rfc3339ToTimestampMs) ?? now()

        return pushEvent(
            UsageEvent(tsMs: tsMs, client: tailClientCodex, agent: "main", model: model,
                       input: input, output: output, cacheRead: cacheRead, cacheWrite: 0),
            dedupKey: "")
    }

    // MARK: - Grok lines (usage_tail.rs:474-541)

    /// Grok Build updates.jsonl: cumulative `totalTokens` with no input/
    /// output split. Emit positive deltas as input tokens.
    ///
    /// `emitFirstAsDelta`: when true (full-file read from offset 0), the
    /// first observed total is treated as a delta from 0 so brand-new
    /// sessions contribute. When false (mid-file attach after EOF baseline),
    /// the first total only seeds state.
    ///
    /// Decreasing totals (stream rewinds) are ignored without lowering the
    /// high-water `lastTotal`, so recovering values are not double-counted.
    private func parseGrokLine(raw: [UInt8], lastTotal: inout Int64?,
                               currentModel: inout String?,
                               emitFirstAsDelta: Bool) -> Bool {
        guard let value = JSONValue.parse(Data(raw)) else { return false }

        if let model = tailExtractGrokModelId(value) {
            currentModel = tailNormalizeModel(model)
        }

        guard let total = tailExtractGrokTotalTokens(value), total >= 0 else { return false }

        let previous: Int64
        if let prev = lastTotal {
            previous = prev
        } else if emitFirstAsDelta {
            previous = 0
        } else {
            lastTotal = total
            return false
        }
        if total <= previous { return false }
        let delta = total - previous
        lastTotal = total

        let tsMs = tailExtractGrokTimestampMs(value) ?? now()
        let model = currentModel ?? "unknown"

        return pushEvent(
            UsageEvent(tsMs: tsMs, client: tailClientGrok, agent: "main", model: model,
                       input: delta, output: 0, cacheRead: 0, cacheWrite: 0),
            dedupKey: "")
    }

    // MARK: - oh-my-pi lines

    /// omp session entries (omp://session.md). Every assistant `message`
    /// carries the usage of exactly one API response — per-call values, not a
    /// running total — so each line is emitted as-is with no threaded state.
    private func parseOmpLine(path: String, raw: [UInt8]) -> Bool {
        guard let value = JSONValue.parse(Data(raw)) else { return false }
        guard value["type"]?.asString == "message" else { return false }
        guard let message = value["message"] else { return false }
        guard message["role"]?.asString == "assistant" else { return false }
        guard let usage = message["usage"] else { return false }

        let input = strictI64(usage["input"]) ?? 0
        let output = strictI64(usage["output"]) ?? 0
        let cacheRead = strictI64(usage["cacheRead"]) ?? 0
        let cacheWrite = strictI64(usage["cacheWrite"]) ?? 0
        if input + output + cacheRead + cacheWrite <= 0 { return false }

        let model = tailNormalizeModel(message["model"]?.asString ?? "unknown")
        // Spelled out rather than chained through `map`/`??`: the autoclosure
        // operands captured `value` alongside the actor-isolated `now()`, which
        // the Release-configuration concurrency checker rejects as a send.
        let tsMs: Int64
        if let epochMs = strictI64(message["timestamp"]) {
            tsMs = normalizeEpochMs(epochMs)
        } else if let iso = value["timestamp"]?.asString,
            let parsed = rfc3339ToTimestampMs(iso)
        {
            tsMs = parsed
        } else {
            tsMs = now()
        }
        let responseId = message["responseId"]?.asString ?? ""

        return pushEvent(
            UsageEvent(tsMs: tsMs, client: tailClientOmp, agent: ompTailAgent(path),
                       model: model, input: input, output: output,
                       cacheRead: cacheRead, cacheWrite: cacheWrite),
            dedupKey: responseId.isEmpty ? "" : "omp:\(responseId)")
    }

    // MARK: - Hermes (usage_tail.rs:543-634)

    /// Open the Hermes state DB and diff against the previous snapshot to
    /// derive per-session deltas. A cold tick stamps current totals as the
    /// baseline silently so historical activity is not counted as a burst.
    private func tickHermes(isCold: Bool) -> Int {
        guard let path = tailHermesDBPath() else { return 0 }
        guard let db = SQLiteDatabase(readOnlyAtPath: path) else { return 0 }
        guard let stmt = db.prepare("""
            SELECT id, model,
                COALESCE(input_tokens, 0),
                COALESCE(output_tokens, 0),
                COALESCE(cache_read_tokens, 0),
                COALESCE(cache_write_tokens, 0)
            FROM sessions
            WHERE model IS NOT NULL AND TRIM(model) != ''
            """)
        else { return 0 }

        var added = 0
        let tsMs = now()
        while stmt.step() {
            // rusqlite's rows.flatten() skips rows whose column types don't
            // match and keeps iterating.
            guard let sessionId = stmt.text(0),
                  let model = stmt.text(1),
                  let input = stmt.i64(2),
                  let output = stmt.i64(3),
                  let cacheRead = stmt.i64(4),
                  let cacheWrite = stmt.i64(5)
            else { continue }
            let prev = hermesSnapshots[sessionId] ?? HermesTailSnapshot()
            hermesSnapshots[sessionId] = HermesTailSnapshot(
                input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
            if isCold { continue }
            let dInput = max(input - prev.input, 0)
            let dOutput = max(output - prev.output, 0)
            let dCacheRead = max(cacheRead - prev.cacheRead, 0)
            let dCacheWrite = max(cacheWrite - prev.cacheWrite, 0)
            if dInput + dOutput + dCacheRead + dCacheWrite <= 0 { continue }
            let event = UsageEvent(
                tsMs: tsMs, client: tailClientHermes, agent: "main",
                model: tailNormalizeModel(model),
                input: dInput, output: dOutput,
                cacheRead: dCacheRead, cacheWrite: dCacheWrite)
            if pushEvent(event, dedupKey: "") { added += 1 }
        }
        return added
    }

    // MARK: - Event ring (usage_tail.rs:636-670)

    /// Append an event, deduplicating against `dedupKey` (use `""` to skip
    /// dedup). A dedup hit merges per-field max into the existing event.
    private func pushEvent(_ event: UsageEvent, dedupKey: String) -> Bool {
        if !dedupKey.isEmpty, let idx = seen[dedupKey], events.indices.contains(idx) {
            events[idx].input = max(events[idx].input, event.input)
            events[idx].output = max(events[idx].output, event.output)
            events[idx].cacheRead = max(events[idx].cacheRead, event.cacheRead)
            events[idx].cacheWrite = max(events[idx].cacheWrite, event.cacheWrite)
            return false
        }
        let idx = events.count
        events.append(event)
        if !dedupKey.isEmpty {
            seen[dedupKey] = idx
        }
        return true
    }

    private func trimEvents() {
        let cutoff = now() - eventWindowSecs * 1000
        let before = events.count
        events.removeAll { $0.tsMs < cutoff }
        if events.count == before { return }
        // Indices into `events` shifted; the whole index map is stale.
        seen.removeAll()
    }

    // MARK: - Rates & trace (usage_tail.rs:672-725)

    /// 60s window total — the animation signal.
    public func ratePerMin() -> Double {
        // Rust returns `window_total(60) as f32`; round-trip through Float
        // so the value matches bit-for-bit in dumps.
        Double(Float(windowTotal(60)))
    }

    /// Tokens/min over an arbitrary trailing window (600s for tray/trace).
    public func rateInWindow(_ windowSecs: Int64) -> Double {
        if windowSecs <= 0 { return 0.0 }
        let total = Float(windowTotal(windowSecs))
        let windowMin = Float(windowSecs) / 60.0
        return Double(total / windowMin)
    }

    private func windowTotal(_ secs: Int64) -> Int64 {
        let cutoff = now() - secs * 1000
        return events.lazy.filter { $0.tsMs >= cutoff }.map(\.total).reduce(0, +)
    }

    /// Per-(client, agent, model) breakdown over `windowSecs`. The caller
    /// (UI layer) decides whether to collapse rows by client based on the
    /// user's "detailed trace" setting — see TraceCollapse.collapseByClient.
    public func trace(windowSecs: Int64) -> [TraceBucket] {
        let cutoff = now() - windowSecs * 1000
        struct Key: Hashable { let client, agent, model: String }
        var groups: [Key: (tokens: Int64, messages: Int)] = [:]
        for e in events where e.tsMs >= cutoff {
            let key = Key(client: e.client, agent: e.agent, model: e.model)
            var slot = groups[key] ?? (0, 0)
            slot.tokens += e.total
            slot.messages += 1
            groups[key] = slot
        }
        let windowMin = max(Float(windowSecs) / 60.0, 1.0 / 60.0)
        var out = groups.map { key, slot in
            TraceBucket(client: key.client, agent: key.agent, model: key.model,
                        tokens: slot.tokens, messages: slot.messages,
                        tokensPerMin: Double(Float(slot.tokens) / windowMin))
        }
        out.sort { $0.tokens > $1.tokens }
        return out
    }

    /// Snapshot of the raw event ring (for the tail-sim/tail-live dumps).
    public func eventsSnapshot() -> [UsageEvent] {
        events
    }

    // MARK: - Roots (usage_tail.rs:728-773)

    func tailRoots() -> [(String, TailClientKind)] {
        var out: [(String, TailClientKind)] = []
        if let sim = config.simulatedHome {
            let claude = joinPath(joinPath(sim, ".claude"), "projects")
            if isDirectory(claude) { out.append((claude, .claude)) }
            let codex = joinPath(joinPath(sim, ".codex"), "sessions")
            if isDirectory(codex) { out.append((codex, .codex)) }
            let grok = joinPath(joinPath(sim, ".grok"), "sessions")
            if isDirectory(grok) { out.append((grok, .grok)) }
            let omp = joinPath(joinPath(joinPath(sim, ".omp"), "agent"), "sessions")
            if isDirectory(omp) { out.append((omp, .omp)) }
            return out
        }

        let env = ProcessInfo.processInfo.environment
        if let home = homeDir() {
            let claude = joinPath(joinPath(home, ".claude"), "projects")
            if isDirectory(claude) { out.append((claude, .claude)) }
            // Codex: primary home plus the same extra homes CodexParser
            // scans (Orca redirects CODEX_HOME to its runtime homes).
            var codexHomes = [env["CODEX_HOME"] ?? joinPath(home, ".codex")]
            codexHomes.append(contentsOf: orcaCodexHomes(home))
            if let extra = env["TOKCAT_CODEX_HOMES"] {
                codexHomes.append(
                    contentsOf: extra.split(separator: ":", omittingEmptySubsequences: false)
                        .map(String.init))
            }
            var seenRoots = Set<String>()
            for codexHome in codexHomes {
                let sessions = joinPath(codexHome, "sessions")
                guard seenRoots.insert(sessions).inserted else { continue }
                if isDirectory(sessions) { out.append((sessions, .codex)) }
            }
        }
        if let grok = tailGrokSessionsRoot() {
            out.append((grok, .grok))
        }
        // oh-my-pi: the same agent dirs the graph parser scans.
        var seenOmpRoots = Set<String>()
        for root in ompSessionRoots() {
            guard seenOmpRoots.insert(root).inserted else { continue }
            if isDirectory(root) { out.append((root, .omp)) }
        }
        return out
    }

    private func tailHermesDBPath() -> String? {
        if let sim = config.simulatedHome {
            let p = joinPath(joinPath(sim, ".hermes"), "state.db")
            return isFile(p) ? p : nil
        }
        if let hermesHome = ProcessInfo.processInfo.environment["HERMES_HOME"] {
            let p = joinPath(hermesHome, "state.db")
            if isFile(p) { return p }
        }
        guard let home = homeDir() else { return nil }
        let p = joinPath(joinPath(home, ".hermes"), "state.db")
        return isFile(p) ? p : nil
    }
}

private func tailGrokSessionsRoot() -> String? {
    if let grokHome = ProcessInfo.processInfo.environment["GROK_HOME"] {
        let p = joinPath(grokHome, "sessions")
        if isDirectory(p) { return p }
    }
    guard let home = homeDir() else { return nil }
    let p = joinPath(joinPath(home, ".grok"), "sessions")
    return isDirectory(p) ? p : nil
}

/// omp subagent transcripts live inside their parent session's directory and
/// are named after the agent (`<session-id>/Scout.jsonl`); the main
/// transcript is the sibling `<session-id>.jsonl`.
func ompTailAgent(_ path: String) -> String {
    let parent = (path as NSString).deletingLastPathComponent
    guard let bucket = rustFileName(parent), ompIsSessionDirName(bucket) else { return "main" }
    return "subagent:\(rustFileStem(path) ?? "unknown")"
}

// MARK: - Grok extractors (usage_tail.rs:775-836)

private let grokModelPaths: [[String]] = [
    ["params", "update", "content", "_meta", "modelId"],
    ["params", "update", "_meta", "modelId"],
    ["params", "_meta", "modelId"],
    ["params", "modelId"],
    ["modelId"],
    ["model"],
]

func tailExtractGrokModelId(_ value: JSONValue) -> String? {
    for path in grokModelPaths {
        if let model = jsonPath(value, path)?.asString,
           !rustTrim(model).isEmpty {
            return model
        }
    }
    return nil
}

private let grokTotalPaths: [[String]] = [
    ["params", "_meta", "totalTokens"],
    ["params", "update", "_meta", "totalTokens"],
    ["params", "update", "totalTokens"],
    ["params", "totalTokens"],
    ["totalTokens"],
]

func tailExtractGrokTotalTokens(_ value: JSONValue) -> Int64? {
    for path in grokTotalPaths {
        if let total = strictI64(jsonPath(value, path)) {
            return total
        }
    }
    return nil
}

private let grokTimestampPaths: [[String]] = [
    ["params", "_meta", "agentTimestampMs"],
    ["params", "update", "_meta", "agentTimestampMs"],
    ["timestamp"],
    ["ts"],
]

func tailExtractGrokTimestampMs(_ value: JSONValue) -> Int64? {
    for path in grokTimestampPaths {
        guard let node = jsonPath(value, path) else { continue }
        if let i = strictI64(node) {
            return normalizeEpochMs(i)
        }
        if let s = node.asString {
            if let ms = rfc3339ToTimestampMs(s) { return ms }
            if let i = Int64(s) { return normalizeEpochMs(i) }
        }
    }
    return nil
}

// jsonPath is shared with GrokParser.swift (identical try_fold port).

// MARK: - Line & value helpers

/// serde_json `Value::as_i64`: integers only, no coercion.
func strictI64(_ value: JSONValue?) -> Int64? {
    if case .int(let i)? = value { return i }
    return nil
}

/// serde_json `Value::as_bool`: booleans only.
func strictBool(_ value: JSONValue?) -> Bool? {
    if case .bool(let b)? = value { return b }
    return nil
}

/// `split_inclusive(|&b| b == b'\n')`: chunks keep their trailing newline;
/// a trailing chunk without one is still yielded.
func splitInclusiveNewline(_ data: Data) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var current: [UInt8] = []
    for b in data {
        current.append(b)
        if b == UInt8(ascii: "\n") {
            out.append(current)
            current = []
        }
    }
    if !current.isEmpty { out.append(current) }
    return out
}

/// Rust's `trim_ascii` port (usage_tail.rs:865-880).
func trimAsciiBytes<C: Collection>(_ bytes: C) -> [UInt8] where C.Element == UInt8 {
    func isWS(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0c || b == 0x0d
    }
    var arr = Array(bytes)
    while let f = arr.first, isWS(f) { arr.removeFirst() }
    while let l = arr.last, isWS(l) { arr.removeLast() }
    return arr
}

/// The TAIL's normalize_model (usage_tail.rs:882-891): lowercase, strip one
/// trailing `-YYYYMMDD` (dash + exactly 8 ASCII digits). This is DIFFERENT
/// from the graph parser's normalize — do not unify.
func tailNormalizeModel(_ id: String) -> String {
    var bytes = Array(id.lowercased().utf8)
    if bytes.count > 9 {
        let tail = bytes[(bytes.count - 8)...]
        if tail.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
           bytes[bytes.count - 9] == UInt8(ascii: "-") {
            bytes.removeLast(9)
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// usage_tail.rs:893-903 — sidechain files without agentId are labeled by
/// their file stem, stripping the `agent-` prefix.
func sidechainLabelFromPath(_ path: String) -> String {
    let stem = rustFileStem(path) ?? "subagent"
    if stem.hasPrefix("agent-") {
        return "subagent:\(String(stem.dropFirst("agent-".count)))"
    }
    return "subagent:\(stem)"
}

private func statMtimeMs(_ sb: stat) -> Int64 {
    // system_time_to_ms returns 0 for pre-epoch/errored mtimes.
    let sec = Int64(sb.st_mtimespec.tv_sec)
    let nsec = Int64(sb.st_mtimespec.tv_nsec)
    if sec < 0 { return 0 }
    return sec * 1000 + nsec / 1_000_000
}

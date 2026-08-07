import Foundation
import SQLite3
import Testing

@testable import Collector

// Ports of the Rust usage_tail unit tests (usage_tail.rs:905-1070) plus
// coverage for the tail-only behaviors called out in the port spec:
// codex last_token_usage handling, dedup per-field max merge, sidechain
// attribution, the tail's normalize_model, cold scan and shrink handling.

private func tailTempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "tokcat-tail-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(nowMs())-\(UInt32.random(in: 0..<UInt32.max))"
        )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func tailTempFile(_ name: String) -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "tokcat-usage-tail-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(nowMs()).jsonl"
        ).path
}

private func rfc3339Now() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: Date())
}

private func claudeAssistantLine(_ messageId: String, _ requestId: String) -> String {
    """
    {"type":"assistant","timestamp":"\(rfc3339Now())","requestId":"\(requestId)","message":{"id":"\(messageId)","model":"claude-sonnet-4-20250514","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":3,"cache_creation_input_tokens":2}}}
    """
}

private func grokLine(_ total: Int64, _ model: String?, _ tsMs: Int64) -> String {
    let modelMeta = model.map {
        #","content":{"type":"text","_meta":{"modelId":"\#($0)"}}"#
    } ?? ""
    return """
    {"method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk"\(modelMeta)},"_meta":{"totalTokens":\(total),"agentTimestampMs":\(tsMs)}}}
    """
}

@Suite struct TailUsageTailerTests {
    // Port of claude_tail_counts_final_line_without_newline (:927-947).
    @Test func claudeTailCountsFinalLineWithoutNewline() async throws {
        let path = tailTempFile("no-newline")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try claudeAssistantLine("msg_no_newline", "req_no_newline")
            .write(toFile: path, atomically: true, encoding: .utf8)

        let tailer = UsageTailer()
        let size = UInt64(try FileManager.default
            .attributesOfItem(atPath: path)[.size] as! Int)
        let added = await tailer.readGrowth(
            path: path, client: .claude, start: 0, end: size, mtimeMs: nowMs())

        #expect(added == 1)
        let trace = await tailer.trace(windowSecs: 3600)
        #expect(trace.count == 1)
        #expect(trace[0].client == "claude-code")
        #expect(trace[0].agent == "main")
        #expect(trace[0].model == "claude-sonnet-4")
        #expect(trace[0].tokens == 20)
        #expect(trace[0].messages == 1)
    }

    // Port of tail_keeps_partial_final_line_for_next_tick (:949-971).
    @Test func tailKeepsPartialFinalLineForNextTick() async throws {
        let path = tailTempFile("partial")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try #"{"type":"assistant""#.write(toFile: path, atomically: true, encoding: .utf8)

        let tailer = UsageTailer()
        var size = UInt64(try FileManager.default
            .attributesOfItem(atPath: path)[.size] as! Int)
        var added = await tailer.readGrowth(
            path: path, client: .claude, start: 0, end: size, mtimeMs: nowMs())

        #expect(added == 0)
        let offsetAfterPartial = await tailer.files[path]?.offset
        #expect(offsetAfterPartial == 0)

        try claudeAssistantLine("msg_partial", "req_partial")
            .write(toFile: path, atomically: true, encoding: .utf8)
        size = UInt64(try FileManager.default
            .attributesOfItem(atPath: path)[.size] as! Int)
        let start = await tailer.files[path]!.offset
        added = await tailer.readGrowth(
            path: path, client: .claude, start: start, end: size, mtimeMs: nowMs())

        #expect(added == 1)
        let trace = await tailer.trace(windowSecs: 3600)
        #expect(trace[0].tokens == 20)
    }

    // Port of grok_tail_emits_positive_total_token_deltas (:983-1069),
    // including the high-water dip phase.
    @Test func grokTailEmitsPositiveTotalTokenDeltas() async throws {
        let path = tailTempFile("grok-delta")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let lines = [
            grokLine(100, "grok-4.5", 1_700_000_000_000),
            grokLine(250, nil, 1_700_000_001_000),
            grokLine(250, nil, 1_700_000_002_000),
            grokLine(300, nil, 1_700_000_003_000),
        ].joined(separator: "\n")
        try lines.write(toFile: path, atomically: true, encoding: .utf8)

        let tailer = UsageTailer()
        var size = UInt64(try FileManager.default
            .attributesOfItem(atPath: path)[.size] as! Int)
        let added = await tailer.readGrowth(
            path: path, client: .grok, start: 0, end: size, mtimeMs: nowMs())

        // Full-file read (start=0): first total is a delta from 0, then
        // +150 and +50 → 3 events.
        #expect(added == 3)
        #expect(await tailer.files[path]?.grokLastTotal == 300)
        #expect(await tailer.files[path]?.grokModel == "grok-4.5")

        // Re-read with recent timestamps for the live trace assertion.
        let path2 = tailTempFile("grok-delta-live")
        defer { try? FileManager.default.removeItem(atPath: path2) }
        let now = nowMs()
        let live = [
            grokLine(100, "grok-4.5", now - 5_000),
            grokLine(180, nil, now - 2_000),
        ].joined(separator: "\n")
        try live.write(toFile: path2, atomically: true, encoding: .utf8)
        size = UInt64(try FileManager.default
            .attributesOfItem(atPath: path2)[.size] as! Int)
        let added2 = await tailer.readGrowth(
            path: path2, client: .grok, start: 0, end: size, mtimeMs: now)
        // first 100 from 0 + 80 growth
        #expect(added2 == 2)
        let trace = await tailer.trace(windowSecs: 3600)
        let grok = trace.first { $0.client == "grok" }
        #expect(grok?.tokens == 180)
        #expect(grok?.model == "grok-4.5")

        // Transient dip below high-water: ignored, high-water kept, recovery
        // does not emit a double-count delta until past 500.
        let path3 = tailTempFile("grok-dip")
        defer { try? FileManager.default.removeItem(atPath: path3) }
        let dip = [
            grokLine(500, "grok-4.5", now - 4_000),
            grokLine(120, nil, now - 3_000),
            grokLine(200, nil, now - 2_000),
            grokLine(520, nil, now - 1_000),
        ].joined(separator: "\n")
        try dip.write(toFile: path3, atomically: true, encoding: .utf8)
        await tailer.seedFileState(
            path: path3,
            state: TailFileState(offset: 0, mtimeMs: now, codexModel: nil,
                                 grokLastTotal: 500, grokModel: "grok-4.5"))
        size = UInt64(try FileManager.default
            .attributesOfItem(atPath: path3)[.size] as! Int)
        let added3 = await tailer.readGrowth(
            path: path3, client: .grok, start: 0, end: size, mtimeMs: now)
        // 500==seed skip; 120/200 ignored; 520 → +20 only.
        #expect(added3 == 1)
        #expect(await tailer.files[path3]?.grokLastTotal == 520)
    }

    // Codex tail path: last_token_usage only, cached subtracted from input,
    // model threaded from turn_context (usage_tail.rs:385-472). The
    // total_token_usage running counter must be ignored entirely — the tail
    // deliberately does NOT reuse the graph parser's delta state machine.
    @Test func codexTailUsesLastTokenUsageWithCacheSubtracted() async throws {
        let path = tailTempFile("codex-last")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let ts = rfc3339Now()
        let lines = """
        {"type":"turn_context","timestamp":"\(ts)","payload":{"model":"gpt-5.3-codex"}}
        {"type":"event_msg","timestamp":"\(ts)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":999999,"output_tokens":88888,"cached_input_tokens":77777},"last_token_usage":{"input_tokens":100,"output_tokens":10,"cached_input_tokens":30}}}}
        """
        try lines.write(toFile: path, atomically: true, encoding: .utf8)

        let tailer = UsageTailer()
        let size = UInt64(try FileManager.default
            .attributesOfItem(atPath: path)[.size] as! Int)
        let added = await tailer.readGrowth(
            path: path, client: .codex, start: 0, end: size, mtimeMs: nowMs())

        #expect(added == 1)
        let events = await tailer.eventsSnapshot()
        #expect(events.count == 1)
        #expect(events[0].client == "codex-cli")
        #expect(events[0].model == "gpt-5.3-codex")
        #expect(events[0].input == 70)  // 100 - 30 cached
        #expect(events[0].output == 10)
        #expect(events[0].cacheRead == 30)
        #expect(events[0].cacheWrite == 0)
        // Model threaded through file state for mid-file attaches.
        #expect(await tailer.files[path]?.codexModel == "gpt-5.3-codex")
    }

    // Streaming retries reuse the msgId:reqId key; the merge takes the
    // per-field max instead of appending (usage_tail.rs:636-658).
    @Test func claudeDedupMergesPerFieldMax() async throws {
        let path = tailTempFile("dedup")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let ts = rfc3339Now()
        func line(_ input: Int, _ output: Int) -> String {
            """
            {"type":"assistant","timestamp":"\(ts)","requestId":"req_1","message":{"id":"msg_1","model":"claude-sonnet-4-20250514","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
            """
        }
        try [line(10, 50), line(12, 5)].joined(separator: "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        let tailer = UsageTailer()
        let size = UInt64(try FileManager.default
            .attributesOfItem(atPath: path)[.size] as! Int)
        let added = await tailer.readGrowth(
            path: path, client: .claude, start: 0, end: size, mtimeMs: nowMs())

        // Second line merges into the first: not counted as added.
        #expect(added == 1)
        let events = await tailer.eventsSnapshot()
        #expect(events.count == 1)
        #expect(events[0].input == 12)  // max(10, 12)
        #expect(events[0].output == 50)  // max(50, 5)
        let trace = await tailer.trace(windowSecs: 3600)
        #expect(trace[0].messages == 1)
    }

    // Sidechain lines are attributed subagent:<agentId>, falling back to the
    // file stem with the agent- prefix stripped (usage_tail.rs:344-357,
    // 893-903).
    @Test func claudeSidechainAttribution() async throws {
        let ts = rfc3339Now()
        func sidechainLine(_ agentId: String?) -> String {
            let idField = agentId.map { #","agentId":"\#($0)""# } ?? ""
            return """
            {"type":"assistant","timestamp":"\(ts)","isSidechain":true\(idField),"message":{"model":"claude-sonnet-4-20250514","usage":{"input_tokens":5,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
            """
        }

        let tailer = UsageTailer()
        let path = tailTempFile("sidechain")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try sidechainLine("abc123").write(toFile: path, atomically: true, encoding: .utf8)
        var size = UInt64(try FileManager.default
            .attributesOfItem(atPath: path)[.size] as! Int)
        _ = await tailer.readGrowth(
            path: path, client: .claude, start: 0, end: size, mtimeMs: nowMs())

        // No agentId → label from the file stem, stripping "agent-".
        let dir = try tailTempDir("sidechain-stem")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stemPath = dir.appendingPathComponent("agent-xyz789.jsonl").path
        try sidechainLine(nil).write(toFile: stemPath, atomically: true, encoding: .utf8)
        size = UInt64(try FileManager.default
            .attributesOfItem(atPath: stemPath)[.size] as! Int)
        _ = await tailer.readGrowth(
            path: stemPath, client: .claude, start: 0, end: size, mtimeMs: nowMs())

        let agents = Set(await tailer.eventsSnapshot().map(\.agent))
        #expect(agents == ["subagent:abc123", "subagent:xyz789"])
    }

    // The tail's normalize_model strips one trailing -YYYYMMDD and is
    // deliberately different from the graph parser's normalize.
    @Test func tailNormalizeModelStripsTrailingDate() {
        #expect(tailNormalizeModel("claude-sonnet-4-20250514") == "claude-sonnet-4")
        #expect(tailNormalizeModel("Claude-Opus-4-20250101") == "claude-opus-4")
        #expect(tailNormalizeModel("gpt-5.3-codex") == "gpt-5.3-codex")
        // 8 digits but no dash before them: untouched.
        #expect(tailNormalizeModel("model20250514") == "model20250514")
        // Too short to carry a date suffix (len must exceed 9).
        #expect(tailNormalizeModel("-20250514") == "-20250514")
        #expect(tailNormalizeModel("a-20250514") == "a")
    }

    // Cold scan: unseen files older than 6h are stamped at EOF without
    // reading; growth after that is picked up from the stamped offset.
    // Shrink drops state and re-reads from 0 (usage_tail.rs:175-200).
    @Test func tickColdScanStampsOldFilesAndShrinkRereads() async throws {
        let home = try tailTempDir("cold-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let projects = home.appendingPathComponent(".claude/projects/proj")
        try FileManager.default.createDirectory(
            at: projects, withIntermediateDirectories: true)
        let path = projects.appendingPathComponent("session.jsonl").path
        try (claudeAssistantLine("msg_old", "req_old") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        // Make the file look 7 hours old.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7 * 3600)],
            ofItemAtPath: path)

        let tailer = UsageTailer(
            config: UsageTailerConfig(simulatedHome: home.path))
        let added = await tailer.tick()
        #expect(added == 0)  // stamped at EOF, never read
        let stampedOffset = await tailer.files[path]?.offset
        let fileSize = UInt64(try FileManager.default
            .attributesOfItem(atPath: path)[.size] as! Int)
        #expect(stampedOffset == fileSize)

        // Append growth: only the new line is read.
        let handle = FileHandle(forWritingAtPath: path)!
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((claudeAssistantLine("msg_new", "req_new") + "\n").utf8))
        try handle.close()
        let added2 = await tailer.tick()
        #expect(added2 == 1)

        // Shrink: state dropped, file re-read from 0.
        try (claudeAssistantLine("msg_shrunk", "req_shrunk") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        let added3 = await tailer.tick()
        #expect(added3 == 1)
        // msg_old was stamped over, never read: only msg_new + msg_shrunk.
        let events = await tailer.eventsSnapshot()
        #expect(events.count == 2)
    }

    // Equal-size refresh (mtime bump, no growth) must preserve the threaded
    // grok high-water state (usage_tail.rs:183-193).
    @Test func equalSizeRefreshPreservesThreadedState() async throws {
        let home = try tailTempDir("grok-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionDir = home.appendingPathComponent(".grok/sessions/proj/s1")
        try FileManager.default.createDirectory(
            at: sessionDir, withIntermediateDirectories: true)
        let path = sessionDir.appendingPathComponent("updates.jsonl").path
        let now = nowMs()
        try (grokLine(400, "grok-4.5", now) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        let tailer = UsageTailer(
            config: UsageTailerConfig(simulatedHome: home.path))
        let added = await tailer.tick()
        #expect(added == 1)
        #expect(await tailer.files[path]?.grokLastTotal == 400)

        // Touch mtime without growing the file.
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: path)
        _ = await tailer.tick()
        #expect(await tailer.files[path]?.grokLastTotal == 400)

        // A dip appended after the refresh is still judged against the
        // preserved high-water total.
        let handle = FileHandle(forWritingAtPath: path)!
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((grokLine(100, nil, now) + "\n").utf8))
        try handle.close()
        let added2 = await tailer.tick()
        #expect(added2 == 0)
        #expect(await tailer.files[path]?.grokLastTotal == 400)
    }

    // Hermes: cold tick stamps per-session baselines silently; the next
    // tick emits positive per-field deltas only (usage_tail.rs:543-634).
    @Test func hermesTickDiffsSessionTotals() async throws {
        let home = try tailTempDir("hermes-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let hermesDir = home.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(
            at: hermesDir, withIntermediateDirectories: true)
        let dbPath = hermesDir.appendingPathComponent("state.db").path

        var db: OpaquePointer?
        #expect(sqlite3_open(dbPath, &db) == SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        let setup = """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                model TEXT,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_write_tokens INTEGER
            );
            INSERT INTO sessions VALUES ('s1', 'gpt-5.5-20250101', 100, 20, 30, 40);
            """
        #expect(sqlite3_exec(db, setup, nil, nil, nil) == SQLITE_OK)

        let tailer = UsageTailer(
            config: UsageTailerConfig(simulatedHome: home.path))
        let added = await tailer.tick()
        #expect(added == 0)  // cold: baseline stamped silently

        // Grow s1 (mixed direction: output dips, must clamp to 0).
        let update = """
            UPDATE sessions SET input_tokens = 160, output_tokens = 5,
                cache_read_tokens = 30, cache_write_tokens = 45 WHERE id = 's1';
            INSERT INTO sessions VALUES ('s2', 'claude-sonnet-4', 7, 3, 0, 0);
            """
        #expect(sqlite3_exec(db, update, nil, nil, nil) == SQLITE_OK)

        let added2 = await tailer.tick()
        #expect(added2 == 2)
        let events = await tailer.eventsSnapshot().sorted { $0.model < $1.model }
        #expect(events.count == 2)
        // s2 is brand new: full totals count as the delta.
        #expect(events[0].model == "claude-sonnet-4")
        #expect(events[0].input == 7)
        #expect(events[0].output == 3)
        // s1: positive per-field deltas only; model date suffix stripped.
        #expect(events[1].model == "gpt-5.5")
        #expect(events[1].input == 60)
        #expect(events[1].output == 0)
        #expect(events[1].cacheRead == 0)
        #expect(events[1].cacheWrite == 5)

        // No change → no events.
        let added3 = await tailer.tick()
        #expect(added3 == 0)
    }

    // Event ring trim: events past EVENT_WINDOW_SECS are dropped and the
    // seen index map is cleared wholesale (usage_tail.rs:660-670), so a
    // late retry of a trimmed message appends a fresh event instead of
    // merging into a stale index.
    @Test func trimClearsSeenIndexWholesale() async throws {
        let home = try tailTempDir("trim-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let projects = home.appendingPathComponent(".claude/projects/p")
        try FileManager.default.createDirectory(
            at: projects, withIntermediateDirectories: true)
        let path = projects.appendingPathComponent("s.jsonl").path

        // Fixed clock so the first event (1h-5s old) survives tick 1 but is
        // trimmed on tick 2 when the clock advances.
        let fixedNow = 1_700_000_000_000 as Int64
        let clock = ClockBox(now: fixedNow)
        let tailer = UsageTailer(config: UsageTailerConfig(
            simulatedHome: home.path, nowMs: { clock.value }))

        func line(_ msgId: String, _ tsMs: Int64, _ input: Int) -> String {
            let date = Date(timeIntervalSince1970: Double(tsMs) / 1000.0)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return """
            {"type":"assistant","timestamp":"\(f.string(from: date))","requestId":"r","message":{"id":"\(msgId)","model":"m","usage":{"input_tokens":\(input),"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
            """
        }

        try (line("msg_a", fixedNow - 3_595_000, 11) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        #expect(await tailer.tick() == 1)
        #expect(await tailer.seen.count == 1)

        // Advance past the window; append an unrelated event to trigger a
        // trim that removes msg_a.
        clock.value = fixedNow + 10_000
        let handle = FileHandle(forWritingAtPath: path)!
        try handle.seekToEnd()
        try handle.write(
            contentsOf: Data((line("msg_b", fixedNow + 9_000, 22) + "\n").utf8))
        try handle.close()
        #expect(await tailer.tick() == 1)
        #expect(await tailer.eventsSnapshot().map(\.input) == [22])
        // seen cleared wholesale — msg_b's own key is gone too.
        #expect(await tailer.seen.isEmpty)

        // A retry of msg_b now appends instead of merging.
        let handle2 = FileHandle(forWritingAtPath: path)!
        try handle2.seekToEnd()
        try handle2.write(
            contentsOf: Data((line("msg_b", fixedNow + 9_000, 22) + "\n").utf8))
        try handle2.close()
        #expect(await tailer.tick() == 1)
        #expect(await tailer.eventsSnapshot().count == 2)
    }
}

/// Mutable clock for fixed-time tests (@unchecked: single-threaded test use).
private final class ClockBox: @unchecked Sendable {
    var value: Int64
    init(now: Int64) { value = now }
}

extension UsageTailer {
    /// Test hook mirroring the Rust test's direct files.lock() insert.
    func seedFileState(path: String, state: TailFileState) {
        files[path] = state
    }
}

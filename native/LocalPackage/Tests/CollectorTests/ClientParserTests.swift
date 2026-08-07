import DataSource
import Foundation
import SQLite3
import Testing

@testable import Collector

// Ports of the Rust unit tests for the stage-2 parsers (usage_graph.rs
// grok tests :3411-3602, hermes tests :3202-3343), plus fixture tests for
// the gemini replace-by-id behavior and the cursor CSV splitter.

private func makeTempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "tokcat-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(nowMs())-\(UInt32.random(in: 0..<UInt32.max))"
        )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct GrokParserTests {
    /// Mirror of write_grok_fixture (usage_graph.rs:3374-3405).
    private func withGrokFixture(
        _ name: String, updates: String, summary: String? = nil, signals: String? = nil,
        events: String? = nil, _ body: (String) -> Void
    ) throws {
        let root = try makeTempDir("grok-\(name)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir =
            root
            .appendingPathComponent(".grok")
            .appendingPathComponent("sessions")
            .appendingPathComponent("%2Ftmp%2Fproject")
            .appendingPathComponent("session-1")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let updatesPath = sessionDir.appendingPathComponent("updates.jsonl").path
        try updates.write(toFile: updatesPath, atomically: true, encoding: .utf8)
        if let summary {
            try summary.write(
                toFile: sessionDir.appendingPathComponent("summary.json").path,
                atomically: true, encoding: .utf8)
        }
        if let signals {
            try signals.write(
                toFile: sessionDir.appendingPathComponent("signals.json").path,
                atomically: true, encoding: .utf8)
        }
        if let events {
            try events.write(
                toFile: sessionDir.appendingPathComponent("events.jsonl").path,
                atomically: true, encoding: .utf8)
        }
        body(updatesPath)
    }

    // Port of parses_grok_total_token_deltas_by_turn (:3411-3443).
    @Test func totalTokenDeltasByTurn() throws {
        try withGrokFixture(
            "by-turn",
            updates: """
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"available_commands_update"},"_meta":{"totalTokens":100,"agentTimestampMs":1700000000000}}}
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","_meta":{"modelId":"grok-4.5"}}},"_meta":{"agentTimestampMs":1700000001000}}}
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_thought_chunk"},"_meta":{"totalTokens":250,"agentTimestampMs":1700000002000}}}
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":300,"agentTimestampMs":1700000003000}}}
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","_meta":{"modelId":"grok-4.5"}}},"_meta":{"agentTimestampMs":1700000004000}}}
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":450,"agentTimestampMs":1700000005000}}}
                """,
            summary: #"{"current_model_id":"grok-4.5","updated_at":"2023-11-14T22:13:20Z"}"#
        ) { path in
            let messages = parseGrokUpdatesFile(path)
            #expect(messages.count == 2)
            #expect(messages[0].client == "grok")
            #expect(messages[0].modelId == "grok-4.5")
            #expect(messages[0].providerId == "xai")
            #expect(messages[0].tokens.input == 200)
            #expect(messages[0].tokens.output == 0)
            #expect(messages[0].timestampMs == 1_700_000_003_000)
            #expect(messages[0].dedupKey == "grok:%2Ftmp%2Fproject:session-1:0")
            #expect(messages[1].tokens.input == 150)
            #expect(messages[1].timestampMs == 1_700_000_005_000)
        }
    }

    // Port of grok_uses_summary_model_when_update_model_is_missing (:3445-3463).
    @Test func usesSummaryModelWhenUpdateModelMissing() throws {
        try withGrokFixture(
            "summary-model",
            updates: """
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"user_message_chunk"},"_meta":{"agentTimestampMs":1700000000000}}}
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":220,"agentTimestampMs":1700000001000}}}
                """,
            summary: #"{"current_model_id":"grok-4.5","updated_at":"2023-11-14T22:13:20Z"}"#
        ) { path in
            let messages = parseGrokUpdatesFile(path)
            #expect(messages.count == 1)
            #expect(messages.first?.modelId == "grok-4.5")
            #expect(messages.first?.tokens.input == 220)
        }
    }

    // Port of grok_ignores_repeated_and_decreasing_total_tokens (:3465-3487).
    @Test func ignoresRepeatedAndDecreasingTotals() throws {
        try withGrokFixture(
            "monotonic",
            updates: """
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"available_commands_update"},"_meta":{"totalTokens":100,"agentTimestampMs":1700000000000}}}
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","_meta":{"modelId":"grok-4.5"}}},"_meta":{"agentTimestampMs":1700000001000}}}
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":150,"agentTimestampMs":1700000002000}}}
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":150,"agentTimestampMs":1700000003000}}}
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":120,"agentTimestampMs":1700000004000}}}
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":200,"agentTimestampMs":1700000005000}}}
                """
        ) { path in
            let messages = parseGrokUpdatesFile(path)
            // Dip to 120 is ignored without lowering the high-water mark, so
            // the final 200 yields one turn delta of 100 (200 - baseline 100).
            #expect(messages.count == 1)
            #expect(messages.first?.tokens.input == 100)
            #expect(messages.first?.timestampMs == 1_700_000_005_000)
        }
    }

    // Port of grok_adds_signals_reconciliation_when_compaction_exceeds_updates
    // (:3489-3520).
    @Test func signalsReconciliationWhenCompactionExceedsUpdates() throws {
        try withGrokFixture(
            "signals",
            updates: """
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","_meta":{"modelId":"grok-4.5"}}},"_meta":{"agentTimestampMs":1700000000000}}}
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":171056,"agentTimestampMs":1700000001000}}}
                """,
            signals:
                #"{"primaryModelId":"grok-4.5","totalTokensBeforeCompaction":3224659,"contextTokensUsed":172309}"#
        ) { path in
            let messages = parseGrokUpdatesFile(path)
            #expect(messages.count == 2)
            #expect(messages[0].tokens.input == 171_056)
            #expect(messages[1].tokens.input == 3_225_912)
            #expect(messages[1].modelId == "grok-4.5")
            #expect(messages[1].dedupKey == "grok:%2Ftmp%2Fproject:session-1:signals")
            // Anchored at the MAX update timestamp, not signals.json mtime.
            #expect(messages[1].timestampMs == 1_700_000_001_000)
            #expect(messages.reduce(Int64(0)) { $0 + $1.tokens.input } == 3_396_968)
        }
    }

    // Port of grok_preserves_total_tokens_without_model_metadata (:3542-3556).
    @Test func preservesTotalsWithoutModelMetadata() throws {
        try withGrokFixture(
            "no-model",
            updates:
                #"{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"available_commands_update"},"_meta":{"totalTokens":120,"agentTimestampMs":1700000000000}}}"#
        ) { path in
            let messages = parseGrokUpdatesFile(path)
            #expect(messages.count == 1)
            #expect(messages.first?.modelId == grokUnknownModel)
            #expect(messages.first?.tokens.input == 120)
            #expect(messages.first?.timestampMs == 1_700_000_000_000)
        }
    }

    // Port of grok_skips_signals_reconciliation_when_updates_cover_total
    // (:3558-3571).
    @Test func skipsSignalsReconciliationWhenUpdatesCoverTotal() throws {
        try withGrokFixture(
            "signals-covered",
            updates: """
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"user_message_chunk"},"_meta":{"agentTimestampMs":1700000000000}}}
                {"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":500,"agentTimestampMs":1700000001000}}}
                """,
            signals: #"{"primaryModelId":"grok-4.5","contextTokensUsed":400}"#
        ) { path in
            let messages = parseGrokUpdatesFile(path)
            #expect(messages.count == 1)
            #expect(messages.first?.tokens.input == 500)
        }
    }

    // Port of grok_events_jsonl_supplies_model_when_summary_missing (:3573-3602).
    @Test func eventsJSONLSuppliesModelWhenSummaryMissing() throws {
        try withGrokFixture(
            "events",
            updates:
                #"{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":90,"agentTimestampMs":1700000001000}}}"#,
            events: #"{"model_id":"grok-4.5","session_id":"session-1","ts":1700000000000}"#
        ) { path in
            let messages = parseGrokUpdatesFile(path)
            #expect(messages.count == 1)
            #expect(messages.first?.modelId == "grok-4.5")
            #expect(messages.first?.tokens.input == 90)
        }
    }
}

@Suite struct HermesParserTests {
    /// Create a writable SQLite fixture db and hand its path to `body`.
    private func withHermesDB(_ name: String, _ sql: String, _ body: (String) -> Void) throws {
        let dir = try makeTempDir("hermes-\(name)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("state.db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        #expect(rc == SQLITE_OK, "fixture SQL failed: \(rc)")
        body(path)
    }

    // Port of hermes_sessions_use_started_at_and_stored_usage_fields
    // (:3202-3308).
    @Test func sessionsUseStartedAtAndStoredUsageFields() throws {
        try withHermesDB(
            "started-at",
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                model TEXT,
                started_at REAL,
                ended_at REAL,
                message_count INTEGER,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_write_tokens INTEGER,
                reasoning_tokens INTEGER,
                billing_provider TEXT,
                estimated_cost_usd REAL,
                actual_cost_usd REAL
            );
            INSERT INTO sessions VALUES
                ('s1', 'gpt-5.5', 1700000000.125, 0.0, 4, 100, 20, 300, 40, 5,
                 'openai-codex', 0.25, 1.25),
                ('s2', 'claude-sonnet-4', 1700259200.0, 0.0, 2, 10, 3, 7, 1, 2,
                 'anthropic', 0.75, 0.0);
            """
        ) { path in
            let messages = parseHermesDB(path)
            let first = messages.first { $0.dedupKey == "hermes:s1" }
            let second = messages.first { $0.dedupKey == "hermes:s2" }

            #expect(first?.providerId == "openai")
            #expect(first?.timestampMs == 1_700_000_000_125)
            #expect(first?.tokens.reasoning == 5)
            #expect(first?.messages == 4)
            #expect(first?.cost == 1.25)

            #expect(second?.providerId == "anthropic")
            #expect(second?.timestampMs == 1_700_259_200_000)
            #expect(second?.tokens.reasoning == 2)
            #expect(second?.messages == 2)
            #expect(second?.cost == 0.75)

            let payload = buildPayload(messages)
            #expect(Set(payload.contributions.map(\.date)).count == 2)
        }
    }

    // Port of hermes_parser_tolerates_minimal_session_schema (:3310-3343).
    @Test func toleratesMinimalSessionSchema() throws {
        try withHermesDB(
            "minimal",
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                model TEXT,
                started_at REAL,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_write_tokens INTEGER
            );
            INSERT INTO sessions VALUES ('s1', 'gpt-5.5', 1700000000, 1, 2, 3, 4);
            """
        ) { path in
            let messages = parseHermesDB(path)
            #expect(messages.count == 1)
            #expect(messages.first?.timestampMs == 1_700_000_000_000)
            #expect(messages.first?.tokens.total == 10)
        }
    }
}

@Suite struct GeminiParserTests {
    // Later duplicate ids REPLACE the earlier message in place — opposite of
    // the pipeline's global first-wins dedup (usage_graph.rs:1176-1187).
    @Test func jsonlReplaceInPlaceById() throws {
        let dir = try makeTempDir("gemini-replace")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.jsonl").path
        try [
            #"{"sessionId":"sess-1","model":"gemini-2.5-pro"}"#,
            #"{"type":"gemini","id":"m1","tokens":{"input":100,"output":10},"timestamp":1700000000000}"#,
            #"{"type":"gemini","id":"m2","tokens":{"input":50,"output":5},"timestamp":1700000001000}"#,
            #"{"type":"gemini","id":"m1","tokens":{"input":120,"output":12},"timestamp":1700000002000}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let messages = parseGeminiJSONL(path, fallbackTs: 1)
        #expect(messages.count == 2)
        // m1 keeps its ORIGINAL position but carries the LATER values.
        #expect(messages[0].dedupKey == "gemini:m1")
        #expect(messages[0].tokens.input == 120)
        #expect(messages[0].tokens.output == 12)
        #expect(messages[0].timestampMs == 1_700_000_002_000)
        #expect(messages[0].modelId == "gemini-2.5-pro")  // model hint carried
        #expect(messages[1].dedupKey == "gemini:m2")
        #expect(messages[1].tokens.input == 50)
    }

    @Test func cacheSubtractionOnlyWhenTotalIsCacheInclusive() throws {
        // total == input+output+thoughts+tool -> cached subtracted from input.
        let inclusive = try #require(
            JSONValue.parse(
                #"{"type":"gemini","model":"gemini-2.5-pro","tokens":{"input":100,"output":10,"thoughts":5,"tool":3,"cached":40,"total":118},"timestamp":1700000000000}"#
            ))
        let m1 = buildGeminiMessage(inclusive, modelHint: nil, fallbackTs: 1)
        #expect(m1?.tokens.input == 63)  // 100-40 + tool 3
        #expect(m1?.tokens.cacheRead == 40)
        #expect(m1?.tokens.reasoning == 5)

        // total mismatch -> input left as-is (cache assumed exclusive).
        let exclusive = try #require(
            JSONValue.parse(
                #"{"type":"gemini","model":"gemini-2.5-pro","tokens":{"input":100,"output":10,"thoughts":5,"tool":3,"cached":40,"total":158},"timestamp":1700000000000}"#
            ))
        let m2 = buildGeminiMessage(exclusive, modelHint: nil, fallbackTs: 1)
        #expect(m2?.tokens.input == 103)  // 100 + tool 3
        #expect(m2?.tokens.cacheRead == 40)
    }
}

@Suite struct CursorParserTests {
    // The hand-rolled quote-toggle splitter (usage_graph.rs:2457-2472) is NOT
    // an RFC-CSV parser: quotes toggle, are kept in the field text, and
    // doubled quotes are not an escape.
    @Test func csvLineQuoteToggleSplitter() {
        #expect(parseCSVLine("a,b,c") == ["a", "b", "c"])
        #expect(parseCSVLine(#""May 1, 2024",gpt-4,"1,000",5"#)
            == [#""May 1, 2024""#, "gpt-4", #""1,000""#, "5"])
        // Doubled quote toggles out and back in: the comma stays quoted-out.
        #expect(parseCSVLine(#""a""b,c",d"#) == [#""a""b,c""#, "d"])
        // Unterminated quote swallows the rest of the line.
        #expect(parseCSVLine(#""a,b"#) == [#""a,b"#])
        #expect(parseCSVLine("") == [""])
        #expect(parseCSVLine("a,,b") == ["a", "", "b"])
        // clean_csv: trim whitespace first, then strip ALL edge quotes.
        #expect(cleanCSV(#" "1,000" "#) == "1,000")
        #expect(cleanCSV(#"""x"""#) == "x")
    }

    @Test func costParsing() {
        #expect(parseCost("$1,234.56") == 1234.56)
        #expect(parseCost("Included") == 0.0)
        #expect(parseCost("NaN") == 0.0)
        #expect(parseCost("-") == 0.0)
        #expect(parseCost("") == 0.0)
        #expect(parseCost("0.42") == 0.42)
    }

    @Test func csvFileKindLayoutAndCacheWrite() throws {
        let dir = try makeTempDir("cursor-csv")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("usage.csv").path
        // 12-column layout with a Kind column: model=4, input w/ cache=6,
        // input w/o cache=7, cache read=8, output=9, cost=11.
        try """
            Date,User,Kind,Max Mode,Model,Provider,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output,Total Tokens,Cost
            2024-05-01,me,usage,off,gpt-4o,openai,1000,400,600,50,1650,$1.25
            """.write(toFile: path, atomically: true, encoding: .utf8)

        let messages = parseCursorFile(path)
        #expect(messages.count == 1)
        let msg = try #require(messages.first)
        #expect(msg.modelId == "gpt-4o")
        #expect(msg.tokens.input == 400)
        // cache_write = input_with_cache - input_without_cache.
        #expect(msg.tokens.cacheWrite == 600)
        #expect(msg.tokens.cacheRead == 600)
        #expect(msg.tokens.output == 50)
        #expect(msg.cost == 1.25)
        #expect(msg.dedupKey == "cursor:usage:2024-05-01")
        // %Y-%m-%d dates anchor at 12:00:00 UTC.
        #expect(msg.timestampMs == parseDateToTimestampMs("2024-05-01"))
        #expect(parseDateToTimestampMs("2024-05-01") == 1_714_564_800_000)
        #expect(parseDateToTimestampMs("bogus") == 0)
    }

    @Test func legacyHeaderLayoutWithoutKind() throws {
        let dir = try makeTempDir("cursor-legacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("usage.acct.csv").path
        // No Kind column: model=1, iwc=2, iwoc=3, cache read=4, output=5, cost=7.
        try """
            Date,Model,Input With Cache,Input Without Cache,Cache Read,Output,Total,Cost
            2024-06-02,claude-sonnet-4,900,300,600,40,1540,0.80
            """.write(toFile: path, atomically: true, encoding: .utf8)

        let messages = parseCursorFile(path)
        #expect(messages.count == 1)
        #expect(messages.first?.modelId == "claude-sonnet-4")
        #expect(messages.first?.tokens.input == 300)
        #expect(messages.first?.tokens.cacheWrite == 600)
        #expect(messages.first?.cost == 0.80)
        // Account comes from the file stem (usage.acct.csv -> usage.acct).
        #expect(messages.first?.dedupKey == "cursor:usage.acct:2024-06-02")
    }
}

@Suite struct DroidModelNormalizationTests {
    // Spot checks of normalize_droid_model (usage_graph.rs:2496-2513).
    @Test func normalizesDroidModelIds() {
        #expect(normalizeDroidModel("custom:GPT_5.5 Codex") == "gpt-5-5-codex")
        #expect(normalizeDroidModel("claude-sonnet-4[beta] ") == "claude-sonnet-4")
        #expect(normalizeDroidModel("a..__b") == "a-b")
        #expect(normalizeDroidModel("-x-") == "x")
    }
}

import DataSource
import Foundation
import Testing

@testable import Collector

// Ports of the Rust unit tests in usage_graph.rs for the stage-1 surface,
// plus lenient-helper coverage for the serde-coercion semantics.

@Suite struct LenientHelperTests {
    @Test func epochMagnitudeThresholds() {
        // seconds -> ms
        #expect(normalizeEpochMs(1_700_000_000) == 1_700_000_000_000)
        // just below the ms threshold still counts as seconds
        #expect(normalizeEpochMs(99_999_999_999) == 99_999_999_999_000)
        // ms passes through
        #expect(normalizeEpochMs(100_000_000_000) == 100_000_000_000)
        #expect(normalizeEpochMs(1_700_000_000_000) == 1_700_000_000_000)
        // micros -> ms (truncating division)
        #expect(normalizeEpochMs(1_700_000_000_123_456) == 1_700_000_000_123)
        // nanos -> ms
        #expect(normalizeEpochMs(1_700_000_000_123_456_789) == 1_700_000_000_123)
        // negative values sniff on magnitude
        #expect(normalizeEpochMs(-1_700_000_000) == -1_700_000_000_000)
    }

    @Test func i64TruncationVsF64RoundingDivergence() {
        // The int path truncates the float `as i64` BEFORE magnitude
        // sniffing (drops sub-second precision)...
        #expect(timestampMsFromValue(.double(1_700_000_000.9)) == 1_700_000_000_000)
        // ...while normalize_epoch_ms_f64 scales first and ROUNDS.
        #expect(normalizeEpochMsF64(1_700_000_000.9) == 1_700_000_000_900)
        #expect(normalizeEpochMsF64(1_700_000_000.0004) == 1_700_000_000_000)
        #expect(normalizeEpochMsF64(1_700_000_000.0006) == 1_700_000_000_001)
        // f64 path rejects non-positive and non-finite values
        #expect(normalizeEpochMsF64(0.0) == nil)
        #expect(normalizeEpochMsF64(-5.0) == nil)
        #expect(normalizeEpochMsF64(.infinity) == nil)
        // i64_value truncates doubles toward zero
        #expect(i64Value(.double(2.9)) == 2)
        #expect(i64Value(.double(-2.9)) == -2)
        // and saturates like Rust `as i64`
        #expect(i64Value(.double(1e30)) == Int64.max)
        #expect(i64Value(.double(-1e30)) == Int64.min)
    }

    @Test func lenientValueCoercions() {
        #expect(i64Value(.int(42)) == 42)
        #expect(i64Value(.string(" 42 ")) == 42)
        #expect(i64Value(.string("4.2")) == nil)
        #expect(i64Value(.bool(true)) == nil)
        #expect(i64Value(nil) == nil)
        #expect(f64Value(.string(" 4.25 ")) == 4.25)
        #expect(f64Value(.int(3)) == 3.0)
        #expect(stringValue(.string("  hi  ")) == "hi")
        #expect(stringValue(.string("   ")) == nil)
        #expect(stringValue(.int(7)) == "7")
        #expect(stringValue(.bool(true)) == nil)
    }

    @Test func jsonIntegerVsDoubleDistinction() throws {
        let v = try #require(JSONValue.parse(#"{"i":10,"f":10.5,"b":true,"s":"1"}"#))
        #expect(i64Value(v["i"]) == 10)
        if case .int = try #require(v["i"]) {} else { Issue.record("10 should parse as int") }
        if case .double = try #require(v["f"]) {} else { Issue.record("10.5 should be double") }
        // Bool must NOT bridge into the numeric paths.
        if case .bool(true) = try #require(v["b"]) {} else { Issue.record("true should be bool") }
        #expect(i64Value(v["b"]) == nil)
        #expect(stringValue(v["s"]) == "1")
    }

    @Test func rfc3339Parsing() {
        #expect(rfc3339ToTimestampMs("2023-11-14T22:13:20Z") == 1_700_000_000_000)
        #expect(rfc3339ToTimestampMs("2023-11-14t22:13:20z") == 1_700_000_000_000)
        #expect(rfc3339ToTimestampMs("2023-11-14 22:13:20Z") == 1_700_000_000_000)
        #expect(rfc3339ToTimestampMs("2023-11-14T22:13:20.5Z") == 1_700_000_000_500)
        #expect(rfc3339ToTimestampMs("2023-11-14T22:13:20.123456789Z") == 1_700_000_000_123)
        #expect(rfc3339ToTimestampMs("2023-11-15T07:13:20+09:00") == 1_700_000_000_000)
        #expect(rfc3339ToTimestampMs("2023-11-14T17:13:20-05:00") == 1_700_000_000_000)
        // rejects: no offset, bad date, trailing garbage, bare fraction dot
        #expect(rfc3339ToTimestampMs("2023-11-14T22:13:20") == nil)
        #expect(rfc3339ToTimestampMs("2023-02-30T00:00:00Z") == nil)
        #expect(rfc3339ToTimestampMs("2023-11-14T22:13:20Zx") == nil)
        #expect(rfc3339ToTimestampMs("2023-11-14T22:13:20.Z") == nil)
        // timestamp_ms_from_value falls back to numeric strings
        #expect(timestampMsFromValue(.string("1700000000")) == 1_700_000_000_000)
        #expect(timestampMsFromValue(.string("not a time")) == nil)
    }
}

@Suite struct CodexParserTests {
    private func withTempJSONL(_ name: String, _ lines: [String], _ body: (String) -> Void)
        throws
    {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokcat-codex-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(nowMs())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.jsonl").path
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        body(path)
    }

    // Port of codex_parser_skips_repeated_total_snapshots (:3072-3094).
    @Test func skipsRepeatedTotalSnapshots() throws {
        try withTempJSONL(
            "repeated-total",
            [
                #"{"type":"session_meta","payload":{"model_provider":"openai"}}"#,
                #"{"type":"turn_context","payload":{"model_info":{"slug":"gpt-5.5"}}}"#,
                #"{"timestamp":"2026-05-24T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.5","total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"total_tokens":110}}}}"#,
                #"{"timestamp":"2026-05-24T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.5","total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"total_tokens":110}}}}"#,
            ]
        ) { path in
            let messages = parseCodexFile(path)
            #expect(messages.count == 1)
            #expect(messages.first?.tokens.input == 80)
            #expect(messages.first?.tokens.cacheRead == 20)
            #expect(messages.first?.tokens.output == 10)
        }
    }

    // Port of codex_parser_skips_stale_regression_snapshots (:3096-3122).
    @Test func skipsStaleRegressionSnapshots() throws {
        try withTempJSONL(
            "stale-regression",
            [
                #"{"type":"turn_context","payload":{"model_info":{"slug":"gpt-5.5"}}}"#,
                #"{"timestamp":"2026-05-24T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.5","total_token_usage":{"input_tokens":1000,"total_tokens":1000},"last_token_usage":{"input_tokens":100,"total_tokens":100}}}}"#,
                #"{"timestamp":"2026-05-24T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.5","total_token_usage":{"input_tokens":990,"total_tokens":990},"last_token_usage":{"input_tokens":50,"total_tokens":50}}}}"#,
                #"{"timestamp":"2026-05-24T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.5","total_token_usage":{"input_tokens":1060,"total_tokens":1060},"last_token_usage":{"input_tokens":60,"total_tokens":60}}}}"#,
            ]
        ) { path in
            let messages = parseCodexFile(path)
            #expect(messages.count == 2)
            #expect(messages.reduce(Int64(0)) { $0 + $1.tokens.input } == 160)
        }
    }

    // Port of codex_parser_skips_forked_session_inherited_baseline (:3124-3145).
    @Test func skipsForkedSessionInheritedBaseline() throws {
        try withTempJSONL(
            "forked-baseline",
            [
                #"{"type":"session_meta","payload":{"forked_from_id":"parent","model_provider":"openai"}}"#,
                #"{"timestamp":"2026-05-24T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"total_tokens":1000},"last_token_usage":{"input_tokens":1000,"total_tokens":1000}}}}"#,
                #"{"type":"turn_context","payload":{"model_info":{"slug":"gpt-5.5"}}}"#,
                #"{"timestamp":"2026-05-24T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.5","total_token_usage":{"input_tokens":1000,"total_tokens":1000},"last_token_usage":{"input_tokens":20,"total_tokens":20}}}}"#,
                #"{"timestamp":"2026-05-24T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.5","total_token_usage":{"input_tokens":1100,"total_tokens":1100},"last_token_usage":{"input_tokens":100,"total_tokens":100}}}}"#,
            ]
        ) { path in
            let messages = parseCodexFile(path)
            #expect(messages.count == 1)
            #expect(messages.first?.tokens.input == 100)
        }
    }

    // Port of codex_cached_tokens_do_not_double_count_input (:3057-3070).
    @Test func cachedTokensDoNotDoubleCountInput() {
        let tokens = CodexTotals(input: 100, output: 20, cached: 30, reasoning: 5).intoTokens()
        #expect(tokens.input == 70)
        #expect(tokens.cacheRead == 30)
        #expect(tokens.total == 125)
    }
}

@Suite struct PricingTests {
    private func assertPrice(
        _ model: String, _ provider: String, _ expected: Price,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let actual = bundledPrice(model: model, provider: provider)
        #expect(actual == expected, "\(model)", sourceLocation: sourceLocation)
    }

    // Port of bundled_price_matches_current_claude_model_families (:2885-2932).
    @Test func claudeModelFamilies() {
        assertPrice("claude-fable-5", "anthropic", Price(10.0, 50.0, 1.0, 12.5))
        assertPrice("claude-fable-5[1m]", "anthropic", Price(10.0, 50.0, 1.0, 12.5))
        assertPrice("claude-opus-4-7", "anthropic", Price(5.0, 25.0, 0.5, 6.25))
        assertPrice("claude-opus-4.8", "anthropic", Price(5.0, 25.0, 0.5, 6.25))
        assertPrice("anthropic/claude-opus-4.8-fast", "openrouter", Price(10.0, 50.0, 1.0, 12.5))
        assertPrice("claude-opus-4-5-20251101", "anthropic", Price(5.0, 25.0, 0.5, 6.25))
        assertPrice("claude-opus-4-1", "anthropic", Price(15.0, 75.0, 1.5, 18.75))
        assertPrice("claude-haiku-4-5-20251001", "anthropic", Price(1.0, 5.0, 0.1, 1.25))
        assertPrice(
            "claude-sonnet-4-5", "anthropic",
            Price(3.0, 15.0, 0.3, 3.75).above200k(6.0, 22.5, 0.6, 7.5))
    }

    // Port of bundled_price_matches_current_gpt_5_family (:2966-2990).
    @Test func gpt5Family() {
        assertPrice("gpt-5.5", "openai", Price(5.0, 30.0, 0.5, 0.0).above272k(10.0, 45.0, 1.0))
        assertPrice("gpt-5.3-codex", "openai", Price(1.75, 14.0, 0.175, 0.0))
        assertPrice("gpt-5.1-codex-max", "openai", Price(1.25, 10.0, 0.125, 0.0))
        assertPrice("openai/gpt-5.4-mini", "openai", Price(0.75, 4.5, 0.075, 0.0))
        assertPrice("gpt-5.2-pro", "openai", Price(21.0, 168.0, 0.0, 0.0))
        assertPrice("gpt-5-nano", "openai", Price(0.05, 0.4, 0.005, 0.0))
    }

    // Port of bundled_price_matches_current_openai_o_family (:2992-3003).
    @Test func openaiOFamily() {
        assertPrice("o3", "openai", Price(2.0, 8.0, 0.5, 0.0))
        assertPrice("o3-deep-research", "openai", Price(10.0, 40.0, 2.5, 0.0))
        assertPrice("o3-mini", "openai", Price(1.1, 4.4, 0.55, 0.0))
        assertPrice("o3-pro", "openai", Price(20.0, 80.0, 0.0, 0.0))
        assertPrice("o4-mini", "openai", Price(1.1, 4.4, 0.275, 0.0))
    }

    // Port of bundled_price_matches_current_gemini_family (:3005-3022).
    @Test func geminiFamily() {
        assertPrice("gemini-2.5-flash", "google", Price(0.3, 2.5, 0.03, 0.0))
        assertPrice(
            "gemini-3.1-pro-preview", "google",
            Price(2.0, 12.0, 0.2, 0.0).above200k(4.0, 18.0, 0.4, 0.0))
        assertPrice("gemini-3.5-flash", "google", Price(1.5, 9.0, 0.15, 0.0))
    }

    // Port of bundled_price_matches_current_openrouter_free_suffix_models (:3024-3030).
    @Test func openrouterFreeSuffixModels() {
        assertPrice("glm-4.7-free", "opencode", Price(0.6, 2.2, 0.11, 0.0))
        assertPrice("glm-4.7", "opencode", Price(0.6, 2.2, 0.11, 0.0))
        assertPrice("kimi-k2.5-free", "opencode", Price(0.6, 3.0, 0.1, 0.0))
        assertPrice("kimi-k2.5", "opencode", Price(0.6, 3.0, 0.1, 0.0))
    }

    // Port of bundled_price_matches_current_cursor_composer_overrides (:3032-3040).
    @Test func cursorComposerOverrides() {
        assertPrice("composer 1.5", "cursor", Price(3.5, 17.5, 0.35, 0.0))
        assertPrice("composer-2.5-fast", "cursor", Price(1.5, 7.5, 0.35, 0.0))
    }

    // Port of bundled_price_matches_current_grok_family (:3495-3513).
    @Test func grokFamily() {
        assertPrice("grok-4.5", "xai", Price(2.0, 6.0, 0.5, 0.0))
        assertPrice("grok-4.3", "xai", Price(1.25, 2.5, 0.2, 0.0))
        assertPrice("grok-4.1-fast", "xai", Price(0.2, 0.5, 0.05, 0.0))
        assertPrice("grok-4", "xai", Price(3.0, 15.0, 0.75, 0.0))
        assertPrice("xai/grok-unknown", "xai", Price(2.0, 6.0, 0.5, 0.0))
        // Grok-prefixed Composer ids must hit Composer prices, not xAI default.
        assertPrice("grok-composer-2.5", "xai", Price(0.5, 2.5, 0.2, 0.0))
        assertPrice("grok-composer-2.5-fast", "xai", Price(1.5, 7.5, 0.35, 0.0))
    }

    // Port of estimate_cost_splits_tiered_prices (:3042-3055).
    @Test func estimateCostSplitsTieredPrices() {
        let tokens = TokenBreakdown(
            input: 300_000, output: 100_000, cacheRead: 300_000, cacheWrite: 0, reasoning: 0)
        let cost = estimateCost(model: "gpt-5.5", provider: "openai", tokens: tokens)
        // input: 272k*5 + 28k*10, output: 100k*30,
        // cache read: 272k*0.5 + 28k*1, all divided by 1M.
        #expect(abs(cost - 4.804) < 0.000_001)
    }

    @Test func reasoningBilledAtOutputRate() {
        let withReasoning = estimateCost(
            model: "o3", provider: "openai",
            tokens: TokenBreakdown(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 1_000_000))
        let asOutput = estimateCost(
            model: "o3", provider: "openai",
            tokens: TokenBreakdown(input: 0, output: 1_000_000, cacheRead: 0, cacheWrite: 0, reasoning: 0))
        #expect(withReasoning == asOutput)
        #expect(abs(withReasoning - 8.0) < 1e-9)
    }
}

@Suite struct PayloadShapeTests {
    // Port of payload_shape_uses_camel_case_fields (:3147-3173).
    @Test func payloadShapeUsesCamelCaseFields() throws {
        let payload = buildPayload([
            UsageMessage(
                client: "claude", modelId: "claude-sonnet-4", providerId: "anthropic",
                timestampMs: 1_700_000_000_000,
                tokens: TokenBreakdown(
                    input: 10, output: 5, cacheRead: 2, cacheWrite: 1, reasoning: 0),
                cost: 0.01)
        ])
        let data = try JSONEncoder().encode(payload)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The day depends on the local timezone (chrono Local semantics).
        let expectedDate = dateFromTimestampMs(1_700_000_000_000)
        let meta = try #require(root["meta"] as? [String: Any])
        let metaRange = try #require(meta["dateRange"] as? [String: Any])
        #expect(metaRange["start"] as? String == expectedDate)
        let contributions = try #require(root["contributions"] as? [[String: Any]])
        let breakdown = try #require(contributions.first?["tokenBreakdown"] as? [String: Any])
        #expect(breakdown["cacheRead"] as? Int == 2)
        #expect(breakdown["cacheWrite"] as? Int == 1)
        let clients = try #require(contributions.first?["clients"] as? [[String: Any]])
        #expect(clients.first?["modelId"] as? String == "claude-sonnet-4")
        #expect(clients.first?["providerId"] as? String == "anthropic")
        let years = try #require(root["years"] as? [[String: Any]])
        let yearRange = try #require(years.first?["range"] as? [String: Any])
        #expect(yearRange["start"] as? String == expectedDate)
    }
}

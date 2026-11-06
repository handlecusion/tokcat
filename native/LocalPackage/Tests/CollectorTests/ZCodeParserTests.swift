import DataSource
import Foundation
import SQLite3
import Testing

@testable import Collector

// ZCode (Z.ai coding agent): parser over the authoritative model_usage table
// in ~/.zcode/cli/db/db.sqlite, mapped so Tokcat's token total equals ZCode's
// own computed_total_tokens (cache reads are moved out of `input` into
// `cacheRead`).

private func zcodeTempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "tokcat-zcode-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(nowMs())-\(UInt32.random(in: 0..<UInt32.max))"
        )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
private func makeZCodeDatabase(at home: URL, rows: [String]) throws -> URL {
    let dir = home.appendingPathComponent(".zcode/cli/db", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("db.sqlite").path
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    defer { sqlite3_close(db) }
    let schema = """
        CREATE TABLE model_usage (
            id TEXT PRIMARY KEY,
            logical_request_id TEXT,
            provider_id TEXT,
            model_id TEXT,
            status TEXT,
            completed_at INTEGER,
            input_tokens INTEGER,
            output_tokens INTEGER,
            reasoning_tokens INTEGER,
            cache_creation_input_tokens INTEGER,
            cache_read_input_tokens INTEGER,
            computed_total_tokens INTEGER
        );
        """
    guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
        throw CocoaError(.fileWriteUnknown)
    }
    for row in rows {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, row, -1, &statement, nil) == SQLITE_OK else {
            continue
        }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }
    return URL(fileURLWithPath: path)
}

private func zcodeUsageInsert(
    id: String, model: String = "GLM-5.3-Flash", provider: String = "account:zai-start-plan",
    status: String = "completed", completedAt: Int64 = 1_793_289_642_829,
    input: Int64 = 101_653, output: Int64 = 278, reasoning: Int64 = 0,
    cacheWrite: Int64 = 0, cacheRead: Int64 = 99_264, computed: Int64 = 101_931
) -> String {
    """
    INSERT INTO model_usage (id, logical_request_id, provider_id, model_id, status,
        completed_at, input_tokens, output_tokens, reasoning_tokens,
        cache_creation_input_tokens, cache_read_input_tokens, computed_total_tokens)
    VALUES ('\(id)', 'lr-\(id)', '\(provider)', '\(model)', '\(status)',
        \(completedAt), \(input), \(output), \(reasoning), \(cacheWrite), \(cacheRead), \(computed));
    """
}

@Suite struct ZCodeParserTests {
    @Test func parsesUsageWithCacheReadsExcludedFromInput() throws {
        let home = try zcodeTempDir("basic")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeZCodeDatabase(at: home, rows: [
            zcodeUsageInsert(id: "row-1"),
        ])

        let messages = ZCodeParser.parse(cache: nil, home: home.path)
        #expect(messages.count == 1)
        let msg = try #require(messages.first)
        #expect(msg.client == "zcode")
        #expect(msg.modelId == "glm-5.3-flash")
        #expect(msg.providerId == "account:zai-start-plan")
        #expect(msg.timestampMs == 1_793_289_642_829)
        // input is the non-cached portion: 101653 - 99264
        #expect(msg.tokens.input == 2_389)
        #expect(msg.tokens.output == 278)
        #expect(msg.tokens.cacheRead == 99_264)
        // Tokcat's total equals ZCode's computed_total_tokens.
        #expect(msg.tokens.total == 101_931)
        #expect(msg.dedupKey == "zcode:row-1")
    }

    @Test func failedAttemptsWithoutUsageAreDropped() throws {
        let home = try zcodeTempDir("errors")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeZCodeDatabase(at: home, rows: [
            zcodeUsageInsert(id: "err-1", status: "error", input: 0, output: 0,
                             cacheRead: 0, computed: 0),
            zcodeUsageInsert(id: "ok-1"),
        ])

        let messages = ZCodeParser.parse(cache: nil, home: home.path)
        #expect(messages.count == 1)
        #expect(messages.first?.dedupKey == "zcode:ok-1")
    }

    @Test func aggregatesAcrossModelsAndKeepsBothModels() throws {
        let home = try zcodeTempDir("multi")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeZCodeDatabase(at: home, rows: [
            zcodeUsageInsert(id: "flash-1", input: 50_000, output: 500,
                             cacheRead: 40_000, computed: 50_500),
            zcodeUsageInsert(id: "big-1", model: "GLM-5.3", input: 120_000,
                             output: 2_000, cacheRead: 110_000, computed: 122_000),
        ])

        let messages = ZCodeParser.parse(cache: nil, home: home.path)
        #expect(messages.count == 2)
        #expect(Set(messages.map { $0.modelId }) == ["glm-5.3-flash", "glm-5.3"])
        // Totals equal the computed columns: input (inclusive of cache reads)
        // + output. flash-1: 50000 + 500 = 50500; big-1: 120000 + 2000 = 122000.
        #expect(messages.reduce(0) { $0 + $1.tokens.total } == 172_500)
    }

    @Test func apiEstimatesReachExistingTotals() throws {
        let home = try zcodeTempDir("cost")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeZCodeDatabase(at: home, rows: [
            zcodeUsageInsert(id: "flash", model: "  Z-AI/GLM-5.3-Flash  ",
                             input: 1_000_000, output: 200_000, reasoning: 50_000,
                             cacheWrite: 100_000, cacheRead: 600_000, computed: 1_350_000),
            zcodeUsageInsert(id: "big", model: "GLM-5.3", provider: "z.ai",
                             input: 1_000_000, output: 200_000, reasoning: 50_000,
                             cacheWrite: 100_000, cacheRead: 600_000, computed: 1_350_000),
        ])
        let messages = UsageGraph.priceMessages(ZCodeParser.parse(cache: nil, home: home.path))
        let flash = try #require(messages.first { $0.modelId == "z-ai/glm-5.3-flash" })
        #expect(flash.providerId == "account:zai-start-plan")
        #expect(flash.tokens.input == 400_000)
        #expect(flash.tokens.output == 200_000)
        #expect(flash.tokens.reasoning == 50_000)
        #expect(flash.tokens.cacheRead == 600_000)
        #expect(flash.tokens.cacheWrite == 100_000)
        #expect(flash.tokens.total == 1_350_000)
        // Flash: .06 + .125 + .018 + .015; flagship: .56 + 1.1 + .156 + .14.
        #expect(abs(flash.cost - 0.218) < 1e-10)
        let payload = buildPayload(messages)
        #expect(payload.summary.totalTokens == 2_700_000)
        #expect(abs(payload.summary.totalCost - 2.174) < 1e-10)
        let day = try #require(payload.contributions.first)
        #expect(abs(day.totals.cost - 2.174) < 1e-10)
        #expect(abs(day.clients.reduce(0) { $0 + $1.cost } - 2.174) < 1e-10)
        #expect(abs(try #require(payload.years.first).totalCost - 2.174) < 1e-10)
    }

    @Test func pricesAreNormalizedAndProviderScoped() {
        for provider in ["z.ai", "zai", "z-ai", "account:zai-start-plan", " Z.AI "] {
            for model in ["GLM-5.3", "glm_5_3", "z-ai/GLM-5.3"] {
                #expect(bundledPrice(model: model, provider: provider) == Price(1.4, 4.4, 0.26, 1.4))
            }
            #expect(bundledPrice(model: "GLM-5.3-Flash", provider: provider)
                    == Price(0.15, 0.5, 0.03, 0.15))
            // Do not accidentally price FlashX or future variants as Flash/flagship.
            #expect(bundledPrice(model: "GLM-5.3-FlashX", provider: provider) == Price(0, 0, 0, 0))
        }
        #expect(bundledPrice(model: "GLM-5.3", provider: "openai") == Price(1.25, 10, 0.125, 0))
        #expect(bundledPrice(model: "GLM-5.3-Flash", provider: "openrouter") == Price(0, 0, 0, 0))
        #expect(bundledPrice(model: "GLM-4.7", provider: "z.ai") == Price(0.6, 2.2, 0.11, 0))
        #expect(bundledPrice(model: "claude-sonnet-4", provider: "anthropic").cacheWrite == 3.75)
    }

    @Test func missingDatabaseYieldsNothing() throws {
        let home = try zcodeTempDir("empty")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(ZCodeParser.parse(cache: nil, home: home.path).isEmpty)
    }

    @Test func registryIncludesZCode() {
        #expect(UsageGraph.registry.contains { $0.name == "zcode" })
    }
}

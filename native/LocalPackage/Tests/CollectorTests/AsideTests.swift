import DataSource
import Foundation
import Testing

@testable import Collector

// Aside browser: session-JSONL parser, account-dir resolution, and the live
// tailer's aside client.

private func asideTempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "tokcat-aside-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(nowMs())-\(UInt32.random(in: 0..<UInt32.max))"
        )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// One `<home>/u/<account>/sessions/<date>_<id>/messages.jsonl`, plus any
/// sibling files Aside drops in the session's `artifacts/` directory.
@discardableResult
private func writeAsideSession(
    home: URL, account: String = "0",
    session: String = "2026-09-05_jijkIkGUe6UGStD0",
    lines: [String], artifacts: [String: String] = [:]
) throws -> String {
    let dir = home.appendingPathComponent("u").appendingPathComponent(account)
        .appendingPathComponent("sessions").appendingPathComponent(session)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("messages.jsonl").path
    try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    if !artifacts.isEmpty {
        let nested = dir.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for (name, body) in artifacts {
            try body.write(
                toFile: nested.appendingPathComponent(name).path,
                atomically: true, encoding: .utf8)
        }
    }
    return path
}

private func asideAssistantLine(
    responseId: String?, model: String = "claude-sonnet-5",
    provider: String = "claude-code", tsMs: Int64 = 1_788_598_095_439,
    input: Int64 = 10, output: Int64 = 738, cacheRead: Int64 = 12831, cacheWrite: Int64 = 0,
    reasoning: Int64 = 334, cost: Double = 0.0049831
) -> String {
    let response = responseId.map { #","responseId":"\#($0)""# } ?? ""
    return """
        {"role":"assistant","timestamp":\(tsMs),"model":"\(model)",\
        "provider":"\(provider)","api":"anthropic-messages","stopReason":"toolUse",\
        "usage":{"input":\(input),"output":\(output),"cacheRead":\(cacheRead),\
        "cacheWrite":\(cacheWrite),"totalTokens":1,"reasoning":\(reasoning),\
        "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,\
        "total":\(cost)}}\(response)}
        """
}

@Suite struct AsideParserTests {
    @Test func parsesAssistantUsageAndCost() throws {
        let home = try asideTempDir("basic")
        defer { try? FileManager.default.removeItem(at: home) }
        let path = try writeAsideSession(
            home: home,
            lines: [
                #"{"role":"system-message","timestamp":1788598095423,"kind":"site_skill"}"#,
                #"{"role":"user","timestamp":1788598095430,"content":[]}"#,
                asideAssistantLine(responseId: "msg_011Cek18kMj2ssfwPnYTLyf5"),
            ])

        let messages = parseAsideFile(path)
        #expect(messages.count == 1)
        let msg = try #require(messages.first)
        #expect(msg.client == "aside")
        #expect(msg.modelId == "claude-sonnet-5")
        // "claude-code" is a routing account, not a vendor: it prices as
        // Anthropic.
        #expect(msg.providerId == "anthropic")
        #expect(msg.timestampMs == 1_788_598_095_439)
        #expect(msg.tokens.input == 10)
        #expect(msg.tokens.output == 738)
        #expect(msg.tokens.cacheRead == 12831)
        // `usage.reasoning` is a subset of output (totalTokens ==
        // input+output+cacheRead+cacheWrite), so carrying it would bill those
        // 334 tokens twice at the output rate.
        #expect(msg.tokens.reasoning == 0)
        #expect(msg.tokens.total == 10 + 738 + 12831)
        // Aside's own price for the call is authoritative and survives
        // collectMessages, which only estimates when cost <= 0.
        #expect(msg.cost == 0.0049831)
        #expect(msg.dedupKey == "aside:msg_011Cek18kMj2ssfwPnYTLyf5")
    }

    /// Per-call usage values are summed; nothing here is cumulative.
    @Test func sumsEveryAssistantCall() throws {
        let home = try asideTempDir("sum")
        defer { try? FileManager.default.removeItem(at: home) }
        let path = try writeAsideSession(
            home: home,
            lines: [
                asideAssistantLine(responseId: "msg_1", cacheRead: 10790, cacheWrite: 5814),
                asideAssistantLine(responseId: "msg_2", cacheRead: 16604, cacheWrite: 5589),
            ])

        let messages = parseAsideFile(path)
        #expect(messages.count == 2)
        #expect(messages.map(\.tokens.cacheWrite) == [5814, 5589])
        #expect(messages[1].tokens.cacheRead == 16604)
    }

    /// A response with no tokens (an aborted turn) is not a data point;
    /// collectMessages would drop it anyway. Tool results and the transcript's
    /// bookkeeping records carry no usage at all.
    @Test func skipsZeroTokenAndNonAssistantEntries() throws {
        let home = try asideTempDir("skip")
        defer { try? FileManager.default.removeItem(at: home) }
        let path = try writeAsideSession(
            home: home,
            lines: [
                asideAssistantLine(
                    responseId: "msg_zero", input: 0, output: 0,
                    cacheRead: 0, cacheWrite: 0, reasoning: 0),
                #"{"role":"toolResult","toolName":"snapshot","isError":false}"#,
                #"{"role":"assistant","timestamp":1788598095439,"model":"claude-sonnet-5"}"#,
                "not json",
            ])

        #expect(parseAsideFile(path).isEmpty)
    }

    /// Aside-gateway responses carry no price (the plan covers them) and no
    /// vendor id, so both fall through to the bundled table.
    @Test func leavesGatewayCallsToThePricingTable() throws {
        let home = try asideTempDir("gateway")
        defer { try? FileManager.default.removeItem(at: home) }
        let path = try writeAsideSession(
            home: home,
            lines: [
                asideAssistantLine(
                    responseId: "resp_0a8", model: "kimi-k2.7-code", provider: "aside",
                    cost: 0)
            ])

        let messages = parseAsideFile(path)
        #expect(messages.count == 1)
        #expect(messages[0].cost == 0.0)
        #expect(messages[0].providerId == "")
    }

    /// Entries have no id of their own, so a response without a responseId
    /// (which happens on gateway calls) falls back to the content key.
    @Test func leavesDedupKeyUnsetWithoutResponseId() throws {
        let home = try asideTempDir("nodedup")
        defer { try? FileManager.default.removeItem(at: home) }
        let path = try writeAsideSession(
            home: home, lines: [asideAssistantLine(responseId: nil)])

        #expect(parseAsideFile(path).first?.dedupKey == nil)
    }

    /// Routing accounts are mapped onto vendor ids the pricing table keys on;
    /// Aside's own gateway is dropped in favor of model-string inference.
    @Test func mapsProviderIdsPricingUnderstands() {
        #expect(asideProvider("claude-code") == "anthropic")
        #expect(asideProvider("openai-codex") == "openai")
        #expect(asideProvider("Google-Vertex") == "google")
        #expect(asideProvider("aside") == "")
        #expect(asideProvider(nil) == "")
    }

    /// Every signed-in account gets its own sessions root, and the roots are
    /// path-sorted so file order does not depend on the filesystem.
    @Test func enumeratesOneRootPerAccount() throws {
        let home = try asideTempDir("roots")
        defer { try? FileManager.default.removeItem(at: home) }
        try writeAsideSession(
            home: home, account: "1", lines: [asideAssistantLine(responseId: "msg_u1")])
        try writeAsideSession(
            home: home, account: "0", lines: [asideAssistantLine(responseId: "msg_u0")])
        // Not an account dir at all: no sessions/ inside.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("u").appendingPathComponent("scratch"),
            withIntermediateDirectories: true)

        let expected = ["0", "1"].map {
            home.appendingPathComponent("u").appendingPathComponent($0)
                .appendingPathComponent("sessions").path
        }
        #expect(asideSessionRoots(in: [home.path]) == expected)
        // A repeated home must not walk the same transcripts twice.
        #expect(asideSessionRoots(in: [home.path, home.path]) == expected)
    }

    /// TOKCAT_ASIDE_HOMES adds roots on top of ~/.aside, and parse() reads
    /// every account it finds there.
    @Test func parseScansExtraHomes() throws {
        let home = try asideTempDir("extra")
        defer { try? FileManager.default.removeItem(at: home) }
        try writeAsideSession(
            home: home, account: "0", lines: [asideAssistantLine(responseId: "msg_extra_u0")])
        try writeAsideSession(
            home: home, account: "2", lines: [asideAssistantLine(responseId: "msg_extra_u2")])

        setenv("TOKCAT_ASIDE_HOMES", home.path, 1)
        defer { unsetenv("TOKCAT_ASIDE_HOMES") }

        #expect(asideHomes().contains(home.path))
        // A superset assertion: the developer's own ~/.aside may also exist.
        let keys = Set(AsideParser.parse(nil).compactMap(\.dedupKey))
        #expect(keys.isSuperset(of: ["aside:msg_extra_u0", "aside:msg_extra_u2"]))
    }
}

@Suite struct AsideTailerTests {
    @Test func tailsSessionTranscriptsOnly() async throws {
        let home = try asideTempDir("tail")
        defer { try? FileManager.default.removeItem(at: home) }
        let tsMs = nowMs()
        try writeAsideSession(
            home: home.appendingPathComponent(".aside"),
            lines: [
                asideAssistantLine(
                    responseId: "msg_main", model: "claude-sonnet-5-20260101", tsMs: tsMs)
            ],
            // A stray JSONL artifact must not be tailed as a transcript.
            artifacts: ["notes.jsonl": asideAssistantLine(responseId: "msg_artifact", tsMs: tsMs)])

        let tailer = UsageTailer(
            config: UsageTailerConfig(
                simulatedHome: home.path, nowMs: { tsMs }, fullScanIntervalMs: 0))
        let added = await tailer.tick()

        #expect(added == 1)
        let trace = await tailer.trace(windowSecs: 3600)
        #expect(trace.count == 1)
        #expect(trace[0].client == "aside")
        // Aside has no subagents; every event is the main agent.
        #expect(trace[0].agent == "main")
        // The tail's normalize_model strips the trailing date stamp.
        #expect(trace[0].model == "claude-sonnet-5")
        #expect(trace[0].tokens == 10 + 738 + 12831)
    }

    /// Streaming retries repeat a responseId; the ring merges them instead of
    /// double-counting.
    @Test func dedupsRepeatedResponseIds() async throws {
        let home = try asideTempDir("tail-dedup")
        defer { try? FileManager.default.removeItem(at: home) }
        let tsMs = nowMs()
        let path = try writeAsideSession(
            home: home.appendingPathComponent(".aside"),
            lines: [
                asideAssistantLine(responseId: "msg_dup", tsMs: tsMs),
                asideAssistantLine(responseId: "msg_dup", tsMs: tsMs),
            ])
        let size = UInt64(
            try FileManager.default.attributesOfItem(atPath: path)[.size] as! Int)

        let tailer = UsageTailer(config: UsageTailerConfig(nowMs: { tsMs }))
        let added = await tailer.readGrowth(
            path: path, client: .aside, start: 0, end: size, mtimeMs: tsMs)

        #expect(added == 1)
        let trace = await tailer.trace(windowSecs: 3600)
        #expect(trace.count == 1)
        #expect(trace[0].messages == 1)
    }
}

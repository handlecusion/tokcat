import DataSource
import Foundation
import Testing

@testable import Collector

// omnirush: session-JSONL parser, agent-dir resolution, and the live tailer's
// omnirush client. Same engine and entry format as omp, so this suite mirrors
// OmpTests — the differences are the `subagents/` directory, the agent-dir env
// vars, and the missing child-agent name.

private func omnirushTempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "tokcat-omnirush-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(nowMs())-\(UInt32.random(in: 0..<UInt32.max))"
        )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// One `<agent-dir>/sessions/<encoded-cwd>/<timestamp>_<id>.jsonl`, plus the
/// subagent transcripts omnirush writes into the sibling `subagents/` directory.
@discardableResult
private func writeOmnirushSession(
    agentDir: URL, bucket: String = "-tmp-project",
    session: String = "2026-08-16T13-37-53-029Z_01a00acb",
    lines: [String], subagents: [String: [String]] = [:]
) throws -> String {
    let dir = agentDir.appendingPathComponent("sessions").appendingPathComponent(bucket)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("\(session).jsonl").path
    try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    if !subagents.isEmpty {
        let nested = dir.appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for (name, body) in subagents {
            try body.joined(separator: "\n").write(
                toFile: nested.appendingPathComponent("\(name).jsonl").path,
                atomically: true, encoding: .utf8)
        }
    }
    return path
}

private func omnirushAssistantLine(
    id: String, responseId: String?, model: String = "gpt-6-astra",
    provider: String = "omnirush", tsMs: Int64 = 1_786_887_525_273,
    input: Int64 = 2, output: Int64 = 191, cacheRead: Int64 = 0, cacheWrite: Int64 = 42752,
    cost: Double = 0.271985
) -> String {
    let response = responseId.map { #","responseId":"\#($0)""# } ?? ""
    return """
        {"type":"message","id":"\(id)","timestamp":"2026-08-16T13:38:49.429Z","message":\
        {"role":"assistant","provider":"\(provider)","model":"\(model)",\
        "usage":{"input":\(input),"output":\(output),"cacheRead":\(cacheRead),\
        "cacheWrite":\(cacheWrite),"totalTokens":1,"cost":{"input":0,"output":0,\
        "cacheRead":0,"cacheWrite":0,"total":\(cost)}},\
        "timestamp":\(tsMs)\(response)}}
        """
}

@Suite(.serialized) struct OmnirushParserTests {
    @Test func parsesAssistantUsageAndCost() throws {
        let dir = try omnirushTempDir("basic")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try writeOmnirushSession(
            agentDir: dir,
            lines: [
                #"{"type":"session","version":3,"id":"01a00acb","cwd":"/tmp/project"}"#,
                #"{"type":"message","id":"a1","message":{"role":"user","timestamp":1786887525202}}"#,
                omnirushAssistantLine(id: "b2", responseId: "resp_011"),
            ])

        let messages = parseOmnirushFile(path)
        #expect(messages.count == 1)
        let msg = try #require(messages.first)
        #expect(msg.client == "omnirush")
        #expect(msg.modelId == "gpt-6-astra")
        // omnirush's own gateway id is dropped: the model string decides.
        #expect(msg.providerId == "")
        #expect(msg.timestampMs == 1_786_887_525_273)
        #expect(msg.tokens.input == 2)
        #expect(msg.tokens.output == 191)
        #expect(msg.tokens.cacheWrite == 42752)
        #expect(msg.tokens.reasoning == 0)
        // omnirush's own price for the call is authoritative and survives
        // collectMessages, which only estimates when cost <= 0. Its models are
        // absent from the bundled table, so this is the only correct source.
        #expect(msg.cost == 0.271985)
        #expect(msg.dedupKey == "omnirush:resp_011")
    }

    /// Per-call usage values are summed; nothing here is cumulative.
    @Test func sumsEveryAssistantCall() throws {
        let dir = try omnirushTempDir("sum")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try writeOmnirushSession(
            agentDir: dir,
            lines: [
                omnirushAssistantLine(id: "b1", responseId: "resp_1", cacheRead: 0, cacheWrite: 100),
                omnirushAssistantLine(id: "b2", responseId: "resp_2", cacheRead: 100, cacheWrite: 50),
            ])

        let messages = parseOmnirushFile(path)
        #expect(messages.count == 2)
        #expect(messages.map(\.tokens.cacheWrite) == [100, 50])
        #expect(messages[1].tokens.cacheRead == 100)
    }

    /// A response with no tokens is not a data point: an aborted or failed turn
    /// is logged with an all-zero usage object, and collectMessages would drop
    /// it anyway.
    @Test func skipsZeroTokenAndNonAssistantEntries() throws {
        let dir = try omnirushTempDir("skip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try writeOmnirushSession(
            agentDir: dir,
            lines: [
                omnirushAssistantLine(
                    id: "b1", responseId: nil, input: 0, output: 0,
                    cacheRead: 0, cacheWrite: 0),
                #"{"type":"message","id":"c1","message":{"role":"toolResult","toolName":"bash"}}"#,
                #"{"type":"model_change","id":"d1","modelId":"gpt-6-sol"}"#,
                #"{"type":"custom","id":"e1","customType":"omnirush-timing","data":{}}"#,
                "not json",
            ])

        #expect(parseOmnirushFile(path).isEmpty)
    }

    /// Without a responseId the entry id is only unique inside its session, so
    /// the dedup key carries the bucket (and the subagents scope).
    @Test func scopesEntryIdsWhenResponseIdIsMissing() throws {
        let dir = try omnirushTempDir("scope")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try writeOmnirushSession(
            agentDir: dir, lines: [omnirushAssistantLine(id: "b2", responseId: nil)],
            subagents: ["fe761dce": [omnirushAssistantLine(id: "b2", responseId: nil)]])

        let main = parseOmnirushFile(path)
        // omnirush nests subagent transcripts in a `subagents` directory beside
        // the parent session file (omp nests `<sessionId>/<agent>.jsonl`).
        let bucket = (path as NSString).deletingLastPathComponent
        let nested = parseOmnirushFile(
            (bucket as NSString).appendingPathComponent("subagents/fe761dce.jsonl"))
        #expect(main.first?.dedupKey == "omnirush:2026-08-16T13-37-53-029Z_01a00acb:b2")
        #expect(
            nested.first?.dedupKey
                == "omnirush:-tmp-project/subagents/fe761dce:b2")
    }

    /// Entry timestamps are RFC3339 strings; they stand in when the inner
    /// epoch-millis response timestamp is absent.
    @Test func fallsBackToEntryTimestamp() throws {
        let dir = try omnirushTempDir("ts")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try writeOmnirushSession(
            agentDir: dir,
            lines: [
                """
                {"type":"message","id":"b1","timestamp":"2026-08-16T13:38:49.429Z",\
                "message":{"role":"assistant","model":"gpt-6-sol","usage":{"input":10,"output":5}}}
                """
            ])

        let messages = parseOmnirushFile(path)
        #expect(messages.count == 1)
        #expect(messages[0].timestampMs == 1_786_887_529_429)
        // No cost recorded: left at 0 so the bundled price table fills it in.
        #expect(messages[0].cost == 0.0)
        // No provider recorded either; collectMessages infers it.
        #expect(messages[0].providerId == "")
    }

    /// Aggregators route many vendors, so their id is dropped in favor of
    /// model-string inference; omnirush's own gateway is one of them.
    @Test func mapsProviderIdsPricingUnderstands() {
        #expect(omnirushProvider("anthropic") == "anthropic")
        #expect(omnirushProvider("google-vertex") == "google")
        #expect(omnirushProvider("Azure") == "openai")
        #expect(omnirushProvider("omnirush") == "")
        #expect(omnirushProvider(nil) == "")
    }

    /// The whole tree under an agent dir is scanned, subagent transcripts
    /// included, and OMNIRUSH_AGENT_DIR re-roots it.
    @Test func parseScansAgentDirIncludingSubagents() throws {
        let dir = try omnirushTempDir("roots")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeOmnirushSession(
            agentDir: dir,
            lines: [omnirushAssistantLine(id: "b1", responseId: "resp_main")],
            subagents: [
                "fe761dce": [omnirushAssistantLine(id: "b1", responseId: "resp_child")]
            ])

        setenv("OMNIRUSH_AGENT_DIR", dir.path, 1)
        unsetenv("OMNIRUSH_DIR")
        unsetenv("TOKCAT_OMNIRUSH_HOMES")
        defer {
            unsetenv("OMNIRUSH_AGENT_DIR")
        }

        #expect(omnirushSessionRoots() == [dir.appendingPathComponent("sessions").path])
        let keys = Set(OmnirushParser.parse(nil).compactMap(\.dedupKey))
        #expect(keys == ["omnirush:resp_main", "omnirush:resp_child"])
    }

    /// `TOKCAT_OMNIRUSH_HOMES` is the escape hatch when the engine's own
    /// overrides are not visible to the app.
    @Test func extraHomesEnvAppendsAgentDirs() throws {
        let dir = try omnirushTempDir("extra")
        defer { try? FileManager.default.removeItem(at: dir) }

        setenv("TOKCAT_OMNIRUSH_HOMES", "\(dir.path):  :/tmp/other-agent", 1)
        defer { unsetenv("TOKCAT_OMNIRUSH_HOMES") }

        let homes = omnirushAgentHomes()
        #expect(homes.contains(dir.path))
        #expect(homes.contains("/tmp/other-agent"))
        // Blank entries from a trailing or doubled colon are dropped.
        #expect(!homes.contains(""))
    }
}

@Suite(.serialized) struct OmnirushTailerTests {
    @Test func tailsMainAndSubagentTranscripts() async throws {
        let home = try omnirushTempDir("tail")
        defer { try? FileManager.default.removeItem(at: home) }
        let agentDir = home.appendingPathComponent(".omnirush").appendingPathComponent("agent")
        let tsMs = nowMs()
        try writeOmnirushSession(
            agentDir: agentDir,
            lines: [omnirushAssistantLine(id: "b1", responseId: "resp_main", tsMs: tsMs)],
            subagents: [
                "fe761dce": [
                    omnirushAssistantLine(
                        id: "b1", responseId: "resp_child", model: "gpt-6-astra-20260101",
                        tsMs: tsMs, input: 1, output: 9, cacheRead: 0, cacheWrite: 0)
                ]
            ])

        let tailer = UsageTailer(
            config: UsageTailerConfig(
                simulatedHome: home.path, nowMs: { tsMs }, fullScanIntervalMs: 0))
        let added = await tailer.tick()

        #expect(added == 2)
        let trace = await tailer.trace(windowSecs: 3600)
        #expect(trace.count == 2)
        #expect(trace.allSatisfy { $0.client == "omnirush" })
        let main = try #require(trace.first { $0.agent == "main" })
        #expect(main.model == "gpt-6-astra")
        #expect(main.tokens == 2 + 191 + 42752)
        // omnirush never records the child's agent name, so subagent rows share
        // one label instead of omp's `subagent:<name>`.
        let child = try #require(trace.first { $0.agent == "subagent" })
        // The tail's normalize_model strips the trailing date stamp.
        #expect(child.model == "gpt-6-astra")
        #expect(child.tokens == 10)
    }

    /// Streaming retries repeat a responseId; the ring merges them instead of
    /// double-counting.
    @Test func dedupsRepeatedResponseIds() async throws {
        let home = try omnirushTempDir("tail-dedup")
        defer { try? FileManager.default.removeItem(at: home) }
        let agentDir = home.appendingPathComponent(".omnirush").appendingPathComponent("agent")
        let tsMs = nowMs()
        let path = try writeOmnirushSession(
            agentDir: agentDir,
            lines: [
                omnirushAssistantLine(id: "b1", responseId: "resp_dup", tsMs: tsMs),
                omnirushAssistantLine(id: "b2", responseId: "resp_dup", tsMs: tsMs),
            ])
        let size = UInt64(
            try FileManager.default.attributesOfItem(atPath: path)[.size] as! Int)

        let tailer = UsageTailer(config: UsageTailerConfig(nowMs: { tsMs }))
        let added = await tailer.readGrowth(
            path: path, client: .omnirush, start: 0, end: size, mtimeMs: tsMs)

        #expect(added == 1)
        let trace = await tailer.trace(windowSecs: 3600)
        #expect(trace.count == 1)
        #expect(trace[0].messages == 1)
    }
}

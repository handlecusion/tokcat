import DataSource
import Foundation
import Testing

@testable import Collector

// oh-my-pi (omp): session-JSONL parser, agent-dir resolution, and the live
// tailer's omp client.

private func ompTempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "tokcat-omp-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(nowMs())-\(UInt32.random(in: 0..<UInt32.max))"
        )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// One `<agent-dir>/sessions/<encoded-cwd>/<timestamp>_<id>.jsonl`, plus the
/// nested subagent transcripts omp writes beside it.
private func writeOmpSession(
    agentDir: URL, bucket: String = "-tmp-project",
    session: String = "2026-08-16T13-37-53-029Z_01a00acb",
    lines: [String], subagents: [String: [String]] = [:]
) throws -> String {
    let dir = agentDir.appendingPathComponent("sessions").appendingPathComponent(bucket)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("\(session).jsonl").path
    try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    if !subagents.isEmpty {
        let nested = dir.appendingPathComponent(session)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for (name, body) in subagents {
            try body.joined(separator: "\n").write(
                toFile: nested.appendingPathComponent("\(name).jsonl").path,
                atomically: true, encoding: .utf8)
        }
    }
    return path
}

private func ompAssistantLine(
    id: String, responseId: String?, model: String = "claude-opus-5",
    provider: String = "anthropic", tsMs: Int64 = 1_786_887_525_273,
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

@Suite struct OmpParserTests {
    @Test func parsesAssistantUsageAndCost() throws {
        let dir = try ompTempDir("basic")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try writeOmpSession(
            agentDir: dir,
            lines: [
                #"{"type":"session","version":3,"id":"01a00acb","cwd":"/tmp/project"}"#,
                #"{"type":"message","id":"a1","message":{"role":"user","timestamp":1786887525202}}"#,
                ompAssistantLine(id: "b2", responseId: "msg_011"),
            ])

        let messages = parseOmpFile(path)
        #expect(messages.count == 1)
        let msg = try #require(messages.first)
        #expect(msg.client == "omp")
        #expect(msg.modelId == "claude-opus-5")
        #expect(msg.providerId == "anthropic")
        #expect(msg.timestampMs == 1_786_887_525_273)
        #expect(msg.tokens.input == 2)
        #expect(msg.tokens.output == 191)
        #expect(msg.tokens.cacheWrite == 42752)
        #expect(msg.tokens.reasoning == 0)
        // omp's own price for the call is authoritative and survives
        // collectMessages, which only estimates when cost <= 0.
        #expect(msg.cost == 0.271985)
        #expect(msg.dedupKey == "omp:msg_011")
    }

    /// Per-call usage values are summed; nothing here is cumulative.
    @Test func sumsEveryAssistantCall() throws {
        let dir = try ompTempDir("sum")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try writeOmpSession(
            agentDir: dir,
            lines: [
                ompAssistantLine(id: "b1", responseId: "msg_1", cacheRead: 0, cacheWrite: 100),
                ompAssistantLine(id: "b2", responseId: "msg_2", cacheRead: 100, cacheWrite: 50),
            ])

        let messages = parseOmpFile(path)
        #expect(messages.count == 2)
        #expect(messages.map(\.tokens.cacheWrite) == [100, 50])
        #expect(messages[1].tokens.cacheRead == 100)
    }

    /// A response with no tokens (an aborted or refused turn) is not a data
    /// point; collectMessages would drop it anyway.
    @Test func skipsZeroTokenAndNonAssistantEntries() throws {
        let dir = try ompTempDir("skip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try writeOmpSession(
            agentDir: dir,
            lines: [
                ompAssistantLine(
                    id: "b1", responseId: "msg_zero", input: 0, output: 0,
                    cacheRead: 0, cacheWrite: 0),
                #"{"type":"message","id":"c1","message":{"role":"toolResult","toolName":"bash"}}"#,
                #"{"type":"model_change","id":"d1","model":"openai/gpt-5"}"#,
                #"{"type":"custom","id":"e1","customType":"tool_execution_start","data":{}}"#,
                "not json",
            ])

        #expect(parseOmpFile(path).isEmpty)
    }

    /// Without a responseId the entry id is only unique inside its session,
    /// so the dedup key carries the session (and subagent) scope.
    @Test func scopesEntryIdsWhenResponseIdIsMissing() throws {
        let dir = try ompTempDir("scope")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try writeOmpSession(
            agentDir: dir, lines: [ompAssistantLine(id: "b2", responseId: nil)],
            subagents: ["Scout": [ompAssistantLine(id: "b2", responseId: nil)]])

        let main = parseOmpFile(path)
        let nested = parseOmpFile(
            (path as NSString).deletingPathExtension + "/Scout.jsonl")
        #expect(main.first?.dedupKey == "omp:2026-08-16T13-37-53-029Z_01a00acb:b2")
        #expect(
            nested.first?.dedupKey
                == "omp:2026-08-16T13-37-53-029Z_01a00acb/Scout:b2")
    }

    /// Entry timestamps are RFC3339 strings; they stand in when the inner
    /// epoch-millis response timestamp is absent.
    @Test func fallsBackToEntryTimestamp() throws {
        let dir = try ompTempDir("ts")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try writeOmpSession(
            agentDir: dir,
            lines: [
                """
                {"type":"message","id":"b1","timestamp":"2026-08-16T13:38:49.429Z",\
                "message":{"role":"assistant","model":"gpt-5","usage":{"input":10,"output":5}}}
                """
            ])

        let messages = parseOmpFile(path)
        #expect(messages.count == 1)
        #expect(messages[0].timestampMs == 1_786_887_529_429)
        // No cost recorded: left at 0 so the bundled price table fills it in.
        #expect(messages[0].cost == 0.0)
        // No provider recorded either; collectMessages infers it.
        #expect(messages[0].providerId == "")
    }

    /// Aggregators route many vendors, so their id is dropped in favor of
    /// model-string inference.
    @Test func mapsProviderIdsPricingUnderstands() {
        #expect(ompProvider("anthropic") == "anthropic")
        #expect(ompProvider("google-vertex") == "google")
        #expect(ompProvider("Azure") == "openai")
        #expect(ompProvider("openrouter") == "")
        #expect(ompProvider(nil) == "")
    }

    /// The whole tree under an agent dir is scanned, subagent transcripts
    /// included, and PI_CODING_AGENT_DIR re-roots it.
    @Test func parseScansAgentDirIncludingSubagents() throws {
        let dir = try ompTempDir("roots")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeOmpSession(
            agentDir: dir,
            lines: [ompAssistantLine(id: "b1", responseId: "msg_main")],
            subagents: [
                "Scout": [ompAssistantLine(id: "b1", responseId: "msg_scout")]
            ])

        setenv("PI_CODING_AGENT_DIR", dir.path, 1)
        defer { unsetenv("PI_CODING_AGENT_DIR") }

        #expect(ompSessionRoots() == [dir.appendingPathComponent("sessions").path])
        let keys = Set(OmpParser.parse(nil).compactMap(\.dedupKey))
        #expect(keys == ["omp:msg_main", "omp:msg_scout"])
    }
}

@Suite struct OmpTailerTests {
    @Test func tailsMainAndSubagentTranscripts() async throws {
        let home = try ompTempDir("tail")
        defer { try? FileManager.default.removeItem(at: home) }
        let agentDir = home.appendingPathComponent(".omp").appendingPathComponent("agent")
        let tsMs = nowMs()
        _ = try writeOmpSession(
            agentDir: agentDir,
            lines: [ompAssistantLine(id: "b1", responseId: "msg_main", tsMs: tsMs)],
            subagents: [
                "Scout": [
                    ompAssistantLine(
                        id: "b1", responseId: "msg_scout", model: "claude-opus-5-20260101",
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
        #expect(trace.allSatisfy { $0.client == "omp" })
        let main = try #require(trace.first { $0.agent == "main" })
        #expect(main.model == "claude-opus-5")
        #expect(main.tokens == 2 + 191 + 42752)
        let scout = try #require(trace.first { $0.agent == "subagent:Scout" })
        // The tail's normalize_model strips the trailing date stamp.
        #expect(scout.model == "claude-opus-5")
        #expect(scout.tokens == 10)
    }

    /// Streaming retries repeat a responseId; the ring merges them instead of
    /// double-counting.
    @Test func dedupsRepeatedResponseIds() async throws {
        let home = try ompTempDir("tail-dedup")
        defer { try? FileManager.default.removeItem(at: home) }
        let agentDir = home.appendingPathComponent(".omp").appendingPathComponent("agent")
        let tsMs = nowMs()
        let path = try writeOmpSession(
            agentDir: agentDir,
            lines: [
                ompAssistantLine(id: "b1", responseId: "msg_dup", tsMs: tsMs),
                ompAssistantLine(id: "b2", responseId: "msg_dup", tsMs: tsMs),
            ])
        let size = UInt64(
            try FileManager.default.attributesOfItem(atPath: path)[.size] as! Int)

        let tailer = UsageTailer(config: UsageTailerConfig(nowMs: { tsMs }))
        let added = await tailer.readGrowth(
            path: path, client: .omp, start: 0, end: size, mtimeMs: tsMs)

        #expect(added == 1)
        let trace = await tailer.trace(windowSecs: 3600)
        #expect(trace.count == 1)
        #expect(trace[0].messages == 1)
    }
}

import DataSource
import Foundation
import Testing

@testable import Collector

// Pins the cloud-session marker semantics measured by `tokcat-dump cloud-probe`:
// a bridged cloud session is recognizable from its worktree path (`cwd` or the
// project-directory slug), while two cheap-looking substitutes over-match —
// raw substrings hit transcripts that merely print the path, and `cse_`
// bridge ids also appear on ordinary sessions the Claude app bridges locally.

private func makeCloudTempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "tokcat-cloud-\(name)-\(ProcessInfo.processInfo.processIdentifier)"
                + "-\(UInt32.random(in: 0..<UInt32.max))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let cloudWorktreePath = "/Users/dev/repo/.claude/worktrees/bridge-cse_01TSxYxjq9U4HGAkv3TCv8He"

/// A transcript with one assistant usage row (3 input + 5 output tokens).
private func assistantRow(timestamp: String, id: String, requestId: String) -> String {
    """
    {"type":"assistant","timestamp":"\(timestamp)","requestId":"\(requestId)",\
    "message":{"id":"\(id)","model":"claude-opus-5",\
    "usage":{"input_tokens":3,"output_tokens":5,"cache_read_input_tokens":0,\
    "cache_creation_input_tokens":0}}}
    """
}

private func writeTranscript(_ root: URL, slug: String, name: String, lines: [String]) throws
    -> String
{
    let dir = root.appendingPathComponent(".claude/projects/\(slug)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("\(name).jsonl").path
    try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

@Suite struct CloudSessionMarkerTests {
    /// The one shape that is a cloud session: worktree cwd + `cse_` bridge id.
    private func withCloudFixture(_ body: (URL) throws -> Void) throws {
        let root = try makeCloudTempDir("fixture")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeTranscript(
            root,
            slug: "-Users-dev-repo--claude-worktrees-bridge-cse-01TSxYxjq9U4HGAkv3TCv8He",
            name: "cloud",
            lines: [
                #"{"type":"bridge-session","sessionId":"a","bridgeSessionId":"cse_01TSxYxjq9U4HGAkv3TCv8He"}"#,
                #"{"type":"attachment","cwd":"\#(cloudWorktreePath)"}"#,
                assistantRow(timestamp: "2026-08-30T12:00:00.000Z", id: "m1", requestId: "r1"),
            ])
        // A local session that only *prints* the worktree path (git worktree
        // list output) and carries a bridge id without the cloud prefix.
        _ = try writeTranscript(
            root,
            slug: "-Users-dev-repo",
            name: "local-mention",
            lines: [
                #"{"type":"bridge-session","sessionId":"b","bridgeSessionId":"session_014rBZWSJ5KV8TzstZ6pJgdE"}"#,
                #"{"type":"attachment","cwd":"/Users/dev/repo","toolUseResult":"\#(cloudWorktreePath)"}"#,
                assistantRow(timestamp: "2026-08-30T13:00:00.000Z", id: "m2", requestId: "r2"),
            ])
        // A local session the Claude app bridges: `cse_` id, local cwd.
        _ = try writeTranscript(
            root,
            slug: "-Users-dev-other",
            name: "local-bridged",
            lines: [
                #"{"type":"bridge-session","sessionId":"c","bridgeSessionId":"cse_016BWdJQ3gszk8FoVveLLZnJ"}"#,
                #"{"type":"attachment","cwd":"/Users/dev/other"}"#,
                assistantRow(timestamp: "2026-08-30T14:00:00.000Z", id: "m3", requestId: "r3"),
            ])
        try body(root)
    }

    @Test func pathSlugNeedsNoReads() throws {
        try withCloudFixture { root in
            let report = CloudSessionScanner.scan(
                marker: .pathSlug, variant: .noRead, home: root.path)
            #expect(report.transcripts.count == 1)
            #expect(report.transcripts.first?.path.contains("bridge-cse") == true)
            #expect(report.bytesRead == 0)
            #expect(report.totalTokens == 8)
        }
    }

    @Test func cwdFieldIgnoresTranscriptsThatMerelyMentionThePath() throws {
        try withCloudFixture { root in
            for variant in [CloudScanVariant.headSniff, .fullScan] {
                let report = CloudSessionScanner.scan(
                    marker: .cwdField, variant: variant, home: root.path)
                #expect(report.transcripts.count == 1, "variant \(variant)")
                #expect(report.totalTokens == 8, "variant \(variant)")
            }
        }
    }

    @Test func rawSubstringOverMatchesQuotedPaths() throws {
        try withCloudFixture { root in
            let report = CloudSessionScanner.scan(
                marker: .rawSubstring, variant: .fullScan, home: root.path)
            // The `git worktree list` output in the local session counts as a hit.
            #expect(report.transcripts.count == 2)
            #expect(report.totalTokens == 16)
        }
    }

    @Test func bridgeSessionIDOverMatchesLocallyBridgedSessions() throws {
        try withCloudFixture { root in
            let report = CloudSessionScanner.scan(
                marker: .bridgeSessionID, variant: .fullScan, home: root.path)
            // All three sessions carry a bridge id; only one is a cloud session.
            #expect(report.transcripts.count == 3)
            #expect(report.totalTokens == 24)
        }
    }

    /// The head budget decides recall for content markers: a marker that only
    /// appears past the budget is invisible to `.headSniff`.
    @Test func headSniffMissesMarkersBeyondTheBudget() throws {
        let root = try makeCloudTempDir("head-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let padding = String(repeating: "x", count: 4096)
        _ = try writeTranscript(
            root,
            slug: "-Users-dev-repo--claude-worktrees-bridge-cse-01TSxYxjq9U4HGAkv3TCv8He",
            name: "late-marker",
            lines: [
                #"{"type":"attachment","cwd":"/Users/dev/repo","note":"\#(padding)"}"#,
                #"{"type":"attachment","cwd":"\#(cloudWorktreePath)"}"#,
                assistantRow(timestamp: "2026-08-30T12:00:00.000Z", id: "m1", requestId: "r1"),
            ])
        // The slug still finds it with zero reads; the content scan does not
        // once the cwd row sits past the configured head.
        #expect(
            CloudSessionScanner.scan(marker: .pathSlug, variant: .noRead, home: root.path)
                .transcripts.count == 1)
        #expect(
            CloudSessionScanner.scan(
                marker: .cwdField, variant: .headSniff, headBytes: 1024, home: root.path
            ).transcripts.isEmpty)
        #expect(
            CloudSessionScanner.scan(marker: .cwdField, variant: .fullScan, home: root.path)
                .transcripts.count == 1)
    }
}

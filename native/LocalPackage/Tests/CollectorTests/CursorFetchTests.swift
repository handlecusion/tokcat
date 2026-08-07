import Foundation
import Testing

@testable import Collector

// Tests for the opt-in Cursor usage fetcher (cursor_usage.rs port):
// JWT subject extraction, the atomic cache write, and clearCache leaving
// the legacy CSV caches alone.

@Suite struct CursorFetchTests {
    private func tempHome(_ suffix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokcat-cursor-fetch-\(suffix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func jwtSubjectReadsTheSubClaim() throws {
        // Payload {"sub":"user_123"} in base64url without padding.
        let payload = Data(#"{"sub":"user_123"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let sub = try CursorUsageFetcher.jwtSubject("head.\(payload).sig")
        #expect(sub == "user_123")

        #expect(throws: (any Error).self) {
            _ = try CursorUsageFetcher.jwtSubject("no-dots-here")
        }
        #expect(throws: (any Error).self) {
            let empty = Data("{}".utf8).base64EncodedString()
            _ = try CursorUsageFetcher.jwtSubject("head.\(empty).sig")
        }
    }

    @Test func cachePathMatchesTheLegacyDirectory() {
        let path = CursorUsageFetcher.cachePath(home: "/Users/example")
        #expect(path.path
            == "/Users/example/.config/tokscale/cursor-cache/tokcat-events.json")
    }

    @Test func writeCacheIsAtomicAndRoundTrips() throws {
        let home = try tempHome("write")
        defer { try? FileManager.default.removeItem(at: home) }

        let cache = CursorCache(
            fetchedAtMs: 1_781_000_000_000,
            events: [
                CachedCursorEvent(
                    timestampMs: 1_780_000_000_000, model: "claude-4.5-sonnet",
                    inputTokens: 100, outputTokens: 20, cacheReadTokens: 5,
                    cost: 0.42)
            ])
        try CursorUsageFetcher.writeCache(cache, home: home.path)

        let path = CursorUsageFetcher.cachePath(home: home.path)
        let data = try Data(contentsOf: path)
        // Field names must match the Rust serde output the graph parser
        // reads (snake_case).
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["fetched_at_ms"] as? Int64 == 1_781_000_000_000)
        let events = json?["events"] as? [[String: Any]]
        #expect(events?.count == 1)
        #expect(events?[0]["timestamp_ms"] as? Int64 == 1_780_000_000_000)
        #expect(events?[0]["input_tokens"] as? Int64 == 100)
        #expect(events?[0]["cache_read_tokens"] as? Int64 == 5)

        // No tmp file left behind after the rename commit.
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: path.deletingLastPathComponent().path)
        #expect(leftovers == ["tokcat-events.json"])

        // Overwrite goes through the same tmp+rename path.
        try CursorUsageFetcher.writeCache(
            CursorCache(fetchedAtMs: 1, events: []), home: home.path)
        let rewritten = try JSONDecoder().decode(
            CursorCache.self, from: Data(contentsOf: path))
        #expect(rewritten.events.isEmpty)
    }

    @Test func clearCacheLeavesLegacyCSVs() throws {
        let home = try tempHome("clear")
        defer { try? FileManager.default.removeItem(at: home) }

        try CursorUsageFetcher.writeCache(
            CursorCache(fetchedAtMs: 5, events: []), home: home.path)
        let path = CursorUsageFetcher.cachePath(home: home.path)
        let legacyCSV = path.deletingLastPathComponent()
            .appendingPathComponent("usage-2025.csv")
        try Data("old".utf8).write(to: legacyCSV)

        CursorUsageFetcher.clearCache(home: home.path)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        // Legacy CSV caches predate Tokcat and stay untouched.
        #expect(FileManager.default.fileExists(atPath: legacyCSV.path))

        // Clearing again is a no-op, not an error.
        CursorUsageFetcher.clearCache(home: home.path)
    }
}

import Foundation
import Testing

@testable import Collector

// The tick walk is pruned by directory mtime and topped up by re-stat'ing
// recently-touched files. These tests pin what each tier is responsible for,
// and what falls through to the periodic full scan.
struct TailTieredScanTests {
    private func home(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tokcat-tiered-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(nowMs())")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".claude/projects/p"),
            withIntermediateDirectories: true)
        return dir
    }

    private func assistantLine(_ msgId: String, input: Int) -> String {
        """
        {"type":"assistant","requestId":"r-\(msgId)","message":{"id":"\(msgId)","model":"m","usage":{"input_tokens":\(input),"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}

        """
    }

    /// Appending to a file leaves its directory's mtime alone, so the pruned
    /// walk skips that directory — the active-file pass is what carries the
    /// live rate signal between full scans.
    @Test func activeFileGrowthIsSeenOnAPrunedTick() async throws {
        let root = try home("active")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(".claude/projects/p/s.jsonl").path
        try assistantLine("a", input: 10).write(toFile: path, atomically: true,
                                                encoding: .utf8)

        // A long interval means only the cold tick is a full walk; every tick
        // after it is pruned.
        let tailer = UsageTailer(config: UsageTailerConfig(
            simulatedHome: root.path, fullScanIntervalMs: 3_600_000))
        #expect(await tailer.tick() == 1)
        #expect(await tailer.activeFiles[path] != nil)

        let handle = FileHandle(forWritingAtPath: path)!
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(assistantLine("b", input: 20).utf8))
        try handle.close()

        #expect(await tailer.tick() == 1)
        #expect(await tailer.eventsSnapshot().map(\.input) == [10, 20])
    }

    /// Creating a file DOES move its directory's mtime, so a brand-new session
    /// must not wait for the full scan — this is the common case (a new agent
    /// run) and the one a 60s delay would be felt in.
    @Test func newFileIsFoundOnAPrunedTick() async throws {
        let root = try home("newfile")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(".claude/projects/p")

        let tailer = UsageTailer(config: UsageTailerConfig(
            simulatedHome: root.path, fullScanIntervalMs: 3_600_000))
        #expect(await tailer.tick() == 0)  // cold, empty

        try assistantLine("fresh", input: 33).write(
            toFile: dir.appendingPathComponent("new.jsonl").path,
            atomically: true, encoding: .utf8)

        #expect(await tailer.tick() == 1)
        #expect(await tailer.eventsSnapshot().map(\.input) == [33])
    }

    /// A whole new project directory appears under the root, which is always
    /// walked — so the nested file is found without a full scan too.
    @Test func newDirectoryIsFoundOnAPrunedTick() async throws {
        let root = try home("newdir")
        defer { try? FileManager.default.removeItem(at: root) }

        let tailer = UsageTailer(config: UsageTailerConfig(
            simulatedHome: root.path, fullScanIntervalMs: 3_600_000))
        #expect(await tailer.tick() == 0)

        let fresh = root.appendingPathComponent(".claude/projects/q/deeper")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try assistantLine("nested", input: 44).write(
            toFile: fresh.appendingPathComponent("s.jsonl").path,
            atomically: true, encoding: .utf8)

        #expect(await tailer.tick() == 1)
        #expect(await tailer.eventsSnapshot().map(\.input) == [44])
    }

    /// The documented gap: a file idle longer than the active window drops off
    /// the watch list, and growth in it waits for the next unpruned walk. The
    /// delta is delayed, never lost — readGrowth resumes from the stored
    /// offset, so the event still carries its full token counts.
    @Test func dormantFileGrowthWaitsForTheFullScan() async throws {
        let root = try home("dormant")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(".claude/projects/p/old.jsonl").path
        try assistantLine("seed", input: 1).write(toFile: path, atomically: true,
                                                  encoding: .utf8)

        // In production the full scan (60s) comes round long before the active
        // window (600s) expires, so the dormant gap is capped at 60s and can't
        // be isolated. Stretch the interval here to exercise the gap itself.
        let fullScanIntervalMs: Int64 = 3_600_000
        let clock = TieredClock(now: nowMs())
        let tailer = UsageTailer(config: UsageTailerConfig(
            simulatedHome: root.path, nowMs: { clock.value },
            fullScanIntervalMs: fullScanIntervalMs))
        #expect(await tailer.tick() == 1)

        // Push the clock past the active window and tick once: the file is
        // still stat'd (it was on the watch list going in), finds no growth,
        // and drops off on the way out.
        clock.value += (activeFileWindowSecs + 60) * 1000
        #expect(await tailer.tick() == 0)
        #expect(await tailer.activeFiles[path] == nil)

        // Now it is genuinely dormant. Appending moves the file's mtime but
        // not its directory's, so the pruned walk skips the directory and
        // nothing re-stats the file.
        let handle = FileHandle(forWritingAtPath: path)!
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(assistantLine("late", input: 99).utf8))
        try handle.close()
        #expect(await tailer.tick() == 0)

        // Next full scan picks the growth up in full.
        clock.value += fullScanIntervalMs
        #expect(await tailer.tick() == 1)
        // The seed event has aged out of the 1h ring by now; what matters is
        // that the deferred delta arrives whole rather than truncated.
        #expect(await tailer.eventsSnapshot().map(\.input) == [99])
    }

    /// A file deleted out from under the active pass must not wedge the tick.
    @Test func deletedActiveFileIsDroppedQuietly() async throws {
        let root = try home("deleted")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(".claude/projects/p/gone.jsonl").path
        try assistantLine("x", input: 5).write(toFile: path, atomically: true,
                                               encoding: .utf8)

        let tailer = UsageTailer(config: UsageTailerConfig(
            simulatedHome: root.path, fullScanIntervalMs: 3_600_000))
        #expect(await tailer.tick() == 1)
        #expect(await tailer.activeFiles[path] != nil)

        try FileManager.default.removeItem(atPath: path)
        #expect(await tailer.tick() == 0)
        #expect(await tailer.activeFiles[path] == nil)
    }

    /// Pruning must not double-count: when a directory IS revisited, the file
    /// it yields is also on the active list, and only one of the two paths may
    /// read the growth.
    @Test func walkAndActivePassDoNotDoubleRead() async throws {
        let root = try home("dedup")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(".claude/projects/p")
        let path = dir.appendingPathComponent("s.jsonl").path
        try assistantLine("a", input: 10).write(toFile: path, atomically: true,
                                                encoding: .utf8)

        let tailer = UsageTailer(config: UsageTailerConfig(
            simulatedHome: root.path, fullScanIntervalMs: 3_600_000))
        #expect(await tailer.tick() == 1)

        // Grow the tracked file AND add a sibling, so the directory's mtime
        // moves and the walk descends into it on the same tick.
        let handle = FileHandle(forWritingAtPath: path)!
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(assistantLine("b", input: 20).utf8))
        try handle.close()
        try assistantLine("c", input: 30).write(
            toFile: dir.appendingPathComponent("sibling.jsonl").path,
            atomically: true, encoding: .utf8)

        #expect(await tailer.tick() == 2)
        #expect(await tailer.eventsSnapshot().map(\.input).sorted() == [10, 20, 30])
    }
}

/// Mutable clock for the tiered-scan tests (@unchecked: single-threaded use).
private final class TieredClock: @unchecked Sendable {
    var value: Int64
    init(now: Int64) { value = now }
}

import Foundation
import Testing

@testable import Collector

// The getattrlistbulk decoder hand-parses packed kernel records, so the
// contract it must hold is "identical to readdir + lstat" — that is what the
// tailer's growth detection was built on.
struct DirScanTests {
    private func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tokcat-dirscan-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(nowMs())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func bulkScanMatchesReaddirAndLstat() throws {
        let dir = try tempDir("mixed")
        defer { try? FileManager.default.removeItem(at: dir) }

        try "hello".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true,
                          encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("empty.jsonl"), atomically: true,
                     encoding: .utf8)
        // A long name pushes the record past one 8-byte alignment boundary.
        try String(repeating: "x", count: 4096).write(
            to: dir.appendingPathComponent(String(repeating: "n", count: 120) + ".jsonl"),
            atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link.jsonl"),
            withDestinationURL: dir.appendingPathComponent("a.jsonl"))

        let bulk = scanDirectory(dir.path).sorted { $0.name < $1.name }
        let fallback = scanDirectoryForTesting(dir.path, forceFallback: true)
            .sorted { $0.name < $1.name }

        #expect(bulk == fallback)
        #expect(bulk.count == 5)

        let byName = Dictionary(uniqueKeysWithValues: bulk.map { ($0.name, $0) })
        #expect(byName["a.jsonl"]?.isRegular == true)
        #expect(byName["a.jsonl"]?.size == 5)
        #expect(byName["empty.jsonl"]?.size == 0)
        #expect(byName["sub"]?.isDir == true)
        // A symlink must be described as itself, not its target: the tailer
        // relies on not following links.
        #expect(byName["link.jsonl"]?.isDir == false)
        #expect(byName["link.jsonl"]?.isRegular == false)
    }

    @Test func mtimeSurvivesTheRoundTrip() throws {
        let dir = try tempDir("mtime")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: stamp], ofItemAtPath: file.path)

        let entry = scanDirectory(dir.path).first { $0.name == "s.jsonl" }
        #expect(entry?.mtimeMs == 1_700_000_000_000)
        #expect(entry?.mtimeNs == 1_700_000_000_000_000_000)
    }

    // Growth must be visible on the very next scan — this is the signal the
    // 5s tick reads.
    @Test func sizeReflectsAppendedBytes() throws {
        let dir = try tempDir("growth")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("g.jsonl").path
        try "abc".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(scanDirectory(dir.path).first { $0.name == "g.jsonl" }?.size == 3)

        let handle = FileHandle(forWritingAtPath: path)!
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("defg".utf8))
        try handle.close()
        #expect(scanDirectory(dir.path).first { $0.name == "g.jsonl" }?.size == 7)
    }

    @Test func unreadableDirectoryScansEmpty() throws {
        #expect(scanDirectory("/nope/does/not/exist").isEmpty)
    }

    @Test func manyEntriesSpanMultipleBulkCalls() throws {
        let dir = try tempDir("many")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Comfortably more entries than one 64K buffer holds in a single
        // getattrlistbulk call, so the resume path is exercised.
        for i in 0..<1500 {
            try "\(i)".write(to: dir.appendingPathComponent("f\(i).jsonl"),
                             atomically: true, encoding: .utf8)
        }
        let bulk = scanDirectory(dir.path).sorted { $0.name < $1.name }
        let fallback = scanDirectoryForTesting(dir.path, forceFallback: true)
            .sorted { $0.name < $1.name }
        #expect(bulk.count == 1500)
        #expect(bulk == fallback)
    }
}

struct JSONLExtensionTests {
    // The tailer's hot loop uses hasJSONLExtension in place of
    // rustExtension(path) == "jsonl"; they must agree on every name.
    @Test(arguments: [
        "a.jsonl", "session.jsonl", ".jsonl", "jsonl", "a.jsonl.gz", "a.json",
        "x.JSONL", ".hidden.jsonl", "a.b.jsonl", "", ".", "..", "updates.jsonl",
    ])
    func matchesRustExtension(name: String) {
        #expect(hasJSONLExtension(name) == (rustExtension(name) == "jsonl"))
    }
}

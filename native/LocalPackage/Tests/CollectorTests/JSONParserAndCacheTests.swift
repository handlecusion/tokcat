import DataSource
import Foundation
import Testing

@testable import Collector

// The byte-level JSON parser must mirror `serde_json::from_str::<Value>`
// exactly (every case below was verified against serde_json 1.x), because
// the Rust side of the parity harness parses with serde.
@Suite struct SerdeJSONParserTests {
    @Test func integerVsDoubleClassification() throws {
        if case .int(0) = try #require(JSONValue.parse("0")) {} else {
            Issue.record("0 should be int")
        }
        // u64 above i64::MAX is stored bit-pattern-wrapped.
        #expect(JSONValue.parse("18446744073709551615").flatMap(i64Value) == -1)
        if case .double = try #require(JSONValue.parse("18446744073709551616")) {} else {
            Issue.record("u64::MAX+1 should fall back to double")
        }
        #expect(JSONValue.parse("-9223372036854775808").flatMap(i64Value) == Int64.min)
        if case .double = try #require(JSONValue.parse("-9223372036854775809")) {} else {
            Issue.record("i64::MIN-1 should fall back to double")
        }
        // serde_json parses "-0" as f64 -0.0, not integer zero.
        guard case .double(let negZero) = try #require(JSONValue.parse("-0")) else {
            Issue.record("-0 should be double")
            return
        }
        #expect(negZero == 0.0 && negZero.sign == .minus)
        #expect(f64Value(JSONValue.parse("1E5")) == 100_000.0)
        #expect(f64Value(JSONValue.parse("0.5e+3")) == 500.0)
    }

    @Test func numberGrammarErrors() {
        // Everything serde_json rejects must come back nil.
        for bad in ["01", "1.", ".5", "+1", "1e", "1e999", "2e308", "NaN", "Infinity", "-"] {
            #expect(JSONValue.parse(bad) == nil, "\(bad) should not parse")
        }
        // ...but f64::MAX territory still parses.
        #expect(f64Value(JSONValue.parse("1.5e308")) == 1.5e308)
    }

    @Test func stringEscapes() throws {
        #expect(JSONValue.parse(#""A\n\t\b\f\/\\\"""#)?.asString == "A\n\t\u{08}\u{0C}/\\\"")
        #expect(JSONValue.parse(#""a\u0000b""#)?.asString == "a\u{0}b")
        // Surrogate pairs combine; lone surrogates are errors (serde strict).
        #expect(JSONValue.parse(#""😀""#)?.asString == "😀")
        #expect(JSONValue.parse(#""\ud800""#) == nil)
        #expect(JSONValue.parse(#""\ude00""#) == nil)
        #expect(JSONValue.parse(#""\ud83dx""#) == nil)
        #expect(JSONValue.parse(#""\x""#) == nil)
        // Raw control characters in strings are errors.
        #expect(JSONValue.parse("\"tab\tchar\"") == nil)
        #expect(JSONValue.parse("\"unterminated") == nil)
    }

    @Test func structureAndTrailingRules() throws {
        // Duplicate keys: last one wins.
        #expect(i64Value(JSONValue.parse(#"{"a":1,"a":2}"#)?["a"]) == 2)
        // Fragments parse at top level; trailing non-whitespace is an error.
        #expect(JSONValue.parse(" true ") == JSONValue.bool(true))
        #expect(JSONValue.parse("truex") == nil)
        #expect(JSONValue.parse("{}x") == nil)
        #expect(JSONValue.parse("[1,2,]") == nil)
        #expect(JSONValue.parse("") == nil)
        #expect(JSONValue.parse("   ") == nil)
        // serde_json's recursion limit: 127 nested containers parse, 128 fail.
        let ok = String(repeating: "[", count: 127) + String(repeating: "]", count: 127)
        let deep = String(repeating: "[", count: 128) + String(repeating: "]", count: 128)
        #expect(JSONValue.parse(ok) != nil)
        #expect(JSONValue.parse(deep) == nil)
    }

    @Test func invalidUTF8DataRejected() {
        #expect(JSONValue.parse(Data([0x22, 0xFF, 0x22])) == nil)
        // Overlong encoding and lone continuation bytes.
        #expect(JSONValue.parse(Data([0x22, 0xC0, 0xAF, 0x22])) == nil)
        #expect(JSONValue.parse(Data([0x80])) == nil)
        // Valid multi-byte UTF-8 passes through.
        #expect(JSONValue.parse(Data(#""héllo👋""#.utf8))?.asString == "héllo👋")
    }
}

@Suite struct JSONLLineIterationTests {
    private func lines(_ data: Data) -> [String] {
        var out: [String] = []
        forEachJSONLLine(data) { out.append(String(decoding: $0, as: UTF8.self)) }
        return out
    }

    @Test func matchesBufReadLinesSemantics() {
        #expect(lines(Data("a\nb".utf8)) == ["a", "b"])
        #expect(lines(Data("a\r\nb\n".utf8)) == ["a", "b"])
        #expect(lines(Data("a\n\nb".utf8)) == ["a", "", "b"])
        #expect(lines(Data("\n\n".utf8)) == ["", ""])
        #expect(lines(Data()) == [])
        // Stops at the first invalid-UTF-8 line, like map_while(Result::ok).
        var bad = Data("ok\n".utf8)
        bad.append(contentsOf: [0xFF, 0xFE])
        bad.append(contentsOf: Data("\nafter".utf8))
        #expect(lines(bad) == ["ok"])
    }

    @Test func trimmedLineParsing() {
        var value: JSONValue?
        forEachJSONLLine(Data("  {\"a\": 1}  \n".utf8)) { value = parseTrimmedJSONLine($0) }
        #expect(i64Value(value?["a"]) == 1)
        // Non-ASCII whitespace at the edges takes the rustTrim fallback.
        forEachJSONLLine(Data("\u{00A0}{\"a\": 2}\u{00A0}\n".utf8)) {
            value = parseTrimmedJSONLine($0)
        }
        #expect(i64Value(value?["a"]) == 2)
        forEachJSONLLine(Data("   \n".utf8)) { value = parseTrimmedJSONLine($0) }
        #expect(value == nil)
    }
}

@Suite struct UsageCacheTests {
    private func withTempDir(_ body: (String) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tokcat-cache-\(ProcessInfo.processInfo.processIdentifier)-\(nowMs())-\(UInt32.random(in: 0..<UInt32.max))"
            ).path
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try body(dir)
    }

    private func message(_ model: String) -> UsageMessage {
        UsageMessage(
            client: "test", modelId: model, providerId: "p",
            timestampMs: 1_700_000_000_000,
            tokens: TokenBreakdown(
                input: 1, output: 1, cacheRead: 0, cacheWrite: 0, reasoning: 0),
            cost: 0.0)
    }

    @Test func unchangedFileParsesOnce() throws {
        try withTempDir { dir in
            let path = joinPath(dir, "a.jsonl")
            try "x".write(toFile: path, atomically: true, encoding: .utf8)
            let cache = UsageCache()
            let expected = [message("m1")]

            cache.beginRun()
            let first = cache.messages(for: path) { _ in expected }
            cache.endRun()
            cache.beginRun()
            let second = cache.messages(for: path) { _ in
                Issue.record("unchanged file must not re-parse")
                return []
            }
            cache.endRun()

            #expect(cache.missCount == 1)
            #expect(first.map(\.modelId) == ["m1"])
            #expect(second.map(\.modelId) == ["m1"])
        }
    }

    @Test func changedFileReparses() throws {
        try withTempDir { dir in
            let path = joinPath(dir, "a.jsonl")
            try "x".write(toFile: path, atomically: true, encoding: .utf8)
            let cache = UsageCache()
            _ = cache.messages(for: path) { _ in [self.message("v1")] }
            // Size change guarantees a key change even within one mtime tick.
            try "xy".write(toFile: path, atomically: true, encoding: .utf8)
            let after = cache.messages(for: path) { _ in [self.message("v2")] }
            #expect(cache.missCount == 2)
            #expect(after.map(\.modelId) == ["v2"])
        }
    }

    @Test func vanishedFileIsEvicted() throws {
        try withTempDir { dir in
            let path = joinPath(dir, "a.jsonl")
            try "x".write(toFile: path, atomically: true, encoding: .utf8)
            let cache = UsageCache()
            cache.beginRun()
            _ = cache.messages(for: path) { _ in [self.message("m")] }
            cache.endRun()
            #expect(cache.entryCount == 1)

            try FileManager.default.removeItem(atPath: path)
            cache.beginRun()  // scan no longer sees the file
            cache.endRun()
            #expect(cache.entryCount == 0)
        }
    }

    @Test func parseFilesInOrderPreservesPathOrder() throws {
        try withTempDir { dir in
            var files: [String] = []
            for i in 0..<20 {
                let path = joinPath(dir, String(format: "f%02d.jsonl", i))
                try "x".write(toFile: path, atomically: true, encoding: .utf8)
                files.append(path)
            }
            // Concurrent parse must concatenate in the given order — the
            // downstream dedup is first-wins across that order.
            let expected = files.map { rustFileStem($0) ?? "" }
            for cache in [nil, UsageCache()] {
                let out = parseFilesInOrder(files, cache: cache) { path in
                    [
                        UsageMessage(
                            client: "test", modelId: rustFileStem(path) ?? "",
                            providerId: "p", timestampMs: 1_700_000_000_000,
                            tokens: TokenBreakdown(
                                input: 1, output: 0, cacheRead: 0, cacheWrite: 0,
                                reasoning: 0),
                            cost: 0.0)
                    ]
                }
                #expect(out.map(\.modelId) == expected)
            }
        }
    }
}

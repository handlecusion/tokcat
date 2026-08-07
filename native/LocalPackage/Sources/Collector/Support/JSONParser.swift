import Foundation

// Byte-level JSON parser producing JSONValue directly, replacing the old
// JSONSerialization + fromFoundation double materialization (which cost
// ~10x the CPU of serde_json on multi-GB JSONL scans).
//
// Semantics mirror `serde_json::from_str::<Value>` — the parser the Rust
// side of the parity harness uses — verified against serde_json 1.x:
// - Integers fitting u64/i64 stay integers; u64 above i64::MAX is stored
//   bit-pattern-wrapped (matching the `n.as_u64().map(|v| v as i64)` wrap
//   the lenient helpers rely on). Everything else parses as f64.
// - "-0"/"-0.0" are f64 (-0.0), leading zeros are errors, "1." / ".5" /
//   "+1" / "1e" are errors, literals overflowing f64 ("1e999") are errors.
// - Strings reject raw control characters and lone surrogate escapes;
//   "😀" pairs combine; the "backslash-u0000" escape is fine.
// - Duplicate object keys: last one wins.
// - Trailing non-whitespace after the top-level value is an error; JSON
//   whitespace (space, \t, \n, \r) is skipped around tokens.
// - Containers nest at most 127 deep (serde_json's recursion limit: 127
//   opens parse, 128 fail).
// - Input must be valid UTF-8 (from_str takes &str). Callers pass
//   `assumeValidUTF8: true` only for byte ranges already validated.

private let jsonMaxDepth = 127

extension JSONValue {
    static func parse(_ text: String) -> JSONValue? {
        var s = text
        return s.withUTF8 { parseSerdeJSON($0, assumeValidUTF8: true) }
    }

    static func parse(_ data: Data) -> JSONValue? {
        data.withUnsafeBytes { raw in
            parseSerdeJSON(raw.bindMemory(to: UInt8.self), assumeValidUTF8: false)
        }
    }
}

/// Parse one JSON document covering the whole buffer (leading/trailing JSON
/// whitespace allowed). Returns nil on any error, like `from_str(...).ok()`.
func parseSerdeJSON(
    _ bytes: UnsafeBufferPointer<UInt8>, assumeValidUTF8: Bool
) -> JSONValue? {
    if !assumeValidUTF8, !validUTF8(bytes) { return nil }
    var p = SerdeJSONParser(b: bytes)
    guard let value = p.parseValue() else { return nil }
    p.skipWhitespace()
    guard p.i == bytes.count else { return nil }
    return value
}

/// Streaming UTF-8 validator (no allocation), word-at-a-time ASCII fast path.
func validUTF8(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
    let n = b.count
    guard let base = b.baseAddress else { return true }
    var i = 0
    while i < n {
        // ASCII fast path: 8 bytes at a time.
        if n - i >= 8 {
            let word = UnsafeRawPointer(base + i).loadUnaligned(as: UInt64.self)
            if word & 0x8080_8080_8080_8080 == 0 {
                i += 8
                continue
            }
        }
        let c = base[i]
        if c < 0x80 {
            i += 1
        } else if c < 0xC2 {
            return false  // continuation byte or overlong 2-byte lead
        } else if c < 0xE0 {
            guard i + 1 < n, base[i + 1] & 0xC0 == 0x80 else { return false }
            i += 2
        } else if c < 0xF0 {
            guard i + 2 < n else { return false }
            let c1 = base[i + 1], c2 = base[i + 2]
            guard c1 & 0xC0 == 0x80, c2 & 0xC0 == 0x80 else { return false }
            if c == 0xE0, c1 < 0xA0 { return false }  // overlong
            if c == 0xED, c1 >= 0xA0 { return false }  // surrogate
            i += 3
        } else if c < 0xF5 {
            guard i + 3 < n else { return false }
            let c1 = base[i + 1], c2 = base[i + 2], c3 = base[i + 3]
            guard c1 & 0xC0 == 0x80, c2 & 0xC0 == 0x80, c3 & 0xC0 == 0x80 else {
                return false
            }
            if c == 0xF0, c1 < 0x90 { return false }  // overlong
            if c == 0xF4, c1 >= 0x90 { return false }  // > U+10FFFF
            i += 4
        } else {
            return false
        }
    }
    return true
}

private struct SerdeJSONParser {
    let b: UnsafeBufferPointer<UInt8>
    var i = 0
    var depth = 0

    mutating func skipWhitespace() {
        while i < b.count {
            let c = b[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                i += 1
            } else {
                break
            }
        }
    }

    mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard i < b.count else { return nil }
        switch b[i] {
        case UInt8(ascii: "{"): return parseObject()
        case UInt8(ascii: "["): return parseArray()
        case UInt8(ascii: "\""): return parseString().map(JSONValue.string)
        case UInt8(ascii: "t"):
            return consume("true") ? .bool(true) : nil
        case UInt8(ascii: "f"):
            return consume("false") ? .bool(false) : nil
        case UInt8(ascii: "n"):
            return consume("null") ? JSONValue.null : nil
        case UInt8(ascii: "-"), 0x30...0x39:
            return parseNumber()
        default:
            return nil
        }
    }

    mutating func consume(_ literal: StaticString) -> Bool {
        let n = literal.utf8CodeUnitCount
        guard i + n <= b.count else { return false }
        let start = literal.utf8Start
        for k in 0..<n where b[i + k] != start[k] { return false }
        i += n
        return true
    }

    mutating func parseObject() -> JSONValue? {
        depth += 1
        defer { depth -= 1 }
        guard depth <= jsonMaxDepth else { return nil }
        i += 1  // '{'
        var obj: [String: JSONValue] = [:]
        skipWhitespace()
        if i < b.count, b[i] == UInt8(ascii: "}") {
            i += 1
            return .object(obj)
        }
        while true {
            skipWhitespace()
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { return nil }
            guard let key = parseString() else { return nil }
            skipWhitespace()
            guard i < b.count, b[i] == UInt8(ascii: ":") else { return nil }
            i += 1
            guard let value = parseValue() else { return nil }
            obj[key] = value  // last duplicate wins, like serde_json
            skipWhitespace()
            guard i < b.count else { return nil }
            switch b[i] {
            case UInt8(ascii: ","):
                i += 1
            case UInt8(ascii: "}"):
                i += 1
                return .object(obj)
            default:
                return nil
            }
        }
    }

    mutating func parseArray() -> JSONValue? {
        depth += 1
        defer { depth -= 1 }
        guard depth <= jsonMaxDepth else { return nil }
        i += 1  // '['
        var items: [JSONValue] = []
        skipWhitespace()
        if i < b.count, b[i] == UInt8(ascii: "]") {
            i += 1
            return .array(items)
        }
        while true {
            guard let value = parseValue() else { return nil }
            items.append(value)
            skipWhitespace()
            guard i < b.count else { return nil }
            switch b[i] {
            case UInt8(ascii: ","):
                i += 1
            case UInt8(ascii: "]"):
                i += 1
                return .array(items)
            default:
                return nil
            }
        }
    }

    mutating func parseString() -> String? {
        i += 1  // opening quote
        let start = i
        // Fast path: no escapes, no control chars.
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") {
                let s = String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
                i += 1
                return s
            }
            if c == UInt8(ascii: "\\") { break }
            if c < 0x20 { return nil }  // raw control character: error
            i += 1
        }
        guard i < b.count else { return nil }
        // Slow path: copy scanned prefix, process escapes.
        var out = [UInt8](b[start..<i])
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                return String(decoding: out, as: UTF8.self)
            }
            if c < 0x20 { return nil }
            if c != UInt8(ascii: "\\") {
                out.append(c)
                i += 1
                continue
            }
            i += 1
            guard i < b.count else { return nil }
            switch b[i] {
            case UInt8(ascii: "\""): out.append(UInt8(ascii: "\"")); i += 1
            case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\")); i += 1
            case UInt8(ascii: "/"): out.append(UInt8(ascii: "/")); i += 1
            case UInt8(ascii: "b"): out.append(0x08); i += 1
            case UInt8(ascii: "f"): out.append(0x0C); i += 1
            case UInt8(ascii: "n"): out.append(UInt8(ascii: "\n")); i += 1
            case UInt8(ascii: "r"): out.append(UInt8(ascii: "\r")); i += 1
            case UInt8(ascii: "t"): out.append(UInt8(ascii: "\t")); i += 1
            case UInt8(ascii: "u"):
                i += 1
                guard let first = parseHex4() else { return nil }
                var scalarValue = UInt32(first)
                if first >= 0xD800, first <= 0xDBFF {
                    // High surrogate: must pair with \uDC00-\uDFFF.
                    guard i + 1 < b.count, b[i] == UInt8(ascii: "\\"),
                        b[i + 1] == UInt8(ascii: "u")
                    else { return nil }
                    i += 2
                    guard let low = parseHex4(), low >= 0xDC00, low <= 0xDFFF else {
                        return nil
                    }
                    scalarValue =
                        0x10000 + ((UInt32(first) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                } else if first >= 0xDC00, first <= 0xDFFF {
                    return nil  // lone trailing surrogate
                }
                appendUTF8(&out, scalarValue)
            default:
                return nil  // invalid escape
            }
        }
        return nil  // unterminated
    }

    mutating func parseHex4() -> UInt16? {
        guard i + 4 <= b.count else { return nil }
        var v: UInt16 = 0
        for _ in 0..<4 {
            let c = b[i]
            let d: UInt16
            switch c {
            case 0x30...0x39: d = UInt16(c - 0x30)
            case 0x41...0x46: d = UInt16(c - 0x41 + 10)
            case 0x61...0x66: d = UInt16(c - 0x61 + 10)
            default: return nil
            }
            v = v << 4 | d
            i += 1
        }
        return v
    }

    func appendUTF8(_ out: inout [UInt8], _ scalar: UInt32) {
        switch scalar {
        case 0..<0x80:
            out.append(UInt8(scalar))
        case 0x80..<0x800:
            out.append(UInt8(0xC0 | scalar >> 6))
            out.append(UInt8(0x80 | scalar & 0x3F))
        case 0x800..<0x10000:
            out.append(UInt8(0xE0 | scalar >> 12))
            out.append(UInt8(0x80 | scalar >> 6 & 0x3F))
            out.append(UInt8(0x80 | scalar & 0x3F))
        default:
            out.append(UInt8(0xF0 | scalar >> 18))
            out.append(UInt8(0x80 | scalar >> 12 & 0x3F))
            out.append(UInt8(0x80 | scalar >> 6 & 0x3F))
            out.append(UInt8(0x80 | scalar & 0x3F))
        }
    }

    mutating func parseNumber() -> JSONValue? {
        let start = i
        var negative = false
        if b[i] == UInt8(ascii: "-") {
            negative = true
            i += 1
            guard i < b.count else { return nil }
        }
        // Integer part: "0" or [1-9][0-9]*, leading zeros are errors.
        var mantissa: UInt64 = 0
        var mantissaOverflow = false
        if b[i] == UInt8(ascii: "0") {
            i += 1
            // serde: "01" is an error ("invalid number").
            if i < b.count, b[i] >= 0x30, b[i] <= 0x39 { return nil }
        } else if b[i] >= 0x31, b[i] <= 0x39 {
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
                let d = UInt64(b[i] - 0x30)
                let (m1, o1) = mantissa.multipliedReportingOverflow(by: 10)
                let (m2, o2) = m1.addingReportingOverflow(d)
                if o1 || o2 { mantissaOverflow = true }
                mantissa = m2
                i += 1
            }
        } else {
            return nil  // ".5", "-x", etc.
        }
        var isFloat = false
        if i < b.count, b[i] == UInt8(ascii: ".") {
            isFloat = true
            i += 1
            guard i < b.count, b[i] >= 0x30, b[i] <= 0x39 else { return nil }  // "1."
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
        }
        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            isFloat = true
            i += 1
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") {
                i += 1
            }
            guard i < b.count, b[i] >= 0x30, b[i] <= 0x39 else { return nil }  // "1e"
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
        }

        if !isFloat, !mantissaOverflow {
            if !negative {
                // Fits u64: ints <= i64::MAX stay ints, larger u64 values are
                // stored bit-pattern-wrapped (JSONValue's u64 convention).
                return .int(Int64(bitPattern: mantissa))
            }
            if mantissa == 0 {
                // serde_json: "-0" parses as f64 -0.0.
                return .double(-0.0)
            }
            if mantissa <= UInt64(Int64.max) {
                return .int(-Int64(mantissa))
            }
            if mantissa == UInt64(Int64.max) + 1 {
                return .int(Int64.min)
            }
            // More negative than i64::MIN: falls through to f64.
        }
        let token = String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
        guard let d = Double(token), d.isFinite else { return nil }  // "1e999": error
        return .double(d)
    }
}

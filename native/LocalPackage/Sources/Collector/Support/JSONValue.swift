import Foundation

/// Mirror of `serde_json::Value`. Parsed by the byte-level serde-compatible
/// parser in JSONParser.swift (see there for the exact semantics): JSON
/// integers that fit i64/u64 stay integers (u64 above Int64.max is stored
/// bit-pattern-wrapped, matching the `n.as_u64().map(|v| v as i64)` wrap in
/// the Rust helpers), everything else is a double.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// `Value::get(key)`: Some only when self is an object holding the key.
    /// A present-but-null member returns `.null` (not nil), like Rust.
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// `Value::as_str()`: strings only, no coercion, no trimming.
    var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

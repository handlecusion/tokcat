import Foundation

// Accessors the quota providers need on top of the parser-oriented core in
// Support/JSONValue.swift (which is intentionally left untouched).

extension JSONValue {
    /// `Value::as_object()` — the keys only; use subscript for members.
    var asObject: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var asArray: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// `Value::as_f64()` — numbers only, no string coercion.
    var asDouble: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    /// `Value::as_i64()` — integer-typed numbers only.
    var asInt64: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }
}

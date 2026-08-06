import Foundation

/// Mirror of `serde_json::Value`. Parsed via JSONSerialization but with the
/// integer-vs-double distinction preserved the way serde_json preserves it:
/// JSON integers that fit i64/u64 stay integers, everything else is a double.
///
/// NSNumber sniffing rules:
/// - Booleans come back as CFBoolean and must be detected before any numeric
///   cast (NSNumber(1) would otherwise bridge to `true`).
/// - Integer-typed NSNumbers ("c/i/s/l/q" and unsigned variants) map to
///   `.int`. u64 values above Int64.max are stored bit-pattern-wrapped, which
///   matches the `n.as_u64().map(|v| v as i64)` wrap in the Rust helpers.
/// - Everything else (incl. NSDecimalNumber, objCType "d") maps to `.double`.
enum JSONValue {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    static func parse(_ text: String) -> JSONValue? {
        parse(Data(text.utf8))
    }

    static func parse(_ data: Data) -> JSONValue? {
        guard
            let obj = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed])
        else { return nil }
        return fromFoundation(obj)
    }

    static func fromFoundation(_ any: Any) -> JSONValue? {
        if any is NSNull { return .null }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            switch UnicodeScalar(UInt8(bitPattern: n.objCType.pointee)) {
            case "c", "i", "s", "l", "q":
                return .int(n.int64Value)
            case "C", "I", "S", "L", "Q":
                return .int(Int64(bitPattern: n.uint64Value))
            default:
                return .double(n.doubleValue)
            }
        }
        if let s = any as? String { return .string(s) }
        if let a = any as? [Any] {
            var items = [JSONValue]()
            items.reserveCapacity(a.count)
            for e in a {
                guard let v = fromFoundation(e) else { return nil }
                items.append(v)
            }
            return .array(items)
        }
        if let d = any as? [String: Any] {
            var obj = [String: JSONValue](minimumCapacity: d.count)
            for (k, e) in d {
                guard let v = fromFoundation(e) else { return nil }
                obj[k] = v
            }
            return .object(obj)
        }
        return nil
    }

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

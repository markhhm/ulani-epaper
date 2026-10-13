import Foundation

/// JSON read with Foundation and written exactly as Python's
/// `json.dumps(value, ensure_ascii=False, indent=1)` writes it (the notes file, the agenda
/// fixtures), so files from either side are byte for byte the same.
enum PythonJSON {
    indirect enum Value: Equatable {
        case null
        case bool(Bool)
        case int(Int)
        case string(String)
        case array([Value])
        case object([Member])  // in this order

        struct Member: Equatable {
            let key: String
            let value: Value
            init(_ key: String, _ value: Value) {
                self.key = key
                self.value = value
            }
        }
    }

    /// The text, without a trailing newline (like `json.dump`).
    static func dumps(_ value: Value, indent: Int = 1) -> String {
        var out = ""
        write(value, depth: 0, indent: indent, into: &out)
        return out
    }

    private static func write(_ value: Value, depth: Int, indent: Int, into out: inout String) {
        let inner = "\n" + String(repeating: " ", count: (depth + 1) * indent)
        let outer = "\n" + String(repeating: " ", count: depth * indent)
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .string(let s): out += quoted(s)
        case .array(let items) where items.isEmpty: out += "[]"
        case .object(let members) where members.isEmpty: out += "{}"
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                out += (i == 0 ? "" : ",") + inner
                write(item, depth: depth + 1, indent: indent, into: &out)
            }
            out += outer + "]"
        case .object(let members):
            out += "{"
            for (i, member) in members.enumerated() {
                out += (i == 0 ? "" : ",") + inner + quoted(member.key) + ": "
                write(member.value, depth: depth + 1, indent: indent, into: &out)
            }
            out += outer + "}"
        }
    }

    /// Python's string escaping with ensure_ascii=False: `"` `\` and the C0 controls only.
    static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: Reading

    /// Foundation's parse of `data` (top-level scalars allowed, as Python's json.loads).
    static func parse(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Whether a parsed value is a JSON true/false (not a number).
    static func isBool(_ value: Any) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// A parsed JSON string (numbers and booleans are not strings).
    static func string(_ value: Any) -> String? {
        value is NSNumber ? nil : value as? String
    }

    /// Python's `bool(value)`: false for null, false, 0, "", [] and {}.
    static func truthy(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull: false
        case let n as NSNumber: n.doubleValue != 0
        case let s as String: !s.isEmpty
        case let a as [Any]: !a.isEmpty
        case let o as [String: Any]: !o.isEmpty
        default: true
        }
    }
}

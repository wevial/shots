import Foundation

/// A JSON value, for the places where shots handles JSON whose shape it doesn't control
/// (model replies, the user's config file) or whose exact text it does (CLI output, the
/// index's JSON columns, log lines).
///
/// Objects keep their keys in insertion order and `serialized()` formats like JavaScript's
/// `JSON.stringify`, so what the Swift code writes reads the same as what the TypeScript
/// daemon wrote. Foundation's `JSONEncoder` can do neither.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

/// A JSON object that remembers the order its keys were added in.
public struct JSONObject: Sendable, Equatable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        for (key, value) in elements { self[key] = value }
    }

    public init(_ pairs: [(String, JSONValue)]) {
        for (key, value) in pairs { self[key] = value }
    }

    /// Setting a new key appends it; setting nil removes it.
    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public func makeIterator() -> some IteratorProtocol<(key: String, value: JSONValue)> {
        keys.lazy.map { (key: $0, value: storage[$0]!) }.makeIterator()
    }

    /// Key order doesn't make two objects different.
    public static func == (a: JSONObject, b: JSONObject) -> Bool { a.storage == b.storage }
}

// MARK: - Reading values

extension JSONValue {
    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var doubleValue: Double? { if case .number(let n) = self { n } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var objectValue: JSONObject? { if case .object(let o) = self { o } else { nil } }
    public var isNull: Bool { self == .null }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}

// MARK: - Building values

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object = JSONObject()
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }

    // Optionals become `null`, the way JSON.stringify writes a null field.
    public init(_ value: String?) { self = value.map(JSONValue.string) ?? .null }
    public init(_ value: Bool?) { self = value.map(JSONValue.bool) ?? .null }
    public init(_ value: Double?) { self = value.map(JSONValue.number) ?? .null }
    public init(_ value: Int?) { self = value.map { .number(Double($0)) } ?? .null }
    public init(_ value: Int64?) { self = value.map { .number(Double($0)) } ?? .null }
    public init(_ value: [String]) { self = .array(value.map(JSONValue.string)) }
    public init(_ value: [String: String]) {
        self = .object(JSONObject(value.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }))
    }
}

/// Types with a fixed JSON shape that other programs (the viewer, the old daemon) rely on.
public protocol JSONRepresentable {
    var json: JSONValue { get }
}

extension JSONRepresentable {
    /// Compact (`indent: nil`) or pretty-printed JSON text.
    public func jsonString(indent: Int? = nil) -> String { json.serialized(indent: indent) }
}

// MARK: - Parsing

public struct JSONParseError: LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
}

extension JSONValue {
    /// Parses JSON text, accepting a bare scalar at the top level like `JSON.parse`.
    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            throw JSONParseError(message: reason ?? "invalid JSON")
        }
        return JSONValue(foundation: object)
    }

    private init(foundation value: Any) {
        switch value {
        case let number as NSNumber:
            // JSONSerialization hands back booleans as NSNumber too; CFBoolean tells them apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(foundation:)))
        case let dictionary as [String: Any]:
            // Foundation doesn't keep the source order; sorting at least makes it stable.
            self = .object(JSONObject(dictionary.keys.sorted().map { ($0, JSONValue(foundation: dictionary[$0]!)) }))
        default:
            self = .null
        }
    }
}

// MARK: - Serializing

extension JSONValue {
    /// Formats like `JSON.stringify(value, null, indent)`.
    public func serialized(indent: Int? = nil) -> String {
        var out = ""
        write(to: &out, indent: indent.map { String(repeating: " ", count: $0) }, depth: 0)
        return out
    }

    private func write(to out: inout String, indent: String?, depth: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += JSONValue.formatNumber(n)
        case .string(let s): JSONValue.writeString(s, to: &out)
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                newline(&out, indent, depth + 1)
                item.write(to: &out, indent: indent, depth: depth + 1)
            }
            newline(&out, indent, depth)
            out += "]"
        case .object(let object):
            guard !object.isEmpty else { out += "{}"; return }
            out += "{"
            for (i, (key, value)) in object.enumerated() {
                if i > 0 { out += "," }
                newline(&out, indent, depth + 1)
                JSONValue.writeString(key, to: &out)
                out += indent == nil ? ":" : ": "
                value.write(to: &out, indent: indent, depth: depth + 1)
            }
            newline(&out, indent, depth)
            out += "}"
        }
    }

    private func newline(_ out: inout String, _ indent: String?, _ depth: Int) {
        guard let indent else { return }
        out += "\n" + String(repeating: indent, count: depth)
    }

    /// JavaScript's number formatting: integers without a fraction, non-finite as null.
    public static func formatNumber(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n == n.rounded(), abs(n) < 1e21 {
            return n == 0 ? "0" : String(Int64(n))
        }
        return "\(n)"
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
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
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

// MARK: - Codable, for embedding in Codable types

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(JSONObject(o.keys.sorted().map { ($0, o[$0]!) }))
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(Dictionary(uniqueKeysWithValues: o.map { ($0.key, $0.value) }))
        }
    }
}

extension JSONValue {
    /// Decodes a `Decodable` type from this value.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(serialized().utf8))
    }
}

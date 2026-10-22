import Foundation

/// The JSON Schema handed to the CLI backends. Codex's strict mode needs every key required
/// and no extras.
public func resultJsonSchema(categories: [String]) -> JSONValue {
    [
        "type": "object",
        "additionalProperties": false,
        "required": ["category", "tags", "title", "confidence"],
        "properties": [
            "category": ["type": "string", "enum": JSONValue(categories)],
            "tags": ["type": "array", "items": ["type": "string"], "maxItems": 8],
            "title": ["type": "string"],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
        ],
    ]
}

/// Pulls the first JSON object out of model text: strips ``` fences and any prose before or
/// after by scanning for a balanced top-level `{…}` (aware of strings and escapes).
public func extractJson(_ text: String) throws -> JSONValue {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let whole = try? JSONValue.parse(trimmed) { return whole }
    let fence = /```(?:json)?\s*([\s\S]*?)```/.ignoresCase()
    let unfenced: String = if let match = trimmed.firstMatch(of: fence) {
        trimmed.replacingCharacters(in: match.range, with: match.output.1)
    } else {
        trimmed
    }

    // UTF-16 offsets, the way the JavaScript version indexed the string.
    let units = Array(unfenced.utf16)
    let open = UInt16(UInt8(ascii: "{")), close = UInt16(UInt8(ascii: "}"))
    let quote = UInt16(UInt8(ascii: "\"")), backslash = UInt16(UInt8(ascii: "\\"))
    var start = units.firstIndex(of: open)
    while let begin = start {
        var depth = 0
        var inString = false
        var i = begin
        scan: while i < units.count {
            let ch = units[i]
            if inString {
                if ch == backslash { i += 1 }
                else if ch == quote { inString = false }
            } else if ch == quote {
                inString = true
            } else if ch == open {
                depth += 1
            } else if ch == close {
                depth -= 1
                if depth == 0 {
                    let candidate = String(decoding: units[begin...i], as: UTF16.self)
                    if let value = try? JSONValue.parse(candidate) { return value }
                    break scan
                }
            }
            i += 1
        }
        start = units[(begin + 1)...].firstIndex(of: open)
    }
    throw ShotsError("no JSON object found in output")
}

public enum Validation: Sendable, Equatable {
    case valid(ClassifyResult)
    case invalid([String])
}

/// Shape check plus normalization. An unknown category is still a valid shape: the chain
/// maps it to misc + review.
public func validateResult(_ raw: JSONValue) -> Validation {
    guard case .object(let o) = raw else { return .invalid(["expected a JSON object"]) }
    var errors: [String] = []
    let category = o["category"]?.stringValue
    if category?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
        errors.append("category must be a non-empty string")
    }
    let tags = o["tags"]?.arrayValue?.compactMap(\.stringValue)
    if tags == nil || tags?.count != o["tags"]?.arrayValue?.count { errors.append("tags must be an array of strings") }
    let title = o["title"]?.stringValue
    if title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
        errors.append("title must be a non-empty string")
    }
    let confidence = o["confidence"]?.doubleValue
    if confidence.map({ !$0.isFinite || $0 < 0 || $0 > 1 }) ?? true {
        errors.append("confidence must be a number between 0 and 1")
    }
    guard errors.isEmpty, let category, let tags, let title, let confidence else { return .invalid(errors) }

    var seen = Set<String>()
    let normalized = tags.map(normalizeTag).filter { !$0.isEmpty && seen.insert($0).inserted }
    return .valid(ClassifyResult(
        category: category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        tags: Array(normalized.prefix(8)),
        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
        confidence: confidence
    ))
}

/// Lowercase, hyphen-separated letters and digits, at most 32 characters.
public func normalizeTag(_ tag: String) -> String {
    var t = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    t = t.replacing(/[\s_]+/.matchingSemantics(.unicodeScalar), with: "-")
    t = t.replacing(/[^\p{L}\p{N}-]/.matchingSemantics(.unicodeScalar), with: "")
    t = t.replacing(/-+/, with: "-")
    if t.hasPrefix("-") { t.removeFirst() }
    if t.hasSuffix("-") { t.removeLast() }
    return String(String.UnicodeScalarView(t.unicodeScalars.prefix(32)))
}

import Foundation
import Testing
@testable import ShotsCore

struct ExtractJsonTests {
    @Test func plainJSON() throws {
        #expect(try extractJson(#"{"a":1}"#) == ["a": 1])
    }

    @Test func stripsCodeFences() throws {
        #expect(try extractJson("```json\n{\"a\": 1}\n```") == ["a": 1])
    }

    @Test func stripsProseAroundTheObject() throws {
        #expect(try extractJson("Sure! Here you go:\n{\"category\":\"code\",\"x\":{\"y\":2}}\nHope that helps.") == ["category": "code", "x": ["y": 2]])
    }

    @Test func bracesInsideStringsDontEndTheObject() throws {
        #expect(try extractJson(#"note {"title":"a } tricky { one","n":1} trailing"#) == ["title": "a } tricky { one", "n": 1])
    }

    @Test func skipsABrokenLeadingObject() throws {
        #expect(try extractJson(#"{oops} then {"ok":true}"#) == ["ok": true])
    }

    @Test func throwsWhenThereIsNoObject() {
        #expect(throws: ShotsError.self) { try extractJson("no json here") }
    }
}

struct ValidateResultTests {
    @Test func acceptsAndNormalizes() throws {
        let raw = try JSONValue.parse(#"{"category":" Code ","tags":["Type Script","type-script","  "],"title":" Loader ","confidence":0.8}"#)
        #expect(validateResult(raw) == .valid(ClassifyResult(category: "code", tags: ["type-script"], title: "Loader", confidence: 0.8)))
    }

    @Test func rejectsBadShapesWithEveryError() {
        guard case .invalid(let errors) = validateResult(["category": "", "tags": "x", "confidence": 2]) else {
            Issue.record("expected invalid")
            return
        }
        #expect(errors.count == 4)
    }

    @Test func unknownCategoriesAreAValidShape() {
        #expect(validateResult(["category": "memes", "tags": [], "title": "t", "confidence": 0.9]) != .invalid([]))
        if case .invalid = validateResult(["category": "memes", "tags": [], "title": "t", "confidence": 0.9]) {
            Issue.record("expected valid")
        }
    }

    @Test func nonObjects() {
        #expect(validateResult([1]) == .invalid(["expected a JSON object"]))
        #expect(validateResult(.null) == .invalid(["expected a JSON object"]))
        if case .valid = validateResult(["category": "a", "tags": [], "title": "t", "confidence": true]) {
            Issue.record("a boolean confidence must not pass")
        }
    }

    @Test func keepsAtMostEightTags() {
        let tags = JSONValue((1...12).map { "t\($0)" })
        guard case .valid(let result) = validateResult(["category": "a", "tags": tags, "title": "t", "confidence": 0.5]) else {
            Issue.record("expected valid")
            return
        }
        #expect(result.tags.count == 8)
    }
}

@Test func schemaIsStrictModeCompatible() throws {
    let schema = resultJsonSchema(categories: ["code", "misc"])
    #expect(schema["additionalProperties"] == false)
    let requiredKeys = schema["required"]?.arrayValue?.compactMap(\.stringValue)
    let required = try #require(requiredKeys)
    let properties = try #require(schema["properties"]?.objectValue?.keys)
    #expect(required.sorted() == properties.sorted())
    #expect(schema["properties"]?["category"]?["enum"] == ["code", "misc"])
    #expect(schema.serialized() == #"{"type":"object","additionalProperties":false,"required":["category","tags","title","confidence"],"properties":{"category":{"type":"string","enum":["code","misc"]},"tags":{"type":"array","items":{"type":"string"},"maxItems":8},"title":{"type":"string"},"confidence":{"type":"number","minimum":0,"maximum":1}}}"#)
}

@Test func normalizeTag() {
    #expect(ShotsCore.normalizeTag("Pull Request!") == "pull-request")
    #expect(ShotsCore.normalizeTag("__x__") == "x")
    #expect(ShotsCore.normalizeTag("-") == "")
    #expect(ShotsCore.normalizeTag(String(repeating: "a", count: 40)).count == 32)
}

struct JSONValueTests {
    @Test func serializesLikeJSONStringify() throws {
        let value: JSONValue = ["b": 1, "a": [true, .null, 0.55, "x/y \"q\"\n"], "e": [:], "f": []]
        #expect(value.serialized() == #"{"b":1,"a":[true,null,0.55,"x/y \"q\"\n"],"e":{},"f":[]}"#)
        #expect(value.serialized(indent: 2) == "{\n  \"b\": 1,\n  \"a\": [\n    true,\n    null,\n    0.55,\n    \"x/y \\\"q\\\"\\n\"\n  ],\n  \"e\": {},\n  \"f\": []\n}")
        #expect(JSONValue.formatNumber(30000) == "30000")
        #expect(JSONValue.formatNumber(-0.0) == "0")
        #expect(JSONValue.formatNumber(.nan) == "null")
        #expect(JSONValue.string("\u{01}").serialized() == #""\u0001""#)
    }

    @Test func parsesScalarsAndBooleansDistinctly() throws {
        #expect(try JSONValue.parse("true") == .bool(true))
        #expect(try JSONValue.parse("1") == .number(1))
        #expect(try JSONValue.parse(#"{"a":[1,"b"]}"#) == ["a": [1, "b"]])
        #expect(throws: JSONParseError.self) { try JSONValue.parse("{") }
    }

    @Test func objectsKeepInsertionOrder() {
        var object: JSONObject = ["z": 1, "a": 2]
        object["m"] = 3
        object["z"] = 4
        #expect(object.keys == ["z", "a", "m"])
        object["a"] = nil
        #expect(object.keys == ["z", "m"])
    }
}

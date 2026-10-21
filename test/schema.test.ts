import { describe, expect, test } from "bun:test";
import { extractJson, normalizeTag, resultJsonSchema, validateResult } from "../src/classify/schema.ts";

describe("extractJson", () => {
  test("plain JSON", () => {
    expect(extractJson('{"a":1}')).toEqual({ a: 1 });
  });
  test("strips code fences", () => {
    expect(extractJson('```json\n{"a": 1}\n```')).toEqual({ a: 1 });
  });
  test("strips prose around the object", () => {
    expect(extractJson('Sure! Here you go:\n{"category":"code","x":{"y":2}}\nHope that helps.')).toEqual({ category: "code", x: { y: 2 } });
  });
  test("braces inside strings don't end the object", () => {
    expect(extractJson('note {"title":"a } tricky { one","n":1} trailing')).toEqual({ title: "a } tricky { one", n: 1 });
  });
  test("skips a broken leading object", () => {
    expect(extractJson('{oops} then {"ok":true}')).toEqual({ ok: true });
  });
  test("throws when there is no object", () => {
    expect(() => extractJson("no json here")).toThrow();
  });
});

describe("validateResult", () => {
  test("accepts and normalises", () => {
    const v = validateResult({ category: " Code ", tags: ["Type Script", "type-script", "  "], title: " Loader ", confidence: 0.8 });
    expect(v).toEqual({ ok: true, value: { category: "code", tags: ["type-script"], title: "Loader", confidence: 0.8 } });
  });
  test("rejects bad shapes with every error", () => {
    const v = validateResult({ category: "", tags: "x", confidence: 2 });
    expect(v.ok).toBe(false);
    if (!v.ok) expect(v.errors).toHaveLength(4);
  });
  test("unknown categories are valid shape (handled by the chain)", () => {
    expect(validateResult({ category: "memes", tags: [], title: "t", confidence: 0.9 }).ok).toBe(true);
  });
  test("non-objects", () => {
    expect(validateResult([1]).ok).toBe(false);
    expect(validateResult(null).ok).toBe(false);
  });
});

test("schema is strict-mode compatible (all keys required, no extras)", () => {
  const s = resultJsonSchema(["code", "misc"]);
  expect(s.additionalProperties).toBe(false);
  expect(s.required.sort()).toEqual(Object.keys(s.properties).sort());
  expect(s.properties.category.enum).toEqual(["code", "misc"]);
});

test("normalizeTag", () => {
  expect(normalizeTag("Pull Request!")).toBe("pull-request");
  expect(normalizeTag("__x__")).toBe("x");
});

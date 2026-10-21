// Exercises the real Swift helper. Skipped when it hasn't been built (`bun run build:helper`).
import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { helperNative, helperPath } from "../src/native.ts";
import { dropFixture, FIXTURES, markAsScreenshot, tempRoot } from "./helpers.ts";

const built = existsSync(helperPath());

describe.skipIf(!built)("shots-helper (real)", () => {
  test("Vision OCR reads the fixtures", async () => {
    const code = await helperNative.ocr(join(FIXTURES, "code.png"), []);
    expect(code.text).toContain("loadConfig");
    expect(code).toMatchObject({ width: 1200, height: 600 });
    const err = await helperNative.ocr(join(FIXTURES, "error.png"), []);
    expect(err.text).toContain("Traceback");
    expect((await helperNative.ocr(join(FIXTURES, "blank.png"), [])).text).toBe("");
  });

  test("screenshot metadata comes from xattrs immediately", async () => {
    const p = dropFixture("code.png", tempRoot(), "shot.png");
    expect((await helperNative.meta(p)).isScreenCapture).not.toBe(true);
    markAsScreenshot(p, "window");
    expect(await helperNative.meta(p)).toEqual({ isScreenCapture: true, captureType: "window", source: "xattr" });
  });

  test("Finder tags land in _kMDItemUserTags and merge/remove correctly", async () => {
    const p = dropFixture("code.png", tempRoot(), "tagged.png");
    const read = () => {
      const hex = execFileSync("xattr", ["-px", "com.apple.metadata:_kMDItemUserTags", p]).toString().replace(/\s/g, "");
      const json = execFileSync("plutil", ["-convert", "json", "-o", "-", "-"], { input: Buffer.from(hex, "hex") }).toString();
      return JSON.parse(json) as string[];
    };
    await helperNative.setTags(p, ["code", "typescript"]);
    expect(read()).toEqual(["code\n0", "typescript\n0"]);
    await helperNative.setTags(p, ["design"], ["code"]);
    expect(read()).toEqual(["typescript\n0", "design\n0"]);
  });

  test("fm-status reports availability and the image-input decision", async () => {
    const s = await helperNative.fmStatus();
    expect(typeof s.available).toBe("boolean");
    expect(s.osVersion).toMatch(/^\d+\.\d+/);
    if (Number(s.osVersion.split(".")[0]) < 27) expect(s.imageInput).toEqual({ enabled: false, reason: expect.stringContaining("macOS 27") });
    if (!s.available) expect(s.reason).toBeTruthy();
  });
});

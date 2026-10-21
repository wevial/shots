import { describe, expect, test } from "bun:test";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { isCandidate, safeMove, slugTitle, stamp, targetName, uniquePath, waitForStable } from "../src/files.ts";
import { tempRoot } from "./helpers.ts";

describe("naming", () => {
  test("stamp uses local time YYYY-MM-DD_HHMM", () => {
    expect(stamp(new Date(2026, 9, 21, 9, 5))).toBe("2026-10-21_0905");
  });
  test("slugTitle is filename-safe and bounded", () => {
    expect(slugTitle("Inbox: admin / “needs you” queue!")).toBe("inbox-admin-needs-you-queue");
    expect(slugTitle("Café résumé")).toBe("cafe-resume");
    expect(slugTitle("../../etc/passwd")).toBe("etc-passwd");
    expect(slugTitle("   ")).toBe("screenshot");
    expect(slugTitle("a".repeat(200)).length).toBeLessThanOrEqual(60);
  });
  test("targetName", () => {
    expect(targetName(new Date(2026, 0, 2, 3, 4), "Hello World", ".PNG")).toBe("2026-01-02_0304_hello-world.png");
  });
  test("isCandidate ignores hidden temp files and non-images", () => {
    expect(isCandidate("/x/Screenshot 2026.png")).toBe(true);
    expect(isCandidate("/x/.Screenshot 2026.png")).toBe(false);
    expect(isCandidate("/x/notes.txt")).toBe(false);
  });
});

describe("moving", () => {
  test("uniquePath never returns an existing file", () => {
    const dir = tempRoot();
    writeFileSync(join(dir, "a.png"), "1");
    writeFileSync(join(dir, "a-2.png"), "2");
    expect(uniquePath(dir, "a.png")).toBe(join(dir, "a-3.png"));
    expect(uniquePath(dir, "a.png", join(dir, "a.png"))).toBe(join(dir, "a.png"));
  });
  test("safeMove refuses to overwrite and keeps the source", () => {
    const dir = tempRoot();
    writeFileSync(join(dir, "src.png"), "src");
    writeFileSync(join(dir, "dest.png"), "dest");
    expect(() => safeMove(join(dir, "src.png"), join(dir, "dest.png"))).toThrow(/exists/);
    expect(readFileSync(join(dir, "src.png"), "utf8")).toBe("src");
    expect(readFileSync(join(dir, "dest.png"), "utf8")).toBe("dest");
  });
  test("safeMove creates the target directory", () => {
    const dir = tempRoot();
    writeFileSync(join(dir, "src.png"), "x");
    safeMove(join(dir, "src.png"), join(dir, "sub/dir/out.png"));
    expect(existsSync(join(dir, "src.png"))).toBe(false);
    expect(readFileSync(join(dir, "sub/dir/out.png"), "utf8")).toBe("x");
  });
});

test("waitForStable waits out a file that is still growing", async () => {
  const dir = tempRoot();
  const p = join(dir, "growing.png");
  writeFileSync(p, "a");
  let writes = 0;
  const timer = setInterval(() => {
    if (++writes <= 5) appendFileSync(p, "more");
  }, 15);
  const st = await waitForStable(p, { intervalMs: 40, stableChecks: 2, timeoutMs: 3000 });
  clearInterval(timer);
  expect(st.size).toBe(1 + 4 * 5);
});

test("waitForStable times out on a missing file", async () => {
  await expect(waitForStable(join(tempRoot(), "nope.png"), { intervalMs: 10, timeoutMs: 100 })).rejects.toThrow(/stabilised/);
});

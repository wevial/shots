# shots

A macOS background agent that files screenshots on its own. Each new capture in the inbox is OCR'd on-device, tagged with the app/window/tab it came from, classified, renamed `YYYY-MM-DD_HHMM_<title>.png`, moved to `~/Screenshots/<category>/`, given Finder tags, and indexed for full-text search.

```
inbox event ─▶ capture app context ─▶ wait for stable size ─▶ xattr/mdls: is it a screenshot?
           ─▶ Vision OCR ─▶ classify: apple → claude-code → codex (privacy-gated)
           ─▶ rename + move + Finder tags + clipboard ─▶ SQLite FTS5 index
```

- **TypeScript on Bun** runs the daemon, queue, SQLite index, CLI backends, and the `shots` CLI. It ships as a single `bun build --compile` binary.
- **`shots-helper` (Swift)** is a stateless bridge to the native APIs: Vision OCR, NSWorkspace/Accessibility context, AppleScript tab URLs, Foundation Models, Finder tag xattrs, and the pasteboard. It prints one JSON object per call.

## Design notes

| Check | Finding | Design consequence |
|---|---|---|
| `mdls` on a fresh capture | `kMDItemIsScreenCapture = (null)` for seconds after the file appears, and forever in folders Spotlight doesn't index | The same fields exist as `com.apple.metadata:kMDItemIsScreenCapture` / `…ScreenCaptureType` / `…GlobalRect` **xattrs** the moment the file lands. Those are read first; `mdls` is the fallback |
| Capture types seen | `selection`, `display` (plus `window`) | Passed to the classifier as context |
| Filenames | `Screenshot … at 10.22.28 AM.png` (narrow no-break space) | The original name is stored verbatim, and the new name is slugged |
| Write pattern | Hidden `.Screenshot…` temp file, then rename | Bun's `fs.watch` reports the rename under the old hidden name, so every event triggers a debounced rescan instead of trusting the filename |
| Foundation Models | `available`, 4096-token context, text-only on 26 | OCR is clipped to 4000 chars for apple. Image input sits behind `#available(macOS 27)` + `capabilities.contains(.vision)` in the same binary |
| `claude` | `-p --output-format json --json-schema` returns `structured_output`. `--restricted --safe-mode` confine reads to cwd (a `/etc/hosts` read was denied) | Used as-is with `--tools Read --allowed-tools Read(./screenshot.png)` |
| `codex` | `exec -i --output-schema -o --sandbox read-only --ignore-user-config` works. not every model name works on every account type | Default codex model is `gpt-6-luna` |

## Install

```bash
scripts/install.sh
```

This builds both binaries into `~/.local/share/shots/bin`, symlinks `~/.local/bin/shots`, writes `~/.config/shots/config.json` if it's missing, and loads the LaunchAgent `com.shots.agent` (it starts at login and restarts if it dies). Logs go to `~/Library/Logs/shots/`.

Next, point screenshots at the inbox and turn off the floating thumbnail:

```bash
defaults write com.apple.screencapture location ~/Screenshots/_inbox
```

```bash
defaults write com.apple.screencapture show-thumbnail -bool false
```

The thumbnail delays the file write by about 5 seconds. Context is captured when the file appears, so with the thumbnail on, the "frontmost app" may already be a different app.

Run `scripts/uninstall.sh` to remove the agent and binaries. It keeps your screenshots, config, and index.

## Permissions

macOS attributes permissions to the **responsible process**: the `shots` binary that launchd starts, not the helper and not your terminal. Grant them to `~/.local/share/shots/bin/shots`.

| Permission | Needed for | Without it |
|---|---|---|
| **Accessibility** | Focused window title; URL of browsers without AppleScript (Firefox) | App name/bundle ID still work (NSWorkspace needs no permission), and window titles fall back to Screen Recording |
| **Automation** (per browser, prompted on first use) | Active tab URL + title in Safari and Chromium-family browsers (Chrome, Arc, Brave, Edge, Vivaldi, Dia) | No URL, or the AX fallback if Accessibility is granted |
| Screen Recording | *Optional.* Window titles via CGWindowList when Accessibility is denied | No window title |
| Full Disk Access | **Not needed** while the inbox and output are outside protected folders (Desktop, Documents, and Downloads are protected) | — |

To grant: System Settings → Privacy & Security → Accessibility → `+` → ⇧⌘G → paste the path, then run `launchctl kickstart -k gui/$(id -u)/com.shots.agent`. The binaries are ad-hoc signed, so **macOS may drop the grant after a rebuild**. Re-add it if `shots doctor` shows `daemon permissions ✗`. The daemon records what it actually sees in `~/.local/share/shots/daemon-status.json`. Run from a terminal, `doctor` can only show the terminal's own grants.

## CLI

```
shots search <query> [--limit N] [--json]   FTS5 over OCR text, title, tags, app, window, URL
shots recat <file> [--backend apple|claude-code|codex|rules] [--category <name>]
shots review [--failed]                     low-confidence/unknown-category shots, or failed jobs
shots doctor                                OS, model + image path, CLIs + auth, permissions, agent
shots config                                effective config
shots run                                   the daemon (launchd runs this)
```

`recat` reuses the stored OCR and context, renames and moves the file, and swaps only the tags shots applied (your own Finder tags stay). Passing `--backend` for a cloud backend on a denylisted shot is refused.

## Classifier chain

Every backend gets the same prompt: the category list with one-line hints, the app/window/URL, the capture type and size, and the OCR text. Every backend returns `{category, tags, title, confidence}`.

- **apple** runs Foundation Models through the helper, using `@Generable` guided generation, on-device. Text-only on macOS 26. On 27+ with the vision capability, it attaches the image automatically.
- **claude-code** runs `claude -p` in a fresh temp dir that holds only a copy of the image. It uses `--restricted --safe-mode --strict-mcp-config`, `Read` scoped to that one file, `dontAsk` permissions, no session persistence, and your existing login.
- **codex** runs `codex exec` in the same kind of temp dir with the image attached via `-i`. It uses a `read-only` sandbox, `--ignore-user-config --ignore-rules --ephemeral`, memories/plugins/hooks disabled, a strict `--output-schema`, and your existing login.
- **rules** is local and deterministic: an `appRules` bundle-ID → category map, then OCR keywords.

CLI output gets JSON extraction (fences and prose stripped) and schema validation. A bad reply gets **one** corrective retry that quotes it, and then the backend fails. A timeout (`timeoutMs`) kills the whole process group.

The chain moves to the next backend on error, unavailability, timeout, or confidence below `escalateBelowConfidence`, and keeps the most confident result it has seen. If the final category is unknown or its confidence is below `reviewBelowConfidence`, the shot goes to `misc`, gets a `review` Finder tag, and appears in `shots review` with the model's suggestion. If every backend fails, the file stays in the inbox, is retried after `retryDelayMs` up to `maxAttempts` times, and shows in `shots review --failed`.

> **Apple's confidence is uncalibrated on macOS 26.** In testing it answered 0.9 for every screenshot, right or wrong, so with the default chain it never escalates. Set `"confidenceCap": {"apple": 0.55}` to always get a cloud second opinion (apple still serves denylisted shots), or reorder `backends`.

## Privacy

- **apple** and **rules** never leave the machine. OCR always runs locally.
- `allowCloud: false` turns off claude-code and codex everywhere.
- `cloudDenylist` (bundle IDs or app names; password managers are seeded) and `cloudDenylistDomains` (for example `"chase.com"`, which matches subdomains of the active browser tab) keep a shot to apple, or to rules if apple is unavailable.
- `cloudWhenAppUnknown` (default `true`) decides what happens when no context was captured, which is the case for files found by a scan rather than a live event.

## Config (`~/.config/shots/config.json`)

The defaults are written on first run, and any key can be overridden. These are the important ones:

```jsonc
{
  "inbox": "~/Screenshots/_inbox",
  "outputRoot": "~/Screenshots",
  "categories": ["code", "design", "ui-reference", "docs", "chat", "finance", "receipts", "shopping", "travel", "social", "errors", "misc"],
  "categoryHints": { "code": "source code, terminals, diffs, …" },
  "backends": ["apple", "claude-code", "codex"],
  "escalateBelowConfidence": 0.6,
  "reviewBelowConfidence": 0.6,
  "confidenceCap": {},
  "timeoutMs": 30000,
  "allowCloud": true,
  "cloudDenylist": ["com.1password.1password", "…"],
  "cloudDenylistDomains": [],
  "copyToClipboard": true,
  "concurrency": 1,                 // 1–2
  "maxAttempts": 3,
  "claudeCode": { "binary": "claude", "model": "sonnet", "effort": "low" },
  "codex": { "binary": "codex", "model": "gpt-6-luna", "effort": "low" }
}
```

The index lives at `~/.local/share/shots/shots.db` (WAL). The `jobs` table makes the daemon idempotent and restart-safe: jobs interrupted mid-run resume, files with the same bytes are skipped as duplicates, and non-screenshots are skipped once and then left alone. Originals are never deleted. A move is a hard link followed by an unlink (copy, verify, unlink across volumes), and it refuses to overwrite.

## Viewer app (Shots.app)

`app/` is a SwiftUI app for browsing and fixing the index. It has a sidebar (All, Needs Review, Failed, categories with counts), a thumbnail grid with FTS search, and an inspector showing the preview, category picker, re-run buttons for Apple/Claude/Codex, tags, metadata, and OCR text. It also supports Quick Look (Space), drag-out, Reveal in Finder, and a menu bar icon that shows the review count and recent shots.

It reads `shots.db` read-only and refreshes when `PRAGMA data_version` changes. Every change goes through `shots recat … --json`, so classification, privacy rules, and file moves stay in one place. The app has no way to delete files.

To build and copy the app to `~/Applications/Shots.app`:

```bash
scripts/build-app.sh --install
```

For development, open `app/Package.swift` in Xcode. Each view has a `#Preview` backed by `Shot.samples`. To run the tests:

```bash
swift test --package-path app
```

## Development

```bash
bun install
```

```bash
bun run build:helper
```

```bash
bun test
```

```bash
bun run typecheck
```

The tests use fixture PNGs (`test/fixtures`, regenerate them with `swift test/fixtures/make-fixtures.swift test/fixtures`), a scripted `MockBackend`, a fake `Native`, and fake `claude`/`codex` executables. Together they cover the escalation and privacy rules, the retry-on-invalid path, timeouts, the filing, deduplication and restart behavior, and the daemon's watcher, burst, and retry handling. `helper.integration.test.ts` runs the real Swift helper (Vision OCR, xattr metadata, Finder tags, FM status) and skips itself if the helper isn't built.

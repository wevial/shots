# shots

A macOS menu bar app that files screenshots on its own. Each new capture in the inbox is OCR'd on-device, tagged with the app/window/tab it came from, classified, renamed `YYYY-MM-DD_HHMM_<title>.png`, moved to `~/Screenshots/<category>/`, given Finder tags, and indexed for full-text search. A SwiftUI window lets you browse, search and re-file them.

```
inbox event ─▶ capture app context ─▶ wait for stable size ─▶ xattr/mdls: is it a screenshot?
           ─▶ Vision OCR ─▶ classify: apple → claude-code → codex (privacy-gated)
           ─▶ rename + move + Finder tags + clipboard ─▶ SQLite FTS5 index
```

Everything is one Swift package in `app/`:

| Target | What it is |
|---|---|
| `ShotsCore` | Config, the SQLite index, file handling, the classifier chain and backends, the pipeline and the watcher. Foundation, SQLite3 and CryptoKit only |
| `ShotsNative` | The macOS side: Vision OCR, NSWorkspace/Accessibility context, AppleScript tab URLs, screenshot xattrs, Finder tags, pasteboard, Foundation Models |
| `ShotsKit` | What the app's views use: the read-only `ShotStore`, the view models (`Shot`, `FailedJob`), `AppModel`, and `DaemonController`, which runs the watcher inside the app |
| `Shots` | The SwiftUI app: main window, Status & Permissions window, menu bar extra |
| `ShotsCommand` | The `shots` CLI, shipped inside the bundle at `Contents/Helpers/shots` |

Shots.app is the only process: it watches the inbox, files screenshots, and holds the macOS permissions. The CLI is for search and fixes from a terminal. Until October 2026 the daemon was a Bun/TypeScript LaunchAgent with a Swift helper. The port kept its config file, index schema and CLI output, and git history has the original.

## Design notes

| Check | Finding | Design consequence |
|---|---|---|
| `mdls` on a fresh capture | `kMDItemIsScreenCapture = (null)` for seconds after the file appears, and forever in folders Spotlight doesn't index | The same fields exist as `com.apple.metadata:kMDItemIsScreenCapture` / `…ScreenCaptureType` / `…GlobalRect` **xattrs** the moment the file lands. Those are read first; `mdls` is the fallback |
| Capture types seen | `selection`, `display` (plus `window`) | Passed to the classifier as context |
| Filenames | `Screenshot … at 10.22.28 AM.png` (narrow no-break space) | The original name is stored verbatim, and the new name is slugged |
| Write pattern | Hidden `.Screenshot…` temp file, then rename | Any change in the inbox triggers a debounced rescan of the folder instead of trusting event file names. A periodic rescan covers missed events |
| Foundation Models | `available`, 4096-token context, text-only on 26 | OCR is clipped to 4000 chars for apple. Image input sits behind `#available(macOS 27)` + `capabilities.contains(.vision)` in the same binary |
| `claude` | `-p --output-format json --json-schema` returns `structured_output`. `--restricted --safe-mode` confine reads to cwd (a `/etc/hosts` read was denied) | Used as-is with `--tools Read --allowed-tools Read(./screenshot.png)` |
| `codex` | `exec -i --output-schema -o --sandbox read-only --ignore-user-config` works. not every model name works on every account type | Default codex model is `gpt-6-luna` |

## Install

```bash
scripts/install.sh
```

This builds `Shots.app`, installs it to `/Applications`, symlinks `~/.local/bin/shots` to the CLI inside it, and launches it. It also removes the old `com.shots.agent` LaunchAgent if that's still around. On first launch the window offers **Launch at Login** (it uses `SMAppService`, so you can turn it off later in the Status window or in System Settings → General → Login Items). Started at login, the app stays in the menu bar. Opened by hand, it shows the window. Logs go to `~/Library/Logs/shots/shots.log`.

Next, point screenshots at the inbox and turn off the floating thumbnail:

```bash
defaults write com.apple.screencapture location ~/Screenshots/_inbox
```

```bash
defaults write com.apple.screencapture show-thumbnail -bool false
```

The thumbnail delays the file write by about 5 seconds. Context is captured when the file appears, so with the thumbnail on, the "frontmost app" may already be a different app.

Run `scripts/uninstall.sh` to quit and remove the app and the symlink. It keeps your screenshots, config and index.

### Signing

`scripts/build-app.sh` signs with the first **Apple Development** identity in your keychain, and falls back to ad-hoc signing with a warning. This matters for permissions: macOS ties an ad-hoc-signed app's grants to that exact build, so **every rebuild drops Accessibility**. Signed with a development certificate, grants survive rebuilds. To get one for free, sign into Xcode → Settings → Accounts with your Apple ID, then Manage Certificates → `+` → Apple Development. Check it with:

```bash
security find-identity -v -p codesigning
```

## Permissions

All grants go to **Shots.app**. The **Status & Permissions** window (Shots ▸ Status & Permissions…, ⌘,, or the menu bar item) shows the live state of each and opens the right System Settings pane. If the menu bar item is missing, check System Settings → Menu Bar → Allow in the Menu Bar.

| Permission | Needed for | Without it |
|---|---|---|
| **Accessibility** | Focused window title; URL of browsers without AppleScript (Firefox) | App name and bundle ID still work (NSWorkspace needs no permission), and window titles fall back to Screen Recording |
| **Automation** (per browser, prompted on first use) | Active tab URL and title in Safari and Chromium-family browsers (Chrome, Arc, Brave, Edge, Vivaldi, Dia) | No URL, or the AX fallback if Accessibility is granted |
| Screen Recording | *Optional.* Window titles via CGWindowList when Accessibility is denied | No window title |
| Full Disk Access | **Not needed** while the inbox and output are outside protected folders (Desktop, Documents and Downloads are protected) | — |

The app records what it actually has in `~/.local/share/shots/daemon-status.json`, which `shots doctor` reads. Run from a terminal, `doctor` can only check the terminal's own grants directly.

## The app

- **Capture preview:** each new screenshot pops a small panel in the bottom-right corner: "Copied · Filing…" within about half a second, then the title, a category menu to re-file it, and Open. It hides a few seconds after filing (not while hovered), can be dragged into other apps, and never takes focus. Toggle it with Show Preview After Capture in the menu bar menu or the Status window. It replaces the macOS floating thumbnail, which stays off.
- **Look:** Liquid Glass cards and controls over a soft gradient in the icon's colors behind the grid, which also shows through the glass sidebar and title bar; each category has its own color on its sidebar icon and badge.
- **Sidebar:** All, Needs Review, Failed, then the categories that hold screenshots; empty ones fold under More.
- **Grid:** thumbnails, newest first, with full-text search over OCR text, titles, tags, app, window and URL. Hovering a card shows a Copy strip along the bottom of its image.
- **Inspector:** preview, title, then Copy / Quick Look / Reveal / Open tiles, a category menu and a Re-run menu (Apple/Claude/Codex), a one-click accept for a suggested category, tags, metadata, OCR text.
- **Keyboard:** ⌘K command palette (actions on the selection, go to any scope, app commands, and full-text jump to any screenshot); ⌘F search, ↓ or Return to the results, Esc to clear; arrow keys move through the grid; Space Quick Look; Return opens; ⌘C copies the image; Esc deselects; ⌘1–⌘9 jump to sidebar rows; ⌥⌘I toggles the inspector; Tab moves between panes. Drag a card out to another app, or right-click to move, re-run, reveal or copy.
- **Menu bar:** watching status, Pause/Resume, the review count, recent screenshots, Open Inbox Folder, Show Preview After Capture, Status & Permissions.

The app icon is drawn by `app/Resources/make-icon.swift`; re-run it (`swift app/Resources/make-icon.swift app/Resources`) after changing the drawing.

The views read the index through a read-only connection and refresh when `PRAGMA data_version` changes. Re-categorizing runs the same `recat` as the CLI, in-process. Nothing in the app deletes files.

## CLI

```
shots search <query> [--limit N] [--json]   FTS5 over OCR text, title, tags, app, window, URL
shots recat <file> [--backend apple|claude-code|codex|rules] [--category <name>] [--json]
shots review [--failed]                     low-confidence/unknown-category shots, or failed jobs
shots doctor                                OS, model + image path, CLIs + auth, permissions, config
shots config [--json]                       effective config
shots run                                   watch the inbox headless (Shots.app normally does this)
```

`recat` reuses the stored OCR and context, renames and moves the file, and swaps only the tags shots applied (your own Finder tags stay). Passing `--backend` for a cloud backend on a denylisted shot is refused. Don't run `shots run` while the app is watching the same inbox.

## Classifier chain

Every backend gets the same prompt: the category list with one-line hints, the app/window/URL, the capture type and size, and the OCR text. Every backend returns `{category, tags, title, confidence}`.

- **apple** runs Foundation Models in-process, using `@Generable` guided generation, on-device. Text-only on macOS 26. On 27+ with the vision capability, it attaches the image automatically.
- **claude-code** runs `claude -p` in a fresh temp dir that holds only a copy of the image. It uses `--restricted --safe-mode --strict-mcp-config`, `Read` scoped to that one file, `dontAsk` permissions, no session persistence, and your existing login.
- **codex** runs `codex exec` in the same kind of temp dir with the image attached via `-i`. It uses a `read-only` sandbox, `--ignore-user-config --ignore-rules --ephemeral`, memories/plugins/hooks disabled, a strict `--output-schema`, and your existing login.
- **rules** is local and deterministic: an `appRules` bundle-ID → category map, then OCR keywords.

CLI backends are found on `PATH` plus `~/.local/bin`, `~/.npm-global/bin`, `/opt/homebrew/bin` and `/usr/local/bin`, since an app started from Finder gets a minimal `PATH`. Their output gets JSON extraction (fences and prose stripped) and schema validation. A bad reply gets **one** corrective retry that quotes it, and then the backend fails. A timeout (`timeoutMs`) kills the whole process group.

The chain moves to the next backend on error, unavailability, timeout, or confidence below `escalateBelowConfidence`, and keeps the most confident result it has seen. If the final category is unknown or its confidence is below `reviewBelowConfidence`, the shot goes to `misc`, gets a `review` Finder tag, and appears under Needs Review with the model's suggestion. If every backend fails, the file stays in the inbox, is retried after `retryDelayMs` up to `maxAttempts` times, and shows under Failed.

> **Apple's confidence is uncalibrated on macOS 26.** In testing it answered 0.9 for every screenshot, right or wrong, so with the default chain it never escalates. Set `"confidenceCap": {"apple": 0.55}` to always get a cloud second opinion (apple still serves denylisted shots), or reorder `backends`.

## Privacy

- **apple** and **rules** never leave the machine. OCR always runs locally.
- `allowCloud: false` turns off claude-code and codex everywhere.
- `cloudDenylist` (bundle IDs or app names; password managers are seeded) and `cloudDenylistDomains` (for example `"chase.com"`, which matches subdomains of the active browser tab) keep a shot to apple, or to rules if apple is unavailable.
- `cloudWhenAppUnknown` (default `true`) decides what happens when no context was captured, which is the case for files found by a scan rather than a live event.

## Config (`~/.config/shots/config.json`)

The defaults are written on first run, and any key can be overridden. **Reload Config** in the Status window picks up changes. These are the important ones:

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

The index lives at `~/.local/share/shots/shots.db` (WAL). The `jobs` table makes the watcher idempotent and restart-safe: jobs interrupted mid-run resume, files with the same bytes are skipped as duplicates, and non-screenshots are skipped once and then left alone. Quitting the app lets the job in progress finish (up to 10 s); queued jobs wait for the next launch. Originals are never deleted. A move is a hard link followed by an unlink (copy, verify, unlink across volumes), and it refuses to overwrite.

## Development

Open `app/Package.swift` in Xcode. Each view has a `#Preview` backed by `Shot.samples`. From a terminal:

```bash
swift build --package-path app
```

```bash
swift test --package-path app
```

```bash
scripts/build-app.sh --install
```

The tests use fixture PNGs (`app/Tests/ShotsCoreTests/Fixtures`; regenerate them with `swift make-fixtures.swift .` from that folder), a scripted `MockBackend`, a `FakeNative`, and fake `claude`/`codex` executables. Together they cover the escalation and privacy rules, the retry-on-invalid path, process-group timeouts, filing, deduplication and restart behavior, and the watcher's burst and retry handling. `NativeIntegrationTests` exercise the real Vision OCR, screenshot xattrs, Finder tags and Foundation Models status. `CompatibilityTests` and `FixtureStoreTests` open an index written by the original TypeScript daemon, to prove old indexes still work.

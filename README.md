# Wispstage

**End-to-end tests for Mac apps that check every screen for you, run while you keep working, and are built to be written by coding agents.**

[中文说明](README.zh-CN.md)

You write what a user does: click Settings, switch the language, press Save. Wispstage drives your real app through the macOS Accessibility API and, after every step, inspects every window of your app for the bugs nobody writes assertions for: truncated labels, overlapping text, text spilling out of a window, leftover `%@` placeholders, "1 Minutes", key presses that only produce a beep. In background mode your app's windows sit beneath the desktop wallpaper, so you keep using your Mac while the suite runs.

It ships as a Swift package and a Claude Code plugin, so an agent can wire it into your project, write the scenarios and read the results.

## Why Wispstage

### Every step gets a free check-up

Each scenario step is followed by a set of generic checks that work on any app, because they rely on what every Mac app already exposes: the accessibility tree (text, frames, fonts, roles), window screenshots and process state. Beep detection additionally needs the level-2 test host described below.

| Fails the step | Listed in the summary for review |
|---|---|
| Crash or hang (no accessibility response within 5 s) | Text contrast below WCAG 4.5:1 (3:1 for large text) |
| Unreplaced placeholders: `%@`, `%d`, `{…}`, and raw localization keys if you supply your strings table's keys | Clickable targets smaller than the 20×20 pt macOS minimum |
| English count/plural mismatches such as "1 Minutes" (when the app runs in English) | Misaligned siblings in a column |
| Two pieces of text overlapping in the same window | Visible elements without an accessibility identifier |
| Text extending outside its window | Text partly covered by another view |
| Truncated text (layout check, confirmed by on-screen text recognition) | Pixel differences against an accepted baseline screenshot |
| A key press nobody handled (the system beep; level 2) | |
| In background mode: the app stealing keyboard focus or coming to the front | |

### Your Mac stays yours

Most Mac UI automation takes over the machine: the app under test comes to the front, the cursor moves and your typing lands in the wrong window. Wispstage has two modes, and you pick one per run:

| | Background (default) | Foreground |
|---|---|---|
| Your Mac | Keep working: the cursor stays put, focus stays where it is, no beeps | Screen, keyboard and cursor are taken for the run, after a 5-second countdown |
| App windows | Placed beneath the desktop wallpaper | Real windows in front, real key focus |
| Input | Accessibility actions and per-process key events; clicks, drags, hovers and scrolls synthesized inside the app process | Real mouse and keyboard events |
| Covers | Everything up to a `t.requireForeground(...)` or `t.globalKey(...)` call; the rest of that scenario is skipped and listed in `summary.txt` under `Skipped in background mode` | Everything |

Background mode needs no virtual machine and no XCUITest runner: only the driver process and a small library linked into your app's test-host target. After each background scenario, Wispstage checks that the system cursor is where it was before the scenario; if you moved the mouse yourself during the scenario, the cursor position is not judged, so your own mouse use never fails a test.

If you move the cursor during a foreground run, the step pauses until the cursor is still and is retried once. If the cursor moves again during the retry, the scenario is recorded as `interrupted`: later steps do not run, it counts as neither passed nor failed, and `summary.txt` lists it under `Interrupted by user input`.

### Built for coding agents

The Claude Code plugin adds the `wispstage` command to the agent's shell and a skill that teaches the agent to:

- add accessibility identifiers in an `area.element` scheme (for example `settings.save`), using `wispstage listing` to find visible elements that lack one;
- write scenarios in Swift against the real app;
- run them and read `summary.txt`, the per-step logs and screenshots;
- move a project up through the adoption levels below.

`wispstage init` scaffolds a scenario package with a working smoke test, so the agent starts from something that already runs.

### Your release build stays clean

The release app never links any test code. Background mode works through a separate test-host target that links the stage library; everything else drives the app from outside. You can adopt it one level at a time:

| Level | What you change | What you get |
|---|---|---|
| 0 | Nothing. Run `wispstage init` | Foreground runs; elements found by text and role |
| 1 | Add accessibility identifiers to visible, interactive elements | Scenarios that survive copy changes and localization |
| 2 | Add a test-host target that links `Wispstage` and calls `Wispstage.install()` after creating `NSApplication` and before `run` | Background runs; beep detection |
| 3 | Put system services (calendar, notifications, authorization, clock, network) behind protocols with test doubles in the test host | Runs that never touch your real data or show permission prompts |

## How it compares

| | Wispstage | XCUITest | AI computer-use tools | Snapshot tests |
|---|---|---|---|---|
| Drives the real, running app | Yes | Yes | Yes | No, renders views in a test process |
| Generic UI checks after every step | Yes | On demand (`performAccessibilityAudit`, macOS 14+), not after every step | No | Pixel diff only |
| Lets you keep using your Mac | Yes, in background mode | No | Varies | Yes |
| Repeatable scenarios in your repo | Yes, Swift | Yes, Swift | Mostly free-form | Yes |
| Test code linked into the release app | None | None | None | None |

## Quick start

Requirements: macOS 14 or later (the deployment target; tested on macOS 27), Xcode 16 or a Swift 6 toolchain.

1. Install the plugin:

   ```bash
   claude plugin marketplace add yales66/wispstage
   claude plugin install wispstage@wispstage
   ```

   To work from a local clone instead:

   ```bash
   git clone https://github.com/yales66/wispstage wispstage
   claude plugin marketplace add ./wispstage
   claude plugin install wispstage@wispstage
   ```

   Outside Claude Code, run `wispstage/bin/wispstage` directly or symlink it into a directory on your `PATH`. The first call compiles the command-line tool into `~/Library/Caches/wispstage/` (override with `WISPSTAGE_CACHE`) and later calls rebuild only when the sources change.

2. In System Settings → Privacy & Security, turn on **Accessibility** and **Screen Recording** for the terminal app that runs `wispstage` (inside Claude Code, the terminal running Claude Code). Foreground runs also need permission to post input events. `wispstage run` checks these permissions before it starts; if one is missing it exits with `The terminal running the driver lacks permissions: <list>. Grant them to the terminal in System Settings > Privacy & Security, then run again.`, where the list names `Accessibility`, `Screen Recording` or `event posting`.

3. In your project root:

   ```bash
   wispstage init --app-name MyApp --executable .build/debug/MyApp
   ```

   `--executable` is relative to the project root. If you omit it, the default is `.build/debug/<app name>`, where the app name comes from `--app-name` or the folder name. For an Xcode project, build into the project folder first and pass the full relative path:

   ```bash
   xcodebuild -scheme MyApp -configuration Debug -derivedDataPath build/xcode build
   wispstage init --app-name MyApp --executable build/xcode/Build/Products/Debug/MyApp.app/Contents/MacOS/MyApp
   ```

   A bare executable such as `.build/debug/MyApp` is fine for foreground runs. For background runs, use an executable inside an `.app` bundle; the [integration guide](skills/wispstage/references/integration.md#level-0-no-changes-to-the-app) explains why and how to wrap a bare one.

   The generated `E2E/Package.swift` depends on your local copy of the plugin by absolute path. Before you commit it, replace that dependency with `.package(url: "https://github.com/yales66/wispstage", from: "0.1.0")` and set `package: "wispstage"` in the `.product(name: "WispstageKit", ...)` entry.

4. Build your app, open the generated `SmokeScenarios.swift` and set `anchorID` to an identifier your app has (until you add identifiers, the scenario falls back to the first static text it finds).

5. Run it. Before level 2, use foreground mode:

   ```bash
   wispstage run --mode foreground smoke.
   ```

6. Open `build/e2e-runs/<timestamp>/summary.txt`.

A scenario looks like this:

```swift
scenario("settings.saveClosesSheet") { t in
    try t.launch(LaunchSpec(executable: t.configuration.defaultExecutable, ready: .anyWindow), step: "launch")
    try t.click(.id("settings.save"))
    try t.shot(id: "main.title")
}
```

The full API is in [`skills/wispstage/references/api.md`](skills/wispstage/references/api.md) and the level-by-level integration guide in [`skills/wispstage/references/integration.md`](skills/wispstage/references/integration.md).

## How it works

```
 Wispstage (driver process)                  your app's test host
 ┌──────────────────────────┐  Accessibility   ┌───────────────────────────┐
 │ scenarios (your Swift)   │ ───────────────▶ │ your app code, unchanged  │
 │ generic checks per step  │  key events      │                           │
 │ screenshots, text recog. │ ───────────────▶ │ Wispstage (levels 2+):    │
 │ summary, baselines       │  Unix socket:    │  windows under wallpaper, │
 │                          │  pointer commands│  no key focus/activation, │
 │                          │ ───────────────▶ │  in-process clicks,       │
 │                          │  events          │  drags, hovers, scrolls   │
 │                          │ ◀─────────────── │                           │
 └──────────────────────────┘                  └───────────────────────────┘
```

The stage library only does what keeping your Mac usable requires, and reports every intervention (a blocked activation, a swallowed beep) as an event that scenarios can assert on. In foreground mode it switches to an observe-only mode that intercepts nothing and only reports beeps, key-window changes and activation requests.

## Commands

| Command | What it does |
|---|---|
| `wispstage init [--app-name N] [--executable PATH] [--dir DIR]` | Scaffold a scenario package (default `E2E/`) with a smoke scenario and a `.wispstage.json` at the project root; never overwrites existing files |
| `wispstage list [filter…]` | List scenario names without launching the app |
| `wispstage run [--mode foreground\|background] [--shots=key\|all\|none] [filter…]` | Run scenarios by full name or prefix (`smoke.`). `--shots` controls automatic full-window screenshots: `key` (default) takes the first, last and failing steps, `all` every step, `none` neither automatic nor failure screenshots. Explicit `t.shot` and `t.shot(id:)` calls take their screenshots whatever `--shots` says. Every screenshot a run keeps, automatic or explicit, is compared with its baseline; failure screenshots are not |
| `wispstage baseline accept <run-dir> [filter…]` | Accept a run's screenshots as the baseline for later pixel comparison |
| `wispstage windows (--pid N \| --bundle-id ID)` | List the on-screen windows of a running app |
| `wispstage listing (--pid N \| --bundle-id ID) [--out FILE]` | Dump a running app's UI as text and list visible elements that lack an identifier |
| `wispstage shot (--pid N \| --bundle-id ID) [--window ID] [--id IDENT] [--out DIR]` | Screenshot a window, or crop one element by identifier |
| `wispstage summary <run-dir>` | Regenerate `summary.txt` from `results.json` |

`list`, `run` and `baseline` find `.wispstage.json` in the current directory or a parent and hand the arguments to the scenario package it names (`scenarioPackage` is relative to that file):

```json
{"scenarioPackage": "E2E", "product": "myapp-e2e"}
```

Each run writes `summary.txt` (counts, failing steps with reasons, the review lists and baseline differences), `results.json`, and one folder per scenario with `steps.log`, screenshots, a text dump of the UI, the accessibility tree on failure, and the app's events and standard error.

## Limitations

- It only sees what the app exposes to accessibility. Custom-drawn content (games, canvas charts) can be compared against baselines but not inspected.
- Background mode and beep detection need level 2: a test-host target that links the stage library.
- Some checks cannot tell intent from accident, so they are listed rather than failed: an overlay that partly covers the content beneath it is often deliberate, and contrast is measured against a background color sampled from the screenshot.
- The overlap and out-of-window tolerances absorb rounding in accessibility frames; their values have not yet been tuned across many apps.
- Beeps that AppKit emits outside the "no responder for this key" path are not yet detected.
- macOS only.

## Development

```bash
swift test --package-path wispstage
```

The Claude Code skill lives in `skills/wispstage/` and the plugin manifest in `.claude-plugin/`. CI runs the same build and tests on GitHub's macOS runner (`.github/workflows/ci.yml`); tests that need a graphical session or Screen Recording skip themselves when the machine lacks it.

## License

MIT. See [LICENSE](LICENSE).

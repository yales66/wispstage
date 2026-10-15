<div align="center">

# Wispstage

**End-to-end tests for Mac apps that run while you keep working.**

Your app runs beneath the desktop wallpaper, your cursor and keyboard stay yours,<br>
and every step is checked for broken UI without you writing an assertion.

[![CI](https://github.com/yales66/wispstage/actions/workflows/ci.yml/badge.svg)](https://github.com/yales66/wispstage/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey.svg)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138.svg)

[Quick start](#quick-start) · [How it works](#how-it-works) · [What it checks](#what-it-checks) · [Writing scenarios](#writing-scenarios) · [For coding agents](#for-coding-agents) · [中文说明](README.zh-CN.md)

</div>

Wispstage drives SwiftUI and AppKit apps through Accessibility and synthesized input. You write scenarios in Swift; Wispstage runs them on your own Mac, checks the UI after every step and writes a plain-text report; when everything passes, a coding agent reads it in a few hundred tokens.

- In background mode the app's windows stay beneath the wallpaper and never take focus. Clicks, drags, hovers and scrolls are carried out inside the app, so the real cursor never moves. No virtual machine is involved. Background mode needs a small test-host target in your project; without it, runs use foreground mode and take over the screen.
- After every step, crashes, hangs, truncated or overlapping text, text outside its window, unfilled placeholders and, with a test host, beeps from unhandled keys fail the step on their own. Low contrast, tiny click targets and missing accessibility identifiers are listed for review.
- Scenarios are compiled Swift, so a run makes no model calls. An agent writes a scenario once and reads a text summary afterward.
- Screenshot baselines are kept per language, appearance and clock format, and every pixel difference comes with a highlight image.
- An optional command channel on the app's standard input and output lets scenarios read app state and wait for app events.
- Motion recording follows elements frame by frame through an animation.
- Test code lives in a separate test-host target; your release app links nothing from Wispstage.
- Background runs from different checkouts run at the same time when their test apps have different bundle identifiers.

Wispstage was built while testing a production Mac app with coding agents.

## What a run gives you

Every run ends with a `summary.txt`:

```
MyApp E2E  2026-10-15T10:15:00Z
Run mode: background
Input: inprocess
Full-window screenshots: key
Passed: 1  Failed: 1  Skipped: 1  Interrupted: 0  Known failures: 0

Skipped in background mode (1, run with --mode foreground to test them):
  hotkeys.global @01-launch: Step needs foreground mode: global hotkeys need system keyboard events

Passed  smoke.launch  (4.8s, 4 steps)
Failed  settings.save  (9.1s, 7 steps)
      Failed step: 04-open-settings
      Reason: [truncation] settings#4512 "Notify me when a session ends"(412,318 180x16) is truncated: recognized "Notify me when a sess…" in the screenshot, with an ellipsis
      Crop [truncation] failed @ 04-open-settings "settings.notify": /Users/me/MyApp/build/e2e-runs/20261015-101500/settings.save/04-open-settings-settings.notify.png
      Missing identifier (1, listed for review):
        @04-open-settings Button"Advanced…" (16,240 96x20)
Skipped  hotkeys.global  (1.2s, 1 step)
      Skipped at: 01-launch
      Reason: Step needs foreground mode: global hotkeys need system keyboard events
```

The `settings.save` scenario contains no assertion about truncation. The check runs after every step, and the summary points straight at a crop of the label that was cut off. Steps are numbered in the order they ran (`04-open-settings`), windows are named by kind and window number (`settings#4512`), and frames read `(x,y width x height)` in points. `Input: inprocess` means pointer input was carried out inside the app.

## How it compares

| While a suite runs | XCUITest | Computer-use agent | Wispstage, background mode |
|---|---|---|---|
| Your cursor and keyboard | Taken over | Taken over | Yours |
| The app's windows | In front | In front | Beneath the wallpaper |
| Model calls | None | One per action, with a screenshot | None |
| What you need | A UI test target | Nothing | A scenario package and a test-host target |

A macOS virtual machine also leaves your desktop alone, at the cost of a second macOS install (tens of GB on disk, several GB of RAM while it runs) and a limit of two macOS guests per Mac under Apple's license. Choose a virtual machine when every run must start from a clean system image. Choose Wispstage for many quick runs on the Mac you work on; [adoption level 3](#adoption-levels) keeps those runs away from your real data.

## Quick start

### Install

In Claude Code:

```bash
claude plugin marketplace add yales66/wispstage
claude plugin install wispstage@wispstage
```

The plugin adds the `wispstage` command to Claude Code's shell, and a skill that teaches Claude to adopt the framework, write scenarios and read results. To use `wispstage` in your own terminal, clone this repository and link `bin/wispstage` into your `PATH`. The first call builds the command-line tool, which takes about a minute; later calls start at once.

### Requirements

macOS 14 or later and a Swift 6 toolchain (Xcode 16 or later). In System Settings → Privacy & Security, grant **Accessibility** and **Screen Recording** (called **Screen & System Audio Recording** on macOS 15 and later) to the terminal app that runs `wispstage`. `wispstage run` checks the permissions it needs before it starts, names any that are missing and exits with 1.

### First run

Build your app, then point `init` at the executable. For a Swift package:

```bash
cd MyApp                                   # your project root
swift build
wispstage init --app-name MyApp --executable .build/debug/MyApp
wispstage run --mode foreground smoke.     # runs scenarios whose names start with "smoke."
```

For an Xcode project, build into the project folder and pass the executable inside the `.app`:

```bash
cd MyApp
xcodebuild -scheme MyApp -derivedDataPath build/xcode build
wispstage init --app-name MyApp --executable build/xcode/Build/Products/Debug/MyApp.app/Contents/MacOS/MyApp
wispstage run --mode foreground smoke.
```

`init` creates a scenario package in `E2E/` with a smoke scenario, and a `.wispstage.json` at the project root. It never overwrites a file that exists. `wispstage run` builds the scenario package but not your app, so rebuild the app before each run after you change it.

The default mode is background, and background mode needs a test host ([adoption level 2](#adoption-levels)). Your app has none yet, so this first run passes `--mode foreground`: after a 5-second countdown the app comes to the front and the run uses your screen, keyboard and cursor. Without a test host, a run that leaves out `--mode` fails every scenario at launch.

When the run finishes, read `build/e2e-runs/<time>/summary.txt`. Then open the generated `E2E/Sources/…/SmokeScenarios.swift` and set `anchorID` to an accessibility identifier your app has; until you do, the smoke scenario falls back to the first static text it finds.

`init` points `E2E/Package.swift` at the copy of Wispstage that ran it (the plugin's install folder, or your clone) by absolute path. Before you commit it, switch to the published package so the path works on other machines: `.package(url: "https://github.com/yales66/wispstage", from: "0.1.0")`, and `package: "wispstage"` in the `.product(name: "WispstageKit", …)` entry.

## How it works

![Wispstage architecture: the driver process runs your scenarios and checks; it reaches the test host through Accessibility, key events, a Unix socket to the stage library and an optional command channel, and captures the app's windows for the checks](docs/architecture.svg)

<sub>[Editable source](docs/architecture.drawio)</sub>

A background-mode run goes like this:

1. `wispstage run` finds `.wispstage.json` and starts your scenario package with `swift run`. That process is the driver: your scenarios compiled together with WispstageKit.
2. For each scenario the runner takes a lock, then runs the scenario. Its launch step starts the test host with `WISPSTAGE_STAGE=1`, and the stage library inside the test host keeps the windows beneath the wallpaper and stops the app from activating or taking key focus.
3. The driver reaches the app in four ways:
   - Accessibility, to read the UI tree, press buttons, set values and pick menu items.
   - Key events sent to the app's process. The stage library delivers them to the key window, so Esc cancels and Return presses the default button.
   - A Unix socket to the stage library. Pointer commands go to the app and are carried out inside it; beeps and key-window events come back.
   - An optional command channel on the app's standard input and output, for state and events your scenarios ask for.
4. After each action the driver waits until the UI stops changing, reads the UI tree, captures the windows and runs its checks. When a scenario ends it compares the scenario's screenshots with the accepted baselines; when the last one ends it writes `summary.txt` and `results.json`.

### Background and foreground mode

| | Background (default) | Foreground |
|---|---|---|
| Your Mac | You keep working: the cursor stays put, focus stays where it is, no beeps | Screen, keyboard and cursor are taken for the run, after a 5-second countdown |
| App windows | Beneath the wallpaper, never key | In front, with real key focus |
| Input | Accessibility actions, key events sent to the app's process, pointer input carried out inside the app | Accessibility actions, real mouse and keyboard events |
| Needs | A test host that links the `Wispstage` library, packaged as an `.app` | Nothing |
| Runs alongside | Background runs of apps with other bundle identifiers | Nothing; it waits for every other run on the Mac |

In background mode a scenario stops at the first `t.requireForeground(...)` or `t.globalKey(...)` call, and `summary.txt` lists it under `Skipped in background mode`. After each background scenario the driver checks that the system cursor is where it was; if the run moved it, the scenario fails, and if you moved the mouse yourself, the position is not judged. In a foreground run, moving the cursor during a step makes the step wait until the cursor is still and retry once; a second move records the scenario as interrupted.

### Adoption levels

| Level | What you change | What you get |
|---|---|---|
| 0 | Nothing. Run `wispstage init` | Foreground runs; elements found by text and role |
| 1 | Accessibility identifiers named `area.element`, such as `settings.save` | Scenarios that survive copy changes and localization |
| 2 | A test-host target that links `Wispstage` and calls `Wispstage.install()` after creating `NSApplication`, before `run` | Background runs and beep detection |
| 3 | Calendar, notifications, authorization, clocks and network behind protocols, with test doubles in the test host | Runs that never touch your data or show permission prompts |

### Adding a test host

Wispstage ships two libraries. `WispstageKit` is what your scenario package uses. `Wispstage` is the stage library, and only the test host links it.

The test host is a second executable target built from the same app code as your release app; the suite launches it instead of your release build. In a Swift package, move the app into a library target, then give the release app and the test host one entry point each:

```swift
// Package.swift
dependencies: [.package(url: "https://github.com/yales66/wispstage", from: "0.1.0")],
targets: [
    .target(name: "MyAppKit"),                                    // the app itself
    .executableTarget(name: "MyApp", dependencies: ["MyAppKit"]), // release entry point
    .executableTarget(name: "MyAppTestHost", dependencies: [
        "MyAppKit", .product(name: "Wispstage", package: "wispstage"),
    ]),
]
```

```swift
// Sources/MyAppKit/MyApp.swift: the App struct, public and without @main
import SwiftUI

public struct MyApp: App {
    public init() {}
    public var body: some Scene { WindowGroup { ContentView() } }
}

// Sources/MyApp/main.swift (release)
import MyAppKit
MyApp.main()

// Sources/MyAppTestHost/main.swift
import AppKit
import Wispstage
import MyAppKit

MainActor.assumeIsolated {
    _ = NSApplication.shared
    _ = Wispstage.install()   // after NSApplication exists, before the app runs
    MyApp.main()
}
```

In an Xcode project the idea is the same: take `@main` off the `App` struct, add a second app target that compiles the same source files plus its own `main.swift` (without `import MyAppKit`), and add the Wispstage package to that target only.

Then point the scenario package at the test host. In `E2E/Sources/<product>/main.swift`, `init` generated an `E2EConfiguration(…)` whose `defaultExecutable:` names the app to launch. Background mode needs that executable inside an `.app` bundle: the driver reads the bundle identifier from it, and macOS treats a bare executable as part of the terminal that started it. An Xcode build already produces an `.app`. A `swift build` product is bare, so wrap it:

```swift
defaultExecutable: try PreviewBundle.prepare(
    executable: projectDir.appendingPathComponent(".build/debug/MyAppTestHost"),
    in: projectDir.appendingPathComponent("build/e2e-bundle"),
    bundleID: "com.example.MyApp.testhost", name: "MyApp Test Host"),
```

`prepare` copies the executable into an `.app` with that bundle identifier, recopies it only when it changes, and returns the executable inside the bundle. After that, `wispstage run` with no `--mode` runs in the background. The [integration guide](skills/wispstage/references/integration.md) covers every level in more detail, including an AppKit test host.

## What it checks

After every action step, on every window of the app:

| Fails the step | Listed in the summary, does not fail |
|---|---|
| A crash, or no accessibility response within 5 s | Text contrast below WCAG 4.5:1 (3:1 for large text) |
| Truncated text, found by text recognition on the window and confirmed on a crop of the element | Click targets smaller than 20×20 pt |
| Overlapping text | Siblings in a column that are not aligned |
| Text outside its window | Visible elements without an accessibility identifier |
| Placeholder text that was never filled in: `%@`, `{name}`, raw localization keys | Text partly covered by another view |
| "1" followed by a plural noun, such as "1 Minutes", in an English UI | |
| A beep from a key press the app does not handle (level 2) | |
| In background mode: a window becoming key, or the app coming to the front | |

When a scenario ends, its screenshots are compared with the accepted baselines. Differences are listed with a highlight image and do not fail the scenario.

Only the beep check and the background-mode focus checks need a test host; every other check works at level 0. When a check fails, the summary links a crop of the element involved. To accept a known exception, `t.waive(.truncation, reason: "…")` waives one check for the next step or for a block.

## Writing scenarios

Scenarios live in the scenario package, one file per area of your app. Create `E2E/Sources/<product>/SettingsScenarios.swift`:

```swift
import WispstageKit

let settingsScenarios: [Scenario] = [
    scenario("settings.save") { t in
        try t.launch(LaunchSpec(executable: t.configuration.defaultExecutable), step: "launch")
        try t.press(id: "main.openSettings")
        try t.window(.settings)
        try t.setValue("settings.name", "Ada", submit: false)
        try t.press(id: "settings.save")
        try t.waitGone(.settings)
        try t.expect(try t.text(of: "main.greeting") == "Hello, Ada", "the greeting uses the saved name")
        try t.shot(id: "main.greeting")
    },
]
```

Then add it to `allScenarios` in the package's `main.swift` (`smokeScenarios + settingsScenarios`).

`t.press(id:)` and `t.press(label:role:)` perform an element's accessibility action and need no pointer. Calls that take a target, such as `t.click`, `t.setValue` and `t.shot`, read a string as an accessibility identifier and accept `.label("Save", role: .button)` to find an element by its text; use `t.click` for controls that respond only to the mouse. `setValue` presses Return after typing unless you pass `submit: false`. Each action is one step: it is logged, the UI is allowed to settle, and the checks run.

`.settings` is a window kind. A window gets its kind from an identifier such as `settings.window`, or from a title containing "Settings"; [api.md](skills/wispstage/references/api.md#targets-target) shows how to add your own kinds.

### Known failures

`t.expectFailure("BUG-12") { … }` records a failure inside the block as a known failure, so the rest of the scenario still runs. When the block stops failing, the summary says the bug may be fixed.

### Reading app state

Your test host can read one command per line on standard input and answer on standard output with three kinds of line. The commands are yours to define, and the app must flush standard output after each line, because a pipe is block-buffered:

| Line the app writes | Meaning |
|---|---|
| `WISPSTAGE_EVENT {"type":"item.saved","id":3}` | An event; `type` is required |
| `WISPSTAGE_STATE <content>` | A reply named `STATE` (any uppercase name works) |
| `WISPSTAGE_ERROR <reason>` | An error; the command that caused it fails |

Scenarios then drive the app and wait on it:

```swift
try t.send("advance 600")                                   // e.g. move a fake clock forward
let state = try t.request("dump-state", reply: "STATE")    // returns <content>
try t.waitEvent("item.saved", where: { $0["id"] as? Int == 3 })
```

### Baselines

`t.shot("name")` keeps a full-window screenshot and `t.shot(id:)` crops one element. `wispstage baseline accept <run-dir>` saves a run's screenshots as baselines. To keep separate baselines per language, appearance or clock format, launch with a variant name, such as `LaunchSpec(…, variant: Baselines.variant(language: "en", appearance: .dark, hour24: true))`, which files them under `en-dark-24h/`.

### Motion

`t.recordMotion("open-panel", ids: ["panel.content"]) { try t.press(id: "panel.open") }` records the element's frame and the screen frame by frame while the block runs. Pass `specs` and the report lists where the movement deviates from them; deviations do not fail the step.

### Hooks and configuration

`E2EHooks` runs your code before each launch (and can refuse it) and after each stop. `E2EConfiguration` sets the run and baseline folders, your localization keys for the placeholder check, and the text recognition languages for the truncation check; add `zh-Hans` for a Chinese UI.

The full API is in [`skills/wispstage/references/api.md`](skills/wispstage/references/api.md).

## Reading the results

Each run writes `build/e2e-runs/<time>/` with `summary.txt`, `results.json` and one folder per scenario:

| File | Contents |
|---|---|
| `steps.log` | Every step, wait and check |
| `NN-<step>.ax.txt` | The step's UI as text, one line per element with role, identifier, text and frame; read this first |
| `NN-<step>.png` | Full-window screenshots, chosen by `--shots` |
| `NN-<step>-<element>.png` | Element crops from `t.shot(id:)` and from failed checks |
| `<shot>.diff.png` | Pixel differences against the baseline |
| `ax-<step>.txt`, `NN-<step>-failed.png` | When a step fails: a raw dump of every window's accessibility tree, and a screenshot |
| `events.jsonl`, `app-stderr.log` | The app's events and standard error |

`--shots=key` (the default) keeps full-window screenshots of the first, last and failing steps; `all` keeps every step; `none` keeps none, though crops of failed checks are still written. Explicit `t.shot` calls always take their screenshots.

`wispstage run` exits with 0 when nothing failed, 1 when a scenario failed or a permission is missing, 2 when no scenario matched or an argument is invalid, and 75 when the screen is locked before the run starts. Skipped and interrupted scenarios do not change the exit code.

## For coding agents

An agent that writes and runs your tests pays for everything it reads. Wispstage keeps that small:

- A passing run is one `summary.txt`. The agent opens more only when something fails.
- Each step's UI is also saved as text (`.ax.txt`), with exact identifiers and strings instead of a picture to read them from.
- When the agent does need to see something, it can open a crop of one element instead of the whole window.

A full-window screenshot of a Retina window costs an agent 2,000 to 4,600 tokens to read, depending on how the model scales images, so looking at one after every step adds up fast. With Wispstage the agent reads about 300 tokens when everything passes (the summary), and about 3,000 when one scenario fails (the summary, that step's text listing and one element crop).

The Claude Code plugin ships a skill that covers adoption, scenario writing, running and reading results, so Claude can take a Mac app from no tests to a background suite.

## Running suites in parallel

Each scenario takes a lock in `~/Library/Caches/wispstage/` before it starts and waits while the lock is held.

| How you run | What runs at the same time |
|---|---|
| Foreground | Nothing else on the Mac |
| Background | Every background run whose test app has a different bundle identifier |
| Background, same bundle identifier | One scenario at a time; the runs take turns |

Give the test host in each git worktree its own bundle identifier and the worktrees' suites run side by side, each with its own sandbox container and preferences.

## Commands

<details>
<summary>All commands</summary>

| Command | What it does |
|---|---|
| `wispstage init [--app-name N] [--executable PATH] [--dir DIR]` | Scaffold a scenario package (default `E2E/`) with a smoke scenario, and a `.wispstage.json` at the project root; never overwrites existing files |
| `wispstage list [filter…]` | Build the scenario package and list scenario names, without launching the app |
| `wispstage run [--mode foreground\|background] [--shots=key\|all\|none] [filter…]` | Run scenarios whose names equal or start with a filter (`smoke.`, `settings.save`); no filter runs all. The mode can also come from `WISPSTAGE_MODE` |
| `wispstage baseline accept <run-dir> [filter…]` | Save a run's screenshots as baselines |
| `wispstage summary <run-dir>` | Rewrite `summary.txt` from `results.json` |
| `wispstage windows (--pid N \| --bundle-id ID)` | List the on-screen windows of a running app |
| `wispstage listing (--pid N \| --bundle-id ID) [--out FILE]` | Write a running app's UI as text and list visible elements without an identifier |
| `wispstage shot (--pid N \| --bundle-id ID) [--window ID] [--id IDENT] [--out DIR]` | Screenshot every window of a running app, one window with `--window`, or one element with `--id` |

`list`, `run` and `baseline` find `.wispstage.json` in the current directory or a parent and pass their arguments to the scenario package it names:

```json
{"scenarioPackage": "E2E", "product": "myapp-e2e"}
```

</details>

## Limitations

- Wispstage sees what the app exposes to Accessibility. Custom-drawn content such as games and canvas charts can be compared against baselines but not inspected, and an overlay missing from the accessibility tree is invisible to the occlusion check.
- Background mode cannot reproduce behavior that depends on an active window: focus rings and active-window colors, a first click that only activates, input-method composition such as Pinyin, real hover, global hotkeys. Run those scenarios in foreground mode.
- Runs need an unlocked screen, and they share CPU and memory with whatever else you are doing.
- The truncation check misses a label that is cut by less than a tenth of its text and shows no ellipsis.
- The plural check looks only for "1" followed by a plural noun, and only in an English UI.
- Beeps that AppKit plays outside its "no responder for this key" path are not detected.
- Hiding windows beneath the wallpaper and delivering key events inside the app rely on how the macOS window server and AppKit behave today; a macOS update can change that.
- macOS only.

## Development

```bash
swift test
```

Tests that need a graphical session or Screen Recording skip themselves on a machine without one. `.github/workflows/ci.yml` builds and tests on a GitHub macOS runner. The skill lives in `skills/wispstage/` and the plugin manifest in `.claude-plugin/`.

## License

MIT. See [LICENSE](LICENSE).

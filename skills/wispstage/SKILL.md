---
name: wispstage
description: End-to-end testing for macOS apps (the Wispstage plugin): adopt it in a Mac app, write scenarios, run them, read results and screenshots, accept baselines, or attach to a running app to list its windows, export its UI listing and take screenshots. Use when the user wants to add end-to-end or UI tests to a Mac app (Swift, SwiftUI, AppKit), click through the app on a real Mac to see how it behaves, find UI elements missing accessibility identifiers, or run or read Wispstage results.
---

# Wispstage

The driver reads the UI through Accessibility and operates the app under test with synthesized keyboard and mouse events on a real Mac, running generic checks and taking screenshots on every step. Scenarios are written in Swift in your project's own scenario package. The `wispstage` command is available directly in Bash (the plugin's bin/); the first call, and the first call after the plugin's sources change, builds it first, with build output in `~/Library/Caches/wispstage/build-*/build.log`.

Paths to this skill's own files (`references/...`, `../../Sources/...`) are relative to the skill's directory (the directory containing this SKILL.md). Paths to the scenario package, `.wispstage.json` and run output are relative to the user's project root.

## Permissions (only the user can grant these, in System Settings)

System Settings > Privacy & Security: grant Accessibility and Screen Recording to the terminal app that runs Claude Code. `run` checks both before starting, and in foreground mode also checks permission to post events; if any is missing it reports that the terminal running the driver lacks the permission, names it, and exits with 1. Without the permissions, `listing` cannot read the tree and `shot` cannot capture images.

Run swift builds and `wispstage` commands with the command sandbox disabled (they read and write ~/Library/Caches and the project's .build).

## Commands

```bash
wispstage init [--app-name name] [--executable executable under test, relative to the project root] [--dir scenario package dir, default E2E]
wispstage list [filter...]                     # list scenario names only, without launching the app
wispstage run [--mode foreground|background] [--shots=key|all|none] [filter...]
wispstage baseline accept <run-dir> [scenario-filter...]
wispstage windows (--pid N | --bundle-id ID)
wispstage listing (--pid N | --bundle-id ID) [--out file]
wispstage shot (--pid N | --bundle-id ID) [--window window-id] [--id identifier] [--out dir]
wispstage summary <run-dir>                    # re-read results.json and rewrite summary.txt
```

- `list`, `run` and `baseline` look for `.wispstage.json` (`{"scenarioPackage": "<scenario package dir>", "product": "<executable target>"}`) from the current directory upward and turn the whole command into `swift run --package-path <scenario-package> <product> ...`, passing the exit code through unchanged.
- A filter is a full scenario name or a prefix (`smoke.`, `settings.save`).
- `run` exit codes: 0 when no scenario failed, even if some were skipped or interrupted (read summary.txt for those); 1 when any scenario fails, a permission is missing before the run, `.wispstage.json` cannot be found or read, or the scenario package fails to compile (read standard error for the reason); 2 when no scenario matched or arguments are invalid; 75 when the screen is locked before the run.
- `windows`, `listing` and `shot` attach to a running app. Use them to learn the UI before adopting (window IDs, element roles, identifiers, text, frames, which elements lack identifiers); run `listing` before writing a scenario and choose selectors from it. Get the pid with `pgrep -x <process name>`.

## Run modes

- Background (the default, `--mode background` or no flag): the app's windows sit beneath the wallpaper, never become key, never activate and make no beeps; input is sent from outside directly to the app's process, and the user keeps using the computer. The app under test must link the stage library (adoption level 2); if the driver cannot connect to the stage, each scenario fails at its launch step and the run continues. Only when the app's windows cannot be hidden beneath the wallpaper does the driver stop the whole run, and later scenarios do not run. Everything in a scenario from `t.requireForeground("why")` or `t.globalKey(...)` on is skipped, and summary.txt lists those scenarios under `Skipped in background mode`. After each scenario the driver checks that the system cursor is where it was before the scenario; when the user moved the pointer during the scenario, steps.log says the cursor position is not judged and the scenario does not fail for it. `WISPSTAGE_CHECK_UNTOUCHED=0` turns this check off; set it only when the user asks. A cursor failure when the user did not move the mouse is a real problem: report it, and do not turn the check off to make the run pass.
- Foreground (`--mode foreground`): the app really comes to the front, input is real mouse and keyboard events, and the run takes over the user's screen, keyboard and cursor. Before the run the terminal counts down 5 seconds and shows roughly how many minutes it will take. If someone moves the cursor during a step, the step pauses and is retried once the cursor is still. If the cursor moves again during the retry, the scenario is recorded as `interrupted`: later steps do not run, it counts as neither passed nor failed, and summary.txt lists it under `Interrupted by user input`. Behavior that an inactive window cannot test reliably (global hotkeys, anything tied to the key window) is testable only in foreground mode. Apps at adoption level 0 or 1 (not linking the stage library) can only run in foreground mode, so `run` needs `--mode foreground`.
- Add `--mode foreground` only when the user asks for it or agrees to it. The `WISPSTAGE_MODE` environment variable also sets the mode; the command-line flag takes precedence.

## Adoption levels (each level unlocks more)

| Level | What changes in the app | What you get |
|---|---|---|
| 0 | Nothing. `wispstage init` creates the scenario package | Foreground only; elements found by text and role; system services are real |
| 1 | Add accessibility identifiers to visible, actionable elements, named "area.element" | Elements found by identifier; selectors survive copy and language changes |
| 2 | Add a test host executable target that links `Wispstage` and calls `Wispstage.install()` after `NSApplication` is created and before `run` | Background mode |
| 3 | Put the system services you use (calendar, notifications, authorization, timer clocks, network) behind interfaces, with test doubles installed in the test host | No contact with the user's real data, no permission prompts, a clock you can set |

For how to do each level (adding identifiers, writing the test host and Package.swift, the criterion for proper dependency injection), see `references/integration.md`.

## Writing scenarios

Scenario package layout (created by `init`): `<dir>/Package.swift`, `<dir>/Sources/<product>/main.swift` (`E2EConfiguration` and `WispstageCLI.main(suite:)`), and one `<Area>Scenarios.swift` per area in the same `<dir>/Sources/<product>/` directory. Write new scenarios in this shape and add them to `allScenarios` in main.swift:

```swift
let settingsScenarios: [Scenario] = [
    scenario("settings.save") { t in
        try t.launch(LaunchSpec(executable: t.configuration.defaultExecutable, ready: .anyWindow), step: "launch")
        try t.press(id: "main.openSettings")
        try t.window(.settings)
        try t.setValue("settings.name", "Alice", submit: false)
        try t.press(id: "settings.save")
        try t.expect(try t.text(of: "settings.status") == "Saved", "Status reads Saved after saving")
        try t.shot(id: "settings.status", name: "after-save")
    },
]
```

- Name scenarios "area.name"; filters select by prefix.
- Each action (`launch`, `press`, `click`, `setValue`, `type`, `key`, `drag`, `hover`, `scroll`, `send`, `shot`) is one step: it is logged to steps.log, screenshotted when `--shots` selects that step (see Reading results) and followed by the generic checks. Queries (`element`, `find`, `text`, `exists`, `windows`, `waitEvent`) are not steps.
- Waiting: `element(id:)`, `find(label:)` and `window(_:)` wait until the target appears (5 seconds by default, change with `timeout:`), and `waitGone` waits for it to disappear; after every action step the driver waits for the UI to settle. Do not put sleeps in scenarios.
- Send input only through `t.*` methods, never by posting CGEvents directly: the driver picks the input path for the run mode, and events posted directly land in the user's frontmost app in background mode.
- Before a step that can only be tested in the foreground, call `try t.requireForeground("global hotkeys need system keyboard events")`.
- Wrap known issues in `t.expectFailure("issue-id") { ... }`. When a check on a step is a genuine false positive, call `t.waive(.overlap, reason: "...")` before that step; the reason goes into results.json.
- `setValue` presses Return after setting the value unless you pass `submit: false`; pass it when the scenario confirms with a button instead.
- For the full API and every `LaunchSpec` field, see `references/api.md`; the sources under `../../Sources/WispstageKit/Core/` are authoritative for signatures.

## Reading results

At the start, `run` prints the run directory, `<runsDir>/<timestamp>/`. It contains:

- `summary.txt`: the counts `Passed`, `Failed`, `Skipped`, `Interrupted` and `Known failures`, the `Skipped in background mode` and `Interrupted by user input` sections, the failing step and reason for each failed scenario, and the sections listed for review. Read this first.
- `results.json`: the same content in machine-readable form (status, failedStep, reason, check, notes and waivers per scenario).
- `<scenario name>/steps.log`: the per-step log. `NN-<step>.png`: full-window screenshots (`--shots=key` keeps only the first and last steps, explicit `shot` calls and failing steps; `all` keeps every step; `none` keeps only explicit `shot` calls). `NN-<step>.ax.txt`: a text listing of the UI at each step (role, identifier, text, frame, occlusion state). `NN-<step>-<identifier>.png`: element screenshots and crops of the elements a check flagged. On failure, `ax-<step>.txt`: the whole accessibility tree. `events.jsonl`: app and stage events. `app-stderr.log`.
- To look at a screenshot, open the png with Read. To judge a UI problem, read the matching `.ax.txt` first, then look at the image.

Generic checks (run after every action step):
- Fail the step: process-alive, responsive, placeholder (unreplaced `%@`, `{...}`, localization keys), plural ("1 Minutes" in an English UI), overlap (overlapping text), bounds (outside the window), truncation, beep (a key press nobody handled); in background mode also key-focus (the app's window became key) and foreground (the app became frontmost).
- Listed for review in summary.txt (do not fail the step): missing-id (visible but without an identifier), hit-target (smaller than 20x20 pt), alignment, contrast, occlusion. These sections are an improvement list, not scenario failures.

## Baseline screenshots

- `wispstage baseline accept <run-dir> [scenario-filter...]` saves that run's full-window and element screenshots as baselines under the scenario package's baselinesDir, as `<variant>/<scenario>/<screenshot name>.png`. Commit them.
- Every later run compares pixel by pixel. Screenshots that differ are listed in summary.txt under `Pixel difference`, with a `<screenshot name>.diff.png` that marks differing pixels in red; screenshots without a baseline are listed under `No baseline`. Pixel differences do not fail the run: a person looks at the diff image to decide whether the change is intended or a regression.
- Before accepting baselines, look at that run's screenshots and confirm the UI is correct.

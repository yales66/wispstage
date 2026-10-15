# Scenario API quick reference (WispstageKit)

Paths on this page are relative to the skill's directory (the parent of `references/`). Signatures in `../../Sources/WispstageKit/Core/E2ETest*.swift`, `../../Sources/WispstageKit/Core/Hooks.swift` and `../../Sources/WispstageKit/Core/Configuration.swift` are authoritative; this page shows the common forms. `t` is the scenario closure's parameter (`E2ETest`).

## Targets (Target)

A string literal is an accessibility identifier: `"settings.save"` equals `.id("settings.save")`. The other forms are `.label("Save")`, `.label("Save", role: .button)`, `.point(x, y)` (global coordinates, top-left origin), `.inWindow(.main, CGPoint(...))` (points from the window's top-left corner; to use a position measured in that window's screenshot, divide the pixel coordinates by the display scale, which is the screenshot's pixel width divided by the window's width in points, 2 on a Retina display), `.element(node)` and `.offset(dx:dy:)` (drag end points only).

Roles (`AXRole`): `.button`, `.staticText`, `.textField`, `.textArea`, `.checkBox`, `.radioButton`, `.menuItem`, `.popUpButton`, `.group`, `.image`, `.link`, `.slider`, `.window`, `.scrollArea`, or a literal such as `"Heading"` (the AX prefix is added automatically).

Window kinds (`WindowKind`): `.main`, `.settings`, `.other`, or a literal such as `"inspector"`; add your own as `static let` in `extension WindowKind`. The default classifier assigns `.main` only to a window with the identifier `main.window` or the window ID in an integer field of the app's `ready` event whose name contains `main` (fields may be nested; a name that also contains `settings` counts as `.settings`); a main window without either is `.other`. See the classifier bullet under "Level 1" in [integration.md](integration.md#level-1-accessibility-identifiers).

## Launch and quit

```swift
try t.launch(LaunchSpec(
    executable: t.configuration.defaultExecutable,
    arguments: LaunchSpec.localeArguments(language: "en", region: "en_US", hour24: false),  // language, region, clock format
    environment: ["MYAPP_FAKE_CALENDAR": "1"],   // layered over the driver's environment
    ready: .anyWindow,            // or .event("ready"), .line { ... }
    readyTimeout: 30,
    quit: .terminate,             // or .command("quit"): sends this line on standard input, then SIGTERM if the app has not quit after 5 seconds
    variant: Baselines.variant(language: "en", appearance: .light, hour24: false),  // baseline variant
    language: "en",               // the plural check runs only when this starts with en; nil uses the first preferred language of the system the driver runs on (`en` if there is none)
    tags: ["real-model"],         // your own tags, read by your hooks
    checksVisibility: true,       // background mode: after launch, check once that the windows are hidden beneath the wallpaper
    missingHint: "Run xcodebuild ... first"), step: "launch en")
try t.relaunch { spec in spec.environment["MYAPP_KEEP"] = "1" }   // quits normally, then relaunches with the previous values
```

The example shows every `LaunchSpec` field. Only `executable` is required; the defaults are `arguments: []`, `environment: [:]`, `ready: .anyWindow`, `readyTimeout: 30`, `quit: .terminate`, `variant: nil`, `language: nil`, `tags: []`, `checksVisibility: true` and `missingHint: nil`.

Attach `willLaunch` and `didStop` hooks in `E2EConfiguration(hooks:)` (implement `E2EHooks`).

## Finding and reading (not steps)

| Call | What it does |
|---|---|
| `t.windows()` | All on-screen windows (`AppWindow`), in stacking order |
| `t.window(.settings, timeout:)` | Waits for a window of that kind to appear |
| `t.waitGone(.settings)` / `t.waitGone(id:)` | Waits for a window or identifier to disappear |
| `t.element(id:in:timeout:)` | Finds by identifier, waiting until it appears |
| `t.find(label:role:in:timeout:)` | Finds by text (title, description or value, exact match) |
| `t.all(role:in:)` | All elements with a role, without waiting |
| `t.exists(id:in:)` | Whether an identifier exists, without waiting |
| `t.text(of:)` | The element's value, else its title; when both are empty, the text of the static text elements in its subtree joined with spaces; when there is none, its description |
| `t.texts(in:)` | All static text in a window |
| `t.point(of:)` | The target's screen coordinates (center of its frame) |
| `t.pixels(of:margin:)` | The pixels inside the target's frame, for before/after comparisons (hover highlights and other things the tree does not expose) |

Waits default to 5 seconds (`Wait.defaultTimeout`).

## Actions (each is one step: logged, UI settled, screenshotted when `--shots` selects it, generic checks)

| Call | What it does |
|---|---|
| `t.press(id:)` / `t.press(label:role:)` | Accessibility press. `role` defaults to `.button`; for a menu item pass `role: .menuItem`, and `role: nil` matches any role |
| `t.click(target, count:, right:, modifiers:)` / `t.click(at:)` | Clicks the center of the frame or a point (for custom gestures) |
| `t.clickOutside(at:)` | Clicks outside the app under test, to test "click elsewhere to dismiss" |
| `t.setValue(target, "text", submit:)` | Sets a text field's value. `submit` defaults to `true`, which presses Return afterward; pass `submit: false` when the scenario confirms another way |
| `t.type("text")` | Types character by character into the current focus |
| `t.key("esc")`, `t.key("s", modifiers: .command)` | Presses a key, delivered to the app's key window; key names are in `Key` in `../../Sources/WispstageKit/Input/Input.swift` |
| `t.globalKey(...)` | A global hotkey; foreground mode only (in background mode the rest of the scenario is skipped, as with `requireForeground`) |
| `t.drag(from:to:steps:)` | Drags; the end point can be an element, a point or `.offset(dx:dy:)` |
| `t.hover(target)`, `t.scroll(target, dy:)` | Hover and scroll (positive dy scrolls up) |
| `t.send("command")` | Sends one line on the command channel; fails if the app replies with an error line |
| `t.shot("name")`, `t.shot(id:margin:name:)`, `t.shot(target, margin:name:)` | Full-window screenshot; element screenshot cropped to the element's frame plus a margin (compared against baselines) |
| `t.step("name") { ... }` | Wraps several queries or raw inputs into one step |

For drags that hold the button down, use `t.mouseDown(at:)`, `t.mouseMove(to:)` and `t.mouseUp(at:)`; for input that should not count as a step, use `t.rawClick`, `t.rawKey`, `t.rawType` and `t.rawHover`.

## Assertions, skipping, known issues

```swift
try t.expect(try t.text(of: "main.count") == "3", "Count is 3 after adding one item")
try t.requireForeground("global hotkeys need system keyboard events")   // in background mode the scenario is recorded as skipped from here
t.waive(.truncation, reason: "long titles truncate by design")         // waives one check on the next step
t.waive(.overlap, reason: "...") { ... }                               // waived on every step in the block
t.expectFailure("BUG-12") { try t.press(id: "x") }                     // a known failure does not block what follows; if the block passes it is recorded as possibly fixed
throw E2EFailure("reason")                                              // fail the scenario yourself
```

Check names: `.processAlive`, `.responsive`, `.placeholder`, `.plural`, `.overlap`, `.bounds`, `.truncation`, `.contrast`, `.occlusion`, `.keyFocus`, `.foreground`, `.beep`, `.alignment`, `.hitTarget`, `.missingIdentifier`.

## Command channel and events

```swift
try t.send("advance 600")
let raw = try t.request("dump-state", reply: "STATE")       // the reply content
let s = try AppState(raw: raw); let n = s["items.0.title"]   // read a JSON field by dotted path
try t.waitEvent("item.saved", where: { $0["id"] as? Int == 3 })
let all = t.events("item.saved")
t.skipPastEvents()
```

## Motion

`t.recordMotion("name", ids: ["panel.content"], specs: [...]) { try t.press(id: "panel.open") }` records the frames of the identified elements and screen captures frame by frame during the actions in the block, and writes `motion-<name>.txt` and `.png`. Deviations from the specs go into the report only and do not fail the step. Parameters are in `../../Sources/WispstageKit/Motion/MotionRecord.swift`.

## Configuration (scenario package main.swift)

`E2EConfiguration(appName:projectDir:defaultExecutable:runsDir:baselinesDir:outputProtocol:classifier:textChecks:hooks:)`:
- `runsDir` defaults to `<projectDir>/build/e2e-runs` and `baselinesDir` to `<projectDir>/e2e-baselines`. The main.swift that `wispstage init` generates passes both explicitly: `runsDir` as `<projectDir>/build/e2e-runs` and `baselinesDir` as `<scenario package>/Baselines`.
- `textChecks: TextCheckConfig(copyKeys:extraPlaceholderPatterns:ocrLanguages:)`: the full set of localization keys (text equal to a key is reported as unreplaced), regexes for your key naming scheme, and the text recognition languages for the truncation check (include `zh-Hans` for a Chinese UI).
- `classifier`: implement `WindowClassifier` to replace the default way window kinds are assigned.

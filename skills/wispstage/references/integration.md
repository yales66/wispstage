# How to adopt each level

One rule applies at every level: tests observe and operate the app only through Accessibility, synthesized input and the test host; the release build's code paths never take an extra branch for testing.

## Level 0: no changes to the app

```bash
cd <project root>
wispstage init --app-name MyApp --executable build/MyApp.app/Contents/MacOS/MyApp
wispstage list
wispstage run --mode foreground smoke.   # foreground mode takes over the screen, keyboard and cursor; run it only after the user agrees
```

- `--executable` is relative to the project root. Foreground runs work with any executable. Background runs need an executable inside an `.app` bundle, because an executable outside a bundle causes two problems:
  - The system treats it as part of the terminal that launched it, so while the terminal is frontmost the app becomes frontmost as soon as it opens a window, and the background-mode foreground check reports that.
  - The driver reads the bundle ID from `<bundle>.app/Contents/Info.plist`. Without a bundle, `run` prints `Cannot read the Bundle ID of the app bundle under test (...), taking the exclusive global lock as in hid mode` (hid mode is the input mode of foreground runs, which hold that lock so only one run uses the screen at a time), so each scenario waits for every other Wispstage run on the Mac and blocks them until it ends.
- To wrap a bare executable such as a `swift build` product, pass it through `PreviewBundle.prepare(executable:in:bundleID:name:)` and launch the executable it returns (example under Level 2).
- The generated Package.swift depends on the local copy of Wispstage that ran `init`, by absolute path: `.package(path: "<absolute path of that copy>")` and `.product(name: "WispstageKit", package: "<its directory name>")`. Before committing, change them to `.package(url: "https://github.com/yales66/wispstage", from: "0.1.0")` and `.product(name: "WispstageKit", package: "wispstage")`.
- For apps without a command channel, use `ready: .anyWindow` (ready as soon as Accessibility sees a window) and `quit: .terminate`.

## Level 1: accessibility identifiers

Name identifiers "area.element", where the area is a part of the UI (a window, page or panel) and the element is a control inside it: `main.title`, `sidebar.addButton`, `settings.save`, `list.item.<model ID>` (list items append a stable key such as the item's ID in your data model, never its title).

```swift
// SwiftUI
Button("Save") { save() }.accessibilityIdentifier("settings.save")
// AppKit
saveButton.setAccessibilityIdentifier("settings.save")
// Windows: name the identifier <kind>.window; the default window classifier reads the kind from it, and scenarios wait for it with t.window("<kind>")
window.setAccessibilityIdentifier("settings.window")
```

- Identifiers are selectors for tests and accessibility. They do not change with copy or language, and they never appear in user-visible text.
- To find elements missing identifiers: with the app open, run `wispstage listing --pid <pid> --out listing.txt`; after the listing of each window that has visible elements without an identifier there is a "-- missing identifiers: N" section; a window without such elements has none. After a run, the missing-id section of summary.txt lists them too.
- The default window classifier (`ConventionWindowClassifier`): an identifier `<kind>.window` gives the prefix as the kind; a title containing "settings" (any case) or its Simplified Chinese equivalent is `.settings`; if the app reports a `ready` event on the command channel, integer fields whose names contain `main` or `settings` (at any nesting depth; a name containing both counts as `settings`) are taken as the window ID of that kind; anything else is `.other`.

## Level 2: a test host that links the stage library

The test host is an executable target used only for testing: it links the same app library as the release app, and its entry point has one extra line that starts the stage. The release target does not depend on Wispstage.

Swift package projects (first split the app into a library plus a minimal main):

```swift
// Package.swift
dependencies: [.package(url: "https://github.com/yales66/wispstage", from: "0.1.0")],
targets: [
    .target(name: "MyAppKit"),                                   // the app itself
    .executableTarget(name: "MyApp", dependencies: ["MyAppKit"]), // release entry point
    .executableTarget(name: "MyAppTestHost", dependencies: [
        "MyAppKit", .product(name: "Wispstage", package: "wispstage"),
    ]),
]
```

The test host's entry point starts the app the same way the release entry point does, with one extra call. Call `Wispstage.install()` after `NSApplication` exists and before the app starts running. When the driver sets `WISPSTAGE_STAGE=1` (background mode), `install()` turns on background mode; with `observe` (foreground mode) it only observes and intercepts nothing; when the variable is unset it does nothing. Its return value says only whether background mode is on, so do background-mode-specific work in the test host only when it is `true`.

SwiftUI: move the `App` struct into the library target without `@main`, and give each entry point a `main.swift`:

```swift
// Sources/MyAppKit/MyApp.swift
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
    _ = Wispstage.install()
    MyApp.main()
}
```

AppKit: keep the app delegate in the library target and create the application yourself:

```swift
// Sources/MyAppTestHost/main.swift (the release main.swift is the same without the Wispstage lines)
import AppKit
import Wispstage
import MyAppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()   // public in MyAppKit
    app.delegate = delegate
    _ = Wispstage.install()
    NSApp.run()
}
```

- Xcode projects: the template puts the `App` struct or `AppDelegate` in the file marked `@main`, so first split that file. Remove `@main`, move the `App` struct or `AppDelegate` into a source file that both targets compile, and give the release target an entry-only `main.swift` (it calls `MyApp.main()`, or creates `NSApplication` and its delegate and calls `NSApp.run()`). Then add a second app target to serve as the test host: it compiles the same shared files plus its own `main.swift` that also calls `Wispstage.install()`. Both targets compile the app's sources directly, so there is no `MyAppKit` module and the `main.swift` files have no `import MyAppKit`. Add Wispstage through a Swift Package dependency to the test-host target only. The app's own code needs no compile-time conditionals.
- Point `defaultExecutable` in the scenario package's main.swift at the test host's build product; `wispstage run` (background by default) then works. A Swift package build (`swift build --product MyAppTestHost`) produces a bare executable, so wrap it in an app bundle first (see Level 0 for why):

```swift
// <scenario package>/Sources/<product>/main.swift
let testHost = projectDir.appendingPathComponent(".build/debug/MyAppTestHost")
let configuration = E2EConfiguration(
    appName: "MyApp",
    projectDir: projectDir,
    defaultExecutable: try PreviewBundle.prepare(executable: testHost, in: projectDir.appendingPathComponent("build/e2e-bundle"),
                                                 bundleID: "com.example.MyApp.testhost", name: "MyApp Test Host"),
    runsDir: projectDir.appendingPathComponent("build/e2e-runs"),
    baselinesDir: packageDir.appendingPathComponent("Baselines"))
```

`prepare` copies the executable into `<in>/<name>.app` with the given bundle ID, copies again only when the source changes, and returns the executable inside the bundle.
- What the stage does in background mode: windows sit beneath the wallpaper and never become key, the app never activates and stays out of the Dock; key events sent from outside are dispatched as if the key window were the keyboard target (Esc cancels, Return triggers the default button); key presses nobody handles make no sound and are reported as `stage.beep`; drags, hovers, scroll wheel events and clicks at coordinates are synthesized inside the process; the app's global event monitors do not receive the real user's clicks.

## Level 3: system services behind interfaces

The criterion: swapping the test double back for the real implementation changes no production code and adds no branch. That is dependency injection. A branch inside a release method that takes another path during tests changes behavior and has to become an interface.

Typical services to change: calendar, notifications, authorization such as Screen Recording, sound effects, login items, timer clocks (setting the wall clock does not move timers along with it), network, model APIs.

Steps:
1. Extract the service into a protocol and keep the release implementation as it is.
2. The app library works with whatever implementation is injected (initializer parameter or environment object) and never checks whether it is under test.
3. The test host installs test doubles based on launch arguments or environment variables; scenarios select them through `LaunchSpec.environment` or `arguments`.
4. When a scenario needs to read the app's internal state, the test host writes protocol lines to standard output (see below) and the scenario reads them with `t.request`.

## Command channel (optional)

When the app under test (usually the test host) reads command lines from standard input and writes protocol lines to standard output, scenarios can receive events, change state and read saved data. The default protocol is `PrefixedLineProtocol(prefix: "WISPSTAGE_")`:

- `WISPSTAGE_EVENT {"type":"ready", "windows": {"main": 123}}`: an event; `type` is required. `ready: .event("ready")` waits for it. `t.waitEvent("ready")` returns the first matching event not already taken by an earlier `waitEvent`, which includes the one sent at launch; to wait only for events that arrive later, call `t.skipPastEvents()` first.
- `WISPSTAGE_ERROR reason`: an error; `t.send` and `t.request` fail when they receive one.
- `WISPSTAGE_<NAME> content` (NAME is uppercase letters, digits and underscores): a reply; `t.request("dump-state", reply: "STATE")` returns the content.

Change the prefix with `E2EConfiguration(outputProtocol:)`; for a different format, implement `OutputProtocol` yourself.

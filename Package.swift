// swift-tools-version: 6.0
import PackageDescription

// The stage library: the Mac app under test links Wispstage through its test host, so the user keeps using the computer while tests run.
// Windows sit beneath the wallpaper, never become key, never activate and make no beeps; key events the driver sends from outside via
// postToPid are dispatched as if the key window were the keyboard target.
// The driver connects to the stage library's socket through WispstageClient and receives stage.* events. Neither depends on any particular app.
// WispstageKit is the driver itself (launching and stopping the app under test, reading the accessibility tree, keyboard and mouse input,
// generic checks on every step, screenshots and baselines, motion recording, the scenario runner).
// Your scenarios live in your own executable target that depends on WispstageKit and calls WispstageCLI.main(suite:) from its entry point.
// The wispstage command attaches to a running app (windows, listing, shot), re-renders a summary (summary), forwards list, run and baseline
// unchanged to your scenario package via .wispstage.json, and init sets up a scenario package in your project.
// The platform stays at macOS 14: the stage library links into the test host of the app under test, and those apps may still support 14.
let package = Package(
    name: "Wispstage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Wispstage", targets: ["Wispstage"]),
        .library(name: "WispstageClient", targets: ["WispstageClient"]),
        .library(name: "WispstageKit", targets: ["WispstageKit"]),
        .executable(name: "wispstage", targets: ["WispstageCommand"]),
    ],
    targets: [
        // One line of JSON per message on the socket: event encoding and parsing, and the driver-side connection. Depends only on Foundation.
        .target(name: "WispstageClient"),
        // The in-process stage: depends only on AppKit, Foundation and the line format above.
        .target(name: "Wispstage", dependencies: ["WispstageClient"]),
        .testTarget(name: "WispstageTests", dependencies: ["Wispstage", "WispstageClient"]),
        // The driver: depends only on system frameworks and the line format above.
        .target(name: "WispstageKit", dependencies: ["WispstageClient"]),
        .executableTarget(name: "WispstageCommand", dependencies: ["WispstageKit"]),
        .testTarget(name: "WispstageKitTests", dependencies: ["WispstageKit", "WispstageClient"]),
    ],
    swiftLanguageModes: [.v5]
)

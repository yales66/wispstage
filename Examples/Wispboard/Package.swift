// swift-tools-version: 6.0
import PackageDescription

// Wispboard: a small kanban board, the example app for Wispstage.
// - WispboardKit is the whole app (SwiftUI views, model, strings in English and German).
// - Wispboard is the release entry point; it does not link Wispstage.
// - WispboardTestHost is the same app plus Wispstage.install(), which the end-to-end scenarios in E2E/ launch (adoption level 2).
// Wispstage comes from this repository by relative path. SwiftPM names a path dependency after its directory, so the
// repository has to be checked out in a directory named "wispstage" (the default for `git clone`).
let package = Package(
    name: "Wispboard",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Wispboard", targets: ["Wispboard"]),
        .executable(name: "WispboardTestHost", targets: ["WispboardTestHost"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(name: "WispboardKit", resources: [.process("Resources")]),
        .executableTarget(name: "Wispboard", dependencies: ["WispboardKit"]),
        .executableTarget(name: "WispboardTestHost", dependencies: [
            "WispboardKit", .product(name: "Wispstage", package: "wispstage"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)

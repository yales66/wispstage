// swift-tools-version: 6.0
import PackageDescription

// End-to-end scenario package for Wispboard. The WispstageKit driver comes from this repository by relative path; SwiftPM names a
// path dependency after its directory, so the repository has to be checked out in a directory named "wispstage".
// In your own project, depend on a release instead:
//   .package(url: "https://github.com/yales66/wispstage", from: "<version>"), with package: "wispstage" in .product below.
let package = Package(
    name: "WispboardE2E",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "wispboard-e2e", targets: ["wispboard-e2e"]),
    ],
    dependencies: [
        .package(path: "../../.."),
    ],
    targets: [
        .executableTarget(name: "wispboard-e2e", dependencies: [.product(name: "WispstageKit", package: "wispstage")]),
    ],
    swiftLanguageModes: [.v5]
)

import Foundation

/// `wispstage init`: creates a scenario package in the current project (an executable target depending on WispstageKit, its entry point
/// and one smoke scenario) plus `.wispstage.json` at the project root. Existing files are not overwritten; they go into `Report.skipped`.
public struct ProjectInit {
    public struct Options: Equatable {
        public var appName: String?
        /// Executable under test, relative to the project root.
        public var executable: String?
        /// Scenario package directory, relative to the project root.
        public var dir: String

        public init(appName: String?, executable: String?, dir: String) {
            self.appName = appName
            self.executable = executable
            self.dir = dir
        }

        public static let known: Set<String> = ["--app-name", "--executable", "--dir"]

        public static func parse(_ args: [String]) throws -> Options {
            let v = try optionValues(args, known: known)
            let dir = v["--dir"] ?? "E2E"
            guard !dir.hasPrefix("/"), !dir.isEmpty else { throw InspectOptions.Invalid(message: "--dir must be a path relative to the project root: \(dir)") }
            return Options(appName: v["--app-name"], executable: v["--executable"], dir: dir)
        }
    }

    public struct Report: Equatable {
        public var created: [String] = []
        public var skipped: [String] = []
    }

    public let appName: String
    public let executable: String
    public let dir: String
    /// Absolute path of the package root containing WispstageKit (the generated Package.swift points to it with `.package(path:)`).
    public let kitPath: String

    /// `projectName` (the project directory name) is used when `--app-name` is not given.
    public init(options: Options, projectName: String, kitPath: String) {
        appName = options.appName ?? projectName
        executable = options.executable ?? ".build/debug/\(options.appName ?? projectName)"
        dir = options.dir.split(separator: "/").joined(separator: "/")
        self.kitPath = kitPath
    }

    /// The scenario package's executable target: the app name lowercased, whitespace replaced with hyphens, plus `-e2e`.
    public var product: String {
        appName.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-") + "-e2e"
    }

    /// SwiftPM names a path dependency after its last path component, so `.product(package:)` must use that.
    var kitPackage: String { URL(fileURLWithPath: kitPath).lastPathComponent }

    var packageName: String { appName.filter { $0.isLetter || $0.isNumber } + "E2E" }

    /// Relative path from the scenario package directory back to the project root.
    var backToProject: String { Array(repeating: "..", count: dir.split(separator: "/").count).joined(separator: "/") }

    /// Generated files: path relative to the project root and content, in write order.
    public func files() -> [(path: String, content: String)] {
        [
            ("\(dir)/Package.swift", packageSwift),
            ("\(dir)/Sources/\(product)/main.swift", mainSwift),
            ("\(dir)/Sources/\(product)/SmokeScenarios.swift", smokeSwift),
            (ScenarioPackageConfig.fileName, configJSON),
        ]
    }

    /// Writes into `root` (the project root); existing files are left alone.
    public func write(to root: URL) throws -> Report {
        var report = Report()
        let fm = FileManager.default
        for (path, content) in files() {
            let url = root.appendingPathComponent(path)
            if fm.fileExists(atPath: url.path) {
                report.skipped.append(path)
                continue
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            report.created.append(path)
        }
        return report
    }

    /// WispstageKit's package root: the `WISPSTAGE_ROOT` environment variable (set by the plugin's bin/wispstage), or else the package root of the sources this program was built from.
    public static func kitRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let r = environment["WISPSTAGE_ROOT"], !r.isEmpty { return URL(fileURLWithPath: r).standardizedFileURL.path }
        // Sources/WispstageKit/CLI/ProjectInit.swift -> package root
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { u.deleteLastPathComponent() }
        return u.standardizedFileURL.path
    }

    /// Next steps and adoption levels printed after generating.
    public var nextSteps: String {
        """
        Next steps:
          1. Build the app under test and check that \(executable) exists (if not, change defaultExecutable in \(dir)/Sources/\(product)/main.swift).
          2. In System Settings, grant Accessibility and Screen Recording to the terminal that runs this command.
          3. Change anchorID in SmokeScenarios.swift, run wispstage list to see scenario names, and run the smoke test with
             wispstage run --mode foreground smoke.
             (Foreground mode takes over the screen, keyboard and cursor; until adoption level 2 only foreground mode works.)
        Adoption levels (each level unlocks more):
          Level 0 (now): the app is unchanged. Foreground mode only, elements are found by text and role, system services are real.
          Level 1: add accessibility identifiers to visible, actionable elements, named "area.element" (such as main.title, settings.save);
                   wispstage listing --pid <pid> lists visible elements without an identifier, and every summary.txt lists missing-id.
          Level 2: add a test-only test host executable target that depends on .product(name: "Wispstage", package: "\(kitPackage)")
                   and calls Wispstage.install() after NSApplication is created and before run; point defaultExecutable at the test host.
                   Background mode (the default) then works: windows sit beneath the wallpaper, the app never becomes frontmost or takes
                   the keyboard, makes no beeps, and you keep using your Mac.
          Level 3: put the system services you use (calendar, notifications, authorization, timer clocks, network) behind interfaces
                   and install test doubles in the test host.

        """
    }

    // MARK: - Templates

    var packageSwift: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        // End-to-end scenario package for \(appName) (generated by wispstage init). The WispstageKit driver comes from Wispstage.
        // The dependency points to Wispstage's package root by local path; to use a git URL instead:
        //   .package(url: "<Wispstage git URL>", from: "<version>"), and change package: in .product below to the repository name.
        let package = Package(
            name: "\(packageName)",
            platforms: [.macOS(.v14)],
            products: [
                .executable(name: "\(product)", targets: ["\(product)"]),
            ],
            dependencies: [
                .package(path: "\(kitPath)"),
            ],
            targets: [
                .executableTarget(name: "\(product)", dependencies: [.product(name: "WispstageKit", package: "\(kitPackage)")]),
            ],
            swiftLanguageModes: [.v5]
        )

        """
    }

    var mainSwift: String {
        """
        // End-to-end scenario entry point for \(appName) (generated by wispstage init).
        //
        // From the project root or any directory below it:
        //   wispstage list [filter...]
        //   wispstage run [--mode foreground|background] [--shots=key|all|none] [filter...]
        //   wispstage baseline accept <run-dir> [scenario-filter...]
        // A filter is a full scenario name or a prefix (smoke.). Without --mode, scenarios run in background mode, which needs
        // the app under test to link the stage library (adoption level 2).
        //
        // To add scenarios: create <Area>Scenarios.swift in this directory with
        // let xxxScenarios: [Scenario] = [scenario("area.name") { t in ... }], then add it to allScenarios below.

        import Foundation
        import WispstageKit

        /// This scenario package's directory (three levels above Sources/<target>/main.swift).
        let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        /// The project root (the directory containing .wispstage.json).
        let projectDir = packageDir.appendingPathComponent("\(backToProject)").standardizedFileURL

        let configuration = E2EConfiguration(
            appName: "\(appName)",
            projectDir: projectDir,
            // The app's executable. At adoption level 2, point this at the test host that links Wispstage.
            defaultExecutable: projectDir.appendingPathComponent("\(executable)"),
            // Each run's output goes in <runsDir>/<timestamp>/; keep it out of version control.
            runsDir: projectDir.appendingPathComponent("build/e2e-runs"),
            // Baseline screenshots (commit these).
            baselinesDir: packageDir.appendingPathComponent("Baselines"))

        let allScenarios: [Scenario] = smokeScenarios

        WispstageCLI.main(suite: E2ESuite(configuration: configuration, scenarios: allScenarios))

        """
    }

    var smokeSwift: String {
        """
        import Foundation
        import WispstageKit

        /// Smoke test: launch the app, wait for any window, find one element, take screenshots.
        let smokeScenarios: [Scenario] = [
            scenario("smoke.launch") { t in
                try t.launch(LaunchSpec(executable: t.configuration.defaultExecutable, ready: .anyWindow,
                                        missingHint: "Build \(appName) first"), step: "launch")
                try t.expect(!(try t.windows()).isEmpty, "At least one window after launch")

                // Replace with an accessibility identifier that exists in your app (named "area.element"); without one, the first static text in the window is used.
                let anchorID = "main.title"
                let anchor: AXNode
                if t.exists(id: anchorID) {
                    anchor = try t.element(id: anchorID)
                } else if let text = try t.all(role: .staticText).first {
                    anchor = text
                } else {
                    throw E2EFailure("No \\(anchorID) in the window and no static text either")
                }
                try t.shot("launched")
                try t.shot(.element(anchor), margin: 8, name: "anchor")
            },
        ]

        """
    }

    var configJSON: String {
        "{\"scenarioPackage\": \"\(dir)\", \"product\": \"\(product)\"}\n"
    }
}

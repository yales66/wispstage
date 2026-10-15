import Foundation
import Testing
@testable import WispstageKit

// The first column of each parameterized case is its name (Swift Testing has no ids: and displays cases by their arguments, so a leading name shows which case is which).

struct ProjectInitTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("wispstage-init-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.resolvingSymlinksInPath()
    }

    private func read(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func demo(dir: String = "E2E", executable: String? = ".build/debug/Demo", kit: String = "/kit/wispstage") throws -> ProjectInit {
        var args = ["--app-name", "Demo", "--dir", dir]
        if let executable { args += ["--executable", executable] }
        return ProjectInit(options: try ProjectInit.Options.parse(args), projectName: "proj", kitPath: kit)
    }

    @Test func createsScenarioPackageAndConfigFile() throws {
        let root = try tempDir()
        let report = try demo().write(to: root)
        #expect(report.created == [
            "E2E/Package.swift", "E2E/Sources/demo-e2e/main.swift", "E2E/Sources/demo-e2e/SmokeScenarios.swift", ".wispstage.json",
        ])
        #expect(report.skipped.isEmpty)

        let pkg = try read(root, "E2E/Package.swift")
        #expect(pkg.contains(#".package(path: "/kit/wispstage")"#))
        #expect(pkg.contains(#".product(name: "WispstageKit", package: "wispstage")"#))
        #expect(pkg.contains(#".executable(name: "demo-e2e", targets: ["demo-e2e"])"#))
        #expect(pkg.contains("git"))

        let main = try read(root, "E2E/Sources/demo-e2e/main.swift")
        #expect(main.contains("WispstageCLI.main(suite:"))
        #expect(main.contains(#"appName: "Demo""#))
        #expect(main.contains(#"".build/debug/Demo""#))
        #expect(main.contains(#"appendingPathComponent("..")"#))

        let smoke = try read(root, "E2E/Sources/demo-e2e/SmokeScenarios.swift")
        #expect(smoke.contains(#"scenario("smoke.launch")"#))
        #expect(smoke.contains("ready: .anyWindow"))
        #expect(smoke.contains("t.shot("))

        let config = try JSONDecoder().decode(ScenarioPackageConfig.self, from: Data(contentsOf: root.appendingPathComponent(".wispstage.json")))
        #expect(config == ScenarioPackageConfig(scenarioPackage: "E2E", product: "demo-e2e"))
    }

    @Test func existingFilesAreNotOverwrittenAndAreReported() throws {
        let root = try tempDir()
        try Data("original".utf8).write(to: root.appendingPathComponent(".wispstage.json"))
        let report = try demo().write(to: root)
        #expect(report.skipped == [".wispstage.json"])
        #expect(report.created.count == 3)
        #expect(try read(root, ".wispstage.json") == "original")
    }

    @Test func deeperScenarioPackageClimbsBackTheMatchingNumberOfLevels() throws {
        let root = try tempDir()
        _ = try demo(dir: "app/Scripts/E2E").write(to: root)
        let main = try read(root, "app/Scripts/E2E/Sources/demo-e2e/main.swift")
        #expect(main.contains(#"appendingPathComponent("../../..")"#))
        #expect(try read(root, ".wispstage.json").contains(#""app/Scripts/E2E""#))
    }

    @Test func dependencyPackageNameIsTheLastComponentOfTheKitRoot() throws {
        let i = try demo(kit: "/tmp/plugins/cache/m/wispstage/0.1.0")
        let pkg = try #require(i.files().first { $0.path == "E2E/Package.swift" }).content
        #expect(pkg.contains(#".product(name: "WispstageKit", package: "0.1.0")"#))
    }

    @Test(arguments: [
        ("all given", ["--app-name", "My App", "--executable", "build/My.app/Contents/MacOS/My", "--dir", "Tests/E2E"],
         ProjectInit.Options(appName: "My App", executable: "build/My.app/Contents/MacOS/My", dir: "Tests/E2E")),
        ("none given", [], ProjectInit.Options(appName: nil, executable: nil, dir: "E2E")),
        ("equals syntax", ["--app-name=Demo"], ProjectInit.Options(appName: "Demo", executable: nil, dir: "E2E")),
    ] as [(String, [String], ProjectInit.Options)])
    func parsesArguments(_ name: String, _ args: [String], _ expected: ProjectInit.Options) throws {
        #expect(try ProjectInit.Options.parse(args) == expected)
    }

    @Test(arguments: [
        ("missing value", ["--app-name"]),
        ("unknown option", ["--frobnicate", "x"]),
        ("absolute directory", ["--dir", "/abs"]),
    ] as [(String, [String])])
    func invalidArgumentsThrow(_ name: String, _ args: [String]) {
        #expect(throws: (any Error).self) { try ProjectInit.Options.parse(args) }
    }

    @Test(arguments: [
        ("no app name uses the project directory name", nil as String?, "proj", "proj-e2e", ".build/debug/proj"),
        ("spaces in the name become hyphens", "My App", "proj", "my-app-e2e", ".build/debug/My App"),
    ] as [(String, String?, String, String, String)])
    func appNameAndDefaults(_ name: String, _ appName: String?, _ projectName: String, _ product: String, _ executable: String) {
        let i = ProjectInit(options: .init(appName: appName, executable: nil, dir: "E2E"), projectName: projectName, kitPath: "/k/wispstage")
        #expect(i.product == product)
        #expect(i.executable == executable)
    }
}

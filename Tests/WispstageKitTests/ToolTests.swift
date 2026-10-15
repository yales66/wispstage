import Foundation
import Testing
@testable import WispstageKit

// The first column of each parameterized case is its name (Swift Testing has no ids: and displays cases by their arguments, so a leading name shows which case is which).

struct ScenarioPackageConfigTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("wispstage-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.resolvingSymlinksInPath()
    }

    @Test func findsConfigFileFromCurrentDirectoryUpward() throws {
        let root = try tempDir()
        try Data(#"{"scenarioPackage":"app/Scripts/E2E","product":"thing-e2e"}"#.utf8)
            .write(to: root.appendingPathComponent(ScenarioPackageConfig.fileName))
        let deep = root.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let found = try #require(try ScenarioPackageConfig.find(from: deep))
        #expect(found.dir.standardizedFileURL.path == root.standardizedFileURL.path)
        #expect(found.config == ScenarioPackageConfig(scenarioPackage: "app/Scripts/E2E", product: "thing-e2e"))
    }

    @Test func returnsNilWhenNoConfigUpToTheRoot() throws {
        let root = try tempDir()
        // No .wispstage.json should exist above the temporary directory (if one does, the machine is not clean and this case cannot be tested)
        #expect(try ScenarioPackageConfig.find(from: root) == nil)
    }

    @Test func malformedConfigThrows() throws {
        let root = try tempDir()
        try Data(#"{"scenarioPackage":"x"}"#.utf8).write(to: root.appendingPathComponent(ScenarioPackageConfig.fileName))
        #expect(throws: (any Error).self) { try ScenarioPackageConfig.find(from: root) }
    }

    @Test(arguments: [
        ("list forwarded unchanged", ["list", "main."]),
        ("baseline forwarded unchanged", ["baseline", "accept", "/r"]),
        ("run forwarded unchanged", ["run", "--mode", "foreground", "smoke."]),
        ("run is not inserted", ["--shots=all", "main."]),
    ] as [(String, [String])])
    func forwardedArgumentsFollowTheExecutableTargetUnchanged(_ name: String, _ args: [String]) {
        let c = ScenarioPackageConfig(scenarioPackage: "app/Scripts/E2E", product: "thing-e2e")
        let dir = URL(fileURLWithPath: "/repo")
        #expect(c.swiftRunArguments(configDir: dir, forwarding: args)
            == ["swift", "run", "--package-path", "/repo/app/Scripts/E2E", "thing-e2e"] + args)
    }
}

struct ToolRoutingTests {
    @Test(arguments: [
        ("list", ["list"], ["list"] as [String]?),
        ("list with filter", ["list", "smoke."], ["list", "smoke."]),
        ("run with filter", ["run", "smoke."], ["run", "smoke."]),
        ("run with mode", ["run", "--mode", "foreground", "main."], ["run", "--mode", "foreground", "main."]),
        ("baseline", ["baseline", "accept", "/r", "main."], ["baseline", "accept", "/r", "main."]),
        ("windows local", ["windows", "--pid", "1"], nil),
        ("listing local", ["listing", "--pid", "1"], nil),
        ("shot local", ["shot", "--pid", "1"], nil),
        ("summary local", ["summary", "/r"], nil),
        ("init local", ["init"], nil),
        ("no subcommand", [], nil),
    ] as [(String, [String], [String]?)])
    func whichTopLevelSubcommandsAreForwardedToTheScenarioPackage(_ name: String, _ args: [String], _ forwarded: [String]?) {
        #expect(WispstageTool.forwardedArguments(args) == forwarded)
    }
}

struct InspectOptionsTests {
    @Test(arguments: [
        ("pid", ["--pid", "123"], InspectTarget.pid(123), [String: String]()),
        ("bundle id and output", ["--bundle-id", "com.example.a", "--out", "/tmp/x"], .bundleID("com.example.a"), ["--out": "/tmp/x"]),
        ("equals syntax", ["--pid=7", "--window=42"], .pid(7), ["--window": "42"]),
    ] as [(String, [String], InspectTarget, [String: String])])
    func parsesTargetAndRemainingOptions(_ name: String, _ args: [String], _ target: InspectTarget, _ rest: [String: String]) throws {
        let o = try InspectOptions.parse(args)
        #expect(o.target == target)
        #expect(o.values.filter { $0.key != "--pid" && $0.key != "--bundle-id" } == rest)
    }

    @Test(arguments: [
        ("no target", [String]()),
        ("both given", ["--pid", "1", "--bundle-id", "a"]),
        ("pid not a number", ["--pid", "abc"]),
        ("option missing value", ["--pid"]),
        ("unknown option", ["--pid", "1", "--frobnicate", "x"]),
    ] as [(String, [String])])
    func invalidArgumentsThrow(_ name: String, _ args: [String]) {
        #expect(throws: (any Error).self) { try InspectOptions.parse(args) }
    }
}

struct SummaryRerenderTests {
    @Test func summaryRerenderedFromResultsMatchesTheOneWrittenAfterTheRun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wispstage-sum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var r = ScenarioResult(name: "main.start", status: "failed", failedStep: "press x", reason: "not found", check: nil, crashReport: nil,
                               durationSec: 1.5, steps: 3, artifacts: dir.path)
        r.waivers = [.init(step: "s", check: "overlap", reason: "known")]
        let ok = ScenarioResult(name: "main.ok", status: "passed", failedStep: nil, reason: nil, check: nil, crashReport: nil,
                                durationSec: 0.5, steps: 1, artifacts: dir.path)
        let record = RunRecord(results: [r, ok], runDir: dir, started: Date(timeIntervalSince1970: 1_800_000_000),
                               finished: Date(timeIntervalSince1970: 1_800_000_100), mode: .background, shots: .key, appName: "Demo")
        let direct = Runner.summaryText(record)
        let enc = JSONEncoder()
        try enc.encode(record).write(to: dir.appendingPathComponent("results.json"))
        let again = try Runner.rewriteSummary(runDir: dir)
        #expect(again == direct)
        #expect(direct.hasPrefix("Demo E2E  "))
        #expect(direct.contains("Failed  main.start  (1.5"))
        #expect(direct.contains("Passed  main.ok  (0.5"))
        #expect(direct.contains("(1.5s, 3 steps)"))
        #expect(direct.contains("(0.5s, 1 step)"))
        #expect(direct.contains("Passed: 1  Failed: 1"))
        #expect(try String(contentsOf: dir.appendingPathComponent("summary.txt"), encoding: .utf8) == direct)
    }

    @Test func throwsWhenResultsAreMissing() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wispstage-none-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { try Runner.rewriteSummary(runDir: dir) }
    }
}

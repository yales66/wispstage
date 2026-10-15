// End-to-end scenarios for Wispboard.
//
// From Examples/Wispboard or any directory below it:
//   wispstage list [filter...]
//   wispstage run [--shots=key|all|none] [filter...]          // background mode: the app stays beneath the wallpaper
//   WISPBOARD_PLANT_BUGS=1 wispstage run                      // the same suite against the app with six planted bugs
// `run` builds the test host (swift build --product WispboardTestHost) before the first scenario, so a fresh clone needs no other step.
// Output goes to Examples/Wispboard/build/e2e-runs/<timestamp>/; read summary.txt there first.

import Foundation
import WispstageKit

/// This scenario package's directory (three levels above Sources/<target>/main.swift).
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
/// The project root (the directory containing .wispstage.json).
let projectDir = packageDir.appendingPathComponent("..").standardizedFileURL

/// Builds the test host, which SwiftPM skips quickly when nothing changed. Only `run` needs it; `list` does not launch the app.
func buildTestHost() {
    guard CommandLine.arguments.dropFirst().first == "run" else { return }
    let swift = Process()
    swift.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    swift.arguments = ["swift", "build", "--package-path", projectDir.path, "--product", "WispboardTestHost"]
    let output = Pipe()
    swift.standardOutput = output
    swift.standardError = output
    print("Building WispboardTestHost…")
    do {
        try swift.run()
        let log = output.fileHandleForReading.readDataToEndOfFile()
        swift.waitUntilExit()
        guard swift.terminationStatus == 0 else {
            FileHandle.standardError.write(log)
            FileHandle.standardError.write(Data("Building WispboardTestHost failed (exit code \(swift.terminationStatus))\n".utf8))
            exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data("Could not run swift build: \(error)\n".utf8))
        exit(1)
    }
}

buildTestHost()

let testHost: URL
do {
    // Wraps the bare SwiftPM executable in an app bundle with its own bundle ID, which background mode needs.
    testHost = try PreviewBundle.prepare(executable: projectDir.appendingPathComponent(".build/debug/WispboardTestHost"),
                                         in: projectDir.appendingPathComponent("build/e2e-bundle"),
                                         bundleID: "com.example.wispboard.testhost", name: "Wispboard")
} catch {
    FileHandle.standardError.write(Data("Could not prepare the test host bundle: \(error)\n".utf8))
    exit(1)
}

let configuration = E2EConfiguration(
    appName: "Wispboard",
    projectDir: projectDir,
    defaultExecutable: testHost,
    // Each run's output goes in <runsDir>/<timestamp>/; kept out of version control.
    runsDir: projectDir.appendingPathComponent("build/e2e-runs"),
    // Baseline screenshots (none are committed for this example).
    baselinesDir: packageDir.appendingPathComponent("Baselines"),
    // German text is read back too when the truncation check compares what is drawn with what the app says.
    textChecks: TextCheckConfig(ocrLanguages: ["en-US", "de-DE"]))

let allScenarios: [Scenario] = boardScenarios + inspectorScenarios + settingsScenarios

WispstageCLI.main(suite: E2ESuite(configuration: configuration, scenarios: allScenarios))

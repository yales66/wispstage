import ApplicationServices
import CoreGraphics
import Foundation

/// An end-to-end scenario: a name (`<area>.<flow>`, runs are filtered by name or prefix) and a body.
public struct Scenario {
    public let name: String
    public let body: (E2ETest) throws -> Void

    public init(_ name: String, _ body: @escaping (E2ETest) throws -> Void) {
        self.name = name
        self.body = body
    }
}

/// Writing a scenario: `scenario("settings.save") { t in try t.launch(spec, step: "launch"); … }`.
public func scenario(_ name: String, _ body: @escaping (E2ETest) throws -> Void) -> Scenario {
    Scenario(name, body)
}

/// Appearance (one segment of the baseline group).
public enum Appearance: String, Sendable { case dark, light }

/// The result of one scenario, written to results.json.
public struct ScenarioResult: Codable {
    public struct KnownFailure: Codable { public var issue: String; public var step: String?; public var reason: String }
    public struct Waiver: Codable { public var step: String; public var check: String; public var reason: String }
    /// A crop: a `t.shot(id:)` crop (check is nil), or the automatic crop of an element involved in a generic check that failed (including waived ones).
    public struct Crop: Codable {
        public var step: String
        public var check: String?
        public var element: String
        public var path: String
        public var waived: Bool
    }

    /// What the listed-for-review checks (missing identifiers, click targets, alignment) saw; each element is recorded only the first time in a scenario.
    public struct Note: Codable, Equatable {
        public var check: String
        public var step: String
        public var element: String
        public var detail: String

        public init(check: String, step: String, element: String, detail: String) {
            self.check = check
            self.step = step
            self.element = element
            self.detail = detail
        }
    }

    public var name: String
    /// passed / failed / skipped (a step needing foreground mode in background mode, `E2ETest.requireForeground`; or a locked screen)
    /// / interrupted (in foreground mode the cursor moved again during a retry, `E2ESkip.interrupted`)
    public var status: String
    public var failedStep: String?
    public var reason: String?
    public var check: String?
    public var crashReport: String?
    public var durationSec: Double
    public var steps: Int
    public var knownFailures: [KnownFailure] = []
    /// The expectFailure block did not fail this time: the issue may be fixed, and the expectFailure should be removed.
    public var unexpectedPasses: [String] = []
    public var waivers: [Waiver] = []
    public var crops: [Crop] = []
    /// Screenshots that differ from their baseline (not a failure, only flagged for a person to look at); see `Baselines`.
    public var visualDiffs: [Baselines.Diff] = []
    /// Screenshots with no baseline of the same name.
    public var noBaseline: [String] = []
    public var notes: [Note] = []
    /// Skipped at a step needing foreground mode in background mode (`E2ETest.requireForeground`); nil otherwise.
    public var foregroundOnly: Bool?
    public var artifacts: String
}

/// One run: selects scenarios by filter, runs each while holding the lock, writes the summary.
public enum Runner {
    public static func list(_ scenarios: [Scenario], filters: [String]) {
        for n in ScenarioFilter.select(scenarios.map(\.name), filters: filters) { print(n) }
    }

    /// Returns the process exit code: 1 when anything failed (known failures do not count), 2 when no scenario was selected.
    public static func run(_ suite: E2ESuite, filters: [String], shots: ShotsMode = .key, mode runMode: RunMode = .current) -> Int32 {
        let config = suite.configuration
        let scenarios = suite.scenarios
        let names = ScenarioFilter.select(scenarios.map(\.name), filters: filters)
        guard !names.isEmpty else {
            FileHandle.standardError.write(Data("No scenario matches \(filters.joined(separator: " "))\n".utf8))
            return 2
        }
        RunMode.current = runMode
        let mode = runMode.inputMode
        guard Preflight.ok(mode: mode) else { return 1 }
        if runMode == .foreground { ForegroundNotice.countdown(names: names, runsDir: config.runsDir) }
        let started = Date()
        let runDir = config.runsDir.appendingPathComponent(Timestamp.dir(started))
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        print("Run directory: \(runDir.path)")
        print("Run mode: \(runMode.rawValue) (--mode or WISPSTAGE_MODE)  Input: \(mode.rawValue)  Full-window screenshots: \(shots.rawValue) (--shots)")
        fflush(stdout)
        var results: [ScenarioResult] = []
        for name in names {
            guard let sc = scenarios.first(where: { $0.name == name }) else { continue }
            let dir = runDir.appendingPathComponent(FileName.safe(name))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let lock = ScreenLock.acquire(mode: mode, executable: config.defaultExecutable)
            let t = E2ETest(name: name, dir: dir, configuration: config, runMode: runMode, shots: shots)
            let t0 = Date()
            var failure: E2EFailure?
            // The inprocess promise: the system cursor and the frontmost app are the same before and after the scenario (Untouched).
            // Wait for the frontmost app to settle first. On 2026-10-14 the app under test (never activated) once became frontmost,
            // right after a hid scenario from another run exited; presumably the system picked it as the new frontmost app after the previous one quit (not confirmed by measurement).
            if mode == .inprocess { Untouched.waitUntilFrontmostSettles() }
            let before = Untouched.Snapshot.now()
            let scenarioStart = Date()
            do {
                try sc.body(t)
            } catch let f as E2EFailure {
                failure = f
            } catch let skip as E2ESkip {
                t.skipped = t.skipped ?? skip
            } catch {
                failure = E2EFailure("\(error)", step: t.currentStep)
            }
            t.finishShots()
            if mode == .inprocess, Untouched.enabled {
                let userMoved = Untouched.userMovedPointer(secondsSinceLastMove: Untouched.secondsSinceUserPointerInput(),
                                                           scenarioSeconds: Date().timeIntervalSince(scenarioStart))
                if userMoved { t.log("  The user moved the pointer during the scenario; the cursor position is not judged") }
                let problems = Untouched.problems(before: before, after: Untouched.Snapshot.now(), appPID: t.app?.pid, userMovedPointer: userMoved)
                for m in problems { t.log("  ✗ Before and after the scenario: \(m)") }
                if failure == nil, let first = problems.first {
                    failure = E2EFailure("In inprocess input mode, \(first)" + (problems.count > 1 ? "; \(problems[1])" : ""),
                                         step: "(before and after the scenario)")
                }
                if problems.isEmpty { t.log("  ✓ System cursor and frontmost app (\(before.frontmostName ?? "?")) unchanged before and after the scenario") }
            }
            if let f = failure { t.recordFailure(f) }
            t.teardown()
            lock.release()
            // Skipped scenario: failures after the skip point are most likely caused by the step that did not run, so it is recorded as skipped and the failure reason stays in steps.log
            let skip = t.skipped
            if let skip, let f = failure { t.log("  Failure after \(skip.interrupted ? "interruption" : "skip") not counted: \(f)") }
            let status = skip?.interrupted == true ? "interrupted" : skip != nil ? "skipped" : failure == nil ? "passed" : "failed"
            if skip != nil { failure = nil }
            var r = ScenarioResult(
                name: name, status: status,
                failedStep: skip.map { $0.step ?? t.currentStep ?? "(before start)" } ?? failure.map { $0.step ?? t.currentStep ?? "(before start)" },
                reason: skip?.reason ?? failure?.description,
                check: failure?.check?.rawValue, crashReport: t.crashReportPath, durationSec: Date().timeIntervalSince(t0),
                steps: t.stepCount, artifacts: dir.path)
            r.knownFailures = t.knownFailures
            r.unexpectedPasses = t.unexpectedPasses
            r.waivers = t.waiverLog
            r.crops = t.crops
            r.notes = t.notes
            if skip?.foregroundOnly == true { r.foregroundOnly = true }
            try? ShotRecord.write(t.shotRecords, to: dir)
            let cmp = Baselines.compare(scenarioDir: dir, scenario: FileName.safe(name), root: config.baselinesDir)
            r.visualDiffs = cmp.diffs
            r.noBaseline = cmp.missing
            results.append(r)
            let mark = ["skipped": "Skipped", "interrupted": "Interrupted"][status] ?? (failure == nil ? "Passed" : "Failed")
            print("\(mark)  \(name)" + (failure.map { "  [\(r.failedStep ?? "")] \($0)" } ?? "")
                  + (r.knownFailures.isEmpty ? "" : "  Known failures: \(r.knownFailures.map(\.issue).joined(separator: ","))"))
            if VisibilityGate.failed {
                print("Windows could not be hidden, stopping the run (later scenarios did not run); to run with visible windows use --mode foreground")
                break
            }
        }
        writeSummary(results, runDir: runDir, started: started, shots: shots, mode: runMode, appName: config.appName)
        return results.contains { $0.status == "failed" } ? 1 : 0
    }

    /// The "Skipped in background mode" section of summary.txt: scenarios and steps skipped in background mode because they need foreground mode (lock-screen skips are not listed).
    static func backgroundSkipLines(_ results: [ScenarioResult]) -> [String] {
        let skips = results.filter { $0.status == "skipped" && $0.foregroundOnly == true }
        guard !skips.isEmpty else { return [] }
        return ["Skipped in background mode (\(skips.count), run with --mode foreground to test them):"]
            + skips.map { "  \($0.name) @\($0.failedStep ?? ""): \($0.reason ?? "")" }
    }

    /// The "Interrupted by user input" section of summary.txt: scenarios and steps where the cursor moved again during a retry in foreground mode.
    static func interruptedLines(_ results: [ScenarioResult]) -> [String] {
        let hits = results.filter { $0.status == "interrupted" }
        guard !hits.isEmpty else { return [] }
        return ["Interrupted by user input (\(hits.count), neither failed nor passed, later steps did not run):"]
            + hits.map { "  \($0.name) @\($0.failedStep ?? ""): \($0.reason ?? "")" }
    }

    /// The listed-for-review sections of summary.txt.
    static func noteLines(_ notes: [ScenarioResult.Note]) -> [String] {
        let titles: [(Check, String)] = [
            (.missingIdentifier, "Missing identifier"), (.hitTarget, "Click target smaller than 20x20 pt"), (.alignment, "Not aligned"), (.contrast, "Low contrast"), (.occlusion, "Partly covered"),
        ]
        var out: [String] = []
        for (check, title) in titles {
            let mine = notes.filter { $0.check == check.rawValue }
            guard !mine.isEmpty else { continue }
            out.append("      \(title) (\(mine.count), listed for review):")
            out += mine.map { "        @\($0.step) \($0.element) \($0.detail)" }
        }
        return out
    }

    private static func writeSummary(_ results: [ScenarioResult], runDir: URL, started: Date, shots: ShotsMode, mode: RunMode, appName: String) {
        let run = RunRecord(results: results, runDir: runDir, started: started, finished: Date(), mode: mode, shots: shots, appName: appName)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? enc.encode(run).write(to: runDir.appendingPathComponent("results.json"))
        let s = summaryText(run)
        try? s.write(to: runDir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        print("\n" + s)
    }

    /// Rereads a run's results.json and regenerates summary.txt (overwriting it), returning its text.
    public static func rewriteSummary(runDir: URL) throws -> String {
        let data = try Data(contentsOf: runDir.appendingPathComponent("results.json"))
        let s = summaryText(try JSONDecoder().decode(RunRecord.self, from: data))
        try s.write(to: runDir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        return s
    }

    /// The full text of summary.txt.
    static func summaryText(_ run: RunRecord) -> String {
        let results = run.scenarios
        var s = "\(run.appName ?? "") E2E  \(run.startedAt)\n"
        s += "Run mode: \(run.mode)\n"
        s += "Input: \((RunMode(rawValue: run.mode)?.inputMode.rawValue) ?? "?")\n"
        s += "Full-window screenshots: \(run.shots ?? "?")\n"
        s += "Passed: \(run.passed)  Failed: \(run.failed)  Skipped: \(run.skipped)  Interrupted: \(run.interrupted)  Known failures: \(run.knownFailures)\n\n"
        let skipLines = backgroundSkipLines(results)
        if !skipLines.isEmpty { s += skipLines.joined(separator: "\n") + "\n\n" }
        let cutLines = interruptedLines(results)
        if !cutLines.isEmpty { s += cutLines.joined(separator: "\n") + "\n\n" }
        for r in results {
            s += "\(["passed": "Passed", "skipped": "Skipped", "interrupted": "Interrupted"][r.status] ?? "Failed")  \(r.name)  (\(String(format: "%.1f", r.durationSec))s, \(counted(r.steps, "step")))\n"
            if r.status == "interrupted" { s += "      Interrupted at: \(r.failedStep ?? "")\n      Reason: \(r.reason ?? "")\n" }
            if r.status == "skipped" { s += "      Skipped at: \(r.failedStep ?? "")\n      Reason: \(r.reason ?? "")\n" }
            if r.status == "failed" { s += "      Failed step: \(r.failedStep ?? "")\n      Reason: \(r.reason ?? "")\n" }
            if let c = r.crashReport { s += "      Crash report: \(c)\n" }
            for k in r.knownFailures { s += "      Known failure \(k.issue): [\(k.step ?? "")] \(k.reason)\n" }
            for u in r.unexpectedPasses { s += "      \(u) did not fail this time, may be fixed\n" }
            for w in r.waivers { s += "      Waived \(w.check) @ \(w.step): \(w.reason)\n" }
            for d in r.visualDiffs {
                s += "      Pixel difference \(d.file) (\(String(format: "%.2f", d.ratio * 100))% of pixels differ): highlight \(d.diffImage ?? "(not generated: sizes differ or unreadable)"); baseline \(d.baseline)\n"
            }
            if !r.noBaseline.isEmpty { s += "      No baseline (\(r.noBaseline.count)): \(r.noBaseline.joined(separator: ", "))\n" }
            for c in r.crops {
                let tag = c.check.map { "[\($0)] \(c.waived ? "waived" : "failed")" } ?? "crop"
                s += "      Crop \(tag) @ \(c.step) \"\(c.element.prefix(30))\": \(c.path)\n"
            }
            for line in noteLines(r.notes) { s += line + "\n" }
        }
        return s
    }
}

/// A run's results.json. `appName` and `shots` are optional because older results.json files lack them.
public struct RunRecord: Codable {
    public var startedAt: String
    public var finishedAt: String
    public var runDir: String
    public var mode: String
    public var shots: String?
    public var appName: String?
    public var passed: Int
    public var failed: Int
    public var skipped: Int
    public var interrupted: Int
    public var knownFailures: Int
    public var scenarios: [ScenarioResult]

    public init(results: [ScenarioResult], runDir: URL, started: Date, finished: Date, mode: RunMode, shots: ShotsMode, appName: String) {
        let iso = ISO8601DateFormatter()
        startedAt = iso.string(from: started)
        finishedAt = iso.string(from: finished)
        self.runDir = runDir.path
        self.mode = mode.rawValue
        self.shots = shots.rawValue
        self.appName = appName
        passed = results.filter { $0.status == "passed" }.count
        failed = results.filter { $0.status == "failed" }.count
        skipped = results.filter { $0.status == "skipped" }.count
        interrupted = results.filter { $0.status == "interrupted" }.count
        knownFailures = results.reduce(0) { $0 + $1.knownFailures.count }
        scenarios = results
    }
}

enum Timestamp {
    static func dir(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }

    static func log(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: d)
    }
}

/// Mutual exclusion between scenarios: each scenario takes an flock before it starts and queues if it cannot get it (by the run mode's input method: foreground is hid, background is inprocess):
/// - hid: the exclusive global lock (`ScreenLock.lockFile`). There is only one real cursor, frontmost app and HID event stream, so only one scenario can use them at a time.
/// - inprocess: the shared global lock (runs alongside other inprocess scenarios, waits for hid scenarios to finish), then the exclusive lock of the app bundle under test
///   (`ScreenLock.instanceLockFile`; a Bundle ID has only one container, so runs in the same worktree stay serial).
///   When each worktree builds the app bundle under test with a different Bundle ID, different worktrees can run at the same time.
/// The global lock guards a single screen, so every app using this driver must share one; that is why the default path is hard-coded here and not in the adopter's configuration.
public final class ScreenLock {
    private let fds: [Int32]

    private init(fds: [Int32]) { self.fds = fds }

    /// The screen lock shared across worktrees and apps; `WISPSTAGE_LOCK` overrides it.
    public static var lockFile: URL {
        if let s = ProcessInfo.processInfo.environment["WISPSTAGE_LOCK"] { return URL(fileURLWithPath: s) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/wispstage/e2e.lock")
    }

    /// The lock that lets one app bundle under test (same Bundle ID, same container) run one scenario at a time, in the same directory as the global lock.
    public static func instanceLockFile(bundleID: String) -> URL {
        lockFile.deletingLastPathComponent().appendingPathComponent("e2e-\(FileName.safe(bundleID)).lock")
    }

    /// Bundle ID of the app bundle containing the executable (the Info.plist next to `<bundle>.app/Contents/MacOS/<executable>`); nil if it cannot be read.
    public static func bundleID(executable: URL) -> String? {
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let d = NSDictionary(contentsOf: plist) else { return nil }
        return d["CFBundleIdentifier"] as? String
    }

    /// Takes only the exclusive global lock (what hid mode does).
    public static func acquire() -> ScreenLock { ScreenLock(fds: [lock(lockFile, exclusive: true)].filter { $0 >= 0 }) }

    public static func acquire(mode: InputMode, executable: URL) -> ScreenLock {
        if mode == .hid { return acquire() }
        guard let id = bundleID(executable: executable) else {
            print("Cannot read the Bundle ID of the app bundle under test (\(executable.path)), taking the exclusive global lock as in hid mode")
            return acquire()
        }
        // Take this bundle's lock before the shared lock: a run queued in the same worktree then does not hold the shared lock and needlessly block hid scenarios
        let own = lock(instanceLockFile(bundleID: id), exclusive: true)
        let shared = lock(lockFile, exclusive: false)
        return ScreenLock(fds: [own, shared].filter { $0 >= 0 })
    }

    private static func lock(_ url: URL, exclusive: Bool) -> Int32 {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            print("Cannot open lock file \(url.path) (errno \(errno)), continuing without a lock")
            return -1
        }
        let op = exclusive ? LOCK_EX : LOCK_SH
        if flock(fd, op | LOCK_NB) != 0 {
            print(exclusive ? "Lock \(url.path) is held by another E2E driver, waiting for it to finish…"
                            : "An E2E run in hid input mode is in progress (lock \(url.path)), waiting for it to finish…")
            fflush(stdout)
            flock(fd, op)
        }
        return fd
    }

    public func release() {
        for fd in fds {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }
}

/// Checks permissions before running: Accessibility, Screen Recording, event posting. The driver runs as a child process of the terminal, so permissions follow the terminal.
enum Preflight {
    static func ok(mode: InputMode) -> Bool {
        var missing: [String] = []
        if !AXIsProcessTrusted() { missing.append("Accessibility") }
        if !CGPreflightScreenCaptureAccess() { missing.append("Screen Recording") }
        // Only foreground mode (hid) needs event posting (under inprocess the app under test synthesizes events in its own process, not through the system)
        if mode == .hid, !CGPreflightPostEventAccess() { missing.append("event posting") }
        if missing.isEmpty { return true }
        FileHandle.standardError.write(Data("The terminal running the driver lacks permissions: \(missing.joined(separator: ", ")). Grant them to the terminal in System Settings > Privacy & Security, then run again.\n".utf8))
        return false
    }
}

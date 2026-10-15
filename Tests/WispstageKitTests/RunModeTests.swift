import CoreGraphics
import Foundation
import Testing
@testable import WispstageKit

// The first column of parameterized cases is the case name (Swift Testing has no ids: and displays cases by their arguments, so a name in the first column tells which one it is).

struct RunModeTests {
    @Test(arguments: [
        ("neither given uses background", nil, [:], RunMode.background),
        ("command line foreground", "foreground", [:], .foreground),
        ("command line overrides environment variable", "background", ["WISPSTAGE_MODE": "foreground"], .background),
        ("environment variable foreground", nil, ["WISPSTAGE_MODE": "foreground"], .foreground),
        ("empty environment variable uses background", nil, ["WISPSTAGE_MODE": ""], .background),
    ] as [(String, String?, [String: String], RunMode)])
    func resolvesMode(_ name: String, _ cli: String?, _ env: [String: String], _ mode: RunMode) throws {
        #expect(try RunMode.resolve(cli: cli, environment: env) == mode)
    }

    @Test(arguments: [
        ("invalid on command line", "hidden", [String: String]()),
        ("invalid in environment variable", nil, ["WISPSTAGE_MODE": "hid"]),
    ] as [(String, String?, [String: String])])
    func invalidOrRemovedNameThrows(_ name: String, _ cli: String?, _ env: [String: String]) {
        #expect(throws: E2EFailure.self) { try RunMode.resolve(cli: cli, environment: env) }
    }

    @Test(arguments: [
        ("separate argument", ["--mode", "foreground", "smoke."], "foreground", ["smoke."]),
        ("with equals sign", ["smoke.", "--mode=background"], "background", ["smoke."]),
        ("not given", ["--shots=all", "settings."], nil, ["--shots=all", "settings."]),
    ] as [(String, [String], String?, [String])])
    func extractsModeFromArguments(_ name: String, _ args: [String], _ raw: String?, _ rest: [String]) throws {
        let (m, r) = try RunMode.extract(from: args)
        #expect(m == raw)
        #expect(r == rest)
    }

    @Test func modeWithoutValueThrows() {
        #expect(throws: E2EFailure.self) { try RunMode.extract(from: ["--mode"]) }
    }

    @Test func modeDeterminesInputMethodAndStage() {
        #expect(RunMode.foreground.inputMode == .hid && !RunMode.foreground.usesStage)
        #expect(RunMode.background.inputMode == .inprocess && RunMode.background.usesStage)
    }

    @Test(arguments: [(RunMode.background, "1"), (.foreground, "observe")])
    func modeDeterminesStageMode(_ mode: RunMode, _ value: String) {
        #expect(mode.stageEnvironmentValue == value)
    }

    @Test(arguments: [(RunMode.background, true), (.foreground, false)])
    func stageConnectionFailureIsFatalOnlyInBackgroundMode(_ mode: RunMode, _ fatal: Bool) {
        // An app at adoption level 0 does not link the stage library and can only run in foreground: it runs without the connection, and beeps have no source and are not checked.
        #expect(mode.requiresStage == fatal)
    }

    @Test func backgroundRunWithoutStageNamesBothWaysOut() {
        struct Refused: Error, CustomStringConvertible { var description: String { "connection refused" } }
        let m = E2ETest.stageMissingMessage(Refused())
        #expect(m.contains("connection refused"))
        #expect(m.contains("background mode"))
        #expect(m.contains("does not link the stage library"))
        #expect(m.contains("--mode foreground"))
        #expect(m.contains("Wispstage.install()"))
        #expect(m.contains("adoption level 2"))
    }
}

struct ChecksByModeTests {
    @Test(arguments: [
        ("foreground mode does not judge coming to the front", Check.foreground, RunMode.foreground, false),
        ("foreground mode does not judge becoming key", .keyFocus, .foreground, false),
        ("foreground mode still judges beeps", .beep, .foreground, true),
        ("background mode judges coming to the front", .foreground, .background, true),
        ("background mode judges becoming key", .keyFocus, .background, true),
        ("background mode judges beeps", .beep, .background, true),
        ("other checks are judged in both modes", .overlap, .foreground, true),
    ] as [(String, Check, RunMode, Bool)])
    func checksAreJudgedByMode(_ name: String, _ c: Check, _ mode: RunMode, _ judged: Bool) {
        #expect(c.judged(in: mode) == judged)
    }
}

struct ForegroundSkipTests {
    private func test(_ mode: RunMode) -> E2ETest {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runmode-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return E2ETest(name: "x", dir: dir, runMode: mode)
    }

    @Test func backgroundModeSkipsForegroundStepAndRecordsItAsForegroundOnly() {
        let t = test(.background)
        #expect(throws: E2ESkip.self) { try t.requireForeground("global shortcut") }
        #expect(t.skipped?.foregroundOnly == true)
    }

    @Test func foregroundModeDoesNotSkipForegroundStep() throws {
        let t = test(.foreground)
        try t.requireForeground("global shortcut")
        #expect(t.skipped == nil)
    }

    @Test func summaryListsOnlyStepsSkippedInBackgroundMode() {
        func result(_ name: String, status: String, step: String?, reason: String?, fg: Bool?) -> ScenarioResult {
            var r = ScenarioResult(name: name, status: status, failedStep: step, reason: reason, check: nil, crashReport: nil,
                                   durationSec: 1, steps: 1, artifacts: "")
            r.foregroundOnly = fg
            return r
        }
        let lines = Runner.backgroundSkipLines([
            result("smoke.foregroundOnly", status: "skipped", step: "01-launch", reason: "Step needs foreground mode: smoke", fg: true),
            result("smoke.lock", status: "skipped", step: "02-x", reason: "Skipped: screen locked", fg: nil),
            result("smoke.e2e", status: "passed", step: nil, reason: nil, fg: nil),
        ])
        #expect(lines == ["Skipped in background mode (1, run with --mode foreground to test them):",
                          "  smoke.foregroundOnly @01-launch: Step needs foreground mode: smoke"])
        #expect(Runner.backgroundSkipLines([result("a", status: "passed", step: nil, reason: nil, fg: nil)]).isEmpty)
    }
}

struct CursorWatchTests {
    @Test(arguments: [
        ("nobody moved it", CGPoint(x: 100, y: 100), 0, CGPoint?.none, CGPoint(x: 100, y: 100), false),
        ("someone else moved it", CGPoint(x: 100, y: 100), 0, CGPoint?.none, CGPoint(x: 140, y: 100), true),
        ("the driver's own move does not count", CGPoint(x: 100, y: 100), 3, CGPoint(x: 400, y: 300), CGPoint(x: 400, y: 300), false),
        ("moved away by someone else after the driver moved it", CGPoint(x: 100, y: 100), 3, CGPoint(x: 400, y: 300), CGPoint(x: 100, y: 100), true),
        ("the driver's last move was before recording", CGPoint(x: 100, y: 100), 0, CGPoint(x: 400, y: 300), CGPoint(x: 100, y: 100), false),
    ] as [(String, CGPoint, Int, CGPoint?, CGPoint, Bool)])
    func detectsCursorMovedByOthers(_ name: String, _ anchor: CGPoint, _ newMoves: Int, _ driverLast: CGPoint?, _ now: CGPoint, _ moved: Bool) {
        var w = CursorWatch()
        w.anchor(at: anchor, driverMoves: 7)
        #expect(w.movedByOthers(now: now, driverMoves: 7 + newMoves, driverLast: driverLast) == moved)
    }

    @Test func noJudgmentWithoutRecordedPosition() {
        #expect(!CursorWatch().movedByOthers(now: CGPoint(x: 1, y: 1), driverMoves: 0, driverLast: nil))
    }

    /// Fake clock: each sleep advances time. The cursor is in a different place at 0, 0.5 and 1.0 seconds, then stays still; it returns only after 2 seconds of stillness.
    @Test func waitsForCursorStillForTwoSeconds() {
        var t: TimeInterval = 0
        let path: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 9, y: 2)]
        let waited = CursorWatch.waitUntilStill(stillFor: 2, interval: 0.5, sample: { path[min(Int(t / 0.5), path.count - 1)] },
                                                now: { t }, sleep: { t += $0 })
        // The last change, to (9,2), is at 1.0 seconds; 2 seconds of stillness ends at 3.0 seconds
        #expect(waited == 3.0)
    }

    @Test func stillDurationIsTheFixedTwoSeconds() {
        #expect(CursorWatch.stillSeconds == 2)
    }
}

struct ForegroundNoticeTests {
    @Test(arguments: [
        ("sums each scenario's historical mean and rounds up", ["a", "b"], ["a": [60.0, 120], "b": [100]], "The screen, keyboard and cursor will be in use for about 4 min"),
        ("scenarios without history use the mean of those with history", ["a", "c"], ["a": [60.0]], "The screen, keyboard and cursor will be in use for about 2 min"),
        ("no history at all says unknown", ["a"], [String: [Double]](), "The screen, keyboard and cursor will be in use for an unknown time (no duration history for these scenarios)"),
    ] as [(String, [String], [String: [Double]], String)])
    func estimatesOccupiedTime(_ name: String, _ names: [String], _ history: [String: [Double]], _ line: String) {
        #expect(ForegroundNotice.occupyLine(names: names, history: history) == line)
    }
}

/// Retrying after someone else moves the cursor in foreground mode: at most one retry; if it moves again the second time, the step is recorded as "interrupted by user input" and later steps do not run.
struct CursorRetryTests {
    private func foregroundTest(cursor: @escaping () -> CGPoint) -> E2ETest {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-retry-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t = E2ETest(name: "x", dir: dir, runMode: .foreground)
        t.screenLocked = { false }
        t.cursorNow = cursor
        t.waitCursorStill = {}
        return t
    }

    @Test func oneMoveRetriesOnceAndCompletesNormally() throws {
        var pos = CGPoint(x: 100, y: 100)
        let t = foregroundTest { pos }
        var runs = 0
        try t.step("click once") {
            runs += 1
            if runs == 1 { pos.x += 50 }
        }
        #expect(runs == 2)
        #expect(t.skipped == nil)
    }

    @Test func anotherMoveDuringRetryRecordsInterruptionWithoutRetrying() {
        var pos = CGPoint(x: 100, y: 100)
        let t = foregroundTest { pos }
        var runs = 0
        #expect(throws: E2ESkip.self) {
            try t.step("click once") {
                runs += 1
                pos.x += 50
            }
        }
        #expect(runs == 2)
        #expect(t.skipped?.interrupted == true)
    }

    @Test func summaryListsInterruptedStepsSeparately() {
        let r = ScenarioResult(name: "editor.a", status: "interrupted", failedStep: "03-click-once", reason: "Interrupted by user input: the cursor moved again during the retry",
                               check: nil, crashReport: nil, durationSec: 1, steps: 3, artifacts: "")
        let ok = ScenarioResult(name: "editor.b", status: "passed", failedStep: nil, reason: nil, check: nil, crashReport: nil,
                                durationSec: 1, steps: 1, artifacts: "")
        #expect(Runner.interruptedLines([r, ok]) == ["Interrupted by user input (1, neither failed nor passed, later steps did not run):",
                                                    "  editor.a @03-click-once: Interrupted by user input: the cursor moved again during the retry"])
        #expect(Runner.interruptedLines([ok]).isEmpty)
    }
}

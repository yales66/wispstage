import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WispstageClient

extension E2ETest {
    // MARK: - Steps

    /// One action step: log, run, wait for the UI to settle, screenshot, generic checks. On failure it also saves ax-<step name>.txt and a failure screenshot.
    @discardableResult
    public func step<R>(_ stepName: String, shot: Bool? = nil, _ body: () throws -> R) throws -> R {
        stepCount += 1
        let label = String(format: "%02d-%@", stepCount, FileName.safe(stepName))
        currentStep = label
        log("▶ \(label)")
        stepStartedAt = Date()
        stepDepth += 1
        defer { stepDepth -= 1 }
        if screenLocked() { throw lockSkip(label) }
        let waived = pendingWaivers.merging(scopedWaivers) { a, _ in a }
        pendingWaivers = [:]
        for (c, reason) in waived { waiverLog.append(.init(step: label, check: c.rawValue, reason: reason)) }
        do {
            let r = try cursorGuarded(body)
            settle()
            if shot ?? (autoShots && shotsMode.capturesStep(stepCount, explicit: nil)) { capture(label) }
            try runChecks(skipping: Set(waived.keys))
            log("  ✓ \(label)")
            return r
        } catch let f as E2EFailure where screenLocked() {
            log("  Screen was locked when this step failed, result discarded: \(f)")
            throw lockSkip(label)
        } catch var f as E2EFailure {
            if f.step == nil { f.step = label }
            failArtifacts(label)
            log("  ✗ \(label): \(f)")
            throw f
        } catch var skip as E2ESkip {
            if skip.step == nil { skip.step = label }
            throw skip
        } catch {
            failArtifacts(label)
            log("  ✗ \(label): \(error)")
            throw E2EFailure("\(error)", step: label)
        }
    }

    /// The outermost step in foreground mode: before running, checks whether someone else moved the cursor between steps, and if so waits for it to stop before starting; checks again afterwards,
    /// and if the cursor moved during this step, pauses, waits until the cursor has been still for `CursorWatch.stillSeconds` seconds, then retries the step (this attempt's result is discarded). All of it goes into steps.log.
    /// Retries at most once: if the cursor moves again during the retry, the step is recorded as "interrupted by user input" (`E2ESkip.interrupted`), neither failed nor passed, and later steps do not run.
    /// Retrying a non-idempotent step (such as a toggle that flips on each click) flips the state back, and another move also means the user is using the computer.
    /// Moves from the driver's own mouse events do not count (`Input.mouseMoves`). Background mode does not touch the user's cursor and does not watch it.
    func cursorGuarded<R>(_ body: () throws -> R) throws -> R {
        guard runMode == .foreground, stepDepth == 1 else { return try body() }
        func moved(_ now: CGPoint) -> Bool {
            cursorWatch.movedByOthers(now: now, driverMoves: Input.mouseMoves, driverLast: Input.lastMouse)
        }
        func pt(_ p: CGPoint?) -> String { p.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "?" }
        let still = Int(CursorWatch.stillSeconds)
        let before = cursorNow()
        if moved(before) {
            log("  ⏸ The cursor moved to \(pt(before)) between steps, waiting for it to be still for \(still)s before this step")
            waitCursorStill()
        }
        for attempt in 1...2 {
            cursorWatch.anchor(at: cursorNow(), driverMoves: Input.mouseMoves)
            let result = Result<R, Error> { try body() }
            let now = cursorNow()
            guard moved(now) else {
                cursorWatch.anchor(at: now, driverMoves: Input.mouseMoves)
                return try result.get()
            }
            let expected = cursorWatch.expected(driverMoves: Input.mouseMoves, driverLast: Input.lastMouse)
            var failed = false
            if case .failure = result { failed = true }
            let what = "The cursor moved during attempt \(attempt) of this step (driver expected \(pt(expected)), actual \(pt(now)))"
            if attempt == 1 {
                log("  ⏸ \(what), waiting for it to be still for \(still)s, then retrying this step" + (failed ? "; this failure is discarded" : ""))
                waitCursorStill()
                continue
            }
            var skip = E2ESkip("Interrupted by user input: the cursor moved again during the retry", step: currentStep)
            skip.interrupted = true
            skipped = skipped ?? skip
            log("  ⏹ \(what), recorded as interrupted by user input, later steps will not run" + (failed ? "; this failure is discarded" : ""))
            throw skip
        }
        preconditionFailure("At most one retry; the loop has already returned or thrown")
    }

    /// The accessibility tree cannot be read while the screen is locked, so this step's and later results are discarded: the scenario is recorded as "Skipped: screen locked", not as failed.
    func lockSkip(_ label: String) -> E2ESkip {
        let skip = E2ESkip("Skipped: screen locked", step: label)
        skipped = skipped ?? skip
        log("  ⤼ Skipped: screen locked")
        return skip
    }

    func failArtifacts(_ label: String) {
        failedStep = label
        guard let p = app, p.isRunning else { return }
        if shotsMode != .none { capture(label + "-failed") }
        dumpAX(label)
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(label + ".ax.txt").path) { writeListingNow() }
    }

    /// Called when the scenario ends while the app is still open: in key mode, adds a full-window screenshot of the last step (unless it was already captured or failed).
    func finishShots() {
        guard shotsMode == .key, autoShots, let label = currentStep, label != failedStep,
              !capturedSteps.contains(label), app?.isRunning ?? false else { return }
        capture(label)
    }

    /// Writes the accessibility trees of all current windows to ax-<name>.txt.
    public func dumpAX(_ label: String) {
        guard let (p, ax) = try? requireApp() else { return }
        var s = ""
        for w in WindowList.resolve(pid: p.pid, app: ax, known: knownWindows(), classifier: configuration.classifier) {
            s += "== \(w)\n" + (w.ax?.dump() ?? "(no accessibility window)\n")
        }
        try? s.write(to: dir.appendingPathComponent("ax-\(FileName.safe(label)).txt"), atomically: true, encoding: .utf8)
    }

    /// Waits for the UI to settle (`Settle`): window frames and accessibility tree text read the same twice in a row (animations and refreshes have paused), up to settleTimeout.
    func settle() {
        guard let p = app, p.isRunning else { return }
        Settle.wait(timeout: settleTimeout, interval: 0.12) { self.settleSnapshot(pid: p.pid) }
    }

    func settleSnapshot(pid: pid_t) -> Settle.Snapshot {
        var out: [String] = []
        for w in axApp?.windows ?? [] {
            w.walk { n, _, _ in
                out.append((n.role ?? "") + "|" + n.allStrings.joined(separator: "|") + "|" + (n.frame.map(Settle.rect) ?? ""))
                return true
            }
        }
        return Settle.Snapshot(windows: WindowList.onScreen(pid: pid).map { ($0.id, $0.frame) }, elements: out)
    }

    // MARK: - Waivers and known failures

    /// Waives one generic check for the next step; requires a reason (recorded in results.json).
    public func waive(_ check: Check, reason: String) {
        pendingWaivers[check] = reason
    }

    /// Waives a check for every step in a block.
    public func waive(_ check: Check, reason: String, _ body: () throws -> Void) rethrows {
        let before = scopedWaivers
        scopedWaivers[check] = reason
        defer { scopedWaivers = before }
        try body()
    }

    /// Known issue: a failure in the block is recorded as a known failure and does not block what follows; if the block does not fail it is recorded as "may be fixed".
    public func expectFailure(_ issue: String, _ body: () throws -> Void) {
        let before = expectingIssue
        expectingIssue = issue
        defer { expectingIssue = before }
        do {
            try body()
            unexpectedPasses.append(issue)
            log("  ? \(issue) did not fail this time, may be fixed")
        } catch let skip as E2ESkip {
            // A skip is not a known failure: record it and mark the scenario as skipped (expectFailure does not throw, so it cannot propagate)
            skipped = skipped ?? skip
        } catch let f as E2EFailure {
            knownFailures.append(.init(issue: issue, step: f.step ?? currentStep, reason: f.description))
            log("  ~ Known failure \(issue): \(f)")
        } catch {
            knownFailures.append(.init(issue: issue, step: currentStep, reason: "\(error)"))
            log("  ~ Known failure \(issue): \(error)")
        }
    }

    /// Assertion; not a step.
    public func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                       file: StaticString = #fileID, line: UInt = #line) throws {
        if try condition() {
            log("  expect ✓ \(message())")
        } else {
            let m = message()
            log("  expect ✗ \(m) (\(file):\(line))")
            throw E2EFailure("Assertion failed: \(m.isEmpty ? "\(file):\(line)" : m)", step: currentStep)
        }
    }

    func recordFailure(_ f: E2EFailure) {
        if f.check == .processAlive || !(app?.isRunning ?? true) {
            crashReportPath = crashReportPath ?? app?.crashReport()?.path
        }
    }
}

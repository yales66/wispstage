import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WispstageClient

extension E2ETest {
    // MARK: - Start and stop

    /// Launches the app under test: first calls the `willLaunch` hook (outside the step; throwing prevents the launch), then starts the process and waits for readiness in a step named `stepName`.
    public func launch(_ spec: LaunchSpec, step stepName: String) throws {
        do { try configuration.hooks.willLaunch(spec, test: self) } catch let f as E2EFailure {
            log("  ✗ \(f.reason)")
            throw E2EFailure(f.reason, step: "launch")
        }
        guard FileManager.default.isExecutableFile(atPath: spec.executable.path) else {
            throw E2EFailure("App under test not found at \(spec.executable.path)" + (spec.missingHint.map { "; \($0)" } ?? ""), step: "launch")
        }
        try step(stepName) { try startApp(spec) }
    }

    /// Relaunches: quits normally with the previous launch values (`LaunchSpec.quit`), then launches again; `adjust` changes the values for this launch (called outside the step; throwing prevents the relaunch).
    public func relaunch(step stepName: String = "relaunch", adjusting adjust: (inout LaunchSpec) throws -> Void) throws {
        guard var spec = launchSpec else { throw E2EFailure("Call launch before relaunch") }
        try adjust(&spec)
        try step(stepName) {
            stopApp(gracefully: true)
            try startApp(spec)
        }
    }

    /// Registers the kinds of window numbers (for example, window numbers printed by a preview entry point); merged with those the classifier recognizes from events, with events taking precedence.
    public func registerWindows(_ windows: [Int: WindowKind]) {
        registeredWindows.merge(windows) { _, b in b }
    }

    /// Starts the process and waits for readiness (not a step; `launch` and `relaunch` wrap it in one; adopters call it directly to do more in the same step).
    public func startApp(_ spec: LaunchSpec) throws {
        if let v = spec.variant { variant = v }
        language = spec.language ?? E2ETest.defaultLanguage(preferred: Locale.preferredLanguages)
        var env = ProcessInfo.processInfo.environment
        // The stage (the Wispstage stage library): background mode enables its background mode, where windows are hidden beneath the wallpaper, do not become key, do not activate, and key presses are routed to the keyboard target;
        // foreground mode enables observe-only mode, where the app really comes to the front, windows really become key and beeps sound, and the stage only reports events (the beep check uses them; key and activation are logged).
        // Stage events arrive over the socket at WISPSTAGE_STAGE_SOCKET.
        stageSocketCount += 1
        let stageSocket = StageSocketPath.make(executable: spec.executable, tag: "\(getpid())-\(stageSocketCount)")
        env["WISPSTAGE_STAGE"] = runMode.stageEnvironmentValue
        env["WISPSTAGE_STAGE_SOCKET"] = stageSocket
        for (k, v) in spec.environment { env[k] = v }
        hiddenRun = runMode.usesStage
        keyFocusSeen = 0
        beepSeen = 0
        let p = try AppProcess(executable: spec.executable, arguments: spec.arguments, environment: env,
                               eventsLog: dir.appendingPathComponent("events.jsonl"),
                               stderrLog: dir.appendingPathComponent("app-stderr.log"),
                               outputProtocol: configuration.outputProtocol)
        app = p
        axApp = AXNode.application(pid: p.pid)
        launchSpec = spec
        eventCursor = 0
        registeredWindows = [:]
        log("pid \(p.pid) \(spec.executable.path)")
        let ok = Wait.until(timeout: spec.readyTimeout) {
            !p.isRunning || spec.ready.satisfied(lines: p.lines, hasWindow: { !(self.axApp?.windows.isEmpty ?? true) })
        }
        guard p.isRunning else { throw E2EFailure("App exited after launch (exit code \(p.process.terminationStatus))", check: .processAlive) }
        guard ok else { throw E2EFailure("App not ready after \(spec.readyTimeout)s") }
        do { try p.connectStage(path: stageSocket) } catch {
            guard !runMode.requiresStage else {
                throw E2EFailure(Self.stageMissingMessage(error))
            }
            log("  App under test does not link the stage library (\(error)); foreground mode runs anyway, beeps have no source and are not checked")
        }
        // After readiness, windows must be readable through Accessibility.
        _ = Wait.until { !(axApp?.windows.isEmpty ?? true) }
        if spec.checksVisibility, hiddenRun { try VisibilityGate.verify(pid: p.pid, log: log) }
        if inputMode == .hid { activate() }
    }

    /// Failure text when a background run cannot reach the stage library in the app under test.
    static func stageMissingMessage(_ error: Error) -> String {
        "Cannot connect to the stage in the app under test (\(error)): this run is in background mode and the app under test does not link the stage library; "
            + "run it as it is with --mode foreground (takes over the screen, keyboard and cursor), "
            + "or add a test host that calls Wispstage.install() before run (adoption level 2)"
    }

    func stopApp(gracefully: Bool) {
        guard let p = app else { return }
        p.stop(gracefully: gracefully, quit: launchSpec?.quit ?? .terminate)
        log("App ended (exit code \(p.process.terminationStatus))")
        configuration.hooks.didStop(p, spec: launchSpec, test: self)
    }

    func teardown() {
        stopApp(gracefully: true)
        try? logHandle?.synchronize()
    }

    /// Brings the app under test to the front (before synthesizing keyboard and mouse events in hid mode).
    /// Asks the system to activate it first, then sets AXFrontmost through Accessibility if that fails; logs a line if it cannot become frontmost (synthesized events may land in another app).
    /// Does nothing in inprocess mode (which promises not to change the user's frontmost app) and returns false.
    @discardableResult
    public func activate() -> Bool {
        guard inputMode == .hid else { return false }
        guard let p = app, let ax = axApp else { return false }
        if frontmostPID() == p.pid { return true }
        NSRunningApplication(processIdentifier: p.pid)?.activate()
        if Wait.until(timeout: 2, { self.frontmostPID() == p.pid }) { return true }
        AXUIElementSetAttributeValue(ax.ref, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        ax.windows.first.map { _ = try? $0.perform(kAXRaiseAction) }
        if Wait.until(timeout: 3, { self.frontmostPID() == p.pid }) { return true }
        log("  App under test cannot become frontmost (frontmost pid \(frontmostPID().map(String.init) ?? "?"))")
        return false
    }

    func frontmostPID() -> pid_t? {
        let sys = AXUIElementCreateSystemWide()
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute as CFString, &v) == .success, let el = v else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(el as! AXUIElement, &pid)
        return pid
    }

    /// The app's process and accessibility root while it is running; fails if it has not launched or has exited.
    public func requireApp() throws -> (AppProcess, AXNode) {
        guard let p = app, let ax = axApp else { throw E2EFailure("App not launched yet, call launch first") }
        guard p.isRunning else { throw E2EFailure("App has exited", check: .processAlive) }
        return (p, ax)
    }
}

import AppKit
import CoreGraphics
import Foundation
import WispstageClient

/// How the driver delivers keyboard and mouse input, set by the run mode (`RunMode.inputMode`: background is inprocess, foreground is hid);
/// it is not specified separately from the run mode:
/// - `inprocess` (default): buttons are pressed with AXPress through Accessibility, the main menu through the app's AXMenuBar, and keys and typing go to the process under test
///   through `postToPid` after focus is set through Accessibility (see ExternalInput.swift); drag, hover, scroll wheel and clicks at a point have no external channel, so the stage's
///   `pointer` command synthesizes NSEvents inside the process under test (`PointerTarget`). The system cursor does not move, no global keyboard events are posted, and the app under test does not come to the front.
///   Global shortcuts (which only respond to system keyboard events) cannot be tested; steps that use them report "step needs foreground mode" and are skipped (`requireForeground`).
/// - `hid`: CGEvents posted to the system HID layer, with the app under test brought to the front first; global shortcuts are received too.
public enum InputMode: String, Sendable {
    case inprocess, hid

    public static func parse(_ raw: String?) throws -> InputMode {
        guard let raw, !raw.isEmpty else { return .inprocess }
        guard let m = InputMode(rawValue: raw) else { throw E2EFailure("Input mode must be inprocess or hid: \(raw)") }
        return m
    }

    /// The input mode of this run, following `RunMode.current`.
    public static var current: InputMode { RunMode.current.inputMode }
}

/// Where mouse gestures go in inprocess mode: the stage's `pointer` command (the Wispstage stage library, synthesizing inside the process under test).
/// Coordinates are measured from the top-left corner of the window's content area; the driver assumes the window under test uses fullSizeContentView or is borderless, so the content area is the whole window,
/// and the driver computes "global point minus the window's top-left corner".
public enum PointerTarget {
    /// Which window the point falls in (in stacking order, frontmost first), and the point measured from that window's top-left corner.
    public static func window(containing p: CGPoint, in windows: [(id: Int, frame: CGRect)]) -> (id: Int, local: CGPoint)? {
        guard let w = windows.first(where: { $0.frame.contains(p) }) else { return nil }
        return (w.id, CGPoint(x: p.x - w.frame.minX, y: p.y - w.frame.minY))
    }

    static func modifiers(_ m: Mods) -> [StagePointer.Modifier] {
        [(Mods.command, StagePointer.Modifier.cmd), (.shift, .shift), (.option, .opt), (.control, .ctrl)]
            .filter { m.contains($0.0) }.map(\.1)
    }
}

/// When Accessibility cannot read the focused text field before typing and the window has more than one, identifies it by the keyboard target's first responder reported by the stage's `status`
/// (after a text field in a panel is clicked, Accessibility still reports AXFocused false; measured 2026-10-14 on a panel in an app under test).
enum ResponderMatch {
    /// The one with the same identifier; without an identifier, the smallest whose frame contains the center of the first responder's frame. nil if none matches.
    static func pick(_ fields: [(id: String?, frame: CGRect?)], responder r: StageStatus.Responder) -> Int? {
        if let id = r.id {
            let same = fields.indices.filter { fields[$0].id == id }
            if same.count == 1 { return same[0] }
        }
        guard let f = r.frame else { return nil }
        let center = CGPoint(x: f.midX, y: f.midY)
        return fields.indices
            .compactMap { i in fields[i].frame.flatMap { $0.contains(center) ? (i, $0.width * $0.height) : nil } }
            .min { $0.1 < $1.1 }?.0
    }
}

/// The inprocess promise: running a scenario does not move the user's system cursor. Compared once before and once after the scenario.
/// The frontmost app is checked per step by `ForegroundWatch` instead (counting only changes to the app under test); comparing it before and after the scenario would also count the user switching apps.
/// A cursor move during which the user moved the pointer is not judged (`userMovedPointer`); `WISPSTAGE_CHECK_UNTOUCHED=0` turns the check off entirely.
public enum Untouched {
    public struct Snapshot: Equatable {
        public var cursor: CGPoint
        public var frontmostPID: pid_t?
        public var frontmostName: String?

        public init(cursor: CGPoint, frontmostPID: pid_t?, frontmostName: String?) {
            self.cursor = cursor
            self.frontmostPID = frontmostPID
            self.frontmostName = frontmostName
        }

        /// The system cursor (`CGEvent(source: nil).location`, global, origin at top left) and the frontmost app.
        public static func now() -> Snapshot {
            let front = NSWorkspace.shared.frontmostApplication
            return Snapshot(cursor: CGEvent(source: nil)?.location ?? .zero, frontmostPID: front?.processIdentifier,
                            frontmostName: front?.localizedName)
        }
    }

    /// Waits until the frontmost app stays the same for 1 second (at most 5 seconds).
    public static func waitUntilFrontmostSettles() {
        var last = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var since = Date()
        Wait.until(timeout: 5, interval: 0.1) {
            let now = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if now != last { last = now; since = Date() }
            return now != nil && Date().timeIntervalSince(since) >= 1
        }
    }

    public static var enabled: Bool { ProcessInfo.processInfo.environment["WISPSTAGE_CHECK_UNTOUCHED"] != "0" }

    /// Whether real pointer input (mouse or trackpad) happened during a scenario that has run for `scenarioSeconds`.
    public static func userMovedPointer(secondsSinceLastMove: TimeInterval, scenarioSeconds: TimeInterval) -> Bool {
        secondsSinceLastMove < scenarioSeconds
    }

    /// Seconds since the last pointer move or drag from an input device, read from the HID system state. Background-mode input never goes
    /// through the HID system (keys go to the app's process, pointer events are synthesized inside it), so these moves come from the user.
    public static func secondsSinceUserPointerInput() -> TimeInterval {
        [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? .infinity
    }

    /// A cursor move while the user was moving the pointer is the user's own and not judged.
    public static func problems(before: Snapshot, after: Snapshot, appPID: pid_t?, userMovedPointer: Bool = false) -> [String] {
        var out: [String] = []
        if !userMovedPointer, hypot(after.cursor.x - before.cursor.x, after.cursor.y - before.cursor.y) > 0.5 {
            out.append("the system cursor moved from (\(Int(before.cursor.x)),\(Int(before.cursor.y))) to (\(Int(after.cursor.x)),\(Int(after.cursor.y)))")
        }
        return out
    }
}

/// A step in a scenario needs foreground mode (such as a global shortcut): thrown in background mode, and the scenario is recorded as skipped, not failed; also used when the screen is locked.
public struct E2ESkip: Error, CustomStringConvertible {
    public var reason: String
    public var step: String?
    /// Skipped at a step needing foreground mode in background mode (`E2ETest.requireForeground`); false for lock-screen skips.
    public var foregroundOnly = false
    /// In foreground mode the cursor moved again during this step's retry: recorded as "interrupted by user input", neither failed nor passed, and later steps do not run.
    public var interrupted = false
    public init(_ reason: String, step: String? = nil) {
        self.reason = reason
        self.step = step
    }
    public var description: String { reason }
}

// MARK: - Run mode

/// The driver's run mode, chosen by the user for each run; background when unspecified (background does not take over the user's screen, keyboard and cursor, so it is the default; the user picks foreground to test what inactive windows cannot show).
/// - `background`: enables the stage library (windows beneath the wallpaper, key and activation intercepted), input is delivered from outside (`InputMode.inprocess`), and the user keeps using the computer;
///   steps in a scenario that need foreground mode (`E2ETest.requireForeground`) are skipped, and summary.txt lists which.
/// - `foreground`: no stage library; the app really comes to the front, windows really become key, and input uses real mouse and keyboard events (`InputMode.hid`);
///   everything inactive windows cannot show (active versus inactive appearance such as focus rings and active colors, really becoming key, global shortcuts) can be tested. Before running it counts down and shows how long it will take over the screen; if someone else moves the cursor during the run, that step pauses and is retried.
///
/// Resolution order: `run --mode`, then the environment variable `WISPSTAGE_MODE`, then background. An adopter's own older environment variable name is translated to
/// `WISPSTAGE_MODE` by the adopter's entry point before calling this.
public enum RunMode: String, Sendable {
    case foreground, background

    public static let environmentKey = "WISPSTAGE_MODE"

    public var inputMode: InputMode { self == .foreground ? .hid : .inprocess }
    /// Whether the stage library's background mode is enabled (WISPSTAGE_STAGE=1); foreground mode enables observe-only mode (`stageEnvironmentValue`).
    public var usesStage: Bool { self == .background }

    public static func resolve(cli: String?, environment: [String: String]) throws -> RunMode {
        if let cli { return try parse(cli, source: "--mode") }
        if let env = environment[environmentKey], !env.isEmpty { return try parse(env, source: environmentKey) }
        return .background
    }

    private static func parse(_ raw: String, source: String) throws -> RunMode {
        guard let m = RunMode(rawValue: raw) else { throw E2EFailure("\(source) must be foreground or background: \(raw)") }
        return m
    }

    /// Takes `--mode X` or `--mode=X` out of the `run` arguments and leaves the rest as is.
    public static func extract(from args: [String]) throws -> (raw: String?, rest: [String]) {
        var raw: String?
        var rest: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--mode" {
                guard i + 1 < args.count else { throw E2EFailure("--mode must be followed by foreground or background") }
                raw = args[i + 1]
                i += 2
                continue
            }
            if a.hasPrefix("--mode=") { raw = String(a.dropFirst("--mode=".count)) } else { rest.append(a) }
            i += 1
        }
        return (raw, rest)
    }

    /// The mode of this run: set from the command line when `Runner.run` starts; otherwise from the environment variable, with an invalid value falling back to background (`Preflight` reports it).
    nonisolated(unsafe) public static var current: RunMode =
        (try? resolve(cli: nil, environment: ProcessInfo.processInfo.environment)) ?? .background
}

// MARK: - Foreground mode: the cursor moved by someone else

/// In foreground mode the user's cursor is the same one the driver's real mouse events move: between steps and after each step, the driver checks whether the cursor is where it thinks it is;
/// if not, someone else (the user) moved it, and the step pauses, waits for the cursor to be still, and retries, so the user's actions are not counted as part of the test.
/// Where the driver thinks it is: the last recorded position; if the driver has posted mouse events since then (`Input.mouseMoves` changed), the last position the driver posted.
public struct CursorWatch {
    /// How long the cursor must be still to count as the user having stopped. A fixed value, not yet measured.
    public static let stillSeconds: TimeInterval = 2
    /// Same tolerance as `Untouched`: coordinates are floating point, so a move within 0.5 points counts as not moving.
    static let tolerance: CGFloat = 0.5

    private var anchor: CGPoint?
    private var moves = 0

    public init() {}

    mutating func anchor(at p: CGPoint, driverMoves: Int) {
        anchor = p
        moves = driverMoves
    }

    func expected(driverMoves: Int, driverLast: CGPoint?) -> CGPoint? {
        driverMoves != moves ? (driverLast ?? anchor) : anchor
    }

    func movedByOthers(now: CGPoint, driverMoves: Int, driverLast: CGPoint?) -> Bool {
        guard let e = expected(driverMoves: driverMoves, driverLast: driverLast) else { return false }
        return hypot(now.x - e.x, now.y - e.y) > Self.tolerance
    }

    /// Samples the cursor every `interval` until it has not moved for `stillFor` seconds in a row; returns the value of `now()` when done.
    @discardableResult
    static func waitUntilStill(stillFor: TimeInterval, interval: TimeInterval, sample: () -> CGPoint, now: () -> TimeInterval,
                               sleep: (TimeInterval) -> Void) -> TimeInterval {
        var last = sample()
        var since = now()
        while now() - since < stillFor {
            sleep(interval)
            let p = sample()
            if hypot(p.x - last.x, p.y - last.y) > tolerance {
                last = p
                since = now()
            }
        }
        return now()
    }

    /// The current system cursor (global, origin at top left).
    static func cursorNow() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
}

/// The notice before a foreground run: the screen, keyboard and cursor will be in use for about N minutes, with a 5-second countdown.
public enum ForegroundNotice {
    public static let countdownSeconds = 5

    /// N is the sum of each scenario's historical mean duration (rounded up to minutes); scenarios without history are filled in with the mean of those that have it, and when none have history it says unknown.
    static func occupyLine(names: [String], history: [String: [Double]]) -> String {
        let means = names.compactMap { n in history[n].flatMap { $0.isEmpty ? nil : $0.reduce(0, +) / Double($0.count) } }
        guard !means.isEmpty else { return "The screen, keyboard and cursor will be in use for an unknown time (no duration history for these scenarios)" }
        let fill = means.reduce(0, +) / Double(means.count)
        let total = means.reduce(0, +) + fill * Double(names.count - means.count)
        return "The screen, keyboard and cursor will be in use for about \(max(1, Int((total / 60).rounded(.up)))) min"
    }

    /// Duration history: each scenario's durationSec in earlier runs' results.json (skipped and interrupted ones excluded, since their duration does not reflect a full run).
    static func history(runsDir: URL) -> [String: [Double]] {
        struct Run: Decodable { struct S: Decodable { var name: String; var status: String; var durationSec: Double }; var scenarios: [S] }
        var out: [String: [Double]] = [:]
        let dirs = (try? FileManager.default.contentsOfDirectory(at: runsDir, includingPropertiesForKeys: nil)) ?? []
        for d in dirs {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("results.json")),
                  let run = try? JSONDecoder().decode(Run.self, from: data) else { continue }
            for s in run.scenarios where !["skipped", "interrupted"].contains(s.status) { out[s.name, default: []].append(s.durationSec) }
        }
        return out
    }

    /// Prints the notice and counts down, one line per second.
    static func countdown(names: [String], runsDir: URL) {
        print("Foreground mode: \(occupyLine(names: names, history: history(runsDir: runsDir))) (\(counted(names.count, "scenario"))). Press Ctrl-C to cancel.")
        for i in stride(from: countdownSeconds, to: 0, by: -1) {
            print("  \(i)…")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

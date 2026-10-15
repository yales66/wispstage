import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WispstageClient

/// The target of an action: by accessibility identifier (a string literal is an identifier), by text, by screen point, by point in a window, or an element already found.
public enum Target: ExpressibleByStringLiteral, CustomStringConvertible {
    case id(String)
    case label(String, role: AXRole?)
    /// Global coordinates, origin at top left.
    case point(CGPoint)
    /// A point in a window, measured from the window's top-left corner (matches that window's screenshot coordinates).
    case inWindow(WindowKind, CGPoint)
    case element(AXNode)
    /// Only for the end of a drag: how many points to move from the start.
    case offset(dx: CGFloat, dy: CGFloat)

    public init(stringLiteral value: String) { self = .id(value) }

    public static func point(_ x: CGFloat, _ y: CGFloat) -> Target { .point(CGPoint(x: x, y: y)) }
    public static func label(_ text: String) -> Target { .label(text, role: nil) }

    public var description: String {
        switch self {
        case .id(let s): return s
        case .label(let s, let r): return r.map { "\($0.raw):\(s)" } ?? s
        case .point(let p): return "(\(Int(p.x)),\(Int(p.y)))"
        case .inWindow(let k, let p): return "\(k.rawValue)(\(Int(p.x)),\(Int(p.y)))"
        case .element(let n): return n.identifier ?? n.spoken ?? n.role ?? "element"
        case .offset(let dx, let dy): return "+(\(Int(dx)),\(Int(dy)))"
        }
    }
}

/// The raw state the app returns over the command channel, with fields read by dot path. Adopters can decode it into their own types.
public struct AppState {
    public let raw: String
    public let json: JSONValue

    public init(raw: String) throws {
        self.raw = raw
        json = try JSONValue.parse(raw)
    }

    /// Reads a field by dot path: `s["selection.id"]`, `s["items.0.title"]`.
    public subscript(_ path: String) -> Any? { json[path] }
}

/// The `t` in a scenario: starts and stops the app under test, acts and observes, runs generic checks after each step, and writes output.
/// Each action (launch, press, click, type, key, drag, hover, scroll, send, shot…) is a step:
/// it is logged to steps.log, screenshotted as NN-<step name>.png and checked with the generic checks; queries (element, find, text, state, waitEvent) are not steps.
public final class E2ETest {
    public let name: String
    public let dir: URL
    /// The adopter's configuration (paths, protocol, window kinds, text check parameters, hooks).
    public let configuration: E2EConfiguration
    let placeholderPatterns: [NSRegularExpression]

    public internal(set) var app: AppProcess?
    var axApp: AXNode?
    /// The values used for the most recent launch.
    public internal(set) var launchSpec: LaunchSpec?
    /// The current UI language of the app under test: `LaunchSpec.language` when given, otherwise the system's preferred language (which the app follows).
    var language = E2ETest.defaultLanguage(preferred: Locale.preferredLanguages)

    /// The language the app under test uses when none is specified: the first of the system's preferred languages, English if there is none.
    static func defaultLanguage(preferred: [String]) -> String { preferred.first ?? "en" }
    /// Window numbers and kinds registered by the adopter (`registerWindows`); cleared on every launch.
    var registeredWindows: [Int: WindowKind] = [:]
    var eventCursor = 0
    /// Whether this launch enabled the stage's background mode (hidden windows, WISPSTAGE_STAGE=1), and how many stage events `KeyFocus` has seen.
    var hiddenRun = false
    var keyFocusSeen = 0
    /// How many stage events the beep check has seen, and when this step started (foreground monitoring cuts off at it).
    var beepSeen = 0
    var stageSocketCount = 0
    var stepStartedAt = Date()
    /// Whether the screen is locked; replaced in unit tests.
    var screenLocked: () -> Bool = { LockScreen.isLocked }
    /// The left button held down after `mouseDown`: window number (0 under hid), window top-left corner (global coordinates), the pointer's current global position.
    var heldMouse: (window: Int, origin: CGPoint, at: CGPoint)?
    var logHandle: FileHandle?

    /// How keyboard and mouse input is delivered, following the run mode (`RunMode.inputMode`); see `InputMode`.
    public let inputMode: InputMode
    /// Set when a step needed foreground mode and was skipped in background mode (`requireForeground`), or skipped because the screen was locked; the scenario is then recorded as skipped.
    public internal(set) var skipped: E2ESkip?

    public internal(set) var stepCount = 0
    public internal(set) var currentStep: String?
    /// Automatic screenshot after each action step; scenarios can turn it off and keep only shot() screenshots.
    public var autoShots = true
    /// Which steps keep a full-window screenshot (`run --shots=key|all|none`, default key); see `ShotsMode`. Every step also writes a text listing NN-<step name>.ax.txt.
    public let shotsMode: ShotsMode
    var capturedSteps: Set<String> = []
    /// Screenshots that go into baseline comparison (full window and `shot(id:)` crops), written to shots.json when the scenario ends.
    public internal(set) var shotRecords: [ShotRecord] = []
    /// The baseline group for the current launch (`LaunchSpec.variant`, such as `<language>-<appearance>-<hour cycle>`); "default" until a launch sets one.
    var variant = "default"
    var failedStep: String?
    /// Upper bound on waiting for the UI to settle after an action step (settled when the accessibility tree's text reads the same twice in a row).
    public var settleTimeout: TimeInterval = 2

    var knownFailures: [ScenarioResult.KnownFailure] = []
    var unexpectedPasses: [String] = []
    var waiverLog: [ScenarioResult.Waiver] = []
    var crops: [ScenarioResult.Crop] = []
    /// What the listed-for-review checks saw (missing identifiers, click areas, alignment), written to results.json and summary.txt.
    var notes: [ScenarioResult.Note] = []
    var noteKeys: Set<String> = []
    var crashReportPath: String?
    var pendingWaivers: [Check: String] = [:]
    var scopedWaivers: [Check: String] = [:]
    var expectingIssue: String?

    /// Run mode (`run --mode`, background by default); see `RunMode`.
    public let runMode: RunMode
    /// Foreground mode: whether the cursor is where the driver thinks it is (`CursorWatch`); how deeply `step` is nested (only the outermost step watches the cursor).
    var cursorWatch = CursorWatch()
    /// Reads the cursor and waits for it to stop moving; replaced in unit tests.
    var cursorNow: () -> CGPoint = CursorWatch.cursorNow
    var waitCursorStill: () -> Void = {
        CursorWatch.waitUntilStill(stillFor: CursorWatch.stillSeconds, interval: 0.1, sample: CursorWatch.cursorNow,
                                   now: { Date().timeIntervalSinceReferenceDate },
                                   sleep: { RunLoop.current.run(until: Date().addingTimeInterval($0)) })
    }
    var stepDepth = 0

    public init(name: String, dir: URL, configuration: E2EConfiguration = .standalone, runMode: RunMode = .current, shots: ShotsMode = .key) {
        self.name = name
        self.runMode = runMode
        self.inputMode = runMode.inputMode
        self.shotsMode = shots
        self.dir = dir
        self.configuration = configuration
        placeholderPatterns = configuration.textChecks.compiledPatterns
        let log = dir.appendingPathComponent("steps.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: log)
        ForegroundWatch.shared.start()
    }

    // MARK: - Log

    /// Writes one line to steps.log (also printed to the terminal).
    public func log(_ line: String) {
        let l = "\(Timestamp.log(Date())) \(line)\n"
        logHandle?.write(Data(l.utf8))
        print("  " + line)
        fflush(stdout)
    }

    /// The text field that could not take focus during the last typing, so the text went in through AXSetValue; cleared on the next typing.
    var valueOnlyField: AXNode?
}

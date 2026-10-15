import AppKit
import WispstageClient

/// The stage: while the app under test runs in a test, the user keeps using the computer. It does only these things, and emits an event for each:
/// 1. Windows go to the minimum window level, ignore the mouse and join all Spaces; the activation policy is `.accessory` (`StageWindows`).
/// 2. When a window asks to become key or the app asks to activate, the stage records the request instead: the window asking to become key
///    is recorded as the keyboard target `keyTarget` (`stage.keyRequested`), and activation emits `stage.activateRequested` (`StageWindows`, `StageActivation`).
/// 3. Keys posted from outside via postToPid are dispatched as if the keyboard target were the key window when there is no key window (`StageKeys`).
/// 4. Keys nobody handles make no sound; the stage emits `stage.beep` (`StageKeys`).
/// 5. The driver's `pointer` command synthesizes mouse gestures in this process and treats windows that are not key as past their first click (`StagePointerInput`).
/// 6. Global event monitors don't receive real user events; each drop emits `stage.globalEventDropped`, and the driver's `globalEvent` command hands
///    them synthesized events (`StageGlobalMonitors`). A mouse down that would make a window key through the click path is intercepted as in point 2 (`StageWindows`).
///
/// The above is background mode (`WISPSTAGE_STAGE=1`). Observe-only mode (`WISPSTAGE_STAGE=observe`, used by the driver's foreground mode) does none of it;
/// it only records windows becoming key, activation requests and actual activation, and beeps for unhandled keys, and lets them all happen (`StageObserve`).
///
/// The test host calls `install()` after `NSApplication` is created and before `run`; when `WISPSTAGE_STAGE` is neither value it does nothing.
/// Events go to the driver over the Unix domain socket given in `WISPSTAGE_STAGE_SOCKET`, one JSON object per line (`StageEvent`).
@MainActor
public enum Wispstage {
    /// Stage mode. `background`: background mode, does points 1–6 above; `observe`: observe-only mode, only records events and changes no AppKit behavior (`StageObserve`).
    public enum Mode: String, Sendable, Equatable {
        case background, observe

        /// Value of the `WISPSTAGE_STAGE` environment variable: `1` is background mode, `observe` is observe-only mode, any other value (or unset) is off.
        public init?(environmentValue: String?) {
            switch environmentValue {
            case "1": self = .background
            case "observe": self = .observe
            default: return nil
            }
        }
    }

    public struct Options: Sendable, Equatable {
        /// Which mode to install; nil means off.
        public var mode: Mode?
        /// Path of the event socket; when nil, events go only to `onEvent`.
        public var socketPath: String?

        public var enabled: Bool { mode != nil }

        public init(mode: Mode?, socketPath: String? = nil) {
            self.mode = mode
            self.socketPath = socketPath
        }

        /// `enabled` true means background mode.
        public init(enabled: Bool, socketPath: String? = nil) {
            self.init(mode: enabled ? .background : nil, socketPath: socketPath)
        }

        /// Mode from `WISPSTAGE_STAGE` (see `Mode.init(environmentValue:)`); socket path from `WISPSTAGE_STAGE_SOCKET` (an empty string counts as unset).
        public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            mode = Mode(environmentValue: environment["WISPSTAGE_STAGE"])
            socketPath = environment["WISPSTAGE_STAGE_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// Whether background mode is on. Once on it stays on (the exchanged methods apply to the whole process). False while observe-only mode is on.
    nonisolated(unsafe) public private(set) static var isActive = false
    /// The installed mode; nil when not installed. The two modes are mutually exclusive in one process: the first one installed stays.
    public private(set) static var mode: Mode?
    /// Minimum window level: beneath the wallpaper. `CGWindowLevelForKey(.desktopWindow) - 1` is still above the wallpaper and visible.
    public static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
    /// The window that receives keys in place of the key window: the window that most recently asked to become key. A test host synthesizing clicks may also set it (in real use, the window you click becomes key).
    public static weak var keyTarget: NSWindow?
    /// Also receives every event (for tests and the host's own logs).
    public static var onEvent: ((StageEvent) -> Void)?

    private static var server: StageServer?
    private static var pinTimer: Timer?

    /// Installs the stage according to the environment. Does nothing and returns false when not requested.
    /// The return value reports only whether background mode is on: installing observe-only mode also returns false, so the test host skips what it does
    /// alongside background mode (such as keeping AppKit from activating at a preview entry point) and the app behaves normally. The modes are mutually
    /// exclusive: with one installed, a request for the other is not installed and the current background-mode state is returned.
    @discardableResult
    public static func install(_ options: Options = Options()) -> Bool {
        guard let requested = options.mode else { return false }
        if let mode {
            if mode != requested { FileHandle.standardError.write(Data("Wispstage: \(mode.rawValue) already installed, not installing \(requested.rawValue)\n".utf8)) }
            return isActive
        }
        mode = requested
        if let path = options.socketPath {
            server = StageServer(path: path) { line, done in
                DispatchQueue.main.async { MainActor.assumeIsolated { handle(line, reply: done) } }
            }
            if server == nil { FileHandle.standardError.write(Data("Wispstage: cannot open socket \(path)\n".utf8)) }
        }
        if requested == .observe {
            StageObserve.install()
            return false
        }
        StageWindows.install()
        StageActivation.install()
        StageKeys.install()
        StageGlobalMonitors.install()
        isActive = true
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow else { return }
            let cls = NSStringFromClass(type(of: w))
            let number = w.windowNumber
            MainActor.assumeIsolated { emit(StageEvent.becameKey, ["window": number, "class": cls]) }
        }
        // Windows that come on screen without going through the exchanged ordering methods (if any) are pinned here
        let t = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { for w in NSApp.windows where w.isVisible { StageWindows.pin(w) } }
        }
        RunLoop.main.add(t, forMode: .common)
        pinTimer = t
        return true
    }

    /// The level the app asked for (the value before pinning). When the stage is off, the window's current level.
    public static func requestedLevel(of w: NSWindow) -> NSWindow.Level { StageWindows.requestedLevel(of: w) }

    static func emit(_ name: String, _ fields: [String: Any] = [:]) {
        emit(line: StageEvent.encode(name, fields))
    }

    static func emit(line: String) {
        server?.send(line)
        if let onEvent, let e = StageEvent(line: line) { onEvent(e) }
    }

    /// One command from the driver; calls `reply` when answered: `pointer` synthesizes its gesture in steps and answers when done; the rest answer at once (`reply(to:)`).
    static func handle(_ line: String, reply done: @escaping (String) -> Void) {
        if let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["cmd"] as? String == "pointer" {
            return StagePointerInput.handle(obj, reply: done)
        }
        done(reply(to: line))
    }

    /// Commands from the driver: `status` (also reports the keyboard target's first responder `firstResponder`: identifier, role, and frame in global top-left-origin coordinates); `globalEvent` (`type` is the event type name, `x` and `y` are screen coordinates with a top-left origin) replies with `delivered`.
    static func reply(to line: String) -> String {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["cmd"] as? String
        else { return #"{"ok":false,"error":"bad command"}"# }
        switch cmd {
        case "status":
            var fields: [String: Any] = ["ok": true, "keyTarget": keyTarget?.windowNumber ?? 0,
                                         "keyWindow": NSApp.keyWindow?.windowNumber ?? 0, "active": NSApp.isActive]
            if let r = StagePointerInput.firstResponder() { fields["firstResponder"] = StageStatus.responderFields(r) }
            return StageEvent.encodeReply(fields)
        case "globalEvent":
            guard let name = obj["type"] as? String, let type = StageGlobalMonitors.types[name] else {
                return #"{"ok":false,"error":"unknown event type"}"#
            }
            let x = (obj["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (obj["y"] as? NSNumber)?.doubleValue ?? 0
            let n = StageGlobalMonitors.deliver(type, at: CGPoint(x: x, y: y))
            return StageEvent.encodeReply(["ok": true, "delivered": n])
        default:
            return #"{"ok":false,"error":"unknown cmd"}"#
        }
    }
}

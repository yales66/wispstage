import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Input and observation the driver performs from outside the app under test: keys and typing go to the process under test through `postToPid`, focus is set through Accessibility,
// the main menu is pressed through the app's AXMenuBar, and hits are computed in the driver from accessibility tree frames. The app needs no test-only code,
// its windows need not become key and it need not come to the front (measured on macOS 27.2, 2026-10-14).

// MARK: - External geometric hit testing

/// Finds the deepest element containing a point in a window's accessibility tree (a preorder list) by frame; later siblings under the same parent count as on top.
///
/// Judged against real clicks, this rule agrees with where clicks land 100% of the time in overlapping areas, versus 65% to 72% for the in-app `accessibilityHitTest`
/// (measured 2026-10-14, macOS 27.2). Rough spots: for views using `.zIndex`, AX order does not follow drawing order; occluding layers absent from the AX tree are invisible;
/// overlay scroll bars cover about 19 points on the right of the content area. The first two are backstopped by the pixel check in `Occlusion`.
public struct GeometricHit {
    private let frames: [CGRect?]
    private let children: [[Int]]

    /// `depths[i]` is the number of ancestors of element i (0 for the root); the list is in preorder.
    public init(frames: [CGRect?], depths: [Int]) {
        self.frames = frames
        var kids = Array(repeating: [Int](), count: frames.count)
        var stack: [Int] = []
        for i in frames.indices {
            while stack.count > depths[i] { stack.removeLast() }
            if let parent = stack.last { kids[parent].append(i) }
            stack.append(i)
        }
        children = kids
    }

    /// Index of the deepest element containing the point; elements without a frame do not block and their children are searched. nil if the point is outside the root.
    public func hit(_ p: CGPoint) -> Int? {
        guard !frames.isEmpty else { return nil }
        func go(_ i: Int) -> Int? {
            if let f = frames[i], !f.contains(p) { return nil }
            for c in children[i].reversed() { if let h = go(c) { return h } }
            return frames[i] == nil ? nil : i
        }
        return go(0)
    }

    public static func deepest(at p: CGPoint, frames: [CGRect?], depths: [Int]) -> Int? {
        GeometricHit(frames: frames, depths: depths).hit(p)
    }
}

// MARK: - Beep prevention

/// Before sending a key, decides whether anything will receive it. A key nobody receives goes to `noResponderFor: keyDown:` in the app, and a real app plays the system beep (measured 2026-10-14, macOS 27.2).
/// The app's local event monitors (which handle keys such as Tab in a custom grid or ⌥Space in a shortcut recorder) are invisible in the accessibility tree, so when no receiver is visible the key is sent anyway and marked unverified;
/// the stage reports unreceived keys as `stage.beep` without a sound (the Wispstage stage library), and `Check.beep` judges them afterwards.
enum KeyGuard {
    enum Decision: Equatable { case send, unverified(String) }

    /// `focusedRole` is the role of the app-level AXFocusedUIElement of the app under test (nil if unreadable); `defaultButton` and `cancelButton`
    /// say whether the window under test has a default button and a cancel button (they receive Return and Esc without modifiers, even when the window is not key; measured 2026-10-14, macOS 27.2).
    static func decide(key: Key, modifiers: Mods, focusedRole: String?, defaultButton: Bool, cancelButton: Bool) -> Decision {
        if let r = focusedRole, r != kAXApplicationRole { return .send }
        if modifiers.isEmpty {
            let n = key.name.lowercased()
            if ["return", "enter"].contains(n), defaultButton { return .send }
            if ["esc", "escape"].contains(n), cancelButton { return .send }
        }
        return .unverified("No focused element in the app under test receives \(key), and it is not a default or cancel button shortcut; sending anyway for the app's local event monitors, the stage reports stage.beep if nothing receives it")
    }
}

// MARK: - Main menu

/// When the app is not frontmost, main menu shortcuts sent through `postToPid` have no effect and beep, so the matching menu item is pressed through the app's AXMenuBar instead (measured 2026-10-14, macOS 27.2).
enum MenuShortcut {
    /// `cmdModifiers` is AXMenuItemCmdModifiers: 0 is ⌘ only, bit 1 adds ⇧, bit 2 adds ⌥, bit 4 adds ⌃, bit 8 removes ⌘.
    static func matches(cmdChar: String, cmdModifiers: Int, key: Key, modifiers: Mods) -> Bool {
        var want: Mods = cmdModifiers & 8 == 0 ? [.command] : []
        if cmdModifiers & 1 != 0 { want.insert(.shift) }
        if cmdModifiers & 2 != 0 { want.insert(.option) }
        if cmdModifiers & 4 != 0 { want.insert(.control) }
        return want == modifiers && !cmdChar.isEmpty && cmdChar.lowercased() == key.name.lowercased()
    }

    /// The enabled menu item in the app's main menu with the same shortcut.
    static func find(in app: AXNode, key: Key, modifiers: Mods) -> AXNode? {
        guard let bar = app.attr(kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var found: AXNode?
        AXNode(bar as! AXUIElement).walk(limit: 3000) { n, _, _ in
            guard found == nil else { return false }
            if n.role == kAXMenuItemRole, let ch = n.string(kAXMenuItemCmdCharAttribute),
               let m = (n.attr(kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue,
               matches(cmdChar: ch, cmdModifiers: m, key: key, modifiers: modifiers), n.isEnabled {
                found = n
            }
            return true
        }
        return found
    }
}

// MARK: - Lock screen

/// The accessibility tree cannot be read while the screen is locked (`AXWindows` returns endlessly nested AXApplication, measured 2026-10-14, macOS 27.2), so results from that time are discarded.
public enum LockScreen {
    /// Exit code of the whole run when the screen is already locked before it starts: EX_TEMPFAIL from sysexits.h (temporary failure, retry later), distinct from passed 0, failed 1 and usage error 2.
    public static let exitCode: Int32 = 75

    static func isLocked(session: [String: Any]?) -> Bool {
        (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Whether the screen is locked right now (CGSSessionScreenIsLocked from `CGSessionCopyCurrentDictionary`).
    public static var isLocked: Bool { isLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any]) }
}

// MARK: - Frontmost monitoring

/// Subscribes to frontmost-app change notifications when the run starts and judges per step: a step during which the app under test became frontmost fails (`Check.foreground`).
/// The user switching between other apps does not count; the app under test calling `NSApp.activate` itself cannot be blocked from outside, only reported (measured 2026-10-14, macOS 27.2).
final class ForegroundWatch {
    struct Activation {
        var at: Date
        var pid: pid_t
        var name: String?
    }

    static let shared = ForegroundWatch()
    private(set) var activations: [Activation] = []
    private var token: NSObjectProtocol?

    func start() {
        guard token == nil else { return }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.activations.append(Activation(at: Date(), pid: app.processIdentifier, name: app.localizedName))
        }
    }

    /// One sentence for each time the app under test became frontmost between `from` and `to`.
    static func violations(_ acts: [Activation], appPID: pid_t, from: Date, to: Date) -> [String] {
        acts.filter { $0.pid == appPID && $0.at >= from && $0.at <= to }.map {
            "The app under test \($0.name ?? "?") (pid \($0.pid)) became frontmost, so the user's keyboard input will go into its windows"
        }
    }
}

// MARK: - postToPid keyboard

/// Key name to key code and characters (named keys or a single letter, digit or symbol, using the US layout): the characters are sent with the event,
/// independent of the user's current keyboard layout and input method.
enum PidKeys {
    private static func fn(_ scalar: Int) -> String { String(Character(UnicodeScalar(scalar)!)) }

    private static let named: [String: (CGKeyCode, String)] = [
        "return": (36, "\r"), "enter": (36, "\r"), "tab": (48, "\t"), "space": (49, " "),
        "delete": (51, "\u{7f}"), "backspace": (51, "\u{7f}"), "esc": (53, "\u{1b}"), "escape": (53, "\u{1b}"),
        "forwarddelete": (117, fn(0xF728)), "home": (115, fn(0xF729)), "end": (119, fn(0xF72B)),
        "pageup": (116, fn(0xF72C)), "pagedown": (121, fn(0xF72D)),
        "left": (123, fn(0xF702)), "right": (124, fn(0xF703)), "down": (125, fn(0xF701)), "up": (126, fn(0xF700)),
        "f1": (122, fn(0xF704)), "f2": (120, fn(0xF705)), "f3": (99, fn(0xF706)), "f4": (118, fn(0xF707)),
        "f5": (96, fn(0xF708)), "f6": (97, fn(0xF709)), "f7": (98, fn(0xF70A)), "f8": (100, fn(0xF70B)),
        "f9": (101, fn(0xF70C)), "f10": (109, fn(0xF70D)), "f11": (103, fn(0xF70E)), "f12": (111, fn(0xF70F)),
    ]
    private static let ansi: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50,
    ]

    struct Stroke: Equatable {
        var code: CGKeyCode
        var characters: String
        /// Arrow and function keys carry the fn flag on a real keyboard (arrow keys also carry the numeric pad flag).
        var function: Bool
        var arrow: Bool
    }

    static func stroke(_ key: Key, modifiers: Mods) -> Stroke? {
        let lower = key.name.lowercased()
        if let (code, ch) = named[lower] {
            let scalar = ch.unicodeScalars.first!.value
            let isFn = scalar >= 0xF700 && scalar <= 0xF8FF
            return Stroke(code: code, characters: ch, function: isFn, arrow: (123...126).contains(code))
        }
        guard lower.count == 1, let ch = lower.first, let code = ansi[ch] else { return nil }
        let plain = String(ch)
        return Stroke(code: code, characters: modifiers.contains(.shift) ? plain.uppercased() : plain, function: false, arrow: false)
    }

    /// Which key code to use for a typed character: the US layout's code when it has one, the matching key for Return and Tab, and 0 for anything else (such as Chinese), with the character sent along with the event.
    static func code(for ch: Character) -> CGKeyCode {
        if ch == "\n" || ch == "\r" { return 36 }
        if ch == "\t" { return 48 }
        if ch == " " { return 49 }
        if let lower = ch.lowercased().first, ch.lowercased().count == 1, let c = ansi[lower] { return c }
        return 0
    }
}

/// Delivers keyboard events straight to the process under test through `CGEvent.postToPid`: they bypass the system HID layer, do not reach the user's frontmost app, do not move the cursor,
/// and arrive even when the window is not key (measured 2026-10-14, macOS 27.2).
enum PidInput {
    private static var source: CGEventSource? { CGEventSource(stateID: .privateState) }

    private static func pause(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private static func post(_ pid: pid_t, code: CGKeyCode, characters: String, flags: CGEventFlags) {
        let units = Array(characters.utf16)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            units.withUnsafeBufferPointer { buf in e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress) }
            e.postToPid(pid)
            pause(0.01)
        }
    }

    static func key(pid: pid_t, _ s: PidKeys.Stroke, modifiers: Mods) {
        var flags = modifiers.flags
        if s.function { flags.insert(.maskSecondaryFn) }
        if s.arrow { flags.insert(.maskNumericPad) }
        post(pid, code: s.code, characters: s.characters, flags: flags)
    }

    /// Sends character by character, with the characters attached to the event (`keyboardSetUnicodeString`), inserted as committed text without input method composition.
    static func type(pid: pid_t, _ text: String) {
        for ch in text {
            let code = PidKeys.code(for: ch)
            let chars = code == 36 ? "\r" : String(ch)
            post(pid, code: code, characters: chars, flags: [])
        }
    }
}

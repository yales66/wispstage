import CoreGraphics
import Foundation

/// A key: a named key ("return" "tab" "esc" "space" "delete" "left" "right" "up" "down" "home" "end"
/// "pageup" "pagedown" "f1"…"f12") or a single letter, digit or symbol (using the US layout).
public struct Key: ExpressibleByStringLiteral, CustomStringConvertible, Sendable {
    public let name: String
    public init(stringLiteral value: String) { name = value }
    public init(_ name: String) { self.name = name }
    public var description: String { name }

    public static let `return`: Key = "return", tab: Key = "tab", esc: Key = "esc", space: Key = "space",
        delete: Key = "delete", left: Key = "left", right: Key = "right", up: Key = "up", down: Key = "down"

    private static let named: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "esc": 53, "escape": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
    private static let ansi: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50,
    ]

    /// Looks up the key name from a key code (saved shortcuts store only the key code); aliases are not returned (36 is return, not enter). nil for an unknown key code.
    public init?(code: CGKeyCode) {
        let aliases: Set<String> = ["enter", "backspace", "escape"]
        if let n = Key.named.first(where: { $0.value == code && !aliases.contains($0.key) })?.key {
            name = n
        } else if let ch = Key.ansi.first(where: { $0.value == code })?.key {
            name = String(ch)
        } else {
            return nil
        }
    }

    public var keyCode: CGKeyCode? {
        let lower = name.lowercased()
        if let c = Key.named[lower] { return c }
        if lower.count == 1, let ch = lower.first { return Key.ansi[ch] }
        return nil
    }
}

/// Modifier keys.
public struct Mods: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Mods(rawValue: 1), shift = Mods(rawValue: 2), option = Mods(rawValue: 4), control = Mods(rawValue: 8)

    var flags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.command) { f.insert(.maskCommand) }
        if contains(.shift) { f.insert(.maskShift) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.control) { f.insert(.maskControl) }
        return f
    }
}

/// Synthesizes keyboard and mouse events posted to the HID layer (global shortcuts receive them too). Coordinates are global, origin at top left.
public enum Input {
    private static var source: CGEventSource? { CGEventSource(stateID: .hidSystemState) }
    /// SwiftUI drag gestures only recognize a drag in multiple steps about a frame apart (about 16 milliseconds).
    public static let dragStepInterval: TimeInterval = 0.016

    /// How many positioned mouse events the driver has posted and where the last one landed: foreground mode uses this to tell whether the driver or someone else moved the cursor (`CursorWatch`).
    nonisolated(unsafe) public private(set) static var mouseMoves = 0
    nonisolated(unsafe) public private(set) static var lastMouse: CGPoint?
    private static let positioned: Set<CGEventType> = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp]

    private static func post(_ e: CGEvent?) {
        guard let e else { return }
        if positioned.contains(e.type) {
            mouseMoves += 1
            lastMouse = e.location
        }
        e.post(tap: .cghidEventTap)
    }

    private static func pause(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    public static func move(to p: CGPoint) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
        pause(dragStepInterval)
    }

    public static func click(at p: CGPoint, count: Int = 1, right: Bool = false, mods: Mods = []) {
        move(to: p)
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = right
            ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        for i in 1...max(count, 1) {
            for type in [down, up] {
                let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                e?.flags = mods.flags
                post(e)
                pause(0.02)
            }
        }
    }

    public static func drag(from a: CGPoint, to b: CGPoint, steps: Int = 20, holdBefore: TimeInterval = 0.1) {
        move(to: a)
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left))
        pause(holdBefore)
        let n = max(steps, 2)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
            pause(dragStepInterval)
        }
        pause(0.05)
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left))
        pause(0.02)
    }

    /// A press-and-hold drag in three parts: move to `p` and press the left button.
    public static func press(at p: CGPoint) {
        move(to: p)
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
        pause(0.1)
    }

    /// Moves from `a` to `b` with the left button held, in `steps` steps.
    public static func dragMove(from a: CGPoint, to b: CGPoint, steps: Int) {
        let n = max(steps, 1)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
            pause(dragStepInterval)
        }
        pause(0.1)
    }

    /// Releases the left button at `p`.
    public static func release(at p: CGPoint) {
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
        pause(0.05)
    }

    /// Moves to a point and nudges twice nearby so hover tracking areas receive an enter event.
    public static func hover(at p: CGPoint) {
        move(to: CGPoint(x: p.x - 3, y: p.y - 3))
        move(to: CGPoint(x: p.x - 1, y: p.y - 1))
        move(to: p)
    }

    /// Scrolling: positive dy scrolls up (content moves down), in pixels.
    public static func scroll(at p: CGPoint, dx: Int32 = 0, dy: Int32) {
        move(to: p)
        post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
        pause(0.02)
    }

    public static func key(code: CGKeyCode, mods: Mods = []) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = mods.flags
            post(e)
            pause(0.01)
        }
    }

    /// Sends Unicode characters one by one, independent of the current input method and layout.
    public static func type(_ text: String) {
        for ch in text {
            let units = Array(String(ch).utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.flags = []
                units.withUnsafeBufferPointer { buf in
                    e?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                }
                post(e)
                pause(0.008)
            }
        }
    }
}

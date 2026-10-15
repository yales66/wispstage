import AppKit
import ObjectiveC
import WispstageClient

/// Pinning levels and intercepting key (points 1 and 2 in the `Wispstage` overview).
///
/// Every window is pinned to `Wispstage.level` (the minimum window level, beneath the wallpaper) before it comes on screen, so the user can neither see
/// nor click it; levels the app sets itself (floating panels at `.floating`, `.statusBar` and the like) are pinned back too, and the original value is
/// kept for `requestedLevel`. All windows therefore share one level, and their order depends only on when they came on screen. How: exchange NSWindow's
/// setLevel: and a few ordering methods so the level is changed before the window comes on screen, and it never shows a frame at its original level.
/// Windows in the menu bar (the app menu, status items) are left alone.
///
/// No window becomes key: a panel that doesn't activate its app (`.nonactivatingPanel`) can become key and take over system keyboard input even while
/// the app isn't frontmost, and what the user types in another app would land in the window under test. `makeKeyWindow` does nothing and
/// `makeKeyAndOrderFront:` only orders the window front; both record the window as `keyTarget` and emit `stage.keyRequested`. The first responder can still be set.
@MainActor
enum StageWindows {
    private static var installed = false
    private static var seen: Set<ObjectIdentifier> = []
    nonisolated(unsafe) private static let requestedKey = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

    static func install() {
        guard !installed else { return }
        installed = true
        exchange(#selector(setter: NSWindow.level), #selector(NSWindow.wispstage_setLevel(_:)))
        exchange(#selector(NSWindow.orderFront(_:)), #selector(NSWindow.wispstage_orderFront(_:)))
        exchange(#selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.wispstage_makeKeyAndOrderFront(_:)))
        exchange(#selector(NSWindow.orderFrontRegardless), #selector(NSWindow.wispstage_orderFrontRegardless))
        exchange(#selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.wispstage_order(_:relativeTo:)))
        exchange(#selector(NSWindow.makeKey), #selector(NSWindow.wispstage_makeKey))
        hookClickToKey()
    }

    /// Number of windows currently dispatching a mouse down (nesting count).
    private static var mouseDownDepth = 0

    /// Click path (point 6 in the `Wispstage` overview): on mouse down, AppKit makes the window key inside `NSWindow.sendEvent:` through the private
    /// `-[NSWindow _handleLeftMouseDownEvent:isDelayedEvent:]` → `-[NSWindow _changeKeyAndMainLimitedOK:]`, without going through `makeKey`
    /// (call stack captured 2026-10-14 in this library's unit tests: a panel that doesn't activate its app and becomes key only if needed, clicked on a text field).
    /// While a mouse down is being dispatched this step is intercepted, recorded as the keyboard target and `stage.keyRequested` is emitted, as with `makeKey`; otherwise it runs unchanged.
    private static func hookClickToKey() {
        let send = #selector(NSWindow.sendEvent(_:))
        if let m = class_getInstanceMethod(NSWindow.self, send) {
            typealias F = @convention(c) (NSWindow, Selector, NSEvent) -> Void
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (NSWindow, NSEvent) -> Void = { w, e in
                let down = e.type == .leftMouseDown || e.type == .rightMouseDown || e.type == .otherMouseDown
                if down { MainActor.assumeIsolated { mouseDownDepth += 1 } }
                original(w, send, e)
                if down { MainActor.assumeIsolated { mouseDownDepth -= 1 } }
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        let change = NSSelectorFromString("_changeKeyAndMainLimitedOK:")
        guard let m = class_getInstanceMethod(NSWindow.self, change),
              method_getTypeEncoding(m).map({ String(cString: $0).hasPrefix("v") }) == true else { return }
        typealias F = @convention(c) (NSWindow, Selector, Bool) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: F.self)
        let block: @convention(block) (NSWindow, Bool) -> Void = { w, limited in
            let swallowed = MainActor.assumeIsolated { () -> Bool in
                guard pins, mouseDownDepth > 0, !isMenuBarWindow(w) else { return false }
                requestKey(w, via: "mouseDown")
                return true
            }
            if !swallowed { original(w, change, limited) }
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    private static func exchange(_ a: Selector, _ b: Selector) {
        guard let ma = class_getInstanceMethod(NSWindow.self, a), let mb = class_getInstanceMethod(NSWindow.self, b) else { return }
        method_exchangeImplementations(ma, mb)
    }

    static func requestedLevel(of w: NSWindow) -> NSWindow.Level {
        (objc_getAssociatedObject(w, requestedKey) as? NSNumber).map { NSWindow.Level(rawValue: $0.intValue) } ?? w.level
    }

    fileprivate static func remember(_ level: NSWindow.Level, for w: NSWindow) {
        objc_setAssociatedObject(w, requestedKey, NSNumber(value: level.rawValue), .OBJC_ASSOCIATION_RETAIN)
    }

    static func isMenuBarWindow(_ w: NSWindow) -> Bool {
        let name = NSStringFromClass(type(of: w))
        return name.contains("StatusBarWindow") || name.contains("MenuBarWindow")
    }

    fileprivate static var pins: Bool { Wispstage.isActive }

    /// Pins to the minimum level, ignores the mouse, joins all Spaces; emits `stage.windowPinned` the first time each window is pinned.
    static func pin(_ w: NSWindow) {
        guard installed, pins, !isMenuBarWindow(w) else { return }
        if w.level != Wispstage.level {
            // For a window whose level was never set through setLevel:, record the original level first
            if objc_getAssociatedObject(w, requestedKey) == nil { remember(w.level, for: w) }
            w.wispstage_setLevel(Wispstage.level)
        }
        if !w.ignoresMouseEvents { w.ignoresMouseEvents = true }
        if !w.collectionBehavior.contains(.canJoinAllSpaces) {
            // Setting canJoinAllSpaces and moveToActiveSpace together throws an exception
            w.collectionBehavior.remove(.moveToActiveSpace)
            w.collectionBehavior.insert(.canJoinAllSpaces)
        }
        // A window not yet on screen has no window number; report it once it has one
        if w.windowNumber > 0, seen.insert(ObjectIdentifier(w)).inserted {
            Wispstage.emit(StageEvent.windowPinned, ["window": w.windowNumber, "class": NSStringFromClass(type(of: w)),
                                                       "level": requestedLevel(of: w).rawValue])
        }
    }

    fileprivate static func requestKey(_ w: NSWindow, via: String? = nil) {
        Wispstage.keyTarget = w
        var fields: [String: Any] = ["window": w.windowNumber, "class": NSStringFromClass(type(of: w))]
        if let via { fields["via"] = via }
        Wispstage.emit(StageEvent.keyRequested, fields)
    }
}

extension NSWindow {
    // After the exchange, calling a method's own name inside its body runs the original implementation.
    @objc func wispstage_setLevel(_ level: NSWindow.Level) {
        StageWindows.remember(level, for: self)
        let pinned = StageWindows.pins && !StageWindows.isMenuBarWindow(self)
        wispstage_setLevel(pinned ? Wispstage.level : level)
    }

    @objc func wispstage_orderFront(_ sender: Any?) {
        StageWindows.pin(self)
        wispstage_orderFront(sender)
    }

    @objc func wispstage_makeKeyAndOrderFront(_ sender: Any?) {
        guard StageWindows.pins else { return wispstage_makeKeyAndOrderFront(sender) }
        StageWindows.pin(self)
        orderFront(sender)
        StageWindows.requestKey(self)
    }

    @objc func wispstage_makeKey() {
        guard StageWindows.pins else { return wispstage_makeKey() }
        StageWindows.requestKey(self)
    }

    @objc func wispstage_orderFrontRegardless() {
        StageWindows.pin(self)
        wispstage_orderFrontRegardless()
    }

    @objc func wispstage_order(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        if place != .out { StageWindows.pin(self) }
        wispstage_order(place, relativeTo: other)
    }
}

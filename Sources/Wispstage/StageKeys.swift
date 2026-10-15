import AppKit
import ObjectiveC
import WispstageClient

/// Keyboard dispatch and beeps (points 3 and 4 in the `Wispstage` overview).
///
/// On the stage there is no key window (`StageWindows` lets no window become key). Keys the driver posts from outside via postToPid then carry
/// window number 0, and AppKit skips the steps it does only for the key window, so: local event monitors identify the window by the event's window and
/// can't find one; Esc doesn't become `cancelOperation:` and Return doesn't press the default button. This fills those in as if the keyboard target were the key window:
/// 1. At the entry of `NSApplication.sendEvent:`, the key's window number is rewritten to the keyboard target (local event monitors run inside sendEvent, so they see the rewritten event);
///    after the monitors, AppKit hands the key to its private `_keyWindow` without looking at the event's window number. While the app isn't frontmost the
///    public `keyWindow` is nil, yet `_keyWindow` can still point at another window (in one app under test, the main window opened earlier; measured 2026-10-14
///    on its quick-entry panel: Esc went to the main window, its own cancelOperation: took it, and the panel stayed open). In real use the keyboard target is
///    the key window, so a key that reaches another window mid-dispatch is not delivered to it; what the monitors didn't consume is delivered here to the keyboard target's `sendEvent:`;
/// 2. At the target window's `sendEvent:`, the window's `performKeyEquivalent:` runs first (default button, cancel button, shortcuts); if nobody takes it, it goes to the first responder as usual;
/// 3. When nobody in the responder chain takes it and it reaches the window's own `keyDown:`, Esc is interpreted as `cancelOperation:` and Return as
///    `insertNewline:` per the standard key bindings, looking for a taker along the responder chain from the first responder;
/// 4. When still nobody takes it, AppKit would play the system beep (`noResponderFor:`); instead `stage.beep` is emitted and nothing sounds.
/// When there is a key window (the stage didn't intercept it), everything is left to AppKit unchanged.
@MainActor
enum StageKeys {
    private static var installed = false

    /// The window a key should land on: the keyboard target while it's still open, otherwise the frontmost visible window that can become key (in real use,
    /// when the key window closes, the system also makes the next window key). Nil when there is a key window, leaving AppKit unchanged.
    static func target() -> NSWindow? {
        guard Wispstage.isActive, NSApp.keyWindow == nil else { return nil }
        if let t = Wispstage.keyTarget, t.isVisible { return t }
        return NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeKey && !StageWindows.isMenuBarWindow($0) }
    }

    /// The same key retargeted to `w` (window number rewritten), other fields copied.
    static func retarget(_ e: NSEvent, to w: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: e.type, location: e.locationInWindow, modifierFlags: e.modifierFlags, timestamp: e.timestamp,
                         windowNumber: w.windowNumber, context: nil, characters: e.characters ?? "",
                         charactersIgnoringModifiers: e.charactersIgnoringModifiers ?? "", isARepeat: e.isARepeat,
                         keyCode: e.keyCode) ?? e
    }

    /// The few standard key bindings (StandardKeyBinding.dict) handled at the window level.
    static func command(for e: NSEvent) -> Selector? {
        switch e.charactersIgnoringModifiers {
        case "\u{1b}": #selector(NSResponder.cancelOperation(_:))
        case "\r", "\u{3}": #selector(NSResponder.insertNewline(_:))
        default: nil
        }
    }

    static func install() {
        guard !installed else { return }
        installed = true
        hookLocalMonitors()
        hookApplicationSendEvent()
        hookWindowSendEvent()
        hookWindowKeyDown()
        silenceUnhandledKeys()
    }

    private static func isKey(_ e: NSEvent) -> Bool { e.type == .keyDown || e.type == .keyUp }

    /// The key being dispatched: whether it reached the window, whether a local event monitor consumed it.
    private struct Dispatch {
        var event: NSEvent
        /// The window this key should land on (the keyboard target).
        unowned let target: NSWindow
        var delivered = false
        var consumed = false
    }
    private static var dispatch: Dispatch?

    private static func hookApplicationSendEvent() {
        let sel = #selector(NSApplication.sendEvent(_:))
        guard let m = class_getInstanceMethod(NSApplication.self, sel) else { return }
        typealias F = @convention(c) (NSApplication, Selector, NSEvent) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: F.self)
        let block: @convention(block) (NSApplication, NSEvent) -> Void = { app, e in
            MainActor.assumeIsolated {
                guard isKey(e), let window = target() else { return original(app, sel, e) }
                let event = e.windowNumber == window.windowNumber ? e : retarget(e, to: window)
                let outer = dispatch
                dispatch = Dispatch(event: event, target: window)
                original(app, sel, event)
                // After the local event monitors, AppKit hands the key to `_keyWindow` (the window hook above withholds it when that isn't the keyboard target); what the monitors didn't consume goes to the keyboard target here
                if let d = dispatch, !d.delivered, !d.consumed { window.sendEvent(event) }
                dispatch = outer
            }
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// Whether a local event monitor consumed the key being dispatched can't be seen from outside: wrap the handler when the monitor is added and note when it returns nil.
    private static func hookLocalMonitors() {
        let sel = #selector(NSEvent.addLocalMonitorForEvents(matching:handler:))
        guard let m = class_getClassMethod(NSEvent.self, sel) else { return }
        typealias Handler = @convention(block) (NSEvent) -> NSEvent?
        typealias F = @convention(c) (AnyClass, Selector, UInt64, Handler) -> Any?
        let original = unsafeBitCast(method_getImplementation(m), to: F.self)
        let block: @convention(block) (AnyClass, UInt64, @escaping Handler) -> Any? = { cls, mask, handler in
            let wrapped: Handler = { e in
                let r = handler(e)
                if r == nil, Thread.isMainThread { MainActor.assumeIsolated { dispatch?.consumed = true } }
                return r
            }
            return original(cls, sel, mask, wrapped)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    private static func hookWindowSendEvent() {
        let sel = #selector(NSWindow.sendEvent(_:))
        guard let m = class_getInstanceMethod(NSWindow.self, sel) else { return }
        typealias F = @convention(c) (NSWindow, Selector, NSEvent) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: F.self)
        let block: @convention(block) (NSWindow, NSEvent) -> Void = { w, e in
            let handled = MainActor.assumeIsolated { () -> Bool in
                if isKey(e), let d = dispatch {
                    // AppKit handed it to `_keyWindow`, which isn't the keyboard target: withhold it and deliver to the keyboard target after AppKit's sendEvent returns
                    guard d.target === w else { return true }
                    dispatch?.delivered = true
                }
                guard Wispstage.isActive, e.type == .keyDown, !w.isKeyWindow else { return false }
                return w.performKeyEquivalent(with: e)
            }
            if !handled { original(w, sel, e) }
        }
        // NSWindow implements sendEvent: itself; subclasses (NSPanel and others) that override it still reach this (they call super)
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    private static func hookWindowKeyDown() {
        let sel = #selector(NSResponder.keyDown(with:))
        guard let method = class_getInstanceMethod(NSWindow.self, sel) else { return }
        // NSWindow may only inherit NSResponder's keyDown; class_replaceMethod changes (or adds) it on NSWindow only and leaves other responders alone.
        typealias F = @convention(c) (NSWindow, Selector, NSEvent) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: F.self)
        let block: @convention(block) (NSWindow, NSEvent) -> Void = { w, e in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard Wispstage.isActive, !w.isKeyWindow, let sel = command(for: e) else { return false }
                return (w.firstResponder ?? w).tryToPerform(sel, with: nil)
            }
            if !handled { original(w, sel, e) }
        }
        class_replaceMethod(NSWindow.self, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }

    /// When nobody takes a key, AppKit plays the system beep in `noResponder(for: keyDown:)`. On the stage the test runs while the user keeps using
    /// the computer, so the app under test shouldn't make a sound: emit `stage.beep` instead; other selectors run unchanged.
    private static func silenceUnhandledKeys() {
        let sel = #selector(NSResponder.noResponder(for:))
        guard let method = class_getInstanceMethod(NSResponder.self, sel) else { return }
        typealias F = @convention(c) (NSResponder, Selector, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: F.self)
        let keyDown = #selector(NSResponder.keyDown(with:))
        let block: @convention(block) (NSResponder, Selector) -> Void = { r, eventSelector in
            let silenced = MainActor.assumeIsolated { () -> Bool in
                guard Wispstage.isActive, eventSelector == keyDown else { return false }
                let e = dispatch?.event ?? NSApp.currentEvent
                var fields: [String: Any] = [:]
                if let e, isKey(e) { fields = ["keyCode": Int(e.keyCode), "window": e.windowNumber] }
                Wispstage.emit(StageEvent.beep, fields)
                return true
            }
            if !silenced { original(r, sel, eventSelector) }
        }
        class_replaceMethod(NSResponder.self, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }
}

import AppKit
import ObjectiveC
import WispstageClient

/// Observe-only mode (`WISPSTAGE_STAGE=observe`): the app comes to the front, windows become key and beeps sound as usual; the stage only records these
/// as events, each carrying `observed: true` (`StageEvent.observedField`). The driver's foreground mode uses it: whether the app should make a sound and
/// when activation and key happen can't otherwise be seen from outside the process in foreground mode.
///
/// None of the background-mode hooks are installed (`StageWindows`, `StageKeys`, `StageGlobalMonitors`, `StageActivation`), the activation policy is
/// unchanged and levels are not pinned: several background-mode wrappers change behavior even when they let an event through (the `keyDown:` added to
/// NSWindow, rewriting the key's window number, replacing global monitor handlers), and observe-only mode must change no AppKit behavior, so it installs only these three:
/// 1. Observes `NSWindow.didBecomeKeyNotification` and emits `stage.becameKey`. However a window becomes key, it goes through `becomeKeyWindow` and posts
///    this notification (Apple documentation for `NSWindow.becomeKey()`), so one place is enough. `queue: nil` records synchronously on the posting thread, in order with other events.
/// 2. Wraps the four activation entry points: emits `stage.activateRequested {via}` first, then calls the original implementation with the original
///    arguments and returns its result; the two on `NSRunningApplication` record only when the receiver is this process. It also observes
///    `NSApplication.didBecomeActiveNotification` and emits `stage.becameActive`: a request doesn't guarantee activation (Apple documentation for
///    `NSApplication.activate()`), so actual activation is recorded separately.
/// 3. Wraps `-[NSResponder noResponderFor:]`: when the selector is `keyDown:`, emits `stage.beep` (with the current key's keyCode and window number),
///    then calls the original implementation so the beep still sounds. This covers only unhandled keys at the end of the responder chain; beeps from
///    places in AppKit that call NSBeep directly (`doCommandBySelector:`, a failed menu shortcut lookup, `NSSound.beep()` and so on) aren't recorded here.
@MainActor
enum StageObserve {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { n in
            guard let w = n.object as? NSWindow else { return }
            emit(StageEvent.becameKey, ["window": w.windowNumber, "class": NSStringFromClass(type(of: w))])
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            emit(StageEvent.becameActive)
        }
        wrapActivation()
        wrapNoResponder()
    }

    /// Events are always emitted on the main thread (`NSRunningApplication` activation and notifications may arrive off the main thread).
    nonisolated private static func emit(_ name: String, _ fields: [String: Any] = [:]) {
        var f = fields
        f[StageEvent.observedField] = true
        let line = StageEvent.encode(name, f)
        let send = { MainActor.assumeIsolated { Wispstage.emit(line: line) } }
        if Thread.isMainThread { send() } else { DispatchQueue.main.async(execute: send) }
    }

    private static func wrapActivation() {
        let activate = NSSelectorFromString("activate")
        if let m = class_getInstanceMethod(NSApplication.self, activate) {
            typealias F = @convention(c) (AnyObject, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (AnyObject) -> Void = { obj in
                emit(StageEvent.activateRequested, ["via": "NSApp.activate"])
                original(obj, activate)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        let ignoring = NSSelectorFromString("activateIgnoringOtherApps:")
        if let m = class_getInstanceMethod(NSApplication.self, ignoring) {
            typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (AnyObject, Bool) -> Void = { obj, flag in
                emit(StageEvent.activateRequested, ["via": "NSApp.activate(ignoringOtherApps:)"])
                original(obj, ignoring, flag)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        let me = ProcessInfo.processInfo.processIdentifier
        @Sendable func isSelf(_ obj: AnyObject) -> Bool { (obj as? NSRunningApplication)?.processIdentifier == me }
        let options = NSSelectorFromString("activateWithOptions:")
        if let m = class_getInstanceMethod(NSRunningApplication.self, options) {
            typealias F = @convention(c) (AnyObject, Selector, UInt) -> Bool
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (AnyObject, UInt) -> Bool = { obj, opts in
                if isSelf(obj) { emit(StageEvent.activateRequested, ["via": "NSRunningApplication.activate(options:)"]) }
                return original(obj, options, opts)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        let from = NSSelectorFromString("activateFromApplication:options:")
        if let m = class_getInstanceMethod(NSRunningApplication.self, from) {
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?, UInt) -> Bool
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (AnyObject, AnyObject?, UInt) -> Bool = { obj, app, opts in
                if isSelf(obj) { emit(StageEvent.activateRequested, ["via": "NSRunningApplication.activate(from:options:)"]) }
                return original(obj, from, app, opts)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    /// In AppKit only NSResponder implements `noResponderFor:` (checked with a probe on Darwin 27.2), so wrapping it in one place is enough.
    private static func wrapNoResponder() {
        let sel = #selector(NSResponder.noResponder(for:))
        guard let m = class_getInstanceMethod(NSResponder.self, sel) else { return }
        typealias F = @convention(c) (NSResponder, Selector, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: F.self)
        let keyDown = #selector(NSResponder.keyDown(with:))
        let block: @convention(block) (NSResponder, Selector) -> Void = { r, eventSelector in
            if eventSelector == keyDown {
                var fields: [String: Any] = [:]
                let key: (code: Int, window: Int)? = Thread.isMainThread ? MainActor.assumeIsolated {
                    guard let e = NSApp?.currentEvent, e.type == .keyDown || e.type == .keyUp else { return nil }
                    return (Int(e.keyCode), e.windowNumber)
                } : nil
                if let key { fields = ["keyCode": key.code, "window": key.window] }
                emit(StageEvent.beep, fields)
            }
            original(r, sel, eventSelector)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }
}

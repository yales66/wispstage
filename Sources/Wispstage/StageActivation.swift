import AppKit
import ObjectiveC
import WispstageClient

/// Intercepting activation (point 2 in the `Wispstage` overview): none of the public ways this process can become frontmost are carried out; each emits
/// `stage.activateRequested` (`via` names the path). Becoming frontmost would take over the app the user is working in, and what they type would land in the
/// window under test. Tests can still assert that the app wanted to activate. `NSRunningApplication.activate…` for other processes runs unchanged.
@MainActor
enum StageActivation {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        swallow(NSApplication.self, "activate", via: "NSApp.activate") { _ in true }
        swallow(NSApplication.self, "activateIgnoringOtherApps:", via: "NSApp.activate(ignoringOtherApps:)", arg: Bool.self) { _ in true }
        swallowRunning("activateWithOptions:", via: "NSRunningApplication.activate(options:)", argCount: 1)
        swallowRunning("activateFromApplication:options:", via: "NSRunningApplication.activate(from:options:)", argCount: 2)
    }

    /// Activation may be called off the main thread (`NSRunningApplication`); events are always emitted on the main thread.
    nonisolated private static func requested(_ via: String) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { Wispstage.emit(StageEvent.activateRequested, ["via": via]) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { Wispstage.emit(StageEvent.activateRequested, ["via": via]) } }
        }
    }

    /// Instance methods with no arguments (or one BOOL argument) and no return value: the original implementation isn't called while the stage is on.
    private static func swallow(_ cls: AnyClass, _ name: String, via: String, _ applies: @escaping @Sendable (AnyObject) -> Bool) {
        let sel = NSSelectorFromString(name)
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias F = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: F.self)
        let block: @convention(block) (AnyObject) -> Void = { obj in
            if Wispstage.isActive && applies(obj) { requested(via) } else { original(obj, sel) }
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    private static func swallow(_ cls: AnyClass, _ name: String, via: String, arg: Bool.Type, _ applies: @escaping @Sendable (AnyObject) -> Bool) {
        let sel = NSSelectorFromString(name)
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: F.self)
        let block: @convention(block) (AnyObject, Bool) -> Void = { obj, flag in
            if Wispstage.isActive && applies(obj) { requested(via) } else { original(obj, sel, flag) }
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// `NSRunningApplication` activation methods (returning BOOL): not carried out for this process, returns true.
    private static func swallowRunning(_ name: String, via: String, argCount: Int) {
        let sel = NSSelectorFromString(name)
        guard let m = class_getInstanceMethod(NSRunningApplication.self, sel) else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        @Sendable func isSelf(_ obj: AnyObject) -> Bool {
            Wispstage.isActive && (obj as? NSRunningApplication)?.processIdentifier == me
        }
        if argCount == 1 {
            typealias F = @convention(c) (AnyObject, Selector, UInt) -> Bool
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (AnyObject, UInt) -> Bool = { obj, opts in
                if isSelf(obj) { requested(via); return true }
                return original(obj, sel, opts)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        } else {
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?, UInt) -> Bool
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (AnyObject, AnyObject?, UInt) -> Bool = { obj, from, opts in
                if isSelf(obj) { requested(via); return true }
                return original(obj, sel, from, opts)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }
}

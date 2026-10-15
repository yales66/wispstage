import AppKit
import ObjectiveC
import WispstageClient

/// Global event monitors (point 6 in the `Wispstage` overview: real user input and global event monitors).
///
/// Handlers the app under test registers with `NSEvent.addGlobalMonitorForEvents` receive no real events while the stage is on: the user's clicks and
/// typing in other apps on the same Mac are not test input, and passing them on would interrupt the scenario (for example, a quick-entry panel that closes
/// when you click elsewhere). AppKit still registers the monitor, but what it gets is a wrapper from the stage (`guarded`), which emits
/// `stage.globalEventDropped` (`type` is the event type name) for each drop.
/// So that behavior such as "close when clicking elsewhere" stays testable, the original handlers are kept by mask, and the driver's `globalEvent` command hands them a synthesized event (`deliver`).
@MainActor
enum StageGlobalMonitors {
    typealias Handler = (NSEvent) -> Void

    private struct Entry {
        let monitor: AnyObject
        let mask: NSEvent.EventTypeMask
        let handler: Handler
    }
    private static var installed = false
    private static var entries: [ObjectIdentifier: Entry] = [:]
    /// Registration order; synthesized events are delivered in this order.
    private static var order: [ObjectIdentifier] = []

    /// Event type names the `globalEvent` command accepts.
    static let types: [String: NSEvent.EventType] = [
        "leftMouseDown": .leftMouseDown, "leftMouseUp": .leftMouseUp,
        "rightMouseDown": .rightMouseDown, "rightMouseUp": .rightMouseUp,
        "otherMouseDown": .otherMouseDown, "otherMouseUp": .otherMouseUp,
        "mouseMoved": .mouseMoved, "scrollWheel": .scrollWheel,
    ]

    static func name(of type: NSEvent.EventType) -> String {
        types.first { $0.value == type }?.key ?? String(type.rawValue)
    }

    static func install() {
        guard !installed else { return }
        installed = true
        hookAdd()
        hookRemove()
    }

    /// The wrapper AppKit gets: while the stage is on, it doesn't call `handler` and emits `stage.globalEventDropped`.
    nonisolated static func guarded(_ handler: @escaping Handler) -> Handler {
        { e in
            guard Wispstage.isActive else { return handler(e) }
            let type = e.type
            onMain { dropped(type) }
        }
    }

    private static func dropped(_ type: NSEvent.EventType) {
        Wispstage.emit(StageEvent.globalEventDropped, ["type": name(of: type)])
    }

    /// Monitor registration, removal and drops are all recorded on the main thread (AppKit usually calls on the main thread anyway).
    nonisolated private static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(body) } else { DispatchQueue.main.async { MainActor.assumeIsolated(body) } }
    }

    private static func register(_ entry: Entry) {
        let id = ObjectIdentifier(entry.monitor)
        entries[id] = entry
        order.append(id)
    }

    private static func unregister(_ monitor: AnyObject) {
        let id = ObjectIdentifier(monitor)
        entries[id] = nil
        order.removeAll { $0 == id }
    }

    /// Synthesizes a `type` event, hands it to the handlers whose mask matches, and returns how many received it. `at` is in screen coordinates with a top-left origin (the same as the driver's).
    static func deliver(_ type: NSEvent.EventType, at p: CGPoint) -> Int {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let loc = NSPoint(x: p.x, y: height - p.y)
        let now = ProcessInfo.processInfo.systemUptime
        let event: NSEvent?
        switch type {
        case .scrollWheel:
            event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)
                .flatMap { $0.location = CGPoint(x: p.x, y: p.y); return NSEvent(cgEvent: $0) }
        default:
            event = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: now, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown ? 1 : 0)
        }
        guard let event else { return 0 }
        let targets = order.compactMap { entries[$0] }.filter { $0.mask.contains(NSEvent.EventTypeMask(type: type)) }
        for t in targets { t.handler(event) }
        return targets.count
    }

    private static func hookAdd() {
        let sel = #selector(NSEvent.addGlobalMonitorForEvents(matching:handler:))
        guard let m = class_getClassMethod(NSEvent.self, sel) else { return }
        typealias Block = @convention(block) (NSEvent) -> Void
        typealias F = @convention(c) (AnyClass, Selector, UInt64, Block) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(m), to: F.self)
        let block: @convention(block) (AnyClass, UInt64, @escaping Block) -> AnyObject? = { cls, mask, handler in
            let wrapped: Block = { guarded({ handler($0) })($0) }
            let monitor = original(cls, sel, mask, wrapped)
            if let monitor {
                let entry = Entry(monitor: monitor, mask: NSEvent.EventTypeMask(rawValue: mask), handler: { handler($0) })
                onMain { register(entry) }
            }
            return monitor
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    private static func hookRemove() {
        let sel = #selector(NSEvent.removeMonitor(_:))
        guard let m = class_getClassMethod(NSEvent.self, sel) else { return }
        typealias F = @convention(c) (AnyClass, Selector, AnyObject) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: F.self)
        let block: @convention(block) (AnyClass, AnyObject) -> Void = { cls, monitor in
            onMain { unregister(monitor) }
            original(cls, sel, monitor)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }
}

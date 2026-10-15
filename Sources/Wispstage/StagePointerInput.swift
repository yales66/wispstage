import AppKit
import ObjectiveC
import WispstageClient

/// Mouse gestures (point 5 in the `Wispstage` overview): the driver's `pointer` command synthesizes NSEvents in this process and posts them to its own
/// event queue (`NSApp.postEvent`), dispatched through the same `NSApp.sendEvent` as real events (local event monitors and controls' own tracking loops
/// get them as usual). Nothing goes through the system HID layer: the system cursor doesn't move, no global events are posted, and the app needn't be frontmost.
///
/// On the stage windows don't become key, but in real use the window the user clicks is key, so clicks are treated as past the first click:
/// - AppKit treats a click on a window that isn't key as a first click, and when the hosting view doesn't accept first mouse the mouse down is swallowed
///   (measured 2026-10-14 in one app under test: SwiftUI Buttons still got it; click and drag gestures on custom draggable views did not). Before the press,
///   `acceptsFirstMouse` returns true for the chain of views under the point (the method is replaced per class, process-wide; only a test host with the stage on gets here).
/// - The window clicked or dragged in is recorded as the keyboard target: in real use, the window you click becomes key.
/// During hover the cursor doesn't move, so the system sends no tracking-area enter or exit; this sends them for the hover point instead.
@MainActor
enum StagePointerInput {
    /// SwiftUI drag gestures are recognized only over several steps about one frame apart (about 16 ms).
    static let stepInterval: Duration = .milliseconds(16)

    private static var eventNumber = 0
    /// The left button held between `down` and `up`: in which window and where it rests (measured from the content area's top-left corner).
    private static var held: (window: NSWindow, at: CGPoint)?
    /// Hover: tracking areas the cursor is "inside"; they get an exit on the next hover elsewhere.
    private static var hovered: [ObjectIdentifier: (area: NSTrackingArea, owner: NSResponder, window: NSWindow)] = [:]
    private static var firstMousePatched: Set<ObjectIdentifier> = []

    /// One at a time: queued while the previous one is still running.
    private static var queue: [(StagePointer, (String) -> Void)] = []
    private static var running = false

    static func handle(_ fields: [String: Any], reply: @escaping (String) -> Void) {
        let p: StagePointer
        do { p = try .init(fields: fields) } catch { return reply(StageEvent.encodeReply(["ok": false, "error": "\(error)"])) }
        queue.append((p, reply))
        guard !running else { return }
        running = true
        Task { @MainActor in
            while !queue.isEmpty {
                let (next, done) = queue.removeFirst()
                do {
                    try await perform(next)
                    done(StageEvent.encodeReply(["ok": true]))
                } catch {
                    done(StageEvent.encodeReply(["ok": false, "error": "\(error)"]))
                }
            }
            running = false
        }
    }

    private static func perform(_ input: StagePointer) async throws {
        switch input {
        case let .click(n, p, right, count, mods):
            let w = try window(n)
            let loc = location(p, in: w)
            try await waitUntilHitTestable(w, at: loc)
            prepare(w, at: loc)
            let (down, up): (NSEvent.EventType, NSEvent.EventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
            for i in 1...max(count, 1) {
                post(mouse(down, loc, in: w, clicks: i, mods: flags(mods), pressure: 1))
                try await pause(.milliseconds(20))
                post(mouse(up, loc, in: w, clicks: i, mods: flags(mods), pressure: 0))
                try await pause(.milliseconds(20))
            }
        case let .drag(n, a, b, steps):
            let w = try window(n)
            let start = location(a, in: w)
            try await waitUntilHitTestable(w, at: start)
            prepare(w, at: start)
            post(mouse(.leftMouseDown, start, in: w, pressure: 1))
            try await pause(.milliseconds(100))
            for p in StagePointer.path(from: a, to: b, steps: steps) {
                post(mouse(.leftMouseDragged, location(p, in: w), in: w, pressure: 1))
                try await pause(stepInterval)
            }
            try await pause(.milliseconds(50))
            post(mouse(.leftMouseUp, location(b, in: w), in: w, pressure: 0))
            try await pause(.milliseconds(20))
        case let .down(n, p):
            guard held == nil else { throw StageClientError("left button already down, send up first") }
            let w = try window(n)
            let loc = location(p, in: w)
            try await waitUntilHitTestable(w, at: loc)
            prepare(w, at: loc)
            post(mouse(.leftMouseDown, loc, in: w, pressure: 1))
            held = (w, p)
            try await pause(.milliseconds(100))
        case let .move(n, b, steps):
            guard let h = held, h.window.windowNumber == n else { throw StageClientError("move requires a down on window \(n) first") }
            for p in StagePointer.path(from: h.at, to: b, steps: steps) {
                post(mouse(.leftMouseDragged, location(p, in: h.window), in: h.window, pressure: 1))
                held = (h.window, p)
                try await pause(stepInterval)
            }
            try await pause(.milliseconds(100))
        case let .up(n, p):
            guard let h = held, h.window.windowNumber == n else { throw StageClientError("up requires a down on window \(n) first") }
            held = nil
            post(mouse(.leftMouseUp, location(p, in: h.window), in: h.window, pressure: 0))
            try await pause(.milliseconds(50))
        case let .hover(n, p):
            let w = try window(n)
            // Move twice nearby before settling: hover that responds only to movement (SwiftUI's onContinuousHover) also receives it
            for d: CGFloat in [3, 1, 0] {
                hover(at: location(CGPoint(x: p.x - d, y: p.y - d), in: w), in: w)
                try await pause(.milliseconds(16))
            }
        case let .scroll(n, p, dy, dx):
            let w = try window(n)
            try scroll(at: location(p, in: w), in: w, dy: dy, dx: dx)
            try await pause(.milliseconds(20))
        }
    }

    // MARK: Windows and coordinates

    private static func window(_ n: Int) throws -> NSWindow {
        guard let w = NSApp.window(withWindowNumber: n), w.isVisible else { throw StageClientError("no visible window \(n)") }
        return w
    }

    /// Right after a window is first shown, its frame view can hit-test to nil for a few milliseconds (seen on a macOS 26.6 GitHub runner,
    /// between 1 and 12 ms after the first display cycle). A mouse down posted then reaches no view, and the drags and up that follow have no
    /// receiver either. Wait until the point hits a view; on timeout, post anyway as before.
    private static func waitUntilHitTestable(_ w: NSWindow, at loc: NSPoint) async throws {
        guard let frame = w.contentView?.superview, frame.frame.contains(loc) else { return }
        let deadline = ContinuousClock.now + .milliseconds(250)   // to be measured: only the 1 to 12 ms range above is known
        while frame.hitTest(loc) == nil, ContinuousClock.now < deadline { try await pause(.milliseconds(4)) }   // 4 ms: to be measured
    }

    private static func prepare(_ w: NSWindow, at loc: NSPoint) {
        Wispstage.keyTarget = w
        if !w.isKeyWindow { acceptFirstMouse(in: w, at: loc) }
    }

    private static func acceptFirstMouse(in w: NSWindow, at loc: NSPoint) {
        guard let frame = w.contentView?.superview, var v = frame.hitTest(loc) else { return }
        while true {
            if let cls = object_getClass(v), !firstMousePatched.contains(ObjectIdentifier(cls)) {
                firstMousePatched.insert(ObjectIdentifier(cls))
                let block: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
                class_replaceMethod(cls, #selector(NSView.acceptsFirstMouse(for:)), imp_implementationWithBlock(block), "B@:@")
            }
            guard let s = v.superview else { break }
            v = s
        }
    }

    private static func location(_ p: CGPoint, in w: NSWindow) -> NSPoint {
        let content = w.contentView?.frame ?? NSRect(origin: .zero, size: w.frame.size)
        return StagePointer.windowPoint(p, contentFrame: content)
    }

    private static func flags(_ mods: [StagePointer.Modifier]) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        for m in mods {
            switch m {
            case .cmd: f.insert(.command)
            case .shift: f.insert(.shift)
            case .opt: f.insert(.option)
            case .ctrl: f.insert(.control)
            }
        }
        return f
    }

    // MARK: Events

    private static func mouse(_ type: NSEvent.EventType, _ loc: NSPoint, in w: NSWindow, clicks: Int = 1,
                              mods: NSEvent.ModifierFlags = [], pressure: Float) -> NSEvent? {
        eventNumber += 1
        return NSEvent.mouseEvent(with: type, location: loc, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: w.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clicks,
                                  pressure: pressure)
    }

    private static func post(_ e: NSEvent?) {
        guard let e else { return }
        NSApp.postEvent(e, atStart: false)
    }

    private static func pause(_ d: Duration) async throws { try await Task.sleep(for: d) }

    /// Hover: posts mouseMoved and sends enter, exit and move to the owners of the tracking areas under the point.
    private static func hover(at loc: NSPoint, in w: NSWindow) {
        post(mouse(.mouseMoved, loc, in: w, pressure: 0))
        guard let root = w.contentView?.superview ?? w.contentView else { return }
        var inside: Set<ObjectIdentifier> = []
        func visit(_ v: NSView) {
            for area in v.trackingAreas {
                guard let owner = area.owner as? NSResponder else { continue }
                let rect = area.options.contains(.inVisibleRect) ? v.visibleRect : area.rect
                guard rect.contains(v.convert(loc, from: nil)) else { continue }
                let id = ObjectIdentifier(area)
                inside.insert(id)
                if hovered[id] == nil, area.options.contains(.mouseEnteredAndExited),
                   let e = enterExit(.mouseEntered, loc, in: w, area: area) {
                    owner.mouseEntered(with: e)
                }
                hovered[id] = (area, owner, w)
                if area.options.contains(.mouseMoved), let e = mouse(.mouseMoved, loc, in: w, pressure: 0) {
                    owner.mouseMoved(with: e)
                }
            }
            for sub in v.subviews where !sub.isHidden { visit(sub) }
        }
        visit(root)
        for (id, entry) in hovered where !inside.contains(id) {
            if entry.area.options.contains(.mouseEnteredAndExited), let e = enterExit(.mouseExited, loc, in: entry.window, area: entry.area) {
                entry.owner.mouseExited(with: e)
            }
            hovered[id] = nil
        }
    }

    /// Enter and exit events must carry the tracking area (`trackingArea` non-nil): SwiftUI's NSHostingView ignores enter events without one, and
    /// onHover doesn't fire (measured 2026-10-15, macOS 27.2). trackingNumber is passed the tracking area object's address, from which AppKit resolves
    /// `trackingArea`; this isn't documented behavior, so the result is checked once after creation and a mismatch is reported on standard error.
    static func enterExit(_ type: NSEvent.EventType, _ loc: NSPoint, in w: NSWindow, area: NSTrackingArea) -> NSEvent? {
        eventNumber += 1
        let e = NSEvent.enterExitEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: eventNumber,
                                       trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()),
                                       userData: nil)
        if let e, e.trackingArea !== area {
            FileHandle.standardError.write(Data("Wispstage: synthesized enter/exit event has no tracking area, SwiftUI hover may not fire\n".utf8))
        }
        return e
    }

    /// NSEvent has no initializer for scroll wheel events: create a CGEvent that is never posted (so the cursor doesn't move),
    /// fill in the location and window number, then convert it to an NSEvent and hand it to the window.
    private static func scroll(at loc: NSPoint, in w: NSWindow, dy: Int, dx: Int) throws {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(clamping: dy), wheel2: Int32(clamping: dx), wheel3: 0) else {
            throw StageClientError("cannot create scroll wheel event")
        }
        let screen = w.convertPoint(toScreen: loc)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: primaryHeight - screen.y)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w.windowNumber))
        guard let e = NSEvent(cgEvent: cg) else { throw StageClientError("cannot convert scroll wheel event to NSEvent") }
        if e.window === w {
            w.sendEvent(e)
        } else if let view = w.contentView?.hitTest(w.contentView?.superview?.convert(loc, from: nil) ?? loc) {
            view.scrollWheel(with: e)
        } else {
            throw StageClientError("no scrollable view at \(loc)")
        }
    }

    // MARK: First responder

    /// First responder of the keyboard target (or the actual key window when there is none); a field editor is replaced by the control it edits. Nil when the window itself is the first responder.
    static func firstResponder() -> StageStatus.Responder? {
        guard let w = NSApp.keyWindow ?? Wispstage.keyTarget, let r = w.firstResponder, r !== w else { return nil }
        var target: NSResponder = r
        if let tv = r as? NSTextView, tv.isFieldEditor, let d = tv.delegate as? NSView { target = d }
        // SwiftUI elements don't conform to Swift's NSAccessibilityProtocol: when the protocol yields nothing, read by selector
        let element = target as AnyObject
        func get(_ key: String) -> Any? { element.responds(to: Selector(key)) ? element.value(forKey: key) : nil }
        let view = target as? NSView
        // For controls like NSTextField the role is on the cell; the view itself answers AXUnknown
        var role = view?.accessibilityRole()?.rawValue ?? (get("accessibilityRole") as? String)
        if role == NSAccessibility.Role.unknown.rawValue, let cell = (view as? NSControl)?.cell?.accessibilityRole() { role = cell.rawValue }
        let id = view?.accessibilityIdentifier() ?? get("accessibilityIdentifier") as? String ?? ""
        var frame: CGRect?
        if let v = target as? NSView, let vw = v.window {
            let screen = vw.convertToScreen(v.convert(v.bounds, to: nil))
            let height = NSScreen.screens.first?.frame.height ?? 0
            frame = CGRect(x: screen.minX, y: height - screen.maxY, width: screen.width, height: screen.height)
        }
        return .init(id: id.isEmpty ? nil : id, role: role, frame: frame)
    }
}

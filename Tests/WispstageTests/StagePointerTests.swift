import AppKit
import Testing
import XCTest
@testable import Wispstage
import WispstageClient

@Suite struct StagePointerCommandTests {
    @Test(arguments: [
        StagePointer.click(window: 12, at: CGPoint(x: 100, y: 200)),
        .click(window: 12, at: CGPoint(x: 100.25, y: 20.5), right: true, count: 2, modifiers: [.cmd, .shift]),
        .drag(window: 7, from: CGPoint(x: 10, y: 20), to: CGPoint(x: -30, y: 40), steps: 25),
        .down(window: 7, at: CGPoint(x: 10, y: 20)),
        .move(window: 7, to: CGPoint(x: 10.5, y: 84), steps: 24),
        .up(window: 7, at: CGPoint(x: 10, y: 84)),
        .hover(window: 7, at: CGPoint(x: 10, y: 20)),
        .scroll(window: 7, at: CGPoint(x: 10, y: 20), dy: -120, dx: 30),
    ])
    func roundTripsThroughJSON(_ p: StagePointer) throws {
        let data = try JSONSerialization.data(withJSONObject: p.fields)
        let back = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(back["cmd"] as? String == "pointer")
        #expect(try StagePointer(fields: back) == p)
    }

    // The first element is the case name (parameterized test cases are told apart by it)
    @Test(arguments: [
        ("noWindow", #"{"cmd":"pointer"}"#),
        ("noWindowNumber", #"{"cmd":"pointer","action":"click","x":1,"y":2}"#),
        ("noY", #"{"cmd":"pointer","action":"click","window":3,"x":1}"#),
        ("unknownAction", #"{"cmd":"pointer","action":"fly","window":3,"x":1,"y":2}"#),
        ("zeroCount", #"{"cmd":"pointer","action":"click","window":3,"x":1,"y":2,"count":0}"#),
        ("unknownMod", #"{"cmd":"pointer","action":"click","window":3,"x":1,"y":2,"mods":["hyper"]}"#),
        ("dragNoSteps", #"{"cmd":"pointer","action":"drag","window":3,"x":1,"y":2,"toX":4,"toY":5}"#),
        ("scrollNoDy", #"{"cmd":"pointer","action":"scroll","window":3,"x":1,"y":2}"#),
    ])
    func rejectsBadCommands(_ id: String, _ line: String) throws {
        let f = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        #expect(throws: StageClientError.self) { try StagePointer(fields: f) }
    }

    @Test func pathSplitsEvenlyWithoutStart() {
        let path = StagePointer.path(from: .zero, to: CGPoint(x: 100, y: 50), steps: 4)
        #expect(path == [CGPoint(x: 25, y: 12.5), CGPoint(x: 50, y: 25), CGPoint(x: 75, y: 37.5), CGPoint(x: 100, y: 50)])
    }

    @Test func windowPointFlipsFromContentTopLeft() {
        #expect(StagePointer.windowPoint(CGPoint(x: 100, y: 44), contentFrame: CGRect(x: 0, y: 0, width: 800, height: 744))
            == CGPoint(x: 100, y: 700))
        #expect(StagePointer.windowPoint(.zero, contentFrame: CGRect(x: 10, y: 20, width: 300, height: 380)) == CGPoint(x: 10, y: 400))
    }

    @Test func statusDecodesFirstResponder() {
        let s = StageStatus(reply: ["ok": true, "keyTarget": 5, "keyWindow": 0, "active": false,
                                    "firstResponder": StageStatus.responderFields(.init(id: "q.answer", role: "AXTextField",
                                                                                         frame: CGRect(x: 1, y: 2, width: 3, height: 4)))])
        #expect(s == StageStatus(keyTarget: 5, keyWindow: 0, active: false,
                                 firstResponder: .init(id: "q.answer", role: "AXTextField", frame: CGRect(x: 1, y: 2, width: 3, height: 4))))
        #expect(StageStatus(reply: ["ok": true]).firstResponder == nil)
    }
}

/// A view that doesn't accept first mouse (like the hosting view of a custom draggable SwiftUI view): counts the mouse events it receives.
final class MouseCountingView: NSView {
    var downs = 0, drags = 0, ups = 0, rightDowns = 0, scrolls: [CGFloat] = [], entered = 0, exited = 0
    var lastDownClicks = 0, lastDownMods: NSEvent.ModifierFlags = []
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override func mouseDown(with e: NSEvent) {
        downs += 1; lastDownClicks = e.clickCount; lastDownMods = e.modifierFlags
        // Controls with their own tracking loop (SwiftUI gestures, NSButton) pull later events from the queue inside mouse down; this one doesn't, leaving them to sendEvent
    }
    override func mouseDragged(with e: NSEvent) { drags += 1 }
    override func mouseUp(with e: NSEvent) { ups += 1 }
    override func rightMouseDown(with e: NSEvent) { rightDowns += 1 }
    override func scrollWheel(with e: NSEvent) { scrolls.append(e.scrollingDeltaY) }
    override func mouseEntered(with e: NSEvent) { entered += 1 }
    override func mouseExited(with e: NSEvent) { exited += 1 }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // AppKit calls this on its own whenever it re-evaluates tracking areas; keep the one area while the bounds are unchanged, so one hover is one enter
        if trackingAreas.count == 1, trackingAreas[0].rect == bounds { return }
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
}

/// The stage's `pointer` and `status` commands: the window isn't key (the test process isn't frontmost, and the stage keeps it from becoming key), yet gestures still reach the view.
@MainActor final class StagePointerTests: XCTestCase {
    private var window: NSWindow!
    private var view: MouseCountingView!

    /// A 120×80 window whose left half (0…60) is the event-counting view.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try GUISession.require()
        Fixture.stage()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = MouseCountingView(frame: NSRect(x: 0, y: 0, width: 60, height: 80))
        window.contentView?.addSubview(view)
        view.updateTrackingAreas()
        window.orderFront(nil)
        XCTAssertFalse(window.isKeyWindow)
    }

    override func tearDown() {
        window?.orderOut(nil)
        super.tearDown()
    }

    /// NSApp isn't running in the test process: dequeue and dispatch posted events here, then spin the run loop briefly.
    private func pump() {
        while let e = NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) { NSApp.sendEvent(e) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    /// Sends one command and spins the main run loop until the reply arrives.
    private func run(_ p: StagePointer) throws -> [String: Any] {
        let line = String(decoding: try JSONSerialization.data(withJSONObject: p.fields), as: UTF8.self)
        var reply: String?
        Wispstage.handle(line) { reply = $0 }
        let deadline = Date().addingTimeInterval(5)
        while reply == nil, Date() < deadline { pump() }
        pump()
        return try XCTUnwrap(reply.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
    }

    func test_clickOnNonKeyWindowCountsAsFirstClickAlreadyPassed() throws {
        let r = try run(.click(window: window.windowNumber, at: CGPoint(x: 30, y: 40), count: 2, modifiers: [.cmd]))
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r)")
        XCTAssertEqual(view.downs, 2)
        XCTAssertEqual(view.ups, 2)
        XCTAssertEqual(view.lastDownClicks, 2)
        XCTAssert(view.lastDownMods.contains(.command))
        XCTAssert(Wispstage.keyTarget === window)
        XCTAssertFalse(window.isKeyWindow)
    }

    func test_rightClickAndOutsideWindowNumber() throws {
        _ = try run(.click(window: window.windowNumber, at: CGPoint(x: 30, y: 40), right: true))
        XCTAssertEqual(view.rightDowns, 1)
        let bad = try run(.click(window: 999_999, at: .zero))
        XCTAssertEqual(bad["ok"] as? Bool, false)
    }

    func test_dragSendsDownDraggedSteps_andUp() throws {
        _ = try run(.drag(window: window.windowNumber, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 70), steps: 4))
        XCTAssertEqual(view.downs, 1)
        XCTAssertEqual(view.drags, 4)
        XCTAssertEqual(view.ups, 1)
    }

    func test_downMoveUpHoldTheButtonAcrossCommands() throws {
        _ = try run(.down(window: window.windowNumber, at: CGPoint(x: 10, y: 10)))
        _ = try run(.move(window: window.windowNumber, to: CGPoint(x: 40, y: 10), steps: 3))
        XCTAssertEqual(view.ups, 0)
        let again = try run(.down(window: window.windowNumber, at: CGPoint(x: 10, y: 10)))
        XCTAssertEqual(again["ok"] as? Bool, false, "down while already held must fail")
        _ = try run(.up(window: window.windowNumber, at: CGPoint(x: 40, y: 10)))
        XCTAssertEqual(view.downs, 1)
        XCTAssertEqual(view.drags, 3)
        XCTAssertEqual(view.ups, 1)
        XCTAssertEqual(try run(.up(window: window.windowNumber, at: .zero))["ok"] as? Bool, false, "up without a down must fail")
    }

    /// The cursor doesn't move, so the system sends no tracking-area enter or exit: the stage sends them for the hover point.
    func test_hoverEntersAndThenExitsTrackingArea() throws {
        _ = try run(.hover(window: window.windowNumber, at: CGPoint(x: 30, y: 40)))
        XCTAssertEqual(view.entered, 1)
        XCTAssertEqual(view.exited, 0)
        _ = try run(.hover(window: window.windowNumber, at: CGPoint(x: 100, y: 40)))
        XCTAssertEqual(view.exited, 1)
    }

    func test_scrollReachesViewUnderPoint() throws {
        _ = try run(.scroll(window: window.windowNumber, at: CGPoint(x: 30, y: 40), dy: -120))
        XCTAssertEqual(view.scrolls.count, 1)
        XCTAssertEqual(view.scrolls.first.map { $0 < 0 }, true)
    }

    /// `status` reports the keyboard target's first responder: while a text field is being edited the first responder is the field editor, and the text field it edits is reported.
    func test_statusReportsFirstResponderOfKeyTarget() throws {
        let field = NSTextField(frame: NSRect(x: 64, y: 10, width: 50, height: 22))
        field.setAccessibilityIdentifier("answer")
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        XCTAssert(window.makeFirstResponder(field))
        let s = StageStatus(reply: try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Wispstage.reply(to: #"{"cmd":"status"}"#).utf8)) as? [String: Any]))
        XCTAssertEqual(s.keyTarget, window.windowNumber)
        XCTAssertEqual(s.firstResponder?.id, "answer")
        XCTAssertEqual(s.firstResponder?.role, NSAccessibility.Role.textField.rawValue)
        let screen = window.convertToScreen(field.convert(field.bounds, to: nil))
        let height = NSScreen.screens.first?.frame.height ?? 0
        XCTAssertEqual(s.firstResponder?.frame, CGRect(x: screen.minX, y: height - screen.maxY, width: screen.width, height: screen.height))
    }

    func test_statusHasNoFirstResponderWhenWindowItselfIs() throws {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        let reply = Wispstage.reply(to: #"{"cmd":"status"}"#)
        XCTAssertNil(StageStatus(reply: try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])).firstResponder, reply)
    }

    /// Over the socket: the driver-side `StageClient.pointer` returns only when the gesture is done.
    func test_clientPointerWaitsForGesture() throws {
        let path = NSTemporaryDirectory() + "wispstage-ptr-\(getpid()).sock"
        let server = try XCTUnwrap(StageServer(path: path) { line, done in
            DispatchQueue.main.async { MainActor.assumeIsolated { Wispstage.handle(line, reply: done) } }
        })
        _ = server
        let client = try StageClient(path: path, timeout: 2)
        defer { client.disconnect() }
        let n = window.windowNumber
        nonisolated(unsafe) var result: Result<Void, Error>?
        Thread.detachNewThread { result = Result { try client.pointer(.drag(window: n, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 10), steps: 3)) } }
        let deadline = Date().addingTimeInterval(5)
        while result == nil, Date() < deadline { pump() }
        pump()
        XCTAssertNoThrow(try result?.get())
        XCTAssertEqual(view.ups, 1)
    }
}

/// Synthesized enter and exit events must carry the tracking area under the point: SwiftUI's NSHostingView ignores enter events whose `trackingArea` is nil,
/// and the hover style (onHover) never appears (measured 2026-10-15, macOS 27.2: changing only this in the same binary flipped a hover scenario between pass and fail).
@MainActor
final class StageEnterExitTests: XCTestCase {
    override func setUpWithError() throws { try GUISession.require() }

    func testEnterAndExitEventsCarryTheTrackingArea() throws {
        // A window that never comes on screen: only for its window number, no orderFront, never key.
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        let view = NSView(frame: w.contentView!.bounds)
        w.contentView!.addSubview(view)
        let area = NSTrackingArea(rect: view.bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: view, userInfo: nil)
        view.addTrackingArea(area)
        for type in [NSEvent.EventType.mouseEntered, .mouseExited] {
            let e = try XCTUnwrap(StagePointerInput.enterExit(type, NSPoint(x: 10, y: 10), in: w, area: area))
            XCTAssertTrue(e.trackingArea === area, "\(type) event has no tracking area")
        }
    }
}

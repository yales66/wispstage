import AppKit
import SwiftUI
import Testing
import XCTest
@testable import Wispstage
import WispstageClient

/// The stage is installed once in this process (the exchanged methods apply globally) and shared by all tests; windows created after that are pinned to
/// the minimum level as soon as they come on screen, out of the user's sight. The test process isn't frontmost and its windows aren't key, which is exactly the situation of an app under test on the stage.
@MainActor
enum Fixture {
    static let socketPath = NSTemporaryDirectory() + "wispstage-stage-test-\(getpid()).sock"
    private(set) static var events: [StageEvent] = []

    static func stage() {
        Wispstage.install(.init(enabled: true, socketPath: socketPath))
        Wispstage.onEvent = { events.append($0) }
    }

    static func clearEvents() { events = [] }
    static func named(_ n: String) -> [StageEvent] { events.filter { $0.name == n } }

    static func window<W: NSWindow>(_ type: W.Type = NSWindow.self as! W.Type) -> W {
        stage()
        let w = W(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    /// A key arriving from outside via postToPid: window number 0.
    static func externalKey(_ chars: String, keyCode: UInt16, type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                      isARepeat: false, keyCode: keyCode))
    }

    static func deliver(_ e: NSEvent) { NSApp.sendEvent(e) }

    static let esc: (String, UInt16) = ("\u{1b}", 53)
    static let ret: (String, UInt16) = ("\r", 36)
    static let a: (String, UInt16) = ("a", 0)
}

final class CountingWindow: NSWindow {
    var cancels = 0
    var newlines = 0
    var keyEquivalents = 0
    override func cancelOperation(_ sender: Any?) { cancels += 1 }
    override func insertNewline(_ sender: Any?) { newlines += 1 }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyEquivalents += 1
        return super.performKeyEquivalent(with: event)
    }
}

/// A view that consumes every key itself (like a text field).
final class SwallowingView: NSView {
    var keys = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keys += 1 }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class Target: NSObject {
    var fired = 0
    @objc func fire(_ sender: Any?) { fired += 1 }
}

@Suite struct OptionsTests {
    @Test(arguments: [
        ([String: String](), false, nil as String?),
        (["WISPSTAGE_STAGE": "1"], true, nil),
        (["WISPSTAGE_STAGE": "1", "WISPSTAGE_STAGE_SOCKET": "/tmp/s.sock"], true, "/tmp/s.sock"),
        (["WISPSTAGE_STAGE": "1", "WISPSTAGE_STAGE_SOCKET": ""], true, nil),
        (["WISPSTAGE_STAGE": "0", "WISPSTAGE_STAGE_SOCKET": "/tmp/s.sock"], false, "/tmp/s.sock"),
    ])
    func readsEnvironment(_ env: [String: String], _ enabled: Bool, _ socket: String?) {
        let o = Wispstage.Options(environment: env)
        #expect(o.enabled == enabled)
        #expect(o.socketPath == socket)
    }

    @MainActor @Test func installDoesNothingWhenNotRequested() {
        #expect(!Wispstage.install(.init(enabled: false)) || Wispstage.isActive)
    }
}

@Suite struct StageEventTests {
    @Test func encodesOneSortedLineAndParsesBack() throws {
        let line = StageEvent.encode(StageEvent.beep, ["keyCode": 53, "window": 7])
        #expect(line == #"{"event":"stage.beep","keyCode":53,"window":7}"#)
        let e = try #require(StageEvent(line: line))
        #expect(e.name == "stage.beep")
        #expect(e.int("keyCode") == 53)
    }

    @Test(arguments: ["", "{}", #"{"ok":true}"#, "not json"])
    func rejectsLinesWithoutEventName(_ line: String) {
        #expect(StageEvent(line: line) == nil)
    }

    @Test func splitsLinesAcrossChunks() {
        var s = LineSplitter()
        #expect(s.feed(Data("a\r\nb".utf8)) == ["a"])
        #expect(s.feed(Data("c\n\n".utf8)) == ["bc", ""])
    }
}

/// Runs under XCTest: under swift-testing's async entry point, AppKit reading the event queue makes the main run loop return and the process exit (measured 2026-10-14).
@MainActor final class StageTests: XCTestCase {
    override func setUpWithError() throws { try GUISession.require() }

    // MARK: Point 1: pinning levels

    func test_pinsEveryLevelToMinimumAndRemembersTheAskedOne() {
        let w = Fixture.window(NSPanel.self)
        w.level = .floating
        XCTAssert(w.level == Wispstage.level)
        XCTAssert(Wispstage.requestedLevel(of: w) == .floating)
        w.orderFront(nil)
        defer { w.orderOut(nil) }
        XCTAssert(w.ignoresMouseEvents)
        XCTAssert(w.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssert(NSApp.activationPolicy() == .accessory)
        // A window that never set its own level still reports normal as its requested level after pinning
        let plain = Fixture.window()
        plain.orderFront(nil)
        defer { plain.orderOut(nil) }
        XCTAssert(plain.level == Wispstage.level)
        XCTAssert(Wispstage.requestedLevel(of: plain) == .normal)
    }

    /// A window with only canJoinAllSpaces is off screen while another app's full-screen Space is in front; fullScreenAuxiliary lets it join that Space too.
    func test_pinnedWindowJoinsFullScreenSpacesAndPinRestoresAfterReset() {
        let w = Fixture.window()
        w.orderFront(nil)
        defer { w.orderOut(nil) }
        XCTAssert(w.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
        // SwiftUI may later replace collectionBehavior; the next pin (the pin timer) must bring both back
        w.collectionBehavior = .fullScreenPrimary
        StageWindows.pin(w)
        XCTAssert(w.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
        XCTAssert(!w.collectionBehavior.contains(.moveToActiveSpace))
    }

    // MARK: Point 2: intercepting key and activation

    func test_makeKeyIsRecordedAsKeyTargetInsteadOfTakingKeyboard() {
        let p = Fixture.window(KeyablePanel.self)
        defer { p.orderOut(nil) }
        Fixture.clearEvents()
        Wispstage.keyTarget = nil
        p.makeKeyAndOrderFront(nil)
        XCTAssert(p.isVisible)
        XCTAssert(!p.isKeyWindow)
        XCTAssert(Wispstage.keyTarget === p)
        Wispstage.keyTarget = nil
        p.makeKey()
        XCTAssert(!p.isKeyWindow)
        XCTAssert(Wispstage.keyTarget === p)
        XCTAssert(Fixture.named(StageEvent.keyRequested).map { $0.int("window") } == [p.windowNumber, p.windowNumber])
        XCTAssert(Fixture.named(StageEvent.becameKey).isEmpty)
    }

    /// A mouse down makes a window key through AppKit's click path (not through makeKey): a panel that doesn't activate its app and becomes key only if
    /// needed becomes key when clicked on a text field (for example, a quick-entry panel whose text field becomes key on click). On the stage this must be
    /// intercepted, recorded as the keyboard target, and `stage.keyRequested` emitted.
    func test_mouseDownOnFieldInNonactivatingPanelIsRecordedNotKey() throws {
        Fixture.stage()
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 60), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 120, height: 22))
        p.contentView?.addSubview(field)
        p.orderFront(nil)
        defer { p.orderOut(nil) }
        Wispstage.keyTarget = nil
        Fixture.clearEvents()
        let at = NSPoint(x: field.frame.midX, y: field.frame.midY)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: p.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                                             pressure: type == .leftMouseDown ? 1 : 0))
        }
        // Queue the mouse up first: on mouse down the text field enters its own tracking loop and waits for the mouse up from the queue
        NSApp.postEvent(try mouse(.leftMouseUp), atStart: false)
        Fixture.deliver(try mouse(.leftMouseDown))
        XCTAssert(!p.isKeyWindow)
        XCTAssertEqual(Fixture.named(StageEvent.becameKey).count, 0)
        XCTAssert(Wispstage.keyTarget === p)
        XCTAssert(Fixture.named(StageEvent.keyRequested).contains { $0.int("window") == p.windowNumber && $0["via"] as? String == "mouseDown" })
    }

    func test_activationOfThisProcessIsRecordedNotPerformed() async throws {
        Fixture.stage()
        Fixture.clearEvents()
        NSApp.activate()
        NSApp.activate(ignoringOtherApps: true)
        XCTAssert(NSRunningApplication.current.activate(options: []))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssert(!NSApp.isActive)
        XCTAssertEqual(Fixture.named(StageEvent.activateRequested).compactMap { $0["via"] as? String },
                ["NSApp.activate", "NSApp.activate(ignoringOtherApps:)", "NSRunningApplication.activate(options:)"])
    }

    // MARK: Point 3: keyboard dispatch

    private func shown<W: NSWindow>(_ type: W.Type) -> W {
        let w = Fixture.window(type)
        w.makeKeyAndOrderFront(nil)
        XCTAssert(Wispstage.keyTarget === w)
        XCTAssert(NSApp.keyWindow == nil)
        return w
    }

    func test_localMonitorSeesExternalKeyOnKeyTarget() throws {
        let w = shown(CountingWindow.self)
        defer { w.orderOut(nil) }
        var seen: [Int] = []
        let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in seen.append(e.windowNumber); return e.window === w ? nil : e }
        defer { m.map(NSEvent.removeMonitor) }
        Fixture.deliver(try Fixture.externalKey(Fixture.a.0, keyCode: Fixture.a.1))
        XCTAssert(seen == [w.windowNumber])
    }

    func test_escOnKeyTargetBecomesCancelOperationOnce() throws {
        let w = shown(CountingWindow.self)
        defer { w.orderOut(nil) }
        Fixture.deliver(try Fixture.externalKey(Fixture.esc.0, keyCode: Fixture.esc.1))
        XCTAssert(w.cancels == 1)
        XCTAssert(w.newlines == 0)
    }

    /// `NSApplication.sendEvent:` hands keys to the private `_keyWindow` without looking at the event's window number. While the app isn't frontmost the
    /// public `keyWindow` is nil, yet `_keyWindow` can still point at another window (for example, a main window opened earlier). In real use the keyboard
    /// target is the key window and keys reach only it; that older window must not receive the key and swallow Esc as its own cancelOperation:.
    func test_keyGoesOnlyToKeyTargetWhenAppKitHoldsAnotherKeyWindow() throws {
        let other = Fixture.window(CountingWindow.self)
        other.orderFront(nil)
        defer { other.orderOut(nil) }
        // The exchanged method name calls AppKit's original makeKey: an ordinary window in an app that isn't frontmost doesn't take over the system keyboard, AppKit only records it
        other.wispstage_makeKey()
        XCTAssert(NSApp.keyWindow == nil)
        XCTAssert((NSApp.value(forKey: "_keyWindow") as? NSWindow) === other, "precondition: AppKit's _keyWindow points at another window")
        let w = shown(CountingWindow.self)
        defer { w.orderOut(nil) }
        Fixture.deliver(try Fixture.externalKey(Fixture.esc.0, keyCode: Fixture.esc.1))
        XCTAssertEqual(other.cancels, 0)
        XCTAssertEqual(w.cancels, 1)
    }

    func test_returnPressesDefaultButtonBeforeFirstResponder() throws {
        let w = shown(CountingWindow.self)
        defer { w.orderOut(nil) }
        let target = Target()
        let b = NSButton(title: "OK", target: target, action: #selector(Target.fire(_:)))
        b.keyEquivalent = "\r"
        w.contentView?.addSubview(b)
        Fixture.deliver(try Fixture.externalKey(Fixture.ret.0, keyCode: Fixture.ret.1))
        XCTAssert(target.fired == 1)
        XCTAssert(w.newlines == 0)
        XCTAssert(w.keyEquivalents == 1)
    }

    func test_keyConsumedByFirstResponderIsNotInterpretedAgain() throws {
        let w = shown(CountingWindow.self)
        defer { w.orderOut(nil) }
        let v = SwallowingView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        w.contentView?.addSubview(v)
        XCTAssert(w.makeFirstResponder(v))
        Fixture.deliver(try Fixture.externalKey(Fixture.esc.0, keyCode: Fixture.esc.1))
        XCTAssert(v.keys == 1)
        XCTAssert(w.cancels == 0)
    }

    func test_typingLandsInFocusedFieldOfKeyTarget() throws {
        let w = shown(NSWindow.self)
        defer { w.orderOut(nil) }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        w.contentView?.addSubview(field)
        XCTAssert(w.makeFirstResponder(field))
        Fixture.deliver(try Fixture.externalKey(Fixture.a.0, keyCode: Fixture.a.1))
        XCTAssert(field.stringValue == "a" || (w.firstResponder as? NSTextView)?.string == "a")
    }

    /// Esc while a SwiftUI text field in a panel has focus: in real use (the panel is key) Esc closes the panel.
    func test_escInFocusedSwiftUIFieldReachesPanelCancel() throws {
        let w = shown(CountingWindow.self)
        defer { w.orderOut(nil) }
        struct V: View { @State var t = "abc"; var body: some View { TextField("x", text: $t).frame(width: 100) } }
        let host = NSHostingView(rootView: V())
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 40)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        func find(_ v: NSView) -> NSTextField? { (v as? NSTextField) ?? v.subviews.lazy.compactMap(find).first }
        let field = try XCTUnwrap(find(host))
        XCTAssert(w.makeFirstResponder(field))
        Fixture.deliver(try Fixture.externalKey(Fixture.esc.0, keyCode: Fixture.esc.1))
        XCTAssertEqual(w.cancels, 1)
    }

    // MARK: Point 4: beeps

    func test_unhandledKeyIsReportedInsteadOfBeep() throws {
        let w = shown(NSWindow.self)
        defer { w.orderOut(nil) }
        Fixture.clearEvents()
        Fixture.deliver(try Fixture.externalKey(Fixture.a.0, keyCode: Fixture.a.1))
        let beeps = Fixture.named(StageEvent.beep)
        XCTAssert(beeps.count == 1)
        XCTAssert(beeps.first?.int("keyCode") == 0)
        XCTAssert(beeps.first?.int("window") == w.windowNumber)
    }

    // MARK: Global event monitors (point 6)

    /// A mouse event with window number 0 (what a global monitor receives: the location is in screen coordinates).
    private func screenMouse(_ type: NSEvent.EventType, at p: NSPoint = .zero) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Real events AppKit hands to global monitors (the user clicking in another app on the same Mac) don't reach the app's handlers; `stage.globalEventDropped` is emitted.
    /// A test can't produce a real global event (that would mean posting events to the system), so this calls the wrapper the stage gives AppKit directly.
    func test_realGlobalEventIsDroppedAndReported() throws {
        Fixture.stage()
        Fixture.clearEvents()
        var called = 0
        let handler = StageGlobalMonitors.guarded { _ in called += 1 }
        handler(try screenMouse(.leftMouseDown))
        handler(try screenMouse(.rightMouseDown))
        XCTAssertEqual(called, 0)
        XCTAssertEqual(Fixture.named(StageEvent.globalEventDropped).compactMap { $0["type"] as? String }, ["leftMouseDown", "rightMouseDown"])
    }

    /// The `globalEvent` command hands a synthesized event to registered global monitor handlers whose mask matches, and stops after removal. Coordinates are given with the screen's top-left as origin.
    func test_globalEventCommandReachesRegisteredMonitors() throws {
        Fixture.stage()
        var clicks: [NSEvent] = []
        var keys = 0
        let m = try XCTUnwrap(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { clicks.append($0) })
        let k = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in keys += 1 }
        defer { k.map(NSEvent.removeMonitor) }
        let reply = Wispstage.reply(to: #"{"cmd":"globalEvent","type":"leftMouseDown","x":100,"y":200}"#)
        XCTAssert(reply.contains(#""delivered":1"#) && reply.contains(#""ok":true"#), reply)
        XCTAssertEqual(clicks.map(\.type), [.leftMouseDown])
        XCTAssertEqual(keys, 0)
        let height = NSScreen.screens.first?.frame.height ?? 0
        XCTAssertEqual(clicks.first?.locationInWindow, NSPoint(x: 100, y: height - 200))
        NSEvent.removeMonitor(m)
        XCTAssert(Wispstage.reply(to: #"{"cmd":"globalEvent","type":"leftMouseDown","x":0,"y":0}"#).contains(#""delivered":0"#))
        XCTAssertEqual(clicks.count, 1)
        XCTAssert(Wispstage.reply(to: #"{"cmd":"globalEvent","type":"nope","x":0,"y":0}"#).contains(#""ok":false"#))
    }

    /// Driver side: `StageClient.globalEvent` sends the command, waits for the reply, and returns how many handlers received it.
    func test_clientGlobalEventReturnsDeliveredCount() throws {
        Fixture.stage()
        var clicks = 0
        let m = try XCTUnwrap(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in clicks += 1 })
        defer { NSEvent.removeMonitor(m) }
        let client = try StageClient(path: Fixture.socketPath, timeout: 2)
        defer { client.disconnect() }
        // The stage answers commands on the main thread: send the request from a background thread and spin the main run loop
        nonisolated(unsafe) var result: Result<Int, Error>?
        Thread.detachNewThread { result = Result { try client.globalEvent("leftMouseDown", x: 10, y: 10, timeout: 2) } }
        XCTAssert(waitUntil { result != nil })
        XCTAssertEqual(try result?.get(), 1)
        XCTAssertEqual(clicks, 1)
    }

    // MARK: Channel

    func test_driverConnectingLateGetsEarlierEventsAndStatus() throws {
        let w = shown(NSWindow.self)
        defer { w.orderOut(nil) }
        let client = try StageClient(path: Fixture.socketPath, timeout: 2)
        defer { client.disconnect() }
        let got = waitUntil { client.events.contains { $0.name == StageEvent.keyRequested && $0.int("window") == w.windowNumber } }
        XCTAssert(got)
        try client.send(#"{"cmd":"status"}"#)
        XCTAssert(waitUntil { client.replies.contains { $0.contains(#""keyTarget":\#(w.windowNumber)"#) && $0.contains(#""ok":true"#) } })
    }

    /// The server receives commands on a background thread and answers on the main thread: spin the main run loop here while waiting.
    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() >= deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }
}

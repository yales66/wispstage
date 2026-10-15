import AppKit
import ObjectiveC
import Testing
import XCTest
@testable import Wispstage
import WispstageClient

@Suite struct StageModeTests {
    @Test(arguments: [
        ("1", Wispstage.Mode.background as Wispstage.Mode?),
        ("observe", .observe),
        ("0", nil), ("", nil), ("OBSERVE", nil), ("yes", nil),
    ])
    func parsesEnvironmentValue(_ value: String, _ mode: Wispstage.Mode?) {
        #expect(Wispstage.Options(environment: ["WISPSTAGE_STAGE": value]).mode == mode)
    }

    @Test func unsetMeansOff() {
        #expect(Wispstage.Options(environment: [:]).mode == nil)
        #expect(!Wispstage.Options(environment: [:]).enabled)
    }

    @Test func observedFieldMarksObserveEvents() throws {
        let e = try #require(StageEvent(line: StageEvent.encode(StageEvent.beep, ["keyCode": 0, StageEvent.observedField: true])))
        #expect(e.observed)
        #expect(!(try #require(StageEvent(line: #"{"event":"stage.beep","keyCode":0}"#))).observed)
    }
}

/// Observe-only mode must be tested in a process that never installed background mode: other tests in this target install background mode
/// (`Fixture.stage()`), which can't be uninstalled, so within one process you can't verify that observe-only mode installed none of the background-mode
/// hooks. This launches a separate xctest process that runs only `ObserveModeChildTests`.
final class ObserveModeIsolationTests: XCTestCase {
    override func setUpWithError() throws { try GUISession.require() }

    func test_observeModeChecksPassInAFreshProcess() throws {
        let bundle = Bundle(for: ObserveModeChildTests.self).bundleURL
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["xctest", "-XCTest", "WispstageTests.ObserveModeChildTests", bundle.path]
        var env = ProcessInfo.processInfo.environment
        env[ObserveModeChildTests.childKey] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, 0, text)
        // The child process actually ran the test rather than skipping everything
        XCTAssertTrue(text.contains("Executed 1 test, with 0 failures"), text)
    }
}

/// Runs only in the child process launched by `ObserveModeIsolationTests` (environment variable `childKey`); skipped in the parent process.
/// The child process puts nothing on screen, doesn't activate and makes no sound: before observe-only mode is installed, the original implementations of
/// activation and noResponderFor: are replaced with counting doubles, so the "original implementation" the wrappers call is the double; windows are created
/// but never ordered on screen, and the test posts the notifications itself.
@MainActor
final class ObserveModeChildTests: XCTestCase {
    nonisolated static let childKey = "WISPSTAGE_OBSERVE_CHILD"

    private struct Counts {
        var activate = 0
        var activateIgnoring: [Bool] = []
        var runningOptions = 0
        var runningFrom = 0
        var noResponder: [Selector] = []
    }
    nonisolated(unsafe) private static var counts = Counts()

    /// Methods background mode replaces (`StageWindows`, `StageKeys`, `StageGlobalMonitors`): instance method IMPs and class method IMPs.
    private static let instanceMethods: [(AnyClass, String)] = [
        (NSWindow.self, "sendEvent:"), (NSApplication.self, "sendEvent:"), (NSWindow.self, "keyDown:"),
        (NSWindow.self, "setLevel:"), (NSWindow.self, "orderFront:"), (NSWindow.self, "makeKeyAndOrderFront:"),
        (NSWindow.self, "orderFrontRegardless"), (NSWindow.self, "orderWindow:relativeTo:"), (NSWindow.self, "makeKeyWindow"),
        (NSWindow.self, "_changeKeyAndMainLimitedOK:"),
    ]
    private static let classMethods: [(AnyClass, String)] = [
        (NSEvent.self, "addLocalMonitorForEventsMatchingMask:handler:"),
        (NSEvent.self, "addGlobalMonitorForEventsMatchingMask:handler:"),
        (NSEvent.self, "removeMonitor:"),
    ]

    private static func imps() -> [String: IMP?] {
        var out: [String: IMP?] = [:]
        for (c, n) in instanceMethods { out["-\(c) \(n)"] = class_getInstanceMethod(c, NSSelectorFromString(n)).map(method_getImplementation) }
        for (c, n) in classMethods { out["+\(c) \(n)"] = class_getClassMethod(c, NSSelectorFromString(n)).map(method_getImplementation) }
        return out
    }

    private static func double(_ cls: AnyClass, _ name: String, _ block: Any) {
        let m = class_getInstanceMethod(cls, NSSelectorFromString(name))!
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    private static func installDoubles() {
        let a: @convention(block) (AnyObject) -> Void = { _ in counts.activate += 1 }
        double(NSApplication.self, "activate", a)
        let b: @convention(block) (AnyObject, Bool) -> Void = { _, flag in counts.activateIgnoring.append(flag) }
        double(NSApplication.self, "activateIgnoringOtherApps:", b)
        // Returns false: the wrapper must pass back the original implementation's return value unchanged
        let c: @convention(block) (AnyObject, UInt) -> Bool = { _, _ in counts.runningOptions += 1; return false }
        double(NSRunningApplication.self, "activateWithOptions:", c)
        let d: @convention(block) (AnyObject, AnyObject?, UInt) -> Bool = { _, _, _ in counts.runningFrom += 1; return false }
        double(NSRunningApplication.self, "activateFromApplication:options:", d)
        let e: @convention(block) (AnyObject, Selector) -> Void = { _, sel in counts.noResponder.append(sel) }
        double(NSResponder.self, "noResponderFor:", e)
    }

    func test_observeMode() throws {
        guard ProcessInfo.processInfo.environment[Self.childKey] == "1" else {
            throw XCTSkip("runs only in the child process launched by ObserveModeIsolationTests")
        }
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        Self.installDoubles()
        let before = Self.imps()
        var events: [StageEvent] = []
        Wispstage.onEvent = { events.append($0) }

        // Install observe-only mode: the return value reports only background mode, so the host skips what it does alongside background mode (such as the open event at a preview entry point)
        XCTAssertFalse(Wispstage.install(.init(mode: .observe)))
        XCTAssertEqual(Wispstage.mode, .observe)
        XCTAssertFalse(Wispstage.isActive)
        XCTAssertEqual(Self.imps().mapValues { $0.map(String.init(describing:)) },
                       before.mapValues { $0.map(String.init(describing:)) }, "observe-only mode replaced background-mode methods")
        XCTAssertEqual(NSApp.activationPolicy(), policy)

        // The window level stays as the app set it: not pinned
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.level = .floating
        XCTAssertEqual(w.level, .floating)

        // (a) Becoming key: reported synchronously as soon as the notification posts (queue nil)
        events = []
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w)
        XCTAssertEqual(events.map(\.name), [StageEvent.becameKey])
        XCTAssertEqual(events.first?.int("window"), w.windowNumber)
        XCTAssertEqual(events.first?.observed, true)

        // (b) Activation requests: reported first, then the original implementation is called and its return value passed back unchanged
        events = []
        NSApp.activate()
        XCTAssertEqual(Self.counts.activate, 1)
        NSApp.activate(ignoringOtherApps: true)
        XCTAssertEqual(Self.counts.activateIgnoring, [true])
        XCTAssertFalse(NSRunningApplication.current.activate(options: []))
        XCTAssertEqual(Self.counts.runningOptions, 1)
        XCTAssertFalse(NSRunningApplication.current.activate(from: NSRunningApplication.current, options: []))
        XCTAssertEqual(Self.counts.runningFrom, 1)
        XCTAssertEqual(events.map(\.name), Array(repeating: StageEvent.activateRequested, count: 4))
        XCTAssertEqual(events.compactMap { $0["via"] as? String },
                       ["NSApp.activate", "NSApp.activate(ignoringOtherApps:)", "NSRunningApplication.activate(options:)",
                        "NSRunningApplication.activate(from:options:)"])
        XCTAssertTrue(events.allSatisfy(\.observed))
        // Activation of other processes isn't recorded; the original implementation is called
        events = []
        let other = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0.processIdentifier != getpid() })
        _ = other.activate(options: [])
        XCTAssertEqual(Self.counts.runningOptions, 2)
        XCTAssertTrue(events.isEmpty)
        // Actual activation
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertEqual(events.map(\.name), [StageEvent.becameActive])
        XCTAssertEqual(events.first?.observed, true)

        // (c) An unhandled keyDown: reports stage.beep and calls the original implementation; other selectors aren't reported and are also called
        events = []
        let r = NSResponder()
        r.noResponder(for: #selector(NSResponder.keyDown(with:)))
        XCTAssertEqual(Self.counts.noResponder, [#selector(NSResponder.keyDown(with:))])
        XCTAssertEqual(events.map(\.name), [StageEvent.beep])
        XCTAssertEqual(events.first?.observed, true)
        r.noResponder(for: #selector(NSResponder.mouseDown(with:)))
        XCTAssertEqual(Self.counts.noResponder.count, 2)
        XCTAssertEqual(events.count, 1)

        // The modes are mutually exclusive: a later request for background mode isn't installed
        XCTAssertFalse(Wispstage.install(.init(mode: .background)))
        XCTAssertFalse(Wispstage.isActive)
        XCTAssertEqual(Wispstage.mode, .observe)
        XCTAssertEqual(Self.imps().mapValues { $0.map(String.init(describing:)) },
                       before.mapValues { $0.map(String.init(describing:)) })
    }
}

import CoreGraphics
import Testing
@testable import WispstageKit
import WispstageClient

struct InputModeTests {
    @Test(arguments: [
        (nil, InputMode.inprocess), ("", .inprocess), ("inprocess", .inprocess), ("hid", .hid),
    ] as [(String?, InputMode)])
    func inputModeDefaultsToInprocess(_ raw: String?, _ mode: InputMode) throws {
        #expect(try InputMode.parse(raw) == mode)
    }

    @Test func invalidInputModeThrows() {
        #expect(throws: E2EFailure.self) { try InputMode.parse("cgevent") }
    }
}

struct PointerTargetTests {
    @Test(arguments: [
        ([] as [Mods], [] as [StagePointer.Modifier]),
        ([.command, .shift], [.cmd, .shift]),
        ([.option, .control], [.opt, .ctrl]),
    ])
    func modifiersMapToStageNames(_ mods: [Mods], _ names: [StagePointer.Modifier]) {
        #expect(PointerTarget.modifiers(Mods(mods)) == names)
    }

    @Test func pointLandsInFrontmostWindowWithCoordinatesFromItsTopLeft() {
        let windows: [(id: Int, frame: CGRect)] = [
            (30, CGRect(x: 900, y: 40, width: 300, height: 100)),
            (11, CGRect(x: 100, y: 50, width: 1200, height: 744)),
        ]
        let hit = PointerTarget.window(containing: CGPoint(x: 1000, y: 60), in: windows)
        #expect(hit?.id == 30)
        #expect(hit?.local == CGPoint(x: 100, y: 20))
        #expect(PointerTarget.window(containing: CGPoint(x: 150, y: 60), in: windows)?.id == 11)
        #expect(PointerTarget.window(containing: CGPoint(x: 5, y: 5), in: windows) == nil)
    }
}

/// When Accessibility cannot read the focus before typing and the window has more than one text field: identify it by the first responder the stage reports.
struct ResponderMatchTests {
    /// A panel with a main text field on top and an answer field below.
    private let fields: [(id: String?, frame: CGRect?)] = [
        ("panel.input", CGRect(x: 100, y: 100, width: 400, height: 30)),
        ("panel.question.answer", CGRect(x: 100, y: 300, width: 400, height: 30)),
    ]

    @Test func sameIdentifierMatches() {
        let r = StageStatus.Responder(id: "panel.question.answer", role: "AXTextField", frame: nil)
        #expect(ResponderMatch.pick(fields, responder: r) == 1)
    }

    /// SwiftUI text fields have no identifier on the AppKit side, and their frame is slightly smaller than the accessibility one: take the field containing its center.
    @Test func withoutIdentifierMatchesByFrameCenter() {
        let r = StageStatus.Responder(id: nil, role: "AXTextField", frame: CGRect(x: 104, y: 304, width: 380, height: 22))
        #expect(ResponderMatch.pick(fields, responder: r) == 1)
    }

    @Test func nestedFieldsPickTheSmallest() {
        let nested: [(id: String?, frame: CGRect?)] = [("outer", CGRect(x: 0, y: 0, width: 600, height: 600)), ("inner", CGRect(x: 100, y: 100, width: 50, height: 20))]
        let r = StageStatus.Responder(id: nil, role: nil, frame: CGRect(x: 110, y: 105, width: 10, height: 10))
        #expect(ResponderMatch.pick(nested, responder: r) == 1)
    }

    @Test(arguments: [
        StageStatus.Responder(id: nil, role: nil, frame: nil),
        StageStatus.Responder(id: "other", role: nil, frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
    ])
    func unmatchedResponderIsNil(_ r: StageStatus.Responder) {
        #expect(ResponderMatch.pick(fields, responder: r) == nil)
    }
}

struct UntouchedTests {
    private let finder = Untouched.Snapshot(cursor: CGPoint(x: 400, y: 300), frontmostPID: 100, frontmostName: "Finder")

    @Test func noProblemWhenCursorAndFrontmostAreUnchanged() {
        #expect(Untouched.problems(before: finder, after: finder, appPID: 200).isEmpty)
    }

    @Test func cursorMoveIsRecorded() {
        let moved = Untouched.Snapshot(cursor: CGPoint(x: 401, y: 300), frontmostPID: 100, frontmostName: "Finder")
        let p = Untouched.problems(before: finder, after: moved, appPID: 200)
        #expect(p.count == 1)
        #expect(p.contains { $0.contains("cursor") })
    }

    /// The user moving the mouse or trackpad during a background run is expected; only a move with no real pointer input means the run moved the cursor.
    @Test func cursorMoveIsNotRecordedWhenTheUserMovedThePointer() {
        let moved = Untouched.Snapshot(cursor: CGPoint(x: 900, y: 40), frontmostPID: 100, frontmostName: "Finder")
        #expect(Untouched.problems(before: finder, after: moved, appPID: 200, userMovedPointer: true).isEmpty)
        #expect(Untouched.problems(before: finder, after: moved, appPID: 200, userMovedPointer: false).count == 1)
    }

    @Test(arguments: [
        ("moved after the scenario started", 3.0, 10.0, true),
        ("last moved before the scenario started", 12.0, 10.0, false),
        ("never moved since boot", Double.infinity, 10.0, false),
    ] as [(String, Double, Double, Bool)])
    func userPointerInputCountsOnlyWithinTheScenario(_ name: String, sinceLastMove: Double, scenario: Double, want: Bool) {
        #expect(Untouched.userMovedPointer(secondsSinceLastMove: sinceLastMove, scenarioSeconds: scenario) == want, "\(name)")
    }

    /// The frontmost app is judged per step by ForegroundWatch: comparing it before and after the scenario would also count the user switching apps.
    @Test func frontmostChangeAcrossScenarioIsNotRecorded() {
        let switched = Untouched.Snapshot(cursor: CGPoint(x: 400, y: 300), frontmostPID: 200, frontmostName: "SampleApp")
        #expect(Untouched.problems(before: finder, after: switched, appPID: 200).isEmpty)
    }
}

struct InstanceLockTests {
    @Test func eachE2EBundleGetsItsOwnLockFileByBundleID() {
        let a = ScreenLock.instanceLockFile(bundleID: "com.example.app.e2e.0c5faf3e")
        let b = ScreenLock.instanceLockFile(bundleID: "com.example.app.e2e.feature-branch")
        #expect(a != b)
        #expect(a.lastPathComponent == "e2e-com.example.app.e2e.0c5faf3e.lock")
        #expect(a.deletingLastPathComponent() == ScreenLock.lockFile.deletingLastPathComponent())
    }
}

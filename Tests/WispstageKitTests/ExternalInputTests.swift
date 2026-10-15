import CoreGraphics
import Foundation
import Testing
@testable import WispstageKit

struct GeometricHitTests {
    /// Preorder list: 0 window; 1 button underneath; 2 panel stacked above it (later sibling, counts as on top); 3 text in the panel.
    private let frames: [CGRect?] = [
        CGRect(x: 0, y: 0, width: 400, height: 300),
        CGRect(x: 10, y: 10, width: 200, height: 100),
        CGRect(x: 100, y: 50, width: 200, height: 100),
        CGRect(x: 110, y: 60, width: 50, height: 20),
    ]
    private let depths = [0, 1, 1, 2]

    @Test(arguments: [
        (CGPoint(x: 120, y: 70), 3), // text in the panel: the deepest
        (CGPoint(x: 150, y: 90), 2), // where button and panel intersect: the later panel under the same parent is on top
        (CGPoint(x: 20, y: 20), 1),
        (CGPoint(x: 350, y: 250), 0), // window only
    ], )
    func picksDeepestElementContainingPointWithLaterSiblingsOnTop(_ p: CGPoint, _ expected: Int) {
        #expect(GeometricHit.deepest(at: p, frames: frames, depths: depths) == expected)
    }

    @Test func pointOutsideWindowHasNoHit() {
        #expect(GeometricHit.deepest(at: CGPoint(x: 500, y: 500), frames: frames, depths: depths) == nil)
    }

    @Test func elementWithoutFrameDoesNotBlockAndItsChildrenAreSearched() {
        // 0 window; 1 group without a frame; 2 button in the group
        let f: [CGRect?] = [CGRect(x: 0, y: 0, width: 100, height: 100), nil, CGRect(x: 10, y: 10, width: 20, height: 20)]
        #expect(GeometricHit.deepest(at: CGPoint(x: 15, y: 15), frames: f, depths: [0, 1, 2]) == 2)
        #expect(GeometricHit.deepest(at: CGPoint(x: 50, y: 50), frames: f, depths: [0, 1, 2]) == 0)
    }

    @Test func laterSiblingNotContainingPointFallsThroughToEarlierSiblingsChild() {
        // 0 window; 1 earlier group; 2 text in the earlier group; 3 small later button (does not contain the point)
        let f: [CGRect?] = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 0, y: 0, width: 50, height: 50),
                            CGRect(x: 5, y: 5, width: 10, height: 10), CGRect(x: 60, y: 60, width: 10, height: 10)]
        #expect(GeometricHit.deepest(at: CGPoint(x: 8, y: 8), frames: f, depths: [0, 1, 2, 1]) == 2)
    }
}

struct KeyGuardTests {
    @Test func sendsWhenAnElementIsFocused() {
        #expect(KeyGuard.decide(key: "a", modifiers: [], focusedRole: "AXTextField", defaultButton: false, cancelButton: false) == .send)
    }

    @Test(arguments: [(Key.return, true, false), (Key("enter"), true, false), (Key.esc, false, true)])
    func returnAndEscAreSentWithoutFocusWhenWindowHasDefaultOrCancelButton(_ key: Key, _ def: Bool, _ cancel: Bool) {
        #expect(KeyGuard.decide(key: key, modifiers: [], focusedRole: nil, defaultButton: def, cancelButton: cancel) == .send)
    }

    @Test(arguments: [(Key.return, false, true), (Key.esc, true, false), (Key("a"), true, true), (Key.tab, true, true)])
    func sendsWithoutReceiverForLocalEventMonitorsAndLeavesUnreceivedKeysToBeepCheck(_ key: Key, _ def: Bool, _ cancel: Bool) {
        // Keys such as Tab in a custom grid or ⌥Space in a shortcut recorder are handled by the app's local event monitors, invisible in the accessibility tree, so refusing before sending would refuse wrongly
        guard case .unverified(let note) = KeyGuard.decide(key: key, modifiers: [], focusedRole: nil, defaultButton: def, cancelButton: cancel) else {
            Issue.record("Should send and mark the receiver as unverified")
            return
        }
        #expect(note.contains("beep"))
    }

    @Test func sendsWithModifiersAndNoReceiverToo() {
        #expect(KeyGuard.decide(key: .space, modifiers: [.option], focusedRole: nil, defaultButton: false, cancelButton: false) != .send)
        guard case .unverified = KeyGuard.decide(key: .space, modifiers: [.option], focusedRole: nil, defaultButton: false, cancelButton: false) else {
            Issue.record("Should send")
            return
        }
    }

    @Test func focusedWholeApplicationIsNotAReceiver() {
        #expect(KeyGuard.decide(key: "a", modifiers: [], focusedRole: "AXApplication", defaultButton: false, cancelButton: false) != .send)
    }

    @Test func returnWithModifiersIsNotTheDefaultButtonShortcut() {
        #expect(KeyGuard.decide(key: .return, modifiers: [.command], focusedRole: nil, defaultButton: true, cancelButton: false) != .send)
    }
}

struct MenuShortcutTests {
    // AXMenuItemCmdModifiers: 0 is ⌘ only, 1 adds ⇧, 2 adds ⌥, 4 adds ⌃, 8 removes ⌘
    @Test(arguments: [
        ("A", 0, Key("a"), Mods.command, true),
        ("A", 1, Key("a"), Mods([.command, .shift]), true),
        ("A", 0, Key("a"), Mods([.command, .shift]), false),
        ("N", 0, Key("a"), Mods.command, false),
        ("A", 8, Key("a"), Mods([]), true),
        ("A", 0, Key("a"), Mods([]), false),
        (",", 0, Key(","), Mods.command, true),
    ])
    func menuItemShortcutMatchesByCharacterAndModifiers(_ ch: String, _ m: Int, _ key: Key, _ mods: Mods, _ expected: Bool) {
        #expect(MenuShortcut.matches(cmdChar: ch, cmdModifiers: m, key: key, modifiers: mods) == expected)
    }
}

struct LockScreenTests {
    @Test(arguments: [
        (["CGSSessionScreenIsLocked": true] as [String: Any]?, true),
        (["CGSSessionScreenIsLocked": false], false),
        ([:], false),
        (nil, false),
    ])
    func readsLockFlagFromSessionDictionary(_ d: [String: Any]?, _ locked: Bool) {
        #expect(LockScreen.isLocked(session: d) == locked)
    }

    @Test func lockScreenExitCodeDiffersFromPassAndFail() {
        #expect(![0, 1, 2].contains(LockScreen.exitCode))
    }

    @Test func lockBetweenStepsSkipsTheStepWithoutFailing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = E2ETest(name: "x", dir: dir)
        t.screenLocked = { true }
        var ran = false
        #expect(throws: E2ESkip.self) { try t.step("x") { ran = true } }
        #expect(!ran)
        #expect(t.skipped?.reason.contains("screen locked") == true)
    }

    @Test func failureInStepWhileLockedIsAlsoSkipped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = E2ETest(name: "x", dir: dir)
        var locked = false
        t.screenLocked = { locked }
        #expect(throws: E2ESkip.self) {
            try t.step("x") { locked = true; throw E2EFailure("Element not found") }
        }
    }
}

struct ForegroundWatchTests {
    private let t0 = Date(timeIntervalSince1970: 1000)

    @Test func appUnderTestBecomingFrontmostDuringStepFails() {
        let acts = [ForegroundWatch.Activation(at: t0.addingTimeInterval(1), pid: 42, name: "SampleApp E2E")]
        let v = ForegroundWatch.violations(acts, appPID: 42, from: t0, to: t0.addingTimeInterval(2))
        #expect(v.count == 1)
        #expect(v.first?.contains("SampleApp E2E") == true)
    }

    @Test func userSwitchingBetweenOtherAppsDoesNotCount() {
        let acts = [ForegroundWatch.Activation(at: t0.addingTimeInterval(1), pid: 7, name: "Safari"),
                    ForegroundWatch.Activation(at: t0.addingTimeInterval(1.5), pid: 8, name: "Finder")]
        #expect(ForegroundWatch.violations(acts, appPID: 42, from: t0, to: t0.addingTimeInterval(2)).isEmpty)
    }

    @Test func switchOutsideThisStepDoesNotCount() {
        let acts = [ForegroundWatch.Activation(at: t0.addingTimeInterval(-1), pid: 42, name: "SampleApp E2E")]
        #expect(ForegroundWatch.violations(acts, appPID: 42, from: t0, to: t0.addingTimeInterval(2)).isEmpty)
    }
}

struct KeyRouteTests {
    /// The stage library routes keys arriving from outside through postToPid as if the keyboard target were the key window (Esc becomes cancelOperation:, local event monitors recognize the window),
    /// so keys without modifiers are always sent from outside.
    @Test(arguments: [(Key.esc, nil as String?), (Key("escape"), "AXApplication"), (Key.return, "AXButton"), (Key("enter"), nil),
                      (Key.tab, nil), (Key.left, nil), (Key("="), nil), (Key("-"), nil)])
    func keysWithoutModifiersAreSentFromOutsideWhenFocusIsNotInTextField(_ key: Key, _ role: String?) {
        #expect(KeyRoute.decide(key: key, modifiers: [], focusedRole: role) == .external)
    }

    @Test(arguments: ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"])
    func escAndReturnInTextFieldAreSentFromOutside(_ role: String) {
        #expect(KeyRoute.decide(key: .esc, modifiers: [], focusedRole: role) == .external)
        #expect(KeyRoute.decide(key: .return, modifiers: [], focusedRole: role) == .external)
    }

    @Test(arguments: [(Key("a"), "AXTextField", Mods([])), (Key.space, nil as String?, Mods.option), (Key.esc, nil, Mods.command), (Key.return, nil, Mods.shift)])
    func typedKeysAndKeysWithModifiersAreSentFromOutside(_ key: Key, _ role: String?, _ mods: Mods) {
        #expect(KeyRoute.decide(key: key, modifiers: mods, focusedRole: role) == .external)
    }

    @Test(arguments: [nil as String?, "AXApplication"])
    func returnUsesAXConfirmForFieldWhoseValueWasWrittenWithoutFocus(_ role: String?) {
        guard case .axConfirm(let note) = KeyRoute.decide(key: .return, modifiers: [], focusedRole: role, valueOnlyField: true) else {
            Issue.record("Should use AXConfirm instead")
            return
        }
        #expect(note.contains("AXConfirm"))
    }

    @Test func escIsStillSentFromOutsideWhenAValueOnlyFieldExists() {
        #expect(KeyRoute.decide(key: .esc, modifiers: [], focusedRole: nil, valueOnlyField: true) == .external)
    }

    @Test func returnIsSentFromOutsideWhenFocusIsInTextFieldRegardlessOfValueOnlyField() {
        #expect(KeyRoute.decide(key: .return, modifiers: [], focusedRole: "AXTextField", valueOnlyField: true) == .external)
    }
}

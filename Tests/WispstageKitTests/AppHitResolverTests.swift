import CoreGraphics
import Testing
@testable import WispstageKit

@Suite struct AppHitResolverTests {
    // Element table: 0 window, 1 group (child of 0), 2 button (child of 1), 3 text (child of 0), 4 another button with the same frame and role as 2 (child of 3)
    private let roles: [String?] = ["AXWindow", "AXGroup", "AXButton", "AXStaticText", "AXButton"]
    private let ids: [String?] = [nil, nil, "a.b", nil, "a.b"]
    private let frames: [CGRect?] = [CGRect(x: 0, y: 0, width: 400, height: 300), CGRect(x: 10, y: 10, width: 100, height: 50),
                                     CGRect(x: 20, y: 20, width: 40, height: 20), CGRect(x: 200, y: 100, width: 80, height: 20),
                                     CGRect(x: 20, y: 20, width: 40, height: 20)]
    private let ancestors: [[Int]] = [[], [0], [0, 1], [0], [0, 3]]

    private func resolve(_ h: AppHit?, for i: Int) -> AppHitResolver.Point {
        AppHitResolver.resolve(h, for: i, roles: roles, ids: ids, frames: frames, ancestors: ancestors)
    }

    @Test func hitOnSelfAncestorOrDescendantCountsAsOwn() {
        #expect(resolve(AppHit(role: "AXGroup", id: nil, frame: CGRect(x: 10, y: 10, width: 100, height: 50), window: 1), for: 1) == .own)
        #expect(resolve(AppHit(role: "AXWindow", id: nil, frame: CGRect(x: 0, y: 0, width: 400, height: 300), window: 1), for: 3) == .own)
        #expect(resolve(AppHit(role: "AXGroup", id: nil, frame: CGRect(x: 10.4, y: 9.6, width: 100, height: 50), window: 1), for: 2) == .own)
    }

    @Test func hitOnAnotherElementGivesTheDeepestOne() {
        #expect(resolve(AppHit(role: "AXStaticText", id: nil, frame: CGRect(x: 200, y: 100, width: 80, height: 20), window: 1), for: 1) == .element(3))
    }

    @Test func candidatesWithSameFrameAndRoleIncludingSelfCountAsOwn() {
        let h = AppHit(role: "AXButton", id: "a.b", frame: CGRect(x: 20, y: 20, width: 40, height: 20), window: 1)
        #expect(resolve(h, for: 2) == .own)
        #expect(resolve(h, for: 3) == .own)   // 4 is a descendant of 3
        #expect(resolve(h, for: 1) == .own)   // 2 is a descendant of 1
    }

    @Test func unmatchedOrUnreadableHitIsUnknown() {
        #expect(resolve(nil, for: 1) == .unknown)
        #expect(resolve(AppHit(role: "AXButton", id: "zzz", frame: CGRect(x: 20, y: 20, width: 40, height: 20), window: 1), for: 1) == .unknown)
        #expect(resolve(AppHit(role: "AXButton", id: nil, frame: nil, window: 1), for: 1) == .unknown)
    }

    @Test func pointCoveredBySameAppWindowAboveCountsAsOtherWindow() {
        let above = [CGRect(x: 300, y: 0, width: 200, height: 100)]
        #expect(AppHitResolver.coveredByWindowAbove(CGPoint(x: 350, y: 50), above: above))
        #expect(!AppHitResolver.coveredByWindowAbove(CGPoint(x: 250, y: 50), above: above))
        #expect(!AppHitResolver.coveredByWindowAbove(CGPoint(x: 350, y: 50), above: []))
    }
}

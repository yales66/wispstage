import CoreGraphics
import Testing
@testable import WispstageKit

@Suite struct VisibilityTests {
    @Test func countsOnlyPixelsWhoseChannelDifferenceSumExceedsThreshold() {
        let a: [UInt8] = [0, 0, 0, 255, 100, 100, 100, 255, 10, 10, 10, 255]
        let b: [UInt8] = [0, 0, 0, 255, 109, 108, 108, 255, 10, 10, 30, 0]
        // The second pixel differs by 9+8+8=25 > 24; the third by only 20 (alpha does not count)
        #expect(Visibility.countDiffering(a, b) == 1)
        #expect(Visibility.countDiffering(a, a) == 0)
    }

    @Test func desktopStackHasOnlyOtherWindowsNearWallpaperLayerIntersectingTarget() {
        let target = CGRect(x: 100, y: 100, width: 400, height: 300)
        let ws: [Visibility.StackWindow] = [
            .init(id: 1, layer: -2147483625, owner: "Wallpaper", frame: CGRect(x: 0, y: 0, width: 1470, height: 956)),
            .init(id: 2, layer: -2147483626, owner: nil, frame: CGRect(x: 0, y: 0, width: 1470, height: 956)),
            .init(id: 3, layer: -2147483643, owner: "SampleApp E2E", frame: target),        // the window under test itself
            .init(id: 4, layer: 0, owner: "Safari", frame: target),                         // ordinary app windows do not count
            .init(id: 5, layer: -2147483603, owner: "Finder", frame: target),               // desktop icons do not count
            .init(id: 6, layer: -2147483625, owner: "Wallpaper", frame: CGRect(x: 2000, y: 0, width: 100, height: 100)),
        ]
        #expect(Visibility.desktopStack(ws, targetID: 3, target: target) == [1, 2])
    }
}

@Suite struct WallpaperCoverTests {
    private let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
    private let target = CGRect(x: 100, y: 100, width: 400, height: 300)
    private let hiddenLayer = -2147483643

    private func wallpaper(_ frame: CGRect, id: Int = 1, alpha: Double = 1) -> Visibility.StackWindow {
        .init(id: id, layer: -2147483625, owner: "Wallpaper", frame: frame, alpha: alpha)
    }

    @Test func beneathOpaqueWallpaperCountsAsHidden() {
        #expect(Visibility.wallpaperCovers(target: target, layer: hiddenLayer, windows: [wallpaper(screen)], displays: [screen]) == nil)
    }

    @Test func otherAppWindowsOnTheUserScreenDoNotAffectTheResult() {
        let ws = [wallpaper(screen), .init(id: 9, layer: 0, owner: "Safari", frame: target, alpha: 1)]
        #expect(Visibility.wallpaperCovers(target: target, layer: hiddenLayer, windows: ws, displays: [screen]) == nil)
    }

    @Test func layerAboveWallpaperIsNotHidden() {
        let why = Visibility.wallpaperCovers(target: target, layer: -2147483624, windows: [wallpaper(screen)], displays: [screen])
        #expect(why?.contains("wallpaper") == true)
    }

    @Test func partialWallpaperCoverageIsNotHidden() {
        let half = CGRect(x: 0, y: 0, width: 300, height: 956)
        #expect(Visibility.wallpaperCovers(target: target, layer: hiddenLayer, windows: [wallpaper(half)], displays: [screen]) != nil)
    }

    @Test func translucentWallpaperDoesNotCount() {
        #expect(Visibility.wallpaperCovers(target: target, layer: hiddenLayer, windows: [wallpaper(screen, alpha: 0.5)], displays: [screen]) != nil)
    }

    // Seen on macOS 27.2 after a restart, 2026-10-15: the wallpaper window's owner is WindowManager, its name Wallpaper, its layer -2147483624.
    @Test func wallpaperWindowOwnedByWindowManagerCounts() {
        let w = Visibility.StackWindow(id: 3, layer: -2147483624, owner: "WindowManager", frame: screen, name: "Wallpaper")
        #expect(Visibility.wallpaperCovers(target: target, layer: hiddenLayer, windows: [w], displays: [screen]) == nil)
    }

    @Test func otherWindowManagerWindowsAreNotWallpaper() {
        let w = Visibility.StackWindow(id: 3, layer: -2147483624, owner: "WindowManager", frame: screen, name: "Stage")
        #expect(Visibility.wallpaperCovers(target: target, layer: hiddenLayer, windows: [w], displays: [screen]) == "no wallpaper window found")
    }

    @Test func missingWallpaperIsNotHidden() {
        #expect(Visibility.wallpaperCovers(target: target, layer: hiddenLayer, windows: [], displays: [screen]) != nil)
    }

    @Test func wallpapersOnTwoDisplaysCanCoverTogether() {
        let left = CGRect(x: 0, y: 0, width: 300, height: 956), right = CGRect(x: 300, y: 0, width: 1170, height: 956)
        let ws = [wallpaper(left), wallpaper(right, id: 2)]
        #expect(Visibility.wallpaperCovers(target: target, layer: hiddenLayer, windows: ws, displays: [left, right]) == nil)
    }

    @Test func partOfWindowOffScreenNeedsNoWallpaper() {
        let off = CGRect(x: 1300, y: 100, width: 400, height: 300)
        #expect(Visibility.wallpaperCovers(target: off, layer: hiddenLayer, windows: [wallpaper(screen)], displays: [screen]) == nil)
    }
}

/// In another app's full-screen Space there is no wallpaper window; that app's opaque window covering the whole window under test hides it as well.
@Suite struct CoverRuleTests {
    private static let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
    private static let target = CGRect(x: 100, y: 100, width: 400, height: 300)
    private static let hiddenLayer = -2147483643
    private static let ownPID: Int32 = 500

    private static func wallpaper() -> Visibility.StackWindow {
        .init(id: 1, layer: -2147483625, owner: "Wallpaper", frame: screen)
    }

    private static func app(_ frame: CGRect = screen, pid: Int32 = 900, layer: Int = 0, alpha: Double = 1, onScreen: Bool = true) -> Visibility.StackWindow {
        .init(id: 7, layer: layer, owner: "Safari", frame: frame, alpha: alpha, pid: pid, onScreen: onScreen)
    }

    @Test(arguments: [
        ("opaque wallpaper covers", [wallpaper()], true),
        ("full-screen window of another app covers", [app()], true),
        ("wallpaper and full-screen window both present", [wallpaper(), app()], true),
        ("full-screen window covers only part", [app(CGRect(x: 0, y: 0, width: 300, height: 956))], false),
        ("translucent full-screen window", [app(alpha: 0.9)], false),
        ("window of the app under test itself", [app(pid: ownPID)], false),
        ("window not on screen", [app(onScreen: false)], false),
        ("window above the normal layer", [app(layer: 3)], false),
        ("window with unknown owner pid", [Visibility.StackWindow(id: 7, layer: 0, owner: "?", frame: screen)], false),
        ("nothing covers", [], false),
    ] as [(String, [Visibility.StackWindow], Bool)])
    func decidesWhetherTheWindowUnderTestIsHidden(_ name: String, _ windows: [Visibility.StackWindow], _ hidden: Bool) {
        let why = Visibility.coverReason(target: Self.target, layer: Self.hiddenLayer, pid: Self.ownPID, windows: windows, displays: [Self.screen])
        #expect((why == nil) == hidden, "\(name): \(why ?? "hidden")")
    }

    @Test func notHiddenKeepsTheWallpaperReason() {
        let why = Visibility.coverReason(target: Self.target, layer: Self.hiddenLayer, pid: Self.ownPID, windows: [], displays: [Self.screen])
        #expect(why?.contains("no wallpaper window found") == true)
    }

    @Test func fullScreenWindowsOnTwoDisplaysCoverTogether() {
        let left = CGRect(x: 0, y: 0, width: 300, height: 956), right = CGRect(x: 300, y: 0, width: 1170, height: 956)
        let why = Visibility.coverReason(target: Self.target, layer: Self.hiddenLayer, pid: Self.ownPID,
                                         windows: [Self.app(left), Self.app(right)], displays: [left, right])
        #expect(why == nil)
    }
}

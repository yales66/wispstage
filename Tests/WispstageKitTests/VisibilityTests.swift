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

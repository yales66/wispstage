import CoreGraphics
import Foundation
import Testing
@testable import WispstageKit

struct PixelDiffTests {
    private func image(_ w: Int, _ h: Int, _ v: UInt8 = 100) -> RGBAImage { RGBAImage(width: w, height: h, fill: (v, v, v, 255)) }

    private func set(_ img: inout RGBAImage, _ x: Int, _ y: Int, _ v: UInt8) {
        let i = (y * img.width + x) * 4
        img.pixels[i] = v
    }

    @Test func identicalImagesHaveNoDifference() {
        let r = PixelDiff.compare(image(20, 10), image(20, 10))
        #expect(r.differing == 0)
        #expect(!r.isDifferent)
    }

    @Test func channelDifferenceOfEightOrLessDoesNotCount() {
        var b = image(20, 10)
        for x in 0..<20 { set(&b, x, 0, 108) }
        #expect(PixelDiff.compare(image(20, 10), b).differing == 0)
    }

    @Test func imageDiffersOnlyAboveHalfPercentDifferingPixels() {
        // 100x100 = 10000 pixels: 50 (0.5%) do not count, 51 do
        var b = image(100, 100)
        for x in 0..<50 { set(&b, x, 0, 200) }
        let at = PixelDiff.compare(image(100, 100), b)
        #expect(at.differing == 50)
        #expect(!at.isDifferent)
        set(&b, 0, 1, 200)
        #expect(PixelDiff.compare(image(100, 100), b).isDifferent)
    }

    @Test func highlightImageMarksDifferingPixelsRed() throws {
        var b = image(10, 10)
        set(&b, 3, 4, 250)
        let r = PixelDiff.compare(image(10, 10), b)
        let h = try #require(r.highlight)
        let i = (4 * 10 + 3) * 4
        #expect(Array(h.pixels[i..<i + 4]) == [255, 0, 0, 255])
        #expect(h.pixels[0] != 255 || h.pixels[1] != 0)  // unchanged pixels are not red
    }

    @Test func differentSizesCountAsFullyDifferent() {
        let r = PixelDiff.compare(image(10, 10), image(12, 10))
        #expect(r.isDifferent)
        #expect(r.ratio == 1)
    }
}

struct BaselineStoreTests {
    private func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-baseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func writePNG(_ img: RGBAImage, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(PNG.write(try #require(img.cgImage), to: url))
    }

    /// A run directory: two full-window screenshots and one element screenshot under smoke.e2e.
    private func makeRun(_ root: URL) throws -> URL {
        let run = root.appendingPathComponent("run")
        let sc = run.appendingPathComponent("smoke.e2e")
        try writePNG(RGBAImage(width: 8, height: 8, fill: (1, 2, 3, 255)), sc.appendingPathComponent("01-launch.png"))
        try writePNG(RGBAImage(width: 8, height: 8, fill: (9, 9, 9, 255)), sc.appendingPathComponent("03-scrolled.png"))
        try writePNG(RGBAImage(width: 4, height: 4, fill: (50, 0, 0, 255)), sc.appendingPathComponent("04-label-toolbar.save.png"))
        try ShotRecord.write([
            ShotRecord(file: "01-launch.png", variant: "zh-Hans-light-24h"),
            ShotRecord(file: "03-scrolled.png", variant: "zh-Hans-light-24h"),
            ShotRecord(file: "04-label-toolbar.save.png", variant: "zh-Hans-light-24h"),
        ], to: sc)
        let other = run.appendingPathComponent("settings.view")
        try writePNG(RGBAImage(width: 8, height: 8, fill: (1, 2, 3, 255)), other.appendingPathComponent("01-launch.png"))
        try ShotRecord.write([ShotRecord(file: "01-launch.png", variant: "en-dark-12h")], to: other)
        return run
    }

    @Test(arguments: [
        ("zh-Hans", Appearance.light, true, "zh-Hans-light-24h"),
        ("en", .dark, false, "en-dark-12h"),
    ] as [(String, Appearance, Bool, String)])
    func baselineGroupFollowsLanguageAppearanceAndClock(language: String, appearance: Appearance, hour24: Bool, key: String) {
        #expect(Baselines.variant(language: language, appearance: appearance, hour24: hour24) == key)
    }

    @Test func acceptSavesFilteredScreenshotsIntoGroupDirectories() throws {
        let root = try tempDir()
        let run = try makeRun(root)
        let base = root.appendingPathComponent("Baselines")
        let n = try Baselines.accept(runDir: run, filters: ["smoke."], root: base)
        #expect(n == 3)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: base.appendingPathComponent("zh-Hans-light-24h/smoke.e2e/04-label-toolbar.save.png").path))
        #expect(!fm.fileExists(atPath: base.appendingPathComponent("en-dark-12h/settings.view").path))
    }

    @Test func compareSeparatesSameDifferentAndMissing() throws {
        let root = try tempDir()
        let run = try makeRun(root)
        let base = root.appendingPathComponent("Baselines")
        let sc = run.appendingPathComponent("smoke.e2e")
        try Baselines.accept(runDir: run, filters: ["smoke.e2e"], root: base)
        // Change one baseline and delete another
        try writePNG(RGBAImage(width: 8, height: 8, fill: (200, 9, 9, 255)), base.appendingPathComponent("zh-Hans-light-24h/smoke.e2e/03-scrolled.png"))
        try FileManager.default.removeItem(at: base.appendingPathComponent("zh-Hans-light-24h/smoke.e2e/01-launch.png"))
        let r = Baselines.compare(scenarioDir: sc, scenario: "smoke.e2e", root: base)
        #expect(r.missing == ["01-launch.png"])
        #expect(r.diffs.map(\.file) == ["03-scrolled.png"])
        #expect(r.same == 1)
        let diff = try #require(r.diffs.first?.diffImage)
        #expect(FileManager.default.fileExists(atPath: diff))
    }
}

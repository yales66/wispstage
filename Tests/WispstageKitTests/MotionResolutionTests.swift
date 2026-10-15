import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import WispstageKit

// MARK: - Resolution-aware judgment

private func px(_ t: Double, x: Double, w: Double, s: Double, ppp: Double?) -> MotionSample {
    MotionSample(t: t, rect: CGRect(x: x, y: 100, width: w * s, height: 50 * s), scale: s, opacity: 1, shadow: nil, pixelsPerPoint: ppp)
}

/// An element tracked by capture: starts at 1.0, moves right with the pointer after 1.1, scale follows a snappy spring of 0.25 s to `to`; frames 12 to 16 get an extra `jitter` (a stretch of overshoot).
private func liftRecording(width w: Double, ppp: Double?, to: Double, jitter: Double) -> MotionRecording {
    var ss = [px(1.0, x: 0, w: w, s: 1, ppp: ppp)]
    for i in 1...40 {
        let t = 1.1 + Double(i) / 60
        var v = 1 + Spring.snappy(duration: 0.25).value(target: to - 1, time: Double(i - 1) / 60)
        if (12...16).contains(i) { v += jitter }
        ss.append(px(t, x: Double(i) * 3, w: w, s: v, ppp: ppp))
    }
    return MotionRecording(name: "Lift", targets: [MotionTarget(id: "c", rect: CGRect(x: 0, y: 100, width: w, height: 50))],
                           tracks: [MotionTrack(name: "c~capture", target: 0, source: .pixels, samples: ss)],
                           inputs: MotionInputs(start: 1.05, release: nil))
}

private func spec(to: Double) -> MotionSpec {
    MotionSpec(name: "Lift", anchor: .firstMove, track: .moving, source: "Section 3",
               expectations: [MotionExpectation(.scale, from: 1, to: to, spring: MotionSpring(.snappy, duration: 0.25))])
}

private func row(_ rows: [MotionReportRow], _ item: String) throws -> MotionReportRow {
    try #require(rows.first { $0.item == item }, "\(rows.map(\.item))")
}

struct MotionResolutionTests {
    @Test(arguments: [
        (MotionChannel.scale, 1.0, 208.0, 1.0 / 208),
        (.scale, 2.0, 208.0, 1.0 / 416),
        (.x, 2.0, 208.0, 0.5),
        (.width, 1.0, 208.0, 1.0),
    ])
    func onePixelResolvableAmount(c: MotionChannel, ppp: Double, width: Double, step: Double) throws {
        let s = try #require(MotionResolution.step(c, pixelsPerPoint: ppp, widthPoints: width))
        #expect(abs(s - step) < 1e-12)
    }

    @Test func accessibilityReadingsHaveNoPixelResolutionLimit() {
        let ss = [px(0, x: 0, w: 208, s: 1, ppp: nil)]
        #expect(MotionResolution.coarsest(.scale, ss) == nil)
    }

    @Test func runOfReadingsUsesCoarsestStep() throws {
        let ss = [px(0, x: 0, w: 208, s: 1, ppp: 2), px(0.1, x: 0, w: 208, s: 1, ppp: 1)]
        let r = try #require(MotionResolution.coarsest(.scale, ss))
        #expect(abs(r - 1.0 / 208) < 1e-12)
    }

    /// Shaped like a measured lift recording: element 208 pt wide at 1 px per pt, with half a pixel of extra wobble near the plateau (0.0025, overshoot about 8%).
    /// The overshoot spec value (0.6% × 0.03) and tolerance (0.9 percentage points × 0.03) are both smaller than one pixel (0.0048): not judged; end value and per-frame deviation (tolerance 0.01) are judged.
    @Test func overshootWithSpecAndToleranceBelowOnePixelIsReportedAsBelowResolution() throws {
        let rows = liftRecording(width: 208, ppp: 1, to: 1.03, jitter: 0.0025).compare(spec(to: 1.03))
        let os = try row(rows, "Scale overshoot")
        #expect(os.diff == "below resolution, not judged", "\(os)")
        #expect(os.note?.contains("smallest resolvable 0.0048") == true, "\(os)")
        let end = try row(rows, "Scale end value")
        #expect(!end.diff.contains("below resolution"))
        let dev = try row(rows, "Scale per-frame deviation from spec curve")
        #expect(!dev.diff.contains("below resolution"))
    }

    /// Element 2000 pt wide at 2 px per pt, scale from 1 to 1.2: one pixel is 0.00025, so the overshoot spec value 0.0012 and tolerance 0.0003 are both resolvable and judged.
    @Test func resolvableOvershootIsJudgedAndMarkedOverTolerance() throws {
        let rows = liftRecording(width: 2000, ppp: 2, to: 1.2, jitter: 0).compare(spec(to: 1.2))
        let os = try row(rows, "Scale overshoot")
        #expect(!os.diff.contains("below resolution"), "\(os)")
        #expect(!os.diff.contains("over"), "\(os)")
        // Same track with an extra 0.01 (5% overshoot): marked over
        let jittery = liftRecording(width: 2000, ppp: 2, to: 1.2, jitter: 0.01).compare(spec(to: 1.2))
        #expect(try row(jittery, "Scale overshoot").diff.contains("over"))
    }

    /// Element 50 pt wide at 1 px per pt: one pixel is 0.02, larger than the end value tolerance 0.01.
    @Test func endValueWithToleranceBelowOnePixelIsReportedAsBelowResolution() throws {
        let rows = liftRecording(width: 50, ppp: 1, to: 1.03, jitter: 0).compare(spec(to: 1.03))
        #expect(try row(rows, "Scale end value").diff == "below resolution, not judged")
        #expect(try row(rows, "Scale per-frame deviation from spec curve").diff == "below resolution, not judged")
    }

    /// The time to 95% has to tell "95% done" from "5% to go": a band of 5% of the start-to-end span (0.0015 for scale 1 to 1.03) is smaller than
    /// one pixel (0.0048 at 208 pt wide and 1 px per pt), so that moment can't be measured and isn't judged.
    @Test func timeTo95WithFivePercentBandBelowOnePixelIsReportedAsBelowResolution() throws {
        let rows = liftRecording(width: 208, ppp: 1, to: 1.03, jitter: 0).compare(spec(to: 1.03))
        let t95 = try row(rows, "Scale time to 95% of end value")
        #expect(t95.diff == "below resolution, not judged", "\(t95)")
        #expect(t95.note?.contains("smallest resolvable 0.0048") == true, "\(t95)")
        #expect(t95.note?.contains("5% band 0.00150") == true, "\(t95)")
    }

    /// 2000 pt wide, 2 px per pt, 1 to 1.2: the 5% band of 0.01 is far larger than one pixel (0.00025), so it is judged.
    @Test func timeTo95WithResolvableFivePercentBandIsJudged() throws {
        let rows = liftRecording(width: 2000, ppp: 2, to: 1.2, jitter: 0).compare(spec(to: 1.2))
        let t95 = try row(rows, "Scale time to 95% of end value")
        #expect(!t95.diff.contains("below resolution"), "\(t95)")
        #expect(t95.diff.hasSuffix("ms"), "\(t95)")
    }

    @Test func readingsWithoutPixelResolutionAreJudgedAsUsual() throws {
        let rows = liftRecording(width: 208, ppp: nil, to: 1.03, jitter: 0.0025).compare(spec(to: 1.03))
        let os = try row(rows, "Scale overshoot")
        #expect(os.diff.contains("over"), "\(os) \(rows)")
    }
}

// MARK: - How long to record

struct MotionRecordSpanTests {
    @Test(arguments: [
        (2.0 as Double?, 5.0 as Double?, 6.0),   // settled early: keep at least until 1 s after release
        (8.0, 5.0, 8.3),                          // settled late: keep until quiet after settling
        (2.0, nil, 2.3),                          // no release
    ])
    func trimKeepsAtLeastOneSecondAfterRelease(quietAt: Double?, release: Double?, until: Double) {
        #expect(abs(MotionRecordSpan.keepUntil(quietAt: quietAt, quiet: 0.3, release: release) - until) < 1e-9)
    }

    @Test func noTrimWhenNeverSettled() {
        #expect(MotionRecordSpan.keepUntil(quietAt: nil, quiet: 0.3, release: 5) == .infinity)
    }
}

// MARK: - Native 2x pixel crop near the targets

struct MotionHiResTests {
    private static func pattern(_ u: Double, _ v: Double) -> Double { 120 + 60 * sin(u / 5) + 50 * cos(v / 4) }

    /// Luminance at window point (x, y): background 230, a 120x40 element centered at `c`, scaled by `s` about its center.
    private static func lum(_ x: Double, _ y: Double, _ c: CGPoint, _ s: Double) -> UInt8 {
        let u = (x - c.x) / s + 60, v = (y - c.y) / s + 20
        guard u >= 0, u < 120, v >= 0, v < 40 else { return 230 }
        return UInt8(pattern(u, v).rounded())
    }

    /// A 300x200 pt full window (1 px per pt) plus a crop at 2 px per pt (`crop` in window points, nil for no crop).
    private static func frame(_ t: Double, center c: CGPoint, scale s: Double, crop: CGRect?) -> MotionGrayFrame {
        var full = [UInt8](repeating: 230, count: 300 * 200)
        for y in 0..<200 { for x in 0..<300 { full[y * 300 + x] = lum(Double(x) + 0.5, Double(y) + 0.5, c, s) } }
        var hi: MotionCrop?
        if let crop {
            let w = Int(crop.width) * 2, h = Int(crop.height) * 2
            var px = [UInt8](repeating: 0, count: w * h)
            for j in 0..<h { for i in 0..<w { px[j * w + i] = lum(crop.minX + (Double(i) + 0.5) / 2, crop.minY + (Double(j) + 0.5) / 2, c, s) } }
            hi = MotionCrop(origin: crop.origin, pixelsPerPoint: 2, width: w, height: h, pixels: px)
        }
        return MotionGrayFrame(t: t, width: 300, height: 200, pixels: full, crop: hi)
    }

    @Test func framesWithCoveringCropReadAt2xAndOthersFallBackWithoutLosingTrack() throws {
        let rect = CGRect(x: 50, y: 60, width: 120, height: 40)
        var frames: [MotionGrayFrame] = []
        for k in 0...10 {
            let c = CGPoint(x: 110 + 2.5 * Double(k), y: 80)
            // Frame 6's crop is somewhere else
            let crop = k == 6 ? CGRect(x: 0, y: 150, width: 40, height: 40) : CGRect(x: c.x - 70, y: 50, width: 140, height: 60)
            frames.append(Self.frame(Double(k) / 60, center: c, scale: 1 + 0.003 * Double(k), crop: crop))
        }
        let ss = MotionPixelTracker.track(frames: frames, rect: rect)
        #expect(ss.count == 11)
        #expect(ss.map(\.pixelsPerPoint) == [2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2])
        let last = try #require(ss.last)
        #expect(abs(last.scale - 1.03) < 0.002)
        #expect(abs(last.rect.midX - 135) < 0.2)
    }

    @Test func onePixelPerPointWithoutCrop() throws {
        let frames = (0...3).map { k in Self.frame(Double(k) / 60, center: CGPoint(x: 110 + Double(k), y: 80), scale: 1, crop: nil) }
        let ss = MotionPixelTracker.track(frames: frames, rect: CGRect(x: 50, y: 60, width: 120, height: 40))
        #expect(ss.map(\.pixelsPerPoint) == [1, 1, 1, 1])
    }

    @Test func changedBoundsBetweenAdjacentFrames() {
        var a = [UInt8](repeating: 200, count: 40 * 30), b = a
        b[5 * 40 + 7] = 0
        b[12 * 40 + 20] = 0
        let fa = MotionGrayFrame(t: 0, width: 40, height: 30, pixels: a)
        let fb = MotionGrayFrame(t: 0.1, width: 40, height: 30, pixels: b)
        #expect(MotionQuiet.changedBounds(fa, fb) == CGRect(x: 7, y: 5, width: 14, height: 8))
        a = b
        #expect(MotionQuiet.changedBounds(MotionGrayFrame(t: 0, width: 40, height: 30, pixels: a), fb) == nil)
    }

    @Test func cropFollowsChangesAndStaysWhenNothingChanges() {
        let seed = CGRect(x: 10, y: 10, width: 20, height: 10)
        let moved = MotionHiRes.nextRegion(previous: seed, changed: CGRect(x: 40, y: 10, width: 30, height: 10))
        #expect(moved == CGRect(x: 40, y: 10, width: 30, height: 10).insetBy(dx: -MotionHiRes.margin, dy: -MotionHiRes.margin))
        #expect(MotionHiRes.nextRegion(previous: moved, changed: nil) == moved)
    }
}

// MARK: - Position from accessibility frame, content jump

struct MotionAXRetakeReportTests {
    /// Drop segment: after release the element drops down; with `retake`, reading 10 retook the template at the accessibility frame and the content jumped `shift` relative to the frame.
    private func drop(retake: Bool, shift: CGVector?) -> MotionRecording {
        var ss: [MotionSample] = [px(0.5, x: 732, w: 208, s: 1, ppp: 2)]
        for i in 1...20 {
            var s = px(1.0 + Double(i) / 60, x: 732, w: 208, s: 1, ppp: 2)
            s.rect.origin.y = 100 + max(0, 30 - Double(i) * 3)
            if i == 10, retake { s.axRetake = true; s.contentShift = shift }
            ss.append(s)
        }
        return MotionRecording(name: "Lift", targets: [MotionTarget(id: "c", rect: CGRect(x: 260, y: 100, width: 208, height: 50))],
                               tracks: [MotionTrack(name: "c~capture", target: 0, source: .pixels, samples: ss)],
                               inputs: MotionInputs(start: 0.4, release: 1.0))
    }

    private let dropSpec = MotionSpec(name: "drop", anchor: .release, track: .moving, source: "Section 3",
                                      expectations: [MotionExpectation(.scale, to: 1, spring: MotionSpring(.snappy, duration: 0.35))])

    @Test func retakenSegmentIsMarkedAsAccessibilityPositionAndContentJumpIsReportedOnly() throws {
        let rec = drop(retake: true, shift: CGVector(dx: 26, dy: 0))
        let rows = rec.compare(dropSpec)
        let ax = try #require(rows.first { $0.item == "Position taken from accessibility frame" }, "\(rows.map(\.item))")
        #expect(ax.note?.contains("no longer two independent readings") == true, "\(ax)")
        let jump = try #require(rows.first { $0.item == "Content jump after drop" }, "\(rows.map(\.item))")
        #expect(jump.measured == "26.0 pt", "\(jump)")
        #expect(jump.diff == "reported only, not judged", "\(jump)")
        #expect(rec.report(specs: [dropSpec]).contains("Content jump after drop: - / 26.0 pt / reported only, not judged"))
    }

    @Test func contentJumpWithinPositionToleranceIsNotListed() {
        let rows = drop(retake: true, shift: CGVector(dx: 0.3, dy: 0)).compare(dropSpec)
        #expect(rows.contains { $0.item == "Position taken from accessibility frame" })
        #expect(!rows.contains { $0.item == "Content jump after drop" })
    }

    @Test func neitherRowWithoutTemplateRetake() {
        let rows = drop(retake: false, shift: nil).compare(dropSpec)
        #expect(!rows.contains { $0.item == "Position taken from accessibility frame" || $0.item == "Content jump after drop" })
    }
}

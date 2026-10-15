import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import WispstageKit

// MARK: - Helpers

/// Samples a SwiftUI spring frame by frame (60 frames per second), simulating animation readings from `from` to `to`.
private func springPoints(_ spring: Spring, from: Double, to: Double, frames: Int = 60) -> [(t: Double, v: Double)] {
    (1...frames).map { i in
        let t = Double(i) / 60
        return (t, from + spring.value(target: to - from, time: t))
    }
}

struct MotionFitTests {
    @Test func springReadingsFitEndValueTimeTo95AndOvershoot() throws {
        let spring = Spring.snappy(duration: 0.25)
        let fit = try #require(MotionFitter.fit(springPoints(spring, from: 1, to: 1.03), from: 1))
        #expect(abs(fit.end - 1.03) < 0.0005)
        let t95 = try #require(fit.t95)
        // Sampled at 60 frames per second, 95% lands within one frame after the theoretical value
        #expect(t95 >= MotionSpring(.snappy, duration: 0.25).t95 - 0.0001)
        #expect(t95 <= MotionSpring(.snappy, duration: 0.25).t95 + 1.0 / 60)
        #expect(abs(fit.overshoot - MotionSpring(.snappy, duration: 0.25).overshoot) < 0.003)
        #expect(!fit.jump)
    }

    @Test func firstFrameAtEndValueIsJumpAndTimeTo95IsFirstFrame() throws {
        let pts = [(t: 0.017, v: 1.03), (t: 0.034, v: 1.03), (t: 0.05, v: 1.03)]
        let fit = try #require(MotionFitter.fit(pts, from: 1))
        #expect(fit.jump)
        #expect(fit.t95 == 0.017)
        #expect(fit.overshoot == 0)
    }

    @Test func noTimeTo95WithoutChange() throws {
        let fit = try #require(MotionFitter.fit([(t: 0, v: 1), (t: 0.1, v: 1)], from: nil))
        #expect(fit.t95 == nil)
    }

    @Test func downwardOvershootIsMeasuredByAmplitude() throws {
        let pts = [(t: 0.0, v: 1.0), (t: 0.1, v: 0.2), (t: 0.2, v: -0.1), (t: 0.3, v: 0.0)]
        let fit = try #require(MotionFitter.fit(pts, from: nil))
        #expect(abs(fit.overshoot - 0.1) < 1e-9)
    }
}

// MARK: - Spec springs

struct MotionSpringTests {
    @Test func snappySpringTheoreticalValuesUseSwiftUIDuration() {
        let s = MotionSpring(.snappy, duration: 0.25)
        // Measured 2026-10-14: Spring.snappy(duration: 0.25) has dampingRatio 0.85, 95% at 0.147 s, overshoot 0.63%
        #expect(abs(s.t95 - 0.147) < 0.002)
        #expect(abs(s.overshoot - 0.0063) < 0.0005)
        #expect(s.description.contains(".snappy(duration: 0.25)"))
    }
}

// MARK: - Comparison

private func sample(_ t: Double, x: Double, y: Double = 100, w: Double = 200, h: Double = 50, s: Double = 1,
                    o: Double? = 1) -> MotionSample {
    MotionSample(t: t, rect: CGRect(x: x, y: y, width: w, height: h), scale: s, opacity: o, shadow: nil)
}

private let lift = MotionSpec(name: "Lift", anchor: .firstMove, track: .moving, source: "Section 3, \"Lift\"", minPointerTravel: 4,
                              expectations: [MotionExpectation(.scale, from: 1, to: 1.03, spring: MotionSpring(.snappy, duration: 0.25)),
                                             MotionExpectation(.shadow, to: 14)])

private let drop = MotionSpec(name: "Drop", anchor: .release, track: .moving, source: "Section 3, \"Drop\"",
                              expectations: [MotionExpectation(.scale, to: 1, spring: MotionSpring(.snappy, duration: 0.35))])

struct MotionCompareTests {
    private let target = MotionTarget(id: "list.row.a", rect: CGRect(x: 0, y: 100, width: 200, height: 50))

    /// The original element (accessibility) stays in place; the copy tracked by capture moves right with the pointer after 1.1, with scale `scale(frame index)`.
    /// Drag input starts at 1.05.
    private func recording(scale: (Int) -> Double) -> MotionRecording {
        var ax = [sample(1.0, x: 0)]
        var px = [sample(1.0, x: 0)]
        for i in 1...20 {
            let t = 1.1 + Double(i) / 60
            ax.append(sample(t, x: 0, o: max(0, 1 - Double(i) / 10)))
            px.append(sample(t, x: Double(i) * 3, s: scale(i)))
        }
        return MotionRecording(name: "Lift", targets: [target],
                               tracks: [MotionTrack(name: "list.row.a", target: 0, source: .accessibility, samples: ax),
                                        MotionTrack(name: "list.row.a~capture", target: 0, source: .pixels, samples: px)],
                               inputs: MotionInputs(start: 1.05, release: nil))
    }

    /// Correct behavior: the lifted copy grows from 1x to 1.03x on a snappy spring of 0.25 s (the first changed frame is the spring's first frame).
    private var fixed: MotionRecording {
        recording { i in 1 + Spring.snappy(duration: 0.25).value(target: 0.03, time: Double(i - 1) / 60) }
    }

    @Test func timeZeroIsFirstTrackChangeNotInputTime() throws {
        let zero = try #require(fixed.time(of: .firstMove))
        #expect(abs(zero - (1.1 + 1.0 / 60)) < 1e-9)
    }

    @Test func picksMostMovingTrackListsDiffsPerItemAndMarksOverTolerance() throws {
        let rows = recording { _ in 1.08 }.compare(lift)
        let end = try #require(rows.first { $0.item == "Scale end value" })
        #expect(end.spec == "1.030")
        #expect(end.measured == "1.080")
        #expect(end.diff == "+0.050 (over ±0.010)")
        #expect(rows.first?.track == "list.row.a~capture")
        let shadow = try #require(rows.first { $0.item == "Shadow radius end value" })
        #expect(shadow.measured == "unknown")
    }

    /// Faulty behavior: the lifted copy is already at 1.03x when it appears.
    @Test func jumpStraightToEndValueIsMarkedOverTolerance() throws {
        let rows = recording { _ in 1.03 }.compare(lift)
        let t95 = try #require(rows.first { $0.item == "Scale time to 95% of end value" })
        #expect(t95.spec == "147 ms")
        #expect(t95.diff == "-147 ms (over ±42 ms)")
        #expect(t95.note?.contains("jump") == true)
        let dev = try #require(rows.first { $0.item == "Scale per-frame deviation from spec curve" })
        #expect(dev.diff.contains("over ±0.010"))
    }

    @Test func motionFollowingSpecIsNotMarkedOverTolerance() throws {
        let rows = fixed.compare(lift)
        let t95 = try #require(rows.first { $0.item == "Scale time to 95% of end value" })
        #expect(!t95.diff.contains("over"))
        let dev = try #require(rows.first { $0.item == "Scale per-frame deviation from spec curve" })
        #expect(!dev.diff.contains("over"))
        let end = try #require(rows.first { $0.item == "Scale end value" })
        #expect(!end.diff.contains("over"))
    }

    /// Faulty behavior: the drop's scale follows a slower curve and is still at 1.013 when the lifted copy is removed.
    @Test func slowDropStoppingHalfwayMarksEndValueAndPerFrameDeviationOverTolerance() throws {
        var px: [MotionSample] = [sample(1.9, x: 300, s: 1.03), sample(2.0, x: 300, s: 1.03)]
        // The plateau at 1.013 lasts longer than 100 ms: the captured end value is the median of the last 100 ms of the window
        for i in 1...26 {
            let t = 2.03 + Double(i) / 60
            let v = i <= 18 ? 1.03 + Spring.snappy(duration: 0.6).value(target: -0.03, time: Double(i - 1) / 60) : 1.013
            px.append(sample(t, x: 300 - Double(i), s: v))
        }
        let rec = MotionRecording(name: "Drop", targets: [target],
                                  tracks: [MotionTrack(name: "list.row.a~capture", target: 0, source: .pixels, samples: px)],
                                  inputs: MotionInputs(start: 1.0, release: 2.01))
        let rows = rec.compare(drop)
        let end = try #require(rows.first { $0.item == "Scale end value" })
        #expect(end.diff == "+0.013 (over ±0.010)")
        let dev = try #require(rows.first { $0.item == "Scale per-frame deviation from spec curve" })
        #expect(dev.diff.contains("over"))
    }

    /// On the onset frame the element is 3 pt from its original position with a 4 pt threshold: lift triggered too early, so the diff is negative.
    @Test func onsetOffsetBelowThresholdGivesNegativeDiff() throws {
        let rows = fixed.compare(lift)
        let travel = try #require(rows.first { $0.item == "Element offset from original position at onset" })
        #expect(travel.spec == "> 4.0 pt")
        #expect(travel.measured == "3.0 pt")
        #expect(travel.diff == "-1.0")
    }

    @Test func reportHasThreeColumnsTimeDefinitionsAndToleranceSource() {
        let text = recording { _ in 1.08 }.report(specs: [lift])
        #expect(text.contains("spec / measured / diff"))
        #expect(text.contains(".snappy(duration: 0.25)"))
        #expect(text.contains("1.030 / 1.080 / +0.050 (over ±0.010)"))
        #expect(text.contains("measured only on solid-color elements"))
    }

    @Test func trackFileHasOneLinePerFramePerElementWithTimeFromZero() throws {
        let lines = fixed.jsonl().split(separator: "\n")
        let first = try #require(lines.first)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        #expect(obj["ms"] as? Int == -117)
        #expect(obj["id"] as? String == "list.row.a")
        #expect(Set(obj.keys) == ["ms", "id", "src", "x", "y", "w", "h", "scale", "opacity", "shadow"])
    }
}

// MARK: - Torn frames and per-frame comparison

struct MotionTearTests {
    @Test(arguments: [
        ([200.0, 200, 190, 200, 200], Set([2])),
        ([200.0, 201, 202, 203, 204], Set<Int>()),
        ([190.0, 200, 200], Set<Int>()),
        ([200.0, 197, 200], Set<Int>()),
    ])
    func frameNarrowerThanBothNeighborsByMoreThanThresholdIsTorn(widths: [Double], torn: Set<Int>) {
        let ss = widths.enumerated().map { i, w in sample(Double(i) / 60, x: 0, w: w) }
        #expect(MotionTear.torn(ss) == torn)
    }

    @Test func perFrameComparisonAllowsOneFrameOfTimeSlack() throws {
        let spring = Spring.snappy(duration: 0.25)
        let curve = { (t: Double) in t < 0 ? 0 : spring.value(target: 30, time: t) }
        let late1 = (0...20).map { i in (t: Double(i) / 60, v: curve(Double(i - 1) / 60)) }
        let late3 = (0...20).map { i in (t: Double(i) / 60, v: curve(Double(i - 3) / 60)) }
        let one = try #require(MotionTolerance.worstDeviation(late1, expected: curve))
        let three = try #require(MotionTolerance.worstDeviation(late3, expected: curve))
        #expect(one.dev < 1e-9)
        #expect(three.dev > 0.5)
    }
}

// MARK: - Capture tracking

struct MotionPixelTrackerTests {
    /// Element texture (a continuous function, so it can still be sampled after subpixel translation and scaling).
    private static func pattern(_ u: Double, _ v: Double) -> Double { 120 + 60 * sin(u / 5) + 50 * cos(v / 4) }

    /// A 300x200 grayscale frame with background 230; the element is 120x40 unscaled, centered at `center`, scaled by `scale` about its center, and composited over the background at `alpha`.
    private static func frame(_ t: Double, center: CGPoint, scale: Double, alpha: Double = 1) -> MotionGrayFrame {
        var px = [UInt8](repeating: 230, count: 300 * 200)
        for y in 0..<200 {
            for x in 0..<300 {
                let u = (Double(x) + 0.5 - center.x) / scale + 60, v = (Double(y) + 0.5 - center.y) / scale + 20
                guard u >= 0, u < 120, v >= 0, v < 40 else { continue }
                px[y * 300 + x] = UInt8((alpha * pattern(u, v) + (1 - alpha) * 230).rounded())
            }
        }
        return MotionGrayFrame(t: t, width: 300, height: 200, pixels: px)
    }

    @Test func followsTranslationAndScale() throws {
        var frames = [Self.frame(0, center: CGPoint(x: 110, y: 80), scale: 1)]
        for k in 1...10 {
            frames.append(Self.frame(Double(k) / 60, center: CGPoint(x: 110 + 2.5 * Double(k), y: 80 + 0.5 * Double(k)),
                                     scale: 1 + 0.003 * Double(k)))
        }
        let ss = MotionPixelTracker.track(frames: frames, rect: CGRect(x: 50, y: 60, width: 120, height: 40))
        #expect(ss.count == 11)
        let last = try #require(ss.last)
        #expect(abs(last.scale - 1.03) < 0.003)
        #expect(abs(last.rect.midX - 135) < 0.3)
        #expect(abs(last.rect.midY - 85) < 0.3)
    }

    @Test func opacityIsEstimatedFromTemplateRegressionSlope() throws {
        let frames = [Self.frame(0, center: CGPoint(x: 110, y: 80), scale: 1),
                      Self.frame(0.1, center: CGPoint(x: 110, y: 80), scale: 1, alpha: 0.5)]
        let ss = MotionPixelTracker.track(frames: frames, rect: CGRect(x: 50, y: 60, width: 120, height: 40))
        let o = try #require(ss.last?.opacity)
        #expect(abs(o - 0.5) < 0.03)
    }
}

// MARK: - Stills

struct MotionStillsTests {
    @Test func eachTimePicksFrameOnScreenAtThatMoment() {
        let times = [0.0, 0.016, 0.033, 0.05, 0.2]
        #expect(MotionStills.pick(frameTimes: times, at: [0, 0.04, 0.1, 0.5]) == [0, 2, 3, 4])
    }

    @Test func timeBeforeFirstFramePicksFirstFrame() {
        #expect(MotionStills.pick(frameTimes: [0.1, 0.2], at: [0.05]) == [0])
    }

    @Test func sheetLaysOutGridWithLabelAboveEachCell() throws {
        let img = try #require(RGBAImage(width: 40, height: 20, fill: (200, 0, 0, 255)).cgImage)
        let sheet = try #require(MotionStills.sheet(cells: [("+0 ms", img), ("+50 ms", img), ("+100 ms", img)], columns: 2))
        #expect(sheet.width == 2 * (40 + 2 * MotionStills.padding))
        #expect(sheet.height == 2 * (20 + MotionStills.labelHeight + 2 * MotionStills.padding))
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import WispstageKit

struct MotionMeasureTests {
    // MARK: Release time

    @Test func releaseIsLastInputDoneReplyAfterInteractionStartConvertedToMediaClock() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let lines: [(Date, OutputLine)] = [
            (t0, .other("E2E_INPUT_DONE")),                       // before the interaction started, doesn't count
            (t0.addingTimeInterval(1), .other("E2E_READY")),
            (t0.addingTimeInterval(3.2), .other("E2E_INPUT_DONE")),
            (t0.addingTimeInterval(9), .event(E2EEvent(json: #"{"type":"log"}"#)!)),
        ]
        // wall clock t0+10 corresponds to media clock 500
        let r = MotionInputs.releaseTime(lines: lines, since: 1, wallNow: t0.addingTimeInterval(10), mediaNow: 500)
        #expect(r.map { abs($0 - 493.2) < 1e-6 } == true)
    }

    @Test func noReleaseTimeWithoutInputReplyDuringInteraction() {
        let lines: [(Date, OutputLine)] = [(Date(), .other("E2E_INPUT_DONE"))]
        #expect(MotionInputs.releaseTime(lines: lines, since: 1, wallNow: Date(), mediaNow: 0) == nil)
    }

    // MARK: Waiting to settle

    private func frame(_ t: Double, dots: [(Int, Int)]) -> MotionGrayFrame {
        var px = [UInt8](repeating: 200, count: 40 * 40)
        for (x, y) in dots { px[y * 40 + x] = 0 }
        return MotionGrayFrame(t: t, width: 40, height: 40, pixels: px)
    }

    @Test func settleWatchesOnlyNearTargetsAndIgnoresChangesOutsideRegion() {
        // One change near the target at 0.1 s; after that only things outside the region change (a clock, the cursor and so on)
        let frames = [frame(0, dots: [(5, 5)]), frame(0.1, dots: [(6, 5)]), frame(0.2, dots: [(6, 5), (30, 30)]), frame(0.3, dots: [(6, 5), (31, 30)])]
        let near = CGRect(x: 0, y: 0, width: 15, height: 15)
        #expect(MotionQuiet.lastChange(frames: frames, region: near) == 0.1)
        #expect(MotionQuiet.lastChange(frames: frames, region: CGRect(x: 0, y: 0, width: 40, height: 40)) == 0.3)
    }

    @Test func noChangeTimeWhenRegionNeverChanges() {
        let frames = [frame(0, dots: []), frame(0.1, dots: [])]
        #expect(MotionQuiet.lastChange(frames: frames, region: CGRect(x: 0, y: 0, width: 40, height: 40)) == nil)
    }

    // MARK: Fitting

    @Test func noFitWhenSpanIsWithinNoise() {
        // Captured scale jitters 1e-5 in the last digit: without minSpan this yields an overshoot of millions of percentage points
        let pts = [(t: 0.0, v: 1.0), (t: 0.1, v: 1.00002), (t: 0.2, v: 0.99999), (t: 0.3, v: 1.00001)]
        let f = MotionFitter.fit(pts, from: nil, minSpan: 0.005)
        #expect(f?.t95 == nil)
        #expect(f?.overshoot == 0)
    }

    @Test func noisyPlateauEndValueIsMedianOfWindowTail() {
        // Plateau at 1.03 jitters ±0.002, and the last reading happens to be 1.028
        var pts: [(t: Double, v: Double)] = [(0, 1.0), (0.05, 1.015), (0.1, 1.025)]
        for (i, v) in [1.03, 1.032, 1.03, 1.028, 1.03, 1.032, 1.03, 1.028].enumerated() { pts.append((0.2 + Double(i) * 0.05, v)) }
        let f = MotionFitter.fit(pts, from: 1, minSpan: 0.005, endSpan: 0.2)
        #expect(f.map { abs($0.end - 1.03) < 1e-9 } == true)
    }
}

struct MotionTrackerLossTests {
    /// An 80x60 luminance image with a 30x20 non-repeating patch at top-left (x, 20) (a repeating pattern would match the wrong period; tracking needs light and dark); uniform when `block` is false.
    private func frame(_ t: Double, x: Int, block: Bool = true) -> MotionGrayFrame {
        var px = [UInt8](repeating: 220, count: 80 * 60)
        if block { for yy in 0..<20 { for xx in 0..<30 { px[(20 + yy) * 80 + x + xx] = UInt8(20 + ((xx / 5) * 7 + (yy / 5) * 13 + (xx / 5) * (yy / 5)) % 5 * 40) } } }
        return MotionGrayFrame(t: t, width: 80, height: 60, pixels: px)
    }

    @Test func stopsTrackingWhenElementDisappearsWithoutRunawayPositions() {
        // After the drop the lifted copy is removed and its place looks different: later frames should have no readings
        let frames = [frame(0, x: 20), frame(0.016, x: 21), frame(0.033, x: 22), frame(0.05, x: 0, block: false), frame(0.066, x: 0, block: false)]
        let out = MotionPixelTracker.track(frames: frames, rect: CGRect(x: 20, y: 20, width: 30, height: 20))
        #expect(out.count == 3, "\(out.map { ($0.rect.minX, $0.scale) })")
        #expect(out.last.map { abs($0.rect.minX - 22) < 0.5 } == true)
    }
}

// MARK: - Retaking the template after losing track

struct MotionTrackerReacquireTests {
    /// A 200x60 luminance image with a 30x20 non-repeating patch at top-left (x, 20); `look` switches to another pattern (the real element appears with a different look); uniform when x is nil.
    private func frame(_ t: Double, x: Int?, look: Int = 0) -> MotionGrayFrame {
        var px = [UInt8](repeating: 220, count: 200 * 60)
        if let x {
            for yy in 0..<20 {
                for xx in 0..<30 {
                    let a = xx / 5, b = yy / 5
                    let v = look == 0 ? (a * 7 + b * 13 + a * b) % 5 : (a * 3 + b * 11 + 2 * a * b + 1) % 5
                    px[(20 + yy) * 200 + x + xx] = UInt8(20 + v * 40)
                }
            }
        }
        return MotionGrayFrame(t: t, width: 200, height: 60, pixels: px)
    }

    private let rect = CGRect(x: 20, y: 20, width: 30, height: 20)

    @Test func jumpBeyondSearchRangeIsRecoveredFromChangedArea() throws {
        // A few frames are missing and the element jumps 78 pt at once (farther than the 24 pt coarse search radius)
        let frames = [frame(0, x: 20), frame(0.016, x: 21), frame(0.033, x: 22), frame(0.1, x: 100), frame(0.116, x: 101)]
        let out = MotionPixelTracker.track(frames: frames, rect: rect)
        #expect(out.count == 5, "\(out.map { ($0.t, $0.rect.minX) })")
        let last = try #require(out.last)
        #expect(abs(last.rect.minX - 101) < 0.5, "\(last.rect)")
        #expect(abs(last.scale - 1) < 0.01)
    }

    @Test func afterLookChangeLosesTrackTemplateIsRetakenAtAccessibilityFrame() throws {
        // From frame 3 the original position is empty and the element with a new pattern appears at 60; accessibility reads it at frame 3 (and it doesn't change after)
        let frames = [frame(0, x: 20), frame(0.016, x: 21), frame(0.033, x: 22), frame(0.05, x: 60, look: 1), frame(0.066, x: 62, look: 1)]
        var asked: [Double] = []
        let out = MotionPixelTracker.track(frames: frames, rect: rect) { f, since in
            asked.append(since)
            return f.t >= 0.05 && since < 0.05 ? CGRect(x: 60, y: 20, width: 30, height: 20) : nil
        }
        #expect(out.count == 5, "\(out.map { ($0.t, $0.rect.minX) })")
        if out.count == 5 {
            #expect(abs(out[3].rect.minX - 60) < 0.5, "\(out[3].rect)")
            #expect(abs(out[4].rect.minX - 62) < 0.5, "\(out[4].rect)")
        }
        #expect(asked.contains(0.033), "after losing track, asks with the time of the last good reading before the loss: \(asked)")
    }

    @Test func noOutputWhenAccessibilityHasNothingAndChangedAreaIsNotElementLike() {
        // The element disappears (the changed area is a uniform background patch at the original position, so no template can be taken) and doesn't reappear
        let frames = [frame(0, x: 20), frame(0.016, x: 21), frame(0.033, x: nil), frame(0.05, x: nil)]
        let out = MotionPixelTracker.track(frames: frames, rect: rect) { _, _ in nil }
        #expect(out.count == 2, "\(out.map { ($0.t, $0.rect.minX) })")
    }

    @Test func readingsIncludeCorrelationWithTemplate() throws {
        let frames = [frame(0, x: 20), frame(0.016, x: 21)]
        let out = MotionPixelTracker.track(frames: frames, rect: rect)
        let m = try #require(out.last?.match)
        #expect(m > 0.95)
    }

    /// The frame stays at 22 while its content moves 8 pt right (the settled element gains an extra control and its text shifts right): the template
    /// follows the shifted content with high correlation, but the new frame accessibility reports differs from the captured position by more than
    /// the position tolerance, so the template is retaken at the frame and the content jump relative to the frame is recorded.
    @Test func mismatchedAccessibilityFrameSnapsToFrameAndRecordsContentShift() throws {
        let frames = [frame(0, x: 20), frame(0.016, x: 22), frame(0.033, x: 22), frame(0.05, x: 30), frame(0.066, x: 30)]
        let out = MotionPixelTracker.track(frames: frames, rect: rect) { f, since in
            f.t >= 0.05 && since < 0.05 ? CGRect(x: 22, y: 20, width: 30, height: 20) : nil
        }
        #expect(out.count == 5, "\(out.map { ($0.t, $0.rect.minX) })")
        guard out.count == 5 else { return }
        #expect(abs(out[3].rect.minX - 22) < 0.01, "\(out[3].rect)")
        #expect(abs(out[4].rect.minX - 22) < 0.5, "\(out[4].rect)")
        #expect(out[3].axRetake)
        #expect(out[3].contentShift.map { abs($0.dx - 8) < 0.5 && abs($0.dy) < 0.5 } == true, "\(String(describing: out[3].contentShift))")
        #expect(!out[4].axRetake)
        #expect(!out[2].axRetake)
    }

    @Test func noRetakeWhenAccessibilityFrameMatchesCapturedPosition() {
        let frames = [frame(0, x: 20), frame(0.016, x: 22), frame(0.033, x: 24)]
        let out = MotionPixelTracker.track(frames: frames, rect: rect) { f, _ in
            f.t >= 0.033 ? CGRect(x: 24.2, y: 20, width: 30, height: 20) : nil
        }
        #expect(out.count == 3)
        #expect(out.allSatisfy { !$0.axRetake })
    }

    // An accessibility frame is used for a template only if it changed after tracking was lost: during a drag the frame at the original position never changes, and using it would capture the placeholder there
    @Test(arguments: [
        (2.0, 1.5, true),   // changed to a new position after the loss
        (1.2, 1.5, false),  // the latest reading at that moment is still the old position from before the loss
        (2.0, 1.9, false),  // the latest reading at 1.8 is earlier than the loss
    ])
    func accessibilityFrameIsUsedOnlyIfReadAfterLoss(at t: Double, lostAfter: Double, found: Bool) {
        let fresh = CGRect(x: 732, y: 206, width: 208, height: 54)
        let rs = [MotionReacquire.Reading(t: 0, rect: CGRect(x: 260, y: 177, width: 208, height: 54)),
                  MotionReacquire.Reading(t: 1.8, rect: fresh)]
        #expect(MotionReacquire.axRect(rs, at: t, lostAfter: lostAfter) == (found ? fresh : nil))
    }
}

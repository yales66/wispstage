import CoreGraphics
import CoreText
import Foundation
import SwiftUI

// Frame-by-frame motion recording (`E2ETest.recordMotion`), measured entirely from outside the app under test, without asking the app for layer data:
// - Geometry (position, size, scale) comes mainly from polling accessibility frames (`MotionAXPoller`). Measured 2026-10-14:
//   one frame read takes 0.14 ms (median), giving about one reading per frame, with p95 error 0 against probe layer ground truth.
// - Geometry of elements missing from the accessibility tree (for example a lifted element with accessibilityHidden), and opacity,
//   come from display-filter frame capture (`MotionDisplayStream` + `MotionPixelTracker`).
// All times are seconds converted from the mach clock: the driver's CACurrentMediaTime and the capture's SCStreamFrameInfo.displayTime use the same clock.

// MARK: - Tracks

/// An element to record: its identifier and its frame when recording starts (in the window, top-left origin, points).
public struct MotionTarget: Equatable, Sendable {
    public let id: String
    public let rect: CGRect

    public init(id: String, rect: CGRect) {
        self.id = id
        self.rect = rect
    }
}

/// One element's reading at one moment. `opacity` and `shadow` are nil when they can't be measured: opacity needs frame capture
/// and a template with enough light and dark variation; shadow radius can't be measured from outside. `pixelsPerPoint` is the pixels per point
/// of the image a capture reading came from (sets the smallest resolvable amount); accessibility readings are layout values and have nil.
public struct MotionSample: Equatable, Sendable {
    public var t: Double
    public var rect: CGRect
    public var scale: Double
    public var opacity: Double?
    public var shadow: Double?
    public var pixelsPerPoint: Double?
    /// Normalized cross-correlation of a capture reading with the template (1 is identical); nil for accessibility readings.
    public var match: Double?
    /// Capture reading: this frame retook the template at the accessibility frame, so the position is the one accessibility reported
    /// (from here on, capture and accessibility are no longer two independent readings).
    public var axRetake: Bool = false
    /// At the retake, the content center the old template tracked minus the accessibility frame center (points): how far the content
    /// jumped relative to the frame; nil for a retake after losing track.
    public var contentShift: CGVector?

    public init(t: Double, rect: CGRect, scale: Double, opacity: Double?, shadow: Double?, pixelsPerPoint: Double? = nil,
                match: Double? = nil) {
        self.t = t
        self.rect = rect
        self.scale = scale
        self.opacity = opacity
        self.shadow = shadow
        self.pixelsPerPoint = pixelsPerPoint
        self.match = match
    }
}

/// Smallest resolvable amount of a capture reading: one pixel. Items whose spec value or tolerance is smaller can't be measured and are
/// reported as "below resolution, not judged" instead of failing. Template matching interpolates to subpixels, so real precision may be better
/// than one pixel, but that hasn't been measured against ground truth, so one pixel is used.
public enum MotionResolution {
    /// Position and edges: 1 / pixels per point (points); scale: one pixel as a fraction of the element's unscaled width; opacity: one level of 8-bit luminance.
    public static func step(_ c: MotionChannel, pixelsPerPoint ppp: Double, widthPoints: Double) -> Double? {
        guard ppp > 0 else { return nil }
        switch c {
        case .x, .y, .width, .height: return 1 / ppp
        case .scale: return widthPoints > 0 ? 1 / (widthPoints * ppp) : nil
        case .opacity: return 1.0 / 255
        case .shadow: return nil
        }
    }

    /// The coarsest step in a run of readings; nil when none has a pixel density (accessibility readings).
    public static func coarsest(_ c: MotionChannel, _ samples: [MotionSample]) -> Double? {
        samples.compactMap { s in
            s.pixelsPerPoint.flatMap { step(c, pixelsPerPoint: $0, widthPoints: s.scale > 0 ? Double(s.rect.width) / s.scale : 0) }
        }.max()
    }

    static let verdict = "below resolution, not judged"

    static func note(_ c: MotionChannel, _ res: Double, _ samples: [MotionSample]) -> String {
        let ppps = Set(samples.compactMap(\.pixelsPerPoint)).sorted().map { String(format: "%g", $0) }.joined(separator: "/")
        return String(format: "smallest resolvable %@ (capture at %@ px per pt, one pixel)", c == .scale || c == .opacity ? String(format: "%.4f", res) : String(format: "%.2f pt", res), ppps)
    }
}

/// One track. An accessibility track is named after the target identifier; a capture track, which follows the element as it looked when
/// recording started, is named "identifier~capture" (the lifted copy that follows the pointer is usually this one).
public struct MotionTrack: Equatable, Sendable {
    public enum Source: String, Sendable {
        case accessibility = "ax"
        case pixels = "px"
    }

    public let name: String
    public let target: Int
    public let source: Source
    public var samples: [MotionSample]

    public init(name: String, target: Int, source: Source, samples: [MotionSample]) {
        self.name = name
        self.target = target
        self.source = source
        self.samples = samples
    }

    /// Whether the element changed between two adjacent readings. Accessibility readings are layout values, so any small difference counts;
    /// capture position noise reaches 0.49 pt (measured 2026-10-14, maximum after removing torn frames), so position must differ by more than 0.5 pt.
    /// The capture scale noise threshold 0.005 is not yet measured.
    func changed(_ a: MotionSample, _ b: MotionSample) -> Bool {
        let (dp, ds): (CGFloat, Double) = source == .accessibility ? (0.01, 0.0001) : (0.5, 0.005)
        return abs(a.rect.minX - b.rect.minX) > dp || abs(a.rect.minY - b.rect.minY) > dp || abs(a.rect.width - b.rect.width) > dp
            || abs(a.rect.height - b.rect.height) > dp || abs(a.scale - b.scale) > ds
    }
}

/// Torn frames: a captured frame stitched from two consecutive composites, so the element is only the intersection of two positions and its
/// width is short by about one frame of movement (measured 2026-10-14: 25% to 28% of frames during a position animation, none at rest).
/// The 2026-10-14 measurement removed frames deviating 2% from the resting value; scaling elements have no fixed resting width, so this
/// compares with the frames before and after instead: a frame more than 2% narrower than both counts as torn.
public enum MotionTear {
    public static let threshold = 0.02

    public static func torn(_ samples: [MotionSample]) -> Set<Int> {
        guard samples.count >= 3 else { return [] }
        var out: Set<Int> = []
        for i in 1..<(samples.count - 1) {
            let w = Double(samples[i].rect.width)
            let ref = Double(min(samples[i - 1].rect.width, samples[i + 1].rect.width))
            if ref > 0, w < ref * (1 - threshold) { out.insert(i) }
        }
        return out
    }

    public static func removing(_ samples: [MotionSample]) -> [MotionSample] {
        let bad = torn(samples)
        return samples.indices.filter { !bad.contains($0) }.map { samples[$0] }
    }
}

/// Tolerances for "deviates from spec", from the 2026-10-14 measurement (derived from the measured error of display-filter capture against
/// probe layer ground truth). Only measured for solid-color elements on a solid background, a 60 Hz display and hidden windows; real UI with
/// text and shadows will have larger errors, not measured.
public enum MotionTolerance {
    /// One frame (60 Hz). Per-frame comparison can only align an external reading to within one frame, so it is compared with the spec values
    /// one frame before and after (measured 2026-10-14).
    public static let frame = 1.0 / 60
    /// Time to 95%: one frame plus the measured maximum error of 25.1 ms.
    public static let t95Ms = 42.0
    /// Overshoot: ±0.9 percentage points for a motion of about 10 pt overall, ±0.15 percentage points for about 180 pt. The boundary between
    /// the two is 50 pt; the boundary value is not yet measured.
    public static let overshootSmall = 0.009
    public static let overshootLarge = 0.0015
    public static let smallAmplitude = 50.0

    /// Per-frame value tolerance: position and edges ±0.5 pt, scale ±0.01, opacity ±0.01; shadow can't be measured and has no tolerance.
    public static func value(_ c: MotionChannel) -> Double? {
        switch c {
        case .x, .y, .width, .height: 0.5
        case .scale, .opacity: 0.01
        case .shadow: nil
        }
    }

    public static func overshoot(amplitudePoints: Double) -> Double {
        amplitudePoints <= smallAmplitude ? overshootSmall : overshootLarge
    }

    /// For each reading, the difference from the closest spec curve value within one frame before or after it; returns the largest (time and difference).
    public static func worstDeviation(_ pts: [(t: Double, v: Double)], expected: (Double) -> Double,
                                      slack: Double = frame) -> (t: Double, dev: Double)? {
        pts.map { p in (t: p.t, dev: [p.t - slack, p.t, p.t + slack].map { abs(p.v - expected($0)) }.min()!) }.max { $0.dev < $1.dev }
    }
}

// MARK: - Fitting

/// Fit of a run of readings: start, end value (last frame), time to 95% of the end value (seconds, from time zero), overshoot (largest
/// amount past the end value as a fraction of the start-to-end span), and whether it jumped (first frame already at 95%, no transition).
public struct MotionFit: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var t95: Double?
    public var overshoot: Double
    public var jump: Bool
}

public enum MotionFitter {
    /// A start-to-end span smaller than this counts as no movement (readings are floating point; a resting value can jitter in the last digit).
    static let epsilon = 1e-6

    /// Times in `pts` are measured from time zero; `from` is the start given by the spec, or the first frame when not given.
    /// `minSpan`: a start-to-end span not above this counts as no movement and gets no 95% time or overshoot (capture readings are noisy,
    /// and fitting a tiny span would divide out an overshoot of millions of percentage points).
    /// `endSpan`: the end value is the median of readings in this much time at the end of the window (0 for the last reading); capture
    /// plateaus jitter up and down, so taking only the last reading would be biased.
    public static func fit(_ pts: [(t: Double, v: Double)], from: Double?, minSpan: Double = 0,
                           endSpan: Double = 0) -> MotionFit? {
        guard let first = pts.first, let last = pts.last else { return nil }
        let start = from ?? first.v
        let tail = pts.filter { $0.t >= last.t - endSpan }.map(\.v).sorted()
        let end = endSpan > 0 && !tail.isEmpty ? (tail.count % 2 == 1 ? tail[tail.count / 2] : (tail[tail.count / 2 - 1] + tail[tail.count / 2]) / 2) : last.v
        let span = end - start
        guard abs(span) > max(minSpan, epsilon) else { return MotionFit(start: start, end: end, t95: nil, overshoot: 0, jump: false) }
        let progress = { (v: Double) in (v - start) / span }
        let t95 = pts.first { progress($0.v) >= 0.95 }?.t
        let overshoot = max(0, (pts.map { progress($0.v) }.max() ?? 1) - 1)
        return MotionFit(start: start, end: end, t95: t95, overshoot: overshoot, jump: progress(first.v) >= 0.95)
    }
}

// MARK: - Specs

/// A spring from the spec, expressed as a SwiftUI Animation: "snappy spring 0.25 s" = `.snappy(duration: 0.25)`,
/// that is `Spring.snappy(duration: 0.25)` (duration is the Spring's response; the preset sets the damping ratio). Theoretical values are computed with SwiftUI's Spring.
public struct MotionSpring: CustomStringConvertible, Sendable {
    public enum Kind: String, Sendable {
        case snappy, smooth, bouncy

        var name: String {
            switch self {
            case .snappy: "Snappy spring"
            case .smooth: "Smooth spring"
            case .bouncy: "Bouncy spring"
            }
        }
    }

    public let kind: Kind
    public let duration: Double

    public init(_ kind: Kind, duration: Double) {
        self.kind = kind
        self.duration = duration
    }

    public var spring: Spring {
        switch kind {
        case .snappy: .snappy(duration: duration)
        case .smooth: .smooth(duration: duration)
        case .bouncy: .bouncy(duration: duration)
        }
    }

    /// Time of first reaching 0.95 when going from 0 to 1 (seconds, solved in 1 ms steps).
    public var t95: Double {
        let s = spring
        for ms in 0...10_000 where s.value(target: 1.0, time: Double(ms) / 1000) >= 0.95 { return Double(ms) / 1000 }
        return .infinity
    }

    /// Largest amount past the end value as a fraction of the full span.
    public var overshoot: Double {
        let s = spring
        let end = max(s.settlingDuration, duration) * 2
        var peak = 0.0
        for ms in 0...Int(end * 1000) { peak = max(peak, s.value(target: 1.0, time: Double(ms) / 1000)) }
        return max(0, peak - 1)
    }

    public var description: String {
        let s = spring
        return String(format: "%@ %@ .%@(duration: %g): SwiftUI Spring response %.2f s, dampingRatio %.2f; theoretical 95%% at %d ms, overshoot %.1f%%, settles at %d ms",
                      kind.name, Self.seconds(duration), kind.rawValue, duration, s.response, s.dampingRatio,
                      Int((t95 * 1000).rounded()), overshoot * 100, Int((s.settlingDuration * 1000).rounded()))
    }

    private static func seconds(_ d: Double) -> String { String(format: "%g s", d) }
}

public enum MotionChannel: String, CaseIterable, Sendable {
    case x, y, width, height, scale, opacity, shadow

    var name: String {
        switch self {
        case .x: "X"
        case .y: "Y"
        case .width: "Width"
        case .height: "Height"
        case .scale: "Scale"
        case .opacity: "Opacity"
        case .shadow: "Shadow radius"
        }
    }

    func value(_ s: MotionSample) -> Double? {
        switch self {
        case .x: Double(s.rect.minX)
        case .y: Double(s.rect.minY)
        case .width: Double(s.rect.width)
        case .height: Double(s.rect.height)
        case .scale: s.scale
        case .opacity: s.opacity
        case .shadow: s.shadow
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .scale, .opacity: String(format: "%.3f", v)
        default: String(format: "%.1f", v)
        }
    }

    /// One more digit than `format` (when reporting resolution, scale amounts are often below the thousandths).
    func format4(_ v: Double) -> String {
        switch self {
        case .scale, .opacity: String(format: "%.5f", v)
        default: String(format: "%.2f", v)
        }
    }

    func signed(_ v: Double) -> String {
        let s = format(abs(v))
        return (v < 0 && s != format(0) ? "-" : "+") + s
    }
}

/// Where one channel in the spec should go: from `from` (when not given, the last frame before time zero, or else the first frame) to `to`;
/// with a spring, the 95% time and overshoot are also compared.
public struct MotionExpectation: Sendable {
    public let channel: MotionChannel
    public let from: Double?
    public let to: Double
    public let spring: MotionSpring?

    public init(_ channel: MotionChannel, from: Double? = nil, to: Double, spring: MotionSpring? = nil) {
        self.channel = channel
        self.from = from
        self.to = to
        self.spring = spring
    }
}

/// Time zero: recording start, lift, or release (drop or spring back). The last two use the first frame where a track changes (see `MotionRecording.time(of:)`).
public enum MotionAnchor: Sendable {
    case start, firstMove, release

    var name: String {
        switch self {
        case .start: "recording start"
        case .firstMove: "lift (first track change after the interaction starts)"
        case .release: "release (first track change after the interaction ends)"
        }
    }
}

/// Which track to compare: the one that moved most in the time window, the element as it was when recording started, or by name.
public enum MotionTrackPick: Sendable {
    case moving, original, named(String)
}

/// One row of the spec table. The time window runs from `anchor` to the next time zero (lift to release, release to recording end).
public struct MotionSpec: Sendable {
    public let name: String
    public let anchor: MotionAnchor
    public let track: MotionTrackPick
    /// Where the spec comes from (document and line), written into the report.
    public let source: String
    /// "Lift only after moving more than N points from the press": when given, compares how far the pointer was from the press point on the frame the track starts moving.
    public let minPointerTravel: Double?
    public let expectations: [MotionExpectation]

    public init(name: String, anchor: MotionAnchor, track: MotionTrackPick, source: String, minPointerTravel: Double? = nil,
                expectations: [MotionExpectation]) {
        self.name = name
        self.anchor = anchor
        self.track = track
        self.source = source
        self.minPointerTravel = minPointerTravel
        self.expectations = expectations
    }
}

/// One row of the comparison report: spec / measured / diff.
public struct MotionReportRow: Equatable, Sendable {
    public var track: String
    public var item: String
    public var spec: String
    public var measured: String
    public var diff: String
    public var note: String?
}

// MARK: - A recording

/// When the driver delivered input (the driver process's CACurrentMediaTime): interaction start, and release (the moment the interaction
/// finished; nil without a drag).
public struct MotionInputs: Equatable, Sendable {
    public let start: Double
    public let release: Double?

    public init(start: Double, release: Double?) {
        self.start = start
        self.release = release
    }
}

extension MotionInputs {
    /// Release time: the last time after the interaction started (after `since`) that the app replied `E2E_INPUT_DONE`. The app replies only
    /// after posting the mouse-up event; the wall-clock time the reply arrived is converted to the media clock using the (`wallNow`, `mediaNow`) pair.
    /// The time the whole interaction step finished isn't used: after an action step, waiting to settle and running generic checks (text
    /// recognition takes seconds per window) happen long after the drop has ended.
    public static func releaseTime(lines: [(Date, OutputLine)], since: Int, wallNow: Date, mediaNow: Double) -> Double? {
        guard let done = lines.dropFirst(since).last(where: { $0.1 == .other("E2E_INPUT_DONE") })?.0 else { return nil }
        return mediaNow - wallNow.timeIntervalSince(done)
    }
}

public struct MotionRecording: Sendable {
    public let name: String
    public let targets: [MotionTarget]
    public let tracks: [MotionTrack]
    public let inputs: MotionInputs
    /// Number of captured frames (written to the report; 0 means capture didn't start).
    public let capturedFrames: Int

    public init(name: String, targets: [MotionTarget], tracks: [MotionTrack], inputs: MotionInputs, capturedFrames: Int = 0) {
        self.name = name
        self.targets = targets
        self.tracks = tracks
        self.inputs = inputs
        self.capturedFrames = capturedFrames
    }

    public var start: Double { tracks.compactMap { $0.samples.first?.t }.min() ?? inputs.start }
    public var end: Double { tracks.compactMap { $0.samples.last?.t }.max() ?? start }

    /// Time zero is the first frame where a track changes, not the input delivery time: a SwiftUI animation first changes 33 to 51 ms after
    /// the trigger (measured 2026-10-14). Lift = first change after the interaction starts; release = first change after the interaction ends.
    public func time(of anchor: MotionAnchor) -> Double? {
        switch anchor {
        case .start: start
        case .firstMove: firstChange(after: inputs.start)
        case .release: inputs.release.flatMap(firstChange(after:))
        }
    }

    /// The first time after `t` that any track differs from its previous reading. Each track's first reading is how it looked when recording
    /// started and doesn't count as a change: accessibility readings are shifted later by `axLead`, so the first reading can land after the
    /// interaction starts (in a lift-and-drag measurement this made time zero 221 ms early).
    func firstChange(after t: Double) -> Double? {
        tracks.compactMap { tr -> Double? in
            let ss = tr.source == .pixels ? MotionTear.removing(tr.samples) : tr.samples
            for i in 1..<max(1, ss.count) where ss[i].t >= t && tr.changed(ss[i - 1], ss[i]) { return ss[i].t }
            return nil
        }.min()
    }

    /// Time zero of the track file: lift, or recording start when there is none.
    public var zero: Double { time(of: .firstMove) ?? start }

    /// Time window: from this time zero to the next one after it (exclusive), or to the recording end.
    func window(_ anchor: MotionAnchor) -> ClosedRange<Double>? {
        guard let a = time(of: anchor) else { return nil }
        let next = [MotionAnchor.firstMove, .release].compactMap { time(of: $0) }.filter { $0 > a }.min()
        return a...(next.map { $0 - 1e-9 } ?? max(end, a))
    }

    func pick(_ p: MotionTrackPick, in w: ClosedRange<Double>) -> MotionTrack? {
        switch p {
        case .original: return tracks.first { $0.name == targets.first?.id }
        case .named(let n): return tracks.first { $0.name == n }
        case .moving:
            return tracks.compactMap { tr -> (MotionTrack, CGFloat)? in
                let inside = tr.samples.filter { w.contains($0.t) }
                guard let a = inside.first, let b = inside.last else { return nil }
                return (tr, hypot(b.rect.midX - a.rect.midX, b.rect.midY - a.rect.midY))
            }.max { $0.1 < $1.1 }?.0
        }
    }

    /// Capture readings are noisy frame to frame (template matching on a one-pixel-per-point luminance image, where one pixel of scale is
    /// about 0.005): spans not above the per-frame tolerance aren't fitted, and the end value is the median of the last 100 ms of the window.
    /// Accessibility readings are layout values and still use the last reading.
    static let pixelEndSpan = 0.1

    static func fit(_ pts: [(t: Double, v: Double)], from: Double?, channel c: MotionChannel, track: MotionTrack) -> MotionFit? {
        track.source == .pixels
            ? MotionFitter.fit(pts, from: from, minSpan: MotionTolerance.value(c) ?? 0, endSpan: pixelEndSpan)
            : MotionFitter.fit(pts, from: from)
    }

    /// Three-point median on capture readings, removing single-frame outliers where template matching occasionally jumps to the original
    /// element (overshoot uses the maximum, so one outlier frame can exceed it); accessibility readings are left as is.
    static func smoothed(_ pts: [(t: Double, v: Double)], _ track: MotionTrack) -> [(t: Double, v: Double)] {
        guard track.source == .pixels, pts.count >= 3 else { return pts }
        return pts.indices.map { i in
            guard i > 0, i < pts.count - 1 else { return pts[i] }
            let m = [pts[i - 1].v, pts[i].v, pts[i + 1].v].sorted()[1]
            return (t: pts[i].t, v: m)
        }
    }

    /// Capture tracks are compared with torn frames removed; accessibility tracks have no tearing.
    private func usable(_ tr: MotionTrack) -> [MotionSample] {
        tr.source == .pixels ? MotionTear.removing(tr.samples) : tr.samples
    }

    // MARK: Comparison

    public func compare(_ spec: MotionSpec) -> [MotionReportRow] {
        guard let w = window(spec.anchor) else {
            return [MotionReportRow(track: "-", item: spec.name, spec: "-", measured: "no \(spec.anchor.name) time point", diff: "-")]
        }
        guard let track = pick(spec.track, in: w) else {
            return [MotionReportRow(track: "-", item: spec.name, spec: "-", measured: "no element to compare in the time window", diff: "-")]
        }
        let a = w.lowerBound
        let samples = usable(track)
        var rows: [MotionReportRow] = []
        for e in spec.expectations {
            let c = e.channel
            let inWindow = samples.filter { w.contains($0.t) }
            let pts = Self.smoothed(inWindow.compactMap { s in c.value(s).map { (t: s.t - a, v: $0) } }, track)
            // Smallest resolvable amount of capture readings: items whose spec value or tolerance is smaller are not judged
            let res = MotionResolution.coarsest(c, inWindow)
            let unresolved = { (need: Double) in res.map { need < $0 } ?? false }
            let resNote = res.map { MotionResolution.note(c, $0, inWindow) }
            let before = samples.last { $0.t < a }.flatMap(c.value)
            guard let fit = Self.fit(pts, from: e.from ?? before, channel: c, track: track) else {
                rows.append(MotionReportRow(track: track.name, item: "\(c.name) end value", spec: c.format(e.to), measured: "unknown", diff: "-",
                                            note: c == .shadow ? "shadow radius can't be measured from outside" : nil))
                continue
            }
            let tol = MotionTolerance.value(c)
            if let tol, unresolved(tol) {
                rows.append(MotionReportRow(track: track.name, item: "\(c.name) end value", spec: c.format(e.to), measured: c.format(fit.end),
                                            diff: MotionResolution.verdict, note: "\(resNote ?? ""), tolerance ±\(c.format(tol))"))
            } else {
                rows.append(MotionReportRow(track: track.name, item: "\(c.name) end value", spec: c.format(e.to), measured: c.format(fit.end),
                                            diff: Self.marked(c.signed(fit.end - e.to), over: tol.map { abs(fit.end - e.to) > $0 } ?? false,
                                                              tol: tol.map { "±" + c.format($0) }), note: resNote))
            }
            guard let spring = e.spring else { continue }
            let specMs = spring.t95 * 1000
            let note: String? = fit.jump ? "first frame already at end value (jump, no transition; first frame at \(Self.ms(pts.first?.t ?? 0)) ms after zero)" : nil
            // The time to 95% has to tell "95% done" from "5% to go": when 5% of the start-to-end span is smaller than one pixel, that moment can't be measured
            let band95 = 0.05 * abs(e.to - fit.start)
            if fit.t95 != nil, unresolved(band95) {
                rows.append(MotionReportRow(track: track.name, item: "\(c.name) time to 95% of end value", spec: "\(Self.ms(spring.t95)) ms",
                                            measured: "\(Self.ms(fit.t95!)) ms", diff: MotionResolution.verdict,
                                            note: "\(resNote ?? ""); 5% band \(c.format4(band95))"))
            } else if let t95 = fit.t95 {
                let d = t95 * 1000 - specMs
                rows.append(MotionReportRow(track: track.name, item: "\(c.name) time to 95% of end value", spec: "\(Self.ms(spring.t95)) ms",
                                            measured: "\(Self.ms(t95)) ms",
                                            diff: Self.marked(Self.signedMs(d), over: abs(d) > MotionTolerance.t95Ms,
                                                              tol: "±\(Int(MotionTolerance.t95Ms)) ms"),
                                            note: note ?? "measured from the first frame where the track changes"))
            } else {
                rows.append(MotionReportRow(track: track.name, item: "\(c.name) time to 95% of end value", spec: "\(Self.ms(spring.t95)) ms",
                                            measured: "no movement", diff: "-", note: "\(c.name.lowercased()) didn't change in the time window"))
            }
            let amplitude = abs(fit.end - fit.start) * (c == .scale ? Double(track.samples.first?.rect.width ?? 0) / max(fit.start, 1e-9) : 1)
            let otol = MotionTolerance.overshoot(amplitudePoints: amplitude)
            let od = fit.overshoot - spring.overshoot
            // Overshoot converted to channel units: the spec overshoot and its tolerance are both fractions of the start-to-end span
            let span = abs(e.to - fit.start)
            if unresolved(min(spring.overshoot, otol) * span) {
                rows.append(MotionReportRow(track: track.name, item: "\(c.name) overshoot", spec: Self.percent(spring.overshoot),
                                            measured: Self.percent(fit.overshoot), diff: MotionResolution.verdict,
                                            note: "\(resNote ?? ""); spec overshoot \(c.format4(spring.overshoot * span)), tolerance \(c.format4(otol * span))"))
            } else {
                rows.append(MotionReportRow(track: track.name, item: "\(c.name) overshoot", spec: Self.percent(spring.overshoot),
                                            measured: Self.percent(fit.overshoot),
                                            diff: Self.marked(String(format: "%@%.1f pp", od >= 0 ? "+" : "-", abs(od) * 100),
                                                              over: abs(od) > otol, tol: String(format: "±%.2f pp", otol * 100)),
                                            note: resNote))
            }
            // Per-frame comparison with the spec curve: start from the spec's value or the last reading before zero, and follow the spring from zero to the end value
            let from = fit.start, to = e.to, s = spring.spring
            let curve = { (t: Double) in t <= 0 ? from : from + s.value(target: to - from, time: t) }
            if let tol, let worst = MotionTolerance.worstDeviation(pts, expected: curve), unresolved(tol) {
                rows.append(MotionReportRow(track: track.name, item: "\(c.name) per-frame deviation from spec curve", spec: "±" + c.format(tol),
                                            measured: "max \(c.format(worst.dev)) (\(Self.ms(worst.t)) ms after zero)",
                                            diff: MotionResolution.verdict, note: resNote))
            } else if let tol, let worst = MotionTolerance.worstDeviation(pts, expected: curve) {
                rows.append(MotionReportRow(track: track.name, item: "\(c.name) per-frame deviation from spec curve", spec: "±" + c.format(tol),
                                            measured: "max \(c.format(worst.dev)) (\(Self.ms(worst.t)) ms after zero)",
                                            diff: Self.marked(c.signed(worst.dev), over: worst.dev > tol, tol: "±" + c.format(tol)),
                                            note: "each frame compared with the closest spec curve value within one frame before or after"))
            }
        }
        if let min = spec.minPointerTravel { rows.append(travelRow(track: track, samples: samples, window: w, min: min)) }
        rows += axRetakeRows(spec: spec, track: track, window: w)
        return rows
    }

    /// When capture retook the template at the accessibility frame: marks that positions from then on come from the accessibility frame; when
    /// the content jumped relative to the frame by more than the position tolerance across a retake, lists a row "Content jump after <spec name>",
    /// reported only, not judged (a person decides whether it's a motion problem).
    private func axRetakeRows(spec: MotionSpec, track: MotionTrack, window w: ClosedRange<Double>) -> [MotionReportRow] {
        guard track.source == .pixels else { return [] }
        let fixes = track.samples.filter { $0.axRetake && w.contains($0.t) }
        guard let first = fixes.first else { return [] }
        var rows = [MotionReportRow(track: track.name, item: "Position taken from accessibility frame", spec: "-",
                                    measured: "from \(Self.ms(first.t - w.lowerBound)) ms after zero", diff: "-",
                                    note: "the capture template tracks the content inside the element; once accessibility reports a new frame (the element's true position), "
                                        + "the template is retaken at that frame; from here on, capture and accessibility are no longer two independent readings")]
        let tol = MotionTolerance.value(.x) ?? 0.5
        for f in fixes {
            guard let d = f.contentShift, Double(hypot(d.dx, d.dy)) > tol else { continue }
            rows.append(MotionReportRow(track: track.name, item: "Content jump after \(spec.name)", spec: "-",
                                        measured: String(format: "%.1f pt", Double(hypot(d.dx, d.dy))), diff: "reported only, not judged",
                                        note: String(format: "across the template retake at %d ms after zero, content moved (%+.1f, %+.1f) pt relative to the frame; may be a jump the user can see",
                                                     Self.ms(f.t - w.lowerBound), Double(d.dx), Double(d.dy))))
        }
        return rows
    }

    /// Threshold: the lifted element follows the pointer, so how far it is from its original position on the frame it starts moving is how far
    /// the pointer had at least moved when lift triggered (assumption, not measured). Not exceeding the threshold means lift definitely triggered too early.
    private func travelRow(track: MotionTrack, samples: [MotionSample], window w: ClosedRange<Double>, min: Double) -> MotionReportRow {
        let item = "Element offset from original position at onset"
        let spec = String(format: "> %.1f pt", min)
        guard let origin = samples.last(where: { $0.t < w.lowerBound }) ?? samples.first,
              let onset = samples.first(where: { w.contains($0.t) }) else {
            return MotionReportRow(track: track.name, item: item, spec: spec, measured: "didn't start moving", diff: "-")
        }
        let d = Double(hypot(onset.rect.midX - origin.rect.midX, onset.rect.midY - origin.rect.midY))
        return MotionReportRow(track: track.name, item: item, spec: spec, measured: String(format: "%.1f pt", d),
                               diff: d <= min ? String(format: "-%.1f", min - d) : "-",
                               note: "distance of the element center on the onset frame from where it was when recording started; when the element follows the pointer, a lower bound on pointer travel at trigger")
    }

    private static func marked(_ diff: String, over: Bool, tol: String?) -> String {
        over ? diff + " (over \(tol ?? ""))" : diff
    }

    private static func ms(_ s: Double) -> Int { Int((s * 1000).rounded()) }
    private static func signedMs(_ v: Double) -> String { (v < 0 ? "-" : "+") + "\(Int(abs(v).rounded())) ms" }
    private static func percent(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

    // MARK: Files

    /// `motion-<name>.jsonl`: one line per reading; `ms` is measured from time zero (`zero`), coordinates and sizes are points in the window
    /// (top-left origin), `src` is the source (ax accessibility, px capture), and capture readings also have `match` (correlation with the template).
    public func jsonl() -> String {
        struct Row { let t: Double; let order: Int; let tr: MotionTrack; let s: MotionSample }
        var rows: [Row] = []
        for (i, tr) in tracks.enumerated() { for s in tr.samples { rows.append(Row(t: s.t, order: i, tr: tr, s: s)) } }
        rows.sort { ($0.t, $0.order) < ($1.t, $1.order) }
        let r = { (v: Double, d: Double) in (v * d).rounded() / d }
        return rows.map { row in
            let obj: [String: Any] = [
                "ms": Int(((row.t - zero) * 1000).rounded()), "id": row.tr.name, "src": row.tr.source.rawValue,
                "x": r(Double(row.s.rect.minX), 10), "y": r(Double(row.s.rect.minY), 10),
                "w": r(Double(row.s.rect.width), 10), "h": r(Double(row.s.rect.height), 10),
                "scale": r(row.s.scale, 10_000), "opacity": row.s.opacity.map { r($0, 1000) as Any } ?? "unknown",
                "shadow": row.s.shadow.map { r($0, 10) as Any } ?? "unknown",
            ].merging(row.s.match.map { ["match": r($0, 1000)] } ?? [:]) { a, _ in a }
            let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: d, as: UTF8.self)
        }.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }

    /// `motion-<name>.txt`: time definitions, how readings are taken and where tolerances come from, "spec / measured / diff" for each spec,
    /// then each track's per-channel start, end and 95% time.
    public func report(specs: [MotionSpec], notes: [String] = []) -> String {
        var out: [String] = []
        out.append("Motion comparison: \(name)")
        let dur = Int(((end - start) * 1000).rounded())
        out.append("Recording: \(dur) ms, \(capturedFrames) captured frames; time zero of the track file = \(time(of: .firstMove) != nil ? MotionAnchor.firstMove.name : "recording start").")
        out.append("Readings: measured from outside the app under test. ax tracks poll accessibility frames (every 2 ms, times shifted 17 ms because readings lead the screen by about one frame); "
                   + "px tracks template-match the element as it looked at recording start in display-filter captures (torn frames removed); opacity is the template regression slope (assumes a uniform background, not measured).")
        out.append("Time zero is the first frame where a track changes, not the input delivery time. 95% time = time from zero until a reading first covers 95% of the start-to-end span; overshoot = largest amount past the end value as a fraction of the start-to-end span.")
        out.append("Items with diff \"below resolution, not judged\": the spec value, tolerance or the band used for the 95% time (5% of the start-to-end span) is smaller than what one captured pixel can resolve, so it can't be measured and isn't judged; the smallest resolvable amount is in that row's parentheses.")
        out.append("Diffs marked \"over\" exceed the tolerance: tolerances come from the 2026-10-14 measurement and were measured only on solid-color elements; real UI with text and shadows will have larger errors, not measured.")
        let springs = specs.flatMap { $0.expectations.compactMap(\.spring) }
        var seen: Set<String> = []
        for s in springs where seen.insert(s.description).inserted {
            out.append("Spec spring: \(s.description)")
        }
        out.append(contentsOf: notes)
        for spec in specs {
            out.append("")
            let rows = compare(spec)
            out.append("## \(spec.name) (time zero: \(spec.anchor.name); compared element: \(rows.first?.track ?? "-"); source: \(spec.source))")
            out.append("Item: spec / measured / diff")
            for r in rows {
                out.append("  \(r.item): \(r.spec) / \(r.measured) / \(r.diff)" + (r.note.map { "  (\($0))" } ?? ""))
            }
        }
        out.append("")
        out.append("## Elements (times from zero)")
        for tr in tracks {
            guard let a = tr.samples.first, let b = tr.samples.last else { continue }
            let ss = usable(tr)
            let torn = tr.samples.count - ss.count
            out.append("\(tr.name) (\(tr.source == .accessibility ? "accessibility" : "capture")): from \(Self.ms(a.t - zero)) ms to \(Self.ms(b.t - zero)) ms, "
                       + counted(tr.samples.count, "reading") + (torn > 0 ? ", \(counted(torn, "torn frame")) removed" : ""))
            for c in MotionChannel.allCases {
                let pts = Self.smoothed(ss.compactMap { s in c.value(s).map { (t: s.t - zero, v: $0) } }, tr)
                if pts.isEmpty { out.append("  \(c.name): unknown"); continue }
                guard let fit = Self.fit(pts, from: nil, channel: c, track: tr), fit.t95 != nil else {
                    if let v = pts.first?.v { out.append("  \(c.name): \(c.format(v)) unchanged") }
                    continue
                }
                let onset = pts.first { abs($0.v - fit.start) > abs(fit.end - fit.start) * 0.02 }?.t
                out.append("  \(c.name): \(c.format(fit.start)) → \(c.format(fit.end)), " +
                           "starts changing \(onset.map { "\(Self.ms($0)) ms" } ?? "-"), 95% at \(fit.t95.map { "\(Self.ms($0)) ms" } ?? "-"), " +
                           "overshoot \(Self.percent(fit.overshoot))")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }
}

// MARK: - Stills sheet

public enum MotionStills {
    /// Padding around each cell and height of the label strip (pixels).
    public static let padding = 8
    public static let labelHeight = 28
    /// Default still times (milliseconds from time zero).
    public static let defaultOffsets = [0, 50, 100, 150, 250, 400]

    /// Which frame was on screen at each time: the last frame displayed no later than it; the first frame when earlier than the first frame.
    public static func pick(frameTimes: [Double], at times: [Double]) -> [Int] {
        times.map { t in frameTimes.lastIndex { $0 <= t } ?? 0 }
    }

    /// Lays cells out in a grid (row-major), each with a label strip above. Cells are sized to the largest image; smaller images sit top-left.
    public static func sheet(cells: [(String, CGImage)], columns: Int) -> CGImage? {
        guard !cells.isEmpty, columns > 0 else { return nil }
        let cw = cells.map(\.1.width).max()!, ch = cells.map(\.1.height).max()!
        let cellW = cw + 2 * padding, cellH = ch + labelHeight + 2 * padding
        let cols = min(columns, cells.count), rows = (cells.count + columns - 1) / columns
        let W = cols * cellW, H = rows * cellH
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.93, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, CGFloat(labelHeight) * 0.6, nil)
        for (i, (label, img)) in cells.enumerated() {
            let col = i % columns, row = i / columns
            let x0 = col * cellW, yTop = row * cellH
            // CGContext origin is bottom-left
            let imgRect = CGRect(x: x0 + padding, y: H - (yTop + padding + labelHeight + img.height), width: img.width, height: img.height)
            ctx.draw(img, in: imgRect)
            ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
            ctx.setLineWidth(1)
            ctx.stroke(imgRect.insetBy(dx: -0.5, dy: -0.5))
            let attr = NSAttributedString(string: label, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
            ])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: CGFloat(x0 + padding), y: CGFloat(H - (yTop + padding + labelHeight)) + CGFloat(labelHeight) * 0.3)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }
}

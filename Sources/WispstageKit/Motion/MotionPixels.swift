import CoreGraphics
import Foundation

/// A crop of a captured frame kept at native pixel density (2 px per pt on Retina): near the targets; `origin` is its top-left corner in window points.
public struct MotionCrop: Sendable {
    public let origin: CGPoint
    public let pixelsPerPoint: Double
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(origin: CGPoint, pixelsPerPoint: Double, width: Int, height: Int, pixels: [UInt8]) {
        self.origin = origin
        self.pixelsPerPoint = pixelsPerPoint
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The area this crop covers in the window (points).
    public var rect: CGRect {
        CGRect(x: origin.x, y: origin.y, width: Double(width) / pixelsPerPoint, height: Double(height) / pixelsPerPoint)
    }
}

/// One captured frame: luminance, one pixel per point, in the window, top-left origin; `crop` is a crop of the same frame near the targets at native pixel density (nil when absent).
public struct MotionGrayFrame: Sendable {
    public let t: Double
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public let crop: MotionCrop?

    public init(t: Double, width: Int, height: Int, pixels: [UInt8], crop: MotionCrop? = nil) {
        self.t = t
        self.width = width
        self.height = height
        self.pixels = pixels
        self.crop = crop
    }

    public var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Tracks an element in captured frames: what is inside its frame in the first recorded frame is the template, and each later frame finds the
/// best-matching translation and scale about the center (highest normalized cross-correlation, see `cost`).
/// Elements missing from the accessibility tree (a lifted element with accessibilityHidden) can only be tracked this way; opacity is estimated
/// from the template regression slope (assumes a uniform background beneath the element, not measured).
/// Error hasn't been measured against ground truth: the 2026-10-14 capture precision measurement used coverage centroids and column projections
/// of solid-color blocks, not template matching.
public enum MotionPixelTracker {
    /// The template is taken this many points inside the frame (so background outside rounded corners stays out of the template).
    static let inset: CGFloat = 3
    /// Coarse search radius around the predicted position (points): on a drop the element flies into its slot and can move over ten points in one frame.
    static let searchRadius = 24
    /// Opacity can't be measured when the template's luminance standard deviation is below this many levels (value not yet measured).
    static let minContrast: Float = 8
    /// When the best position's normalized cross-correlation with the template is below this value, tracking is lost and later frames produce no
    /// output: after a drop the lifted copy is removed and the real element appears with a different look, and searching on runs off thousands of
    /// points outside the window (measured in a lift-and-drag recording). Value not yet measured.
    static let minMatch: Float = 0.5

    /// Template: offsets from the frame center and luminance.
    struct Template {
        var du: [Float] = []
        var dv: [Float] = []
        var val: [Float] = []
        var mean: Float = 0
        var std: Float = 0

        init(frame: MotionGrayFrame, rect: CGRect, step: Int) {
            self.init(pixels: frame.pixels, width: frame.width, height: frame.height, origin: .zero, k: 1, rect: rect, step: step)
        }

        /// `pixels` is `width`x`height` luminance, with the top-left pixel at window point `origin` and `k` pixels per point; `step` is in pixels.
        init(pixels: [UInt8], width: Int, height: Int, origin: CGPoint, k: Double, rect: CGRect, step: Int) {
            let r = rect.insetBy(dx: MotionPixelTracker.inset, dy: MotionPixelTracker.inset)
            let cx = Float(rect.midX), cy = Float(rect.midY)
            let x0 = max(0, Int(((r.minX - origin.x) * k).rounded(.up))), x1 = min(width - 1, Int(((r.maxX - origin.x) * k).rounded(.down)) - 1)
            let y0 = max(0, Int(((r.minY - origin.y) * k).rounded(.up))), y1 = min(height - 1, Int(((r.maxY - origin.y) * k).rounded(.down)) - 1)
            guard x0 <= x1, y0 <= y1 else { return }
            let ox = Float(origin.x), oy = Float(origin.y), kf = Float(k)
            for y in stride(from: y0, through: y1, by: step) {
                for x in stride(from: x0, through: x1, by: step) {
                    du.append(ox + (Float(x) + 0.5) / kf - cx)
                    dv.append(oy + (Float(y) + 0.5) / kf - cy)
                    val.append(Float(pixels[y * width + x]))
                }
            }
            let n = Float(max(1, val.count))
            mean = val.reduce(0, +) / n
            std = (val.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n).squareRoot()
        }
    }

    /// A luminance image: top-left pixel at window point (ox, oy), k pixels per point. The full-window image is (0, 0, 1).
    struct Plane {
        let p: UnsafeBufferPointer<UInt8>
        let w: Int
        let h: Int
        var ox: Float = 0
        var oy: Float = 0
        var k: Float = 1

        /// Luminance at window point (x, y).
        @inline(__always)
        func at(_ x: Float, _ y: Float) -> Float { MotionPixelTracker.sample(p, w, h, (x - ox) * k, (y - oy) * k) }
    }

    /// Bilinear luminance sample (pixel centers at +0.5); out of bounds clamps to the nearest edge.
    @inline(__always)
    static func sample(_ p: UnsafeBufferPointer<UInt8>, _ w: Int, _ h: Int, _ x: Float, _ y: Float) -> Float {
        let fx = min(max(x - 0.5, 0), Float(w - 1)), fy = min(max(y - 0.5, 0), Float(h - 1))
        let ix = min(Int(fx), w - 2 < 0 ? 0 : w - 2), iy = min(Int(fy), h - 2 < 0 ? 0 : h - 2)
        let ax = fx - Float(ix), ay = fy - Float(iy)
        let i = iy * w + ix
        let a = Float(p[i]), b = Float(p[min(i + 1, p.count - 1)])
        let c = Float(p[min(i + w, p.count - 1)]), d = Float(p[min(i + w + 1, p.count - 1)])
        return (a * (1 - ax) + b * ax) * (1 - ay) + (c * (1 - ax) + d * ax) * ay
    }

    /// Negated normalized cross-correlation of the template centered at (cx, cy) with scale s against the frame (smaller is more similar).
    /// Cross-correlation instead of luminance difference: when an element fades in or out its overall luminance changes and the position of
    /// minimum difference drifts, while cross-correlation is unaffected by linear changes in brightness.
    static func cost(_ t: Template, _ pl: Plane, _ cx: Float, _ cy: Float, _ s: Float) -> Float {
        var sv: Float = 0, svv: Float = 0, svt: Float = 0
        for k in 0..<t.val.count {
            let v = pl.at(cx + t.du[k] * s, cy + t.dv[k] * s)
            sv += v; svv += v * v; svt += v * (t.val[k] - t.mean)
        }
        let n = Float(max(1, t.val.count))
        let varV = svv / n - (sv / n) * (sv / n)
        guard varV > 1e-6, t.std > 1e-6 else { return 0 }
        return -(svt / n) / (varV.squareRoot() * t.std)
    }

    /// A set of templates: which frame and which frame rect they were taken from (`rect`, window points); `s0` is that rect's scale relative to
    /// the frame when recording started.
    /// The native-pixel template `hi` is made only when the crop of the template frame covers the whole element; sample points are every 2 pt
    /// like the full-window template (same sample count, so matching doesn't take several times longer), but take native pixel values and
    /// interpolate on native pixels.
    struct Templates {
        let rect: CGRect
        let s0: Float
        let coarse: Template
        let fine: Template
        let hi: Template?

        init?(frame f: MotionGrayFrame, rect: CGRect, base: CGRect) {
            fine = Template(frame: f, rect: rect, step: 2)
            guard !fine.val.isEmpty else { return nil }
            coarse = Template(frame: f, rect: rect, step: 6)
            self.rect = rect
            s0 = Float(rect.width / base.width)
            hi = f.crop.flatMap { c -> Template? in
                guard c.rect.contains(rect.insetBy(dx: inset, dy: inset)) else { return nil }
                let t = Template(pixels: c.pixels, width: c.width, height: c.height, origin: c.origin, k: c.pixelsPerPoint, rect: rect,
                                 step: max(1, Int((2 * c.pixelsPerPoint).rounded())))
                return t.val.isEmpty ? nil : t
            }
        }
    }

    /// Hill-climbs position and scale in turn, halving the step down to 1/8 pt and 0.0005. `s` is the scale relative to the template frame.
    static func climb(_ t: Template, _ pl: Plane, x x0: Float, y y0: Float, s s0: Float) -> (x: Float, y: Float, s: Float, cost: Float) {
        var x = x0, y = y0, sc = s0
        var cur = cost(t, pl, x, y, sc)
        var step: Float = 1, sstep: Float = 0.008
        while step >= 0.125 {
            var moved = true
            while moved {
                moved = false
                for (ddx, ddy, dds) in [(step, 0, 0), (-step, 0, 0), (0, step, 0), (0, -step, 0), (0, 0, sstep), (0, 0, -sstep)] as [(Float, Float, Float)] {
                    let c = cost(t, pl, x + ddx, y + ddy, sc + dds)
                    if c < cur { cur = c; x += ddx; y += ddy; sc += dds; moved = true }
                }
            }
            step /= 2
            sstep = max(0.0005, sstep / 2)
        }
        return (x, y, sc, cur)
    }

    /// Coarse search: tries centers on the `xs`×`ys` grid and returns the best match.
    static func gridSearch(_ t: Template, _ pl: Plane, xs: StrideThrough<Float>, ys: StrideThrough<Float>, s: Float) -> (cost: Float, x: Float, y: Float) {
        var best = (cost: Float.infinity, x: Float(0), y: Float(0))
        for y in ys { for x in xs { let c = cost(t, pl, x, y, s); if c < best.cost { best = (c, x, y) } } }
        return best
    }

    /// Each reading's `pixelsPerPoint` is the pixel density of the image used for the fine search: when the frame has a native-pixel crop
    /// (`MotionGrayFrame.crop`) covering the element, the fine search runs on the crop, otherwise on the full window (one pixel per point).
    /// Frames whose crop doesn't cover the element fall back to the full window and don't count as lost track. `match` is the reading's correlation with the template.
    /// After losing track (correlation below `minMatch`), runaway positions aren't output; each frame from the lost one on tries to recover,
    /// and frames before recovery have no readings:
    /// 1. When `reacquire(frame, time)` returns a frame rect (read from accessibility) that changed after that time, the template is retaken there:
    ///    the element changed its look (after a drop the lifted copy is replaced by the real element in its list), so the old template no longer matches;
    /// 2. Otherwise looks at the area that changed between this frame and the previous one: first searches it with the old template (missing
    ///    frames, or a jump beyond the coarse search radius in one frame); if that fails and the changed area is about the element's size,
    ///    retakes the template there. A template with no light and dark variation (background) doesn't count.
    /// While tracking, it also asks `reacquire(frame, time the current template was taken)`: when the returned rect differs from the captured
    /// position by more than the position tolerance, the template is retaken at that rect, the reading is marked `axRetake`, and `contentShift`
    /// records how far the content jumped relative to the frame.
    public static func track(frames: [MotionGrayFrame], rect: CGRect,
                             reacquire: ((MotionGrayFrame, Double) -> CGRect?)? = nil) -> [MotionSample] {
        guard let base = frames.first, rect.width > 2 * inset, rect.height > 2 * inset,
              var tpl = Templates(frame: base, rect: rect, base: rect) else { return [] }
        var out: [MotionSample] = []
        // s is the scale relative to the frame when recording started; divide by tpl.s0 when comparing with the template
        var cx = Float(rect.midX), cy = Float(rect.midY), s: Float = 1
        var vx: Float = 0, vy: Float = 0
        var lostAfter: Double?
        var lastGood = base.t
        // When the current template was taken: only accessibility frames that changed after this count
        var tplTime = base.t
        for (fi, f) in frames.enumerated() {
            // Which image this frame's fine search uses: the crop, when it covers the element (the template area) at the predicted position
            let hiCrop = { (x: Float, y: Float) -> MotionCrop? in
                guard tpl.hi != nil, let c = f.crop else { return nil }
                let w = rect.width * CGFloat(s), h = rect.height * CGFloat(s)
                let r = CGRect(x: CGFloat(x) - w / 2, y: CGFloat(y) - h / 2, width: w, height: h).insetBy(dx: inset - 2, dy: inset - 2)
                return c.rect.contains(r) ? c : nil
            }
            var ppp = 1.0
            var match: Float = 1
            var axRetake = false
            var shift: CGVector?
            let found: Bool = f.pixels.withUnsafeBufferPointer { p in
                let full = Plane(p: p, w: f.width, h: f.height)
                // Fine search from (x, y); when the correlation is high enough, update the position; returns whether tracking held
                let refine = { (x: Float, y: Float) -> Bool in
                    let rs = s / tpl.s0
                    let r: (x: Float, y: Float, s: Float, cost: Float)
                    var k = 1.0
                    if let c = hiCrop(x, y), let hi = tpl.hi {
                        r = c.pixels.withUnsafeBufferPointer { cp in
                            climb(hi, Plane(p: cp, w: c.width, h: c.height, ox: Float(c.origin.x), oy: Float(c.origin.y), k: Float(c.pixelsPerPoint)),
                                  x: x, y: y, s: rs)
                        }
                        k = c.pixelsPerPoint
                    } else {
                        r = climb(tpl.fine, full, x: x, y: y, s: rs)
                    }
                    guard -r.cost >= minMatch else { return false }
                    ppp = k
                    match = -r.cost
                    vx = r.x - cx; vy = r.y - cy
                    cx = r.x; cy = r.y; s = r.s * tpl.s0
                    return true
                }
                // Retake the template at r (window points); if that works, continue tracking from there
                let retake = { (r: CGRect) -> Bool in
                    guard let t = Templates(frame: f, rect: r, base: rect), t.fine.std >= minContrast else { return false }
                    tpl = t
                    tplTime = f.t
                    cx = Float(r.midX); cy = Float(r.midY); s = t.s0
                    vx = 0; vy = 0
                    ppp = t.hi != nil ? (f.crop?.pixelsPerPoint ?? 1) : 1
                    match = 1
                    return true
                }
                if fi == 0 {
                    if let c = hiCrop(cx, cy) { ppp = c.pixelsPerPoint }
                    return true
                }
                if lostAfter == nil {
                    // Coarse search: predict from the previous frame's velocity and try every 2 pt around it (keeping the previous frame's scale)
                    let px = cx + vx, py = cy + vy, R = Float(searchRadius)
                    let best = gridSearch(tpl.coarse, full, xs: stride(from: px - R, through: px + R, by: 2),
                                          ys: stride(from: py - R, through: py + R, by: 2), s: s / tpl.s0)
                    if refine(best.x, best.y) {
                        // Tracking held, but accessibility reported a new frame that differs from the captured position by more than the position tolerance: the template follows the content inside the element (for example text),
                        // and the content moved within the frame (the settled element gains an extra control and its text shifts right). The frame is the element's position, so retake the template there
                        let w = rect.width * CGFloat(s), h = rect.height * CGFloat(s)
                        let tol = CGFloat(MotionTolerance.value(.x) ?? 0.5)
                        if let r = reacquire?(f, tplTime),
                           abs(r.minX - (CGFloat(cx) - w / 2)) > tol || abs(r.minY - (CGFloat(cy) - h / 2)) > tol {
                            let d = CGVector(dx: CGFloat(cx) - r.midX, dy: CGFloat(cy) - r.midY)
                            if retake(r) { axRetake = true; shift = d }
                        }
                        return true
                    }
                    lostAfter = lastGood
                }
                // Lost track: first retake at the accessibility frame, then look at the changed area
                if let la = lostAfter, let r = reacquire?(f, la), retake(r) { axRetake = true; return true }
                guard let cb = MotionQuiet.changedBounds(frames[fi - 1], f, step: 2) else { return false }
                let best = gridSearch(tpl.coarse, full, xs: stride(from: Float(cb.minX), through: Float(cb.maxX), by: 2),
                                      ys: stride(from: Float(cb.minY), through: Float(cb.maxY), by: 2), s: s / tpl.s0)
                // The recovery jump isn't velocity (frames were missing in between), so predict the next frame from where it is
                if best.cost.isFinite, refine(best.x, best.y) { vx = 0; vy = 0; return true }
                let w = rect.width * CGFloat(s), h = rect.height * CGFloat(s)
                let like = (0.7...1.5).contains(cb.width / w) && (0.7...1.5).contains(cb.height / h)
                return like && retake(cb)
            }
            guard found else { continue }
            lostAfter = nil
            lastGood = f.t
            let o = f.pixels.withUnsafeBufferPointer { p in opacity(tpl.fine, Plane(p: p, w: f.width, h: f.height), cx, cy, s / tpl.s0) }
            let w = Double(rect.width) * Double(s), h = Double(rect.height) * Double(s)
            out.append(MotionSample(t: f.t, rect: CGRect(x: Double(cx) - w / 2, y: Double(cy) - h / 2, width: w, height: h),
                                    scale: Double(s), opacity: o, shadow: nil, pixelsPerPoint: ppp, match: Double(match)))
            out[out.count - 1].axRetake = axRetake
            out[out.count - 1].contentShift = shift
        }
        return out
    }

    /// Regression slope of luminance against the template: when the element is composited at α over a uniform background, frame = α·template + (1-α)·background, so the slope is α.
    static func opacity(_ t: Template, _ pl: Plane, _ cx: Float, _ cy: Float, _ s: Float) -> Double? {
        guard t.std >= minContrast, !t.val.isEmpty else { return nil }
        var sxy: Float = 0, sx: Float = 0
        var vals: [Float] = []
        vals.reserveCapacity(t.val.count)
        for k in 0..<t.val.count { vals.append(pl.at(cx + t.du[k] * s, cy + t.dv[k] * s)) }
        let my = vals.reduce(0, +) / Float(vals.count)
        for k in 0..<t.val.count {
            sxy += (t.val[k] - t.mean) * (vals[k] - my)
            sx += (t.val[k] - t.mean) * (t.val[k] - t.mean)
        }
        return sx > 0 ? Double(sxy / sx) : nil
    }

    /// Opacity of the element at `rect` (window points) scaled by `scale` about its center, with the template taken from `baseRect` in frame `base`.
    static func opacity(in frame: MotionGrayFrame, rect: CGRect, scale: Double, base: MotionGrayFrame, baseRect: CGRect) -> Double? {
        let t = Template(frame: base, rect: baseRect, step: 3)
        return frame.pixels.withUnsafeBufferPointer { p in
            opacity(t, Plane(p: p, w: frame.width, h: frame.height), Float(rect.midX), Float(rect.midY), Float(scale))
        }
    }
}

/// Waiting for the screen to settle: only the area near the targets (window points) is watched; changes elsewhere (a clock, the cursor, another panel) don't count.
public enum MotionQuiet {
    /// A pixel counts as changed when its luminance differs by more than this many levels: captured luminance is lossless and identical frame to
    /// frame at rest (measured 2026-10-14: "maximum 0 at rest"); a few levels of margin cover last-digit color conversion. Value not yet measured.
    static let threshold = 6

    /// Time of the last frame that differs from its previous frame within the region; nil if it never changed.
    public static func lastChange(frames: [MotionGrayFrame], region: CGRect) -> Double? {
        guard frames.count >= 2 else { return nil }
        for i in stride(from: frames.count - 1, to: 0, by: -1) where differs(frames[i - 1], frames[i], in: region) { return frames[i].t }
        return nil
    }

    /// Bounding rect (window points) of pixels whose luminance changed between two adjacent frames; nil if none changed. `step` samples every
    /// nth pixel (computed for every frame in the capture callback, so it has to be fast), and the rect is padded by step so edges between two sample points aren't missed.
    public static func changedBounds(_ a: MotionGrayFrame, _ b: MotionGrayFrame, step: Int = 1) -> CGRect? {
        guard a.width == b.width, a.height == b.height else { return CGRect(x: 0, y: 0, width: b.width, height: b.height) }
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for y in Swift.stride(from: 0, to: a.height, by: step) {
                    let row = y * a.width
                    for x in Swift.stride(from: 0, to: a.width, by: step) where abs(Int(pa[row + x]) - Int(pb[row + x])) > threshold {
                        x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                    }
                }
            }
        }
        guard x1 >= 0 else { return nil }
        let pad = step - 1
        return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1).insetBy(dx: CGFloat(-pad), dy: CGFloat(-pad))
    }

    static func differs(_ a: MotionGrayFrame, _ b: MotionGrayFrame, in region: CGRect) -> Bool {
        guard a.width == b.width, a.height == b.height else { return true }
        let x0 = max(0, Int(region.minX.rounded(.down))), x1 = min(a.width, Int(region.maxX.rounded(.up)))
        let y0 = max(0, Int(region.minY.rounded(.down))), y1 = min(a.height, Int(region.maxY.rounded(.up)))
        guard x0 < x1, y0 < y1 else { return false }
        for y in y0..<y1 {
            let row = y * a.width
            for x in x0..<x1 where abs(Int(a.pixels[row + x]) - Int(b.pixels[row + x])) > threshold { return true }
        }
        return false
    }
}

/// The native-pixel crop follows changes on screen: it keeps wherever changed (padded by `margin` pt), and frames without changes reuse the
/// previous area (a resting element is still inside it). The first area is the targets' frames when recording starts. Only one crop is kept,
/// not the full window: a full window at 2x pixels is several MB a frame, reaching GB within a few seconds of motion.
public enum MotionHiRes {
    /// Extra points kept around the crop: when only part of an element changes (for example only its text color), the crop still usually covers the whole element. Value not yet measured.
    public static let margin: CGFloat = 12
    /// Crops use at most this many bytes per recording; later frames keep no crop (only the full window at one pixel per point). Value not yet measured.
    static let byteBudget = 512 * 1024 * 1024

    public static func nextRegion(previous: CGRect, changed: CGRect?) -> CGRect {
        changed.map { $0.insetBy(dx: -margin, dy: -margin) } ?? previous
    }
}

/// Accessibility frames used to retake the template after capture loses track.
public enum MotionReacquire {
    public struct Reading: Equatable, Sendable {
        public let t: Double
        public let rect: CGRect
        public init(t: Double, rect: CGRect) { self.t = t; self.rect = rect }
    }

    /// The latest reading at time `t`, provided it changed to that value after tracking was lost (`lostAfter`, the time of the last good reading
    /// before the loss); otherwise nil. Polling records only changed readings, and during a drag the frame at the original position never changes
    /// (the lifted copy isn't in the accessibility tree), so taking a template from an older reading would capture the placeholder at the original position.
    public static func axRect(_ readings: [Reading], at t: Double, lostAfter: Double) -> CGRect? {
        guard let r = readings.last(where: { $0.t <= t }), r.t > lostAfter else { return nil }
        return r.rect
    }
}

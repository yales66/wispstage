import ApplicationServices
import CoreGraphics
import Foundation

/// Occlusion: text fully covered by something stacked above it in the same app (such as a detail panel covering the content beneath it)
/// is still in the accessibility tree with its frame unchanged, but cannot be seen, so it should not take part in the overlap and bounds checks.
/// Method: hit-test a few points inside the element's frame (`AXUIElementCopyElementAtPosition`); for text, add the layers the hit test passes through
/// from the tree order (`Layering`); for each point covered by something else, decide from the screenshot whether the covering layer is transparent, glass or opaque (`classify`, `layerKind`),
/// and combine them into one state (`state`, `refinePartial`). Text beneath a fully transparent layer is not occluded; text fully covered by an opaque or glass layer is left out of the text checks;
/// partly visible text takes part as usual, and text partly covered locally fails the step (`Check.occlusion`).
public enum Occlusion {
    /// The hit-test result at one point: `own` is the element itself, an ancestor or a descendant; `other` is another element. nil when no result can be read.
    public enum Hit: Equatable, Sendable { case own, other }

    /// What the covering layer looks like at a point that hits another element:
    /// - seeThrough: fully transparent (receives clicks but draws nothing, such as the dismiss layer outside a detail panel); the text beneath stays visible, not occlusion;
    /// - glass: translucent glass, what is beneath shows through blurred; counts as occlusion;
    /// - opaque: opaque; counts as occlusion;
    /// - otherWindow: another window of the same app (such as a floating panel above the main window). It is not in this window's screenshot, so it is not judged by pixels;
    ///   full coverage counts as occlusion; partial coverage is marked separately and does not count as partial occlusion within this window (a floating window floats as designed; it is not a layout error).
    public enum Cover: Equatable, Sendable { case seeThrough, glass, opaque, otherWindow }

    /// One sample point: hits the element itself (or an ancestor or descendant), or is covered by something else.
    public enum PointHit: Equatable, Sendable { case own, covered(Cover) }

    /// An element's occlusion state, written at the end of its listing line.
    public enum State: String, Equatable, Sendable {
        case visible, occluded, underGlass, partial, partialGlass, partialOtherWindow, partialUnderLayer

        /// Fully invisible (fully covered by opaque or glass): left out of the overlap, bounds and contrast checks.
        public var hidesText: Bool { self == .occluded || self == .underGlass }

        /// The mark at the end of the listing line.
        public var mark: String? {
            switch self {
            case .visible: nil
            case .occluded: "occluded"
            case .underGlass: "under glass"
            case .partial: "partly covered"
            case .partialGlass: "partly under glass"
            case .partialOtherWindow: "partly under another window"
            case .partialUnderLayer: "partly under an overlay"
            }
        }
    }

    /// Combines the sample points into one state, ignoring unreadable points. When there are both visible points (hitting itself or seen through a transparent layer) and covered points, it is partly covered:
    /// with an opaque cover among them it is "partly covered", otherwise with glass "partly under glass", and covered only by other windows "partly under another window". With no visible point, glass gives "under glass", otherwise "occluded".
    public static func state(_ points: [PointHit?]) -> State {
        var seen = 0, glass = 0, opaque = 0, window = 0
        for p in points.compactMap({ $0 }) {
            switch p {
            case .own, .covered(.seeThrough): seen += 1
            case .covered(.glass): glass += 1
            case .covered(.opaque): opaque += 1
            case .covered(.otherWindow): window += 1
            }
        }
        if glass + opaque + window == 0 { return .visible }
        if seen == 0 { return glass > 0 ? .underGlass : .occluded }
        return opaque > 0 ? .partial : glass > 0 ? .partialGlass : .partialOtherWindow
    }

    /// Partial occlusion splits in two: when every opaque layer covering it is an overlay (the same layer fully covers some other element, such as a detail panel), text half showing at the overlay's edge is by design,
    /// recorded as "partly under an overlay" and listed for review (does not fail the step); when some layer covers only a corner of it and fully covers no element, the layout collided, so it stays "partly covered" and fails the step.
    static func refinePartial(_ s: State, opaqueCoverers: Set<Int>, overlays: Set<Int>) -> State {
        guard s == .partial, !opaqueCoverers.isEmpty, opaqueCoverers.isSubset(of: overlays) else { return s }
        return .partialUnderLayer
    }

    /// Colors within this difference (per component, 0…1) count as the same color. Not yet measured.
    public static let colorTolerance = 0.08
    /// The sample patch needs at least this many pixels in the element's own text color for its text to count as visible. Not yet measured.
    public static let minimumTextPixels = 2
    /// A sample patch whose luminance range (95th minus 5th percentile) is below this counts as a solid color. Not yet measured.
    public static let uniformRange = 0.03
    /// A luminance difference this large between adjacent pixels counts as a clear edge (glyphs, lines); glass blur smooths edges away. Not yet measured.
    public static let sharpEdge = 0.15

    /// Decides the layer covering a sample point that hits another element (rough, by pixels). `patch` is the screenshot pixels around the sample point within the element's own frame;
    /// `textColor` is the element's own text color (already composited over its own background), nil if none; `ownBackground` is the background color where the element is not covered;
    /// `coverHasContent`: the covering layer has its own accessibility elements in this patch (its text or images), so glyphs in the patch may be its own, and transparency is not decided from the text color.
    /// Order: the patch contains the element's text color → transparent; a solid color → transparent if it matches the element's own background (a blank part of the element), otherwise opaque;
    /// a clear edge → transparent when there is no text color to compare and the covering layer has no content here (the glyphs seen are the element's own), otherwise opaque; anything else (varied but with blurred edges) → glass.
    public static func classify(patch: RGBAImage, textColor: RGB?, ownBackground: RGB?, coverHasContent: Bool) -> Cover {
        let px = patch.allRGB().map(RGB.init)
        guard !px.isEmpty else { return .opaque }
        if !coverHasContent, let textColor, px.filter({ $0.distance(textColor) <= colorTolerance }).count >= minimumTextPixels {
            return .seeThrough
        }
        let lum = px.map(\.luminance).sorted()
        let range = lum[min(lum.count - 1, lum.count * 95 / 100)] - lum[lum.count * 5 / 100]
        if range < uniformRange {
            let mean = RGB(r: px.map(\.r).reduce(0, +) / Double(px.count), g: px.map(\.g).reduce(0, +) / Double(px.count),
                           b: px.map(\.b).reduce(0, +) / Double(px.count))
            if !coverHasContent, let ownBackground, mean.distance(ownBackground) <= colorTolerance / 2 { return .seeThrough }
            return .opaque
        }
        var edge = 0.0
        for y in 0..<patch.height {
            for x in 0..<patch.width {
                let l = RGB(patch.rgb(x, y)).luminance
                if x + 1 < patch.width { edge = max(edge, abs(l - RGB(patch.rgb(x + 1, y)).luminance)) }
                if y + 1 < patch.height { edge = max(edge, abs(l - RGB(patch.rgb(x, y + 1)).luminance)) }
            }
        }
        if edge >= sharpEdge { return !coverHasContent && textColor == nil ? .seeThrough : .opaque }
        return .glass
    }

    /// Whether a layer covering others is transparent: among the sample points it covers on text (only text counts, since text has a color to compare),
    /// those judged see-through are at least as many as those judged covered. Once decided, all points of every element under this layer follow it (containers have no text color to compare and follow the text's result).
    /// What a layer covering others is: sample points on text where this patch has none of the layer's own content (text has a color to compare) vote.
    /// When see-through votes are at least as many as the rest it is a transparent layer (seeing the element's own text color is strong evidence); otherwise glass if glass votes are at least as many as opaque ones, else opaque. nil without votes.
    /// Once decided, every point this layer covers follows it (neither containers nor patches where the layer has its own content can be judged from pixels alone).
    public static func layerKind(votes: [Cover]) -> Cover? {
        guard !votes.isEmpty else { return nil }
        let seen = votes.filter { $0 == .seeThrough }.count
        let glass = votes.filter { $0 == .glass }.count
        if seen >= votes.count - seen { return .seeThrough }
        return glass >= votes.count - seen - glass ? .glass : .opaque
    }

    /// Sample points: the center first, then one point left and right (text runs horizontally) and one above and below. Tested in order; once one hits the element itself, no more are needed.
    public static func samplePoints(in r: CGRect) -> [CGPoint] {
        [(0.5, 0.5), (0.15, 0.5), (0.85, 0.5), (0.5, 0.25), (0.5, 0.75)].map { fx, fy in
            CGPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy)
        }
    }

    /// The sample area of text: the visible part of the laid-out glyphs' frame (`AXBoundsForRange`), the same frame the overlap check uses; falls back to the element frame when unreadable or not intersecting.
    /// The element frame accessibility reports can be much larger than the text (for the text in a shortcut recorder field, the frame is the whole field, including the clear button at its right end),
    /// so sampling by element frame would count a button over blank space as occlusion; only covers over glyphs count.
    static func sampleRect(visible: CGRect, textBounds: CGRect?) -> CGRect {
        guard let b = textBounds, b.width > 0, b.height > 0 else { return visible }
        let r = b.intersection(visible)
        return r.isNull || r.width <= 0 || r.height <= 0 ? visible : r
    }

    /// Occluded only when at least one sample point has a readable result and all of them hit other elements (partly visible elements still take part in the checks).
    public static func isOccluded(_ hits: [Hit?]) -> Bool {
        let known = hits.compactMap { $0 }
        return !known.isEmpty && known.allSatisfy { $0 == .other }
    }

    /// Tests the sample points in order, stopping at the first one that hits the element itself.
    static func isOccluded(_ r: CGRect, hit: (CGPoint) -> Hit?) -> Bool {
        var hits: [Hit?] = []
        for p in samplePoints(in: r) {
            let h = hit(p)
            if h == .own { return false }
            hits.append(h)
        }
        return isOccluded(hits)
    }
}

/// The identity of an accessibility element (equality by CFEqual), usable in sets.
struct AXRef: Hashable {
    let ref: AXUIElement
    static func == (a: AXRef, b: AXRef) -> Bool { CFEqual(a.ref, b.ref) }
    func hash(into h: inout Hasher) { h.combine(CFHash(ref)) }
}

/// Hit testing on the app under test: `app` is the application element, `ancestors` is the tested element's ancestor chain (excluding itself).
enum HitTest {
    /// A hit-test result: the element itself (or an ancestor or descendant), or another element (carrying the hit element, to decide whether it is a transparent layer).
    enum Result {
        case own
        case other(AXUIElement)

        var isOwn: Bool { if case .own = self { true } else { false } }
    }

    static func hit(app: AXUIElement, at p: CGPoint, element: AXUIElement, ancestors: Set<AXRef>) -> Result? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success, let hit else { return nil }
        let me = AXRef(ref: element)
        let h = AXRef(ref: hit)
        if h == me || ancestors.contains(h) { return .own }
        // Whether the hit is a descendant of the element: walk up the hit element's parent chain looking for it; reaching one of its ancestors (a common ancestor of both) means no
        var cur = hit
        for _ in 0..<80 {
            var v: AnyObject?
            guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &v) == .success, let parent = v,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            let pe = parent as! AXUIElement
            let pr = AXRef(ref: pe)
            if pr == me { return .own }
            if ancestors.contains(pr) { return .other(hit) }
            cur = pe
        }
        return .other(hit)
    }
}

/// What covers what within one window. Hit testing only finds elements that receive clicks: the glass background of a detail panel does not, so the hit test passes through it to the
/// transparent dismiss layer beneath (measured 2026-10-14), so the tree order fills the gap: SwiftUI's accessibility tree follows drawing order, and in a ZStack
/// later views come later and are drawn on top. At a point, among the hit element and the elements after the element (and its subtree) in the tree whose frame contains the point, the last one is the covering layer.
enum Layering {
    /// `frames` and `subtreeEnd` (the exclusive end index of each element's subtree) are in preorder; `hit` is the index of the other element the hit test hit (nil when it hit the element itself).
    static func cover(at p: CGPoint, of i: Int, frames: [CGRect?], subtreeEnd: [Int], hit: Int?) -> Int? {
        var j = frames.count - 1
        while j >= subtreeEnd[i] {
            if let f = frames[j], f.width > 0, f.height > 0, f.contains(p) { return max(j, hit ?? j) }
            j -= 1
        }
        return hit
    }
}

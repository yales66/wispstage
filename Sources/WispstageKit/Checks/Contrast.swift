import CoreGraphics
import Foundation

/// An sRGB color, each component 0…1 (not linearized).
public struct RGB: Equatable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ p: (UInt8, UInt8, UInt8)) {
        self.init(r: Double(p.0) / 255, g: Double(p.1) / 255, b: Double(p.2) / 255)
    }

    /// The largest difference among the three components.
    func distance(_ o: RGB) -> Double { max(abs(r - o.r), abs(g - o.g), abs(b - o.b)) }

    var luminance: Double { WCAG.relativeLuminance(self) }
}

/// The text color the app declares (Accessibility AXForegroundColor, converted to sRGB), with opacity.
public struct TextColor: Equatable, Sendable {
    public var rgb: RGB
    public var alpha: Double

    public init(rgb: RGB, alpha: Double) {
        self.rgb = rgb
        self.alpha = alpha
    }

    /// Converts the CGColor reported by Accessibility to sRGB; nil when it cannot be converted.
    init?(_ color: CGColor) {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let comps = c.components, comps.count >= 3 else { return nil }
        self.init(rgb: RGB(r: Double(comps[0]), g: Double(comps[1]), b: Double(comps[2])),
                  alpha: comps.count >= 4 ? Double(comps[3]) : 1)
    }

    /// Composites over the background by opacity (blending sRGB-encoded values, an approximation that matches system compositing).
    public func composite(over bg: RGB) -> RGB {
        RGB(r: rgb.r * alpha + bg.r * (1 - alpha), g: rgb.g * alpha + bg.g * (1 - alpha), b: rgb.b * alpha + bg.b * (1 - alpha))
    }
}

/// WCAG 2.2 relative luminance, contrast ratio and thresholds (https://www.w3.org/TR/WCAG22/ , retrieved 2026-10-14):
/// - Success Criterion 1.4.3 Contrast (Minimum): text contrast at least 4.5:1, large text at least 3:1.
/// - Term "large scale (text)": at least 18 point or 14 point bold.
/// - Term "relative luminance": L = 0.2126 R + 0.7152 G + 0.0722 B; a component ≤ 0.04045 is divided by 12.92,
///   otherwise ((c + 0.055) / 1.055) ^ 2.4.
/// - Term "contrast ratio": (L1 + 0.05) / (L2 + 0.05), with L1 the lighter one.
/// "Point" means UI point: the contrast table on the Accessibility page of Apple's Human Interface Guidelines pairs "18 pts" and "Bold" with 3:1
/// (https://developer.apple.com/design/human-interface-guidelines/accessibility , retrieved 2026-10-14), i.e. it uses WCAG points as UI points.
public enum WCAG {
    public static let normalTextMinimum = 4.5
    public static let largeTextMinimum = 3.0
    public static let largeTextSize: CGFloat = 18
    public static let largeBoldTextSize: CGFloat = 14

    public static func relativeLuminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    public static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// When the font size is unknown, judge as body text (4.5:1), erring on the strict side.
    public static func minimumRatio(pointSize: CGFloat?, bold: Bool) -> Double {
        guard let s = pointSize else { return normalTextMinimum }
        return s >= largeTextSize || (bold && s >= largeBoldTextSize) ? largeTextMinimum : normalTextMinimum
    }
}

/// Measures text contrast on a per-element crop.
///
/// How colors are picked (rough):
/// - Background: the outermost ring of pixels of the crop (the text frame itself) is bucketed at 16 levels per component, and the mean color of the largest bucket is used. Text frames hug the glyphs, so the outer ring is mostly background;
///   when the outer ring is translucent (glass windows) it is not judged;
///   when the background is a gradient, an image, or a pattern showing through glass, that bucket falls below `minimumBackgroundShare` and it is not judged (returns nil).
/// - Foreground: when the app declares a text color (Accessibility AXForegroundColor), it is composited by opacity over the measured background: note 2 of the WCAG term "contrast ratio"
///   allows ignoring anti-aliasing, which is what using the declared color corresponds to. Without one, the crop is bucketed and the mean color of the bucket with enough pixels that contrasts most with the background is used
///   (the core of thin strokes mostly reaches full color on a 2x display, but small and light text comes out lighter, so the measured contrast is low).
/// Precise: the WCAG formula and thresholds, and the declared text color. Rough: the background color (bucket mode, unreliable on glass and images),
/// the foreground color when none is declared, and text on glass (the system's vibrancy effects change the color actually drawn, so the declared color differs from what is on screen).
/// Calibration: compare item by item against the contrast audit in Accessibility Inspector on the same screen,
/// note the categories that differ a lot, then decide whether to loosen the check or change how colors are picked; do not loosen the thresholds before that comparison.
public enum Contrast {
    public struct Measurement: Equatable {
        public var foreground: RGB
        public var background: RGB
        public var ratio: Double
        public var fromDeclared: Bool
    }

    /// The largest bucket of the outer ring must reach at least this share to count as the background. Value not yet measured.
    public static let minimumBackgroundShare = 0.4
    /// Without a declared text color, a foreground bucket needs at least this many pixels (or this share of the image) to count as strokes rather than noise. Value not yet measured.
    public static let minimumForegroundPixels = 3
    public static let minimumForegroundShare = 0.01

    private static func bucket(_ c: (UInt8, UInt8, UInt8)) -> Int { Int(c.0 >> 4) << 8 | Int(c.1 >> 4) << 4 | Int(c.2 >> 4) }

    /// Groups pixels into buckets and returns each bucket's pixel count and mean color.
    static func buckets(_ pixels: [(UInt8, UInt8, UInt8)]) -> [(count: Int, mean: RGB)] {
        var sums: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
        for p in pixels {
            let k = bucket(p)
            var s = sums[k] ?? (0, 0, 0, 0)
            s.n += 1; s.r += Int(p.0); s.g += Int(p.1); s.b += Int(p.2)
            sums[k] = s
        }
        return sums.values.map { s in
            (s.n, RGB(r: Double(s.r) / Double(s.n) / 255, g: Double(s.g) / Double(s.n) / 255, b: Double(s.b) / Double(s.n) / 255))
        }
    }

    /// Not judged when the mean opacity of the outer ring is below this: a screenshot of a glass window has a translucent background; what shows on screen is whatever is behind the window,
    /// which the screenshot does not contain (measured 2026-10-14: the outer ring of a glass window in light appearance measured #666666 while it looked light gray). Value not yet measured.
    public static let minimumBackgroundAlpha = 0.98

    /// Mean color and share of the largest bucket in the outermost ring of pixels; nil when the ring is translucent.
    static func background(_ img: RGBAImage) -> (color: RGB, share: Double)? {
        guard img.width >= 2, img.height >= 2 else { return nil }
        var ring: [(UInt8, UInt8, UInt8)] = []
        var alpha = 0
        func take(_ x: Int, _ y: Int) {
            ring.append(img.rgb(x, y))
            alpha += Int(img.pixels[(y * img.width + x) * 4 + 3])
        }
        for x in 0..<img.width { take(x, 0); take(x, img.height - 1) }
        for y in 1..<(img.height - 1) { take(0, y); take(img.width - 1, y) }
        guard Double(alpha) / Double(ring.count * 255) >= minimumBackgroundAlpha else { return nil }
        guard let top = buckets(ring).max(by: { $0.count < $1.count }) else { return nil }
        return (top.mean, Double(top.count) / Double(ring.count))
    }

    public static func measure(_ img: RGBAImage, declared: TextColor?) -> Measurement? {
        guard let bg = background(img), bg.share >= minimumBackgroundShare else { return nil }
        if let declared {
            let fg = declared.composite(over: bg.color)
            return Measurement(foreground: fg, background: bg.color, ratio: WCAG.contrastRatio(fg, bg.color), fromDeclared: true)
        }
        let all = img.allRGB()
        let floor = max(minimumForegroundPixels, Int(Double(all.count) * minimumForegroundShare))
        let candidates = buckets(all).filter { $0.count >= floor && $0.mean.distance(bg.color) > 1.0 / 16 }
        guard let fg = candidates.max(by: { WCAG.contrastRatio($0.mean, bg.color) < WCAG.contrastRatio($1.mean, bg.color) }) else { return nil }
        return Measurement(foreground: fg.mean, background: bg.color, ratio: WCAG.contrastRatio(fg.mean, bg.color), fromDeclared: false)
    }
}

extension RGBAImage {
    func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }

    func allRGB() -> [(UInt8, UInt8, UInt8)] {
        var out: [(UInt8, UInt8, UInt8)] = []
        out.reserveCapacity(width * height)
        for y in 0..<height { for x in 0..<width { out.append(rgb(x, y)) } }
        return out
    }

    /// Crops a pixel rectangle (clamped to the image).
    func sub(_ r: CGRect) -> RGBAImage? {
        let rr = r.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rr.isNull, rr.width >= 1, rr.height >= 1 else { return nil }
        let x0 = Int(rr.minX), y0 = Int(rr.minY), w = Int(rr.width), h = Int(rr.height)
        var px: [UInt8] = []
        px.reserveCapacity(w * h * 4)
        for y in y0..<(y0 + h) {
            let start = (y * width + x0) * 4
            px.append(contentsOf: pixels[start..<(start + w * 4)])
        }
        return RGBAImage(width: w, height: h, pixels: px)
    }
}

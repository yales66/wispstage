import AppKit
import CoreGraphics
import Foundation

/// The font Accessibility reports (the AXFont dictionary in an `AXAttributedStringForRange` result: AXFontName, AXFontSize).
/// Measured 2026-10-14: SwiftUI Text reports it, and system font names look like `.SFNS-Semibold`.
public struct FontSpec: Equatable, Sendable {
    public var name: String
    public var size: CGFloat

    public init(name: String, size: CGFloat) {
        self.name = name
        self.size = size
    }

    public init?(axFont: [String: Any]) {
        guard let name = axFont["AXFontName"] as? String, let n = axFont["AXFontSize"] as? NSNumber else { return nil }
        self.init(name: name, size: CGFloat(n.doubleValue))
    }

    /// Weight: system fonts are recognized by the suffix of their name.
    var weight: NSFont.Weight {
        let suffix = name.split(separator: "-").last.map(String.init)?.lowercased() ?? ""
        let table: [String: NSFont.Weight] = [
            "ultralight": .ultraLight, "thin": .thin, "light": .light, "regular": .regular, "medium": .medium,
            "semibold": .semibold, "bold": .bold, "heavy": .heavy, "black": .black,
        ]
        return table[suffix] ?? .regular
    }

    /// WCAG "bold": bold and heavier (CSS bold is 700); semibold (600) does not count.
    public var isBold: Bool { weight >= .bold }

    private var isSystem: Bool { name.hasPrefix(".SF") || name.hasPrefix(".AppleSystem") }

    /// The font rebuilt in the driver process, used to measure how wide and tall the full text is. For system fonts, the weight and the rounded and monospaced variants are recognized by name.
    public var nsFont: NSFont {
        guard isSystem else { return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight) }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let design: NSFontDescriptor.SystemDesign? = name.contains("Rounded") ? .rounded : name.contains("Mono") ? .monospaced : nil
        if let design, let d = base.fontDescriptor.withDesign(design), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }
}

/// Quick filter for truncation: external Accessibility gets the full text, while the frame is the laid-out (already truncated) block. If laying out the full text in the font at the frame's width needs more height than the frame,
/// some text is not shown (single-line truncation and exceeding the line limit both land here). It serves only as a quick filter and as the "width needed by the font" figure in reports; the verdict comes from
/// `TruncationOCR`: this filter misses everything clipped by an outer view (`.clipped()`, `.fixedSize()` overflow), and it cannot measure buttons or placeholder text
/// (measured 2026-10-14).
public enum Truncation {
    /// Lay out with the width widened by this many points: Accessibility frames are rounded to 0.5 points, and glyph widths differ by fractions between the driver's and the app's layout. Value not yet measured; as a quick filter it only affects the wording in reports, not the verdict.
    public static let widthTolerance: CGFloat = 1
    /// Counts as truncated only when the needed height exceeds the frame by more than this many points. Value not yet measured.
    public static let heightTolerance: CGFloat = 2

    /// Width (points) of the full text laid out on one line.
    public static func singleLineWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    public static func isTruncated(_ text: String, font: NSFont, frame: CGSize) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, frame.width > 0, frame.height > 0 else { return false }
        let need = (text as NSString).boundingRect(
            with: CGSize(width: frame.width + widthTolerance, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return ceil(need.height) > frame.height + heightTolerance
    }
}

/// Alignment: when sibling elements of the same role in one container form a vertical column, their left edges (or a right edge or center shared by the whole column) line up.
/// Only vertical stacks are checked: left edges in a horizontal row differ by nature. Spacing is not checked: spacing values in a spec vary by section, so it cannot be a generic check.
public enum Alignment {
    /// Two edges within this many points count as aligned. Value not yet measured.
    public static let tolerance: CGFloat = 2
    /// Judged only with at least this many elements: with two, it is unclear which one is off. Value not yet measured.
    public static let minimumCount = 3

    /// Indices of the misaligned elements. First check that it is a vertical stack (sorted by top edge, no vertical overlap), then find whichever of left edge, right edge and center
    /// has the most aligned elements; only when more than half are aligned does the column count as intended to align, and the rest count as off.
    public static func outliers(_ frames: [CGRect]) -> [Int] {
        guard frames.count >= minimumCount else { return [] }
        let order = frames.indices.sorted { frames[$0].minY < frames[$1].minY }
        for (a, b) in zip(order, order.dropFirst()) where frames[b].minY < frames[a].maxY - tolerance { return [] }
        var best: [Int] = []
        for edge in [\CGRect.minX, \CGRect.maxX, \CGRect.midX] {
            let xs = frames.map { $0[keyPath: edge] }
            for anchor in xs {
                let group = xs.indices.filter { abs(xs[$0] - anchor) <= tolerance }
                if group.count > best.count { best = group }
            }
        }
        guard best.count >= 2, best.count * 2 > frames.count, best.count < frames.count else { return [] }
        return frames.indices.filter { !best.contains($0) }
    }
}

/// Click target: an actionable element's frame is no smaller than the macOS minimum control size in Apple's Human Interface Guidelines.
public enum HitTarget {
    /// Apple Human Interface Guidelines, "Accessibility" page, "Offer sufficiently sized controls" table: macOS default 28x28 pt, minimum 20x20 pt
    /// (https://developer.apple.com/design/human-interface-guidelines/accessibility , retrieved 2026-10-14).
    /// The check uses the official 20x20 (both width and height must meet it).
    public static let minimum = CGSize(width: 20, height: 20)

    static let actionableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXLink",
        "AXComboBox", "AXIncrementor", "AXDisclosureTriangle", "AXTextField", "AXTextArea",
    ]
    /// Drawn by the system and not changeable by the app: scroll bars and the title bar's close, minimize and zoom buttons.
    static let systemRoles: Set<String> = ["AXScrollBar", "AXValueIndicator", "AXMenuBar", "AXMenuBarItem"]
    static let systemSubroles: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]

    static func isSystem(role: String?, subrole: String?) -> Bool {
        role.map(systemRoles.contains) ?? false || subrole.map(systemSubroles.contains) ?? false
    }

    public static func isActionable(role: String?, subrole: String?, actions: [String]) -> Bool {
        if let role, actionableRoles.contains(role) { return true }
        return actions.contains("AXPress")
    }

    public static func isTooSmall(role: String?, subrole: String?, size: CGSize) -> Bool {
        guard let role, actionableRoles.contains(role), !isSystem(role: role, subrole: subrole) else { return false }
        return size.width < minimum.width || size.height < minimum.height
    }
}

/// Missing identifier: visible, with text or actionable, but without an accessibility identifier (scenarios find elements by identifier; without one they can only find them by text).
public enum MissingIdentifier {
    /// `labelledByAncestor`: it sits inside an actionable element that has an identifier (text inside a button), so it can be found through that element.
    public static func isMissing(role: String?, subrole: String?, id: String?, text: String?, actionable: Bool,
                                 labelledByAncestor: Bool) -> Bool {
        guard id?.isEmpty ?? true, !labelledByAncestor, !HitTarget.isSystem(role: role, subrole: subrole) else { return false }
        return !(text?.isEmpty ?? true) || actionable
    }
}

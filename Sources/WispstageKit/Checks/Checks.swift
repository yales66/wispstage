import CoreGraphics
import Foundation

/// The name of a generic check; `t.waive(.overlap, reason: "…")` uses it to waive that check for the next step.
/// The 15 below are built in; adopters can add their own with `Check(rawValue: "my-check")` for `waive` and failure grouping. Custom checks fail the step by default.
public struct Check: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// The app process is still running; on a crash, the path of this run's crash report is attached.
    public static let processAlive = Check(rawValue: "process-alive")
    /// Accessibility requests get a response within 5 seconds (the app is not hung).
    public static let responsive = Check(rawValue: "responsive")
    /// Text contains no unreplaced placeholders (`%@`, `%d`, `{…}`, copy key names).
    public static let placeholder = Check(rawValue: "placeholder")
    /// In an English UI, no count of 1 paired with a plural, such as "1 Minutes".
    public static let plural = Check(rawValue: "plural")
    /// The frames of two text runs in the same window do not overlap.
    public static let overlap = Check(rawValue: "overlap")
    /// Text frames stay inside their window.
    public static let bounds = Check(rawValue: "bounds")
    /// Static text whose full string, laid out in the font Accessibility reports, does not fit its frame (truncated, or more lines than shown); see `Truncation`.
    public static let truncation = Check(rawValue: "truncation")
    /// Contrast between text and background is below the WCAG 1.4.3 threshold (4.5:1 for body text, 3:1 for large text); see `Contrast`.
    public static let contrast = Check(rawValue: "contrast")
    /// Text is partly covered by something opaque in the same app (fully covered text is hidden and does not count); see `Occlusion`.
    public static let occlusion = Check(rawValue: "occlusion")
    /// In background mode (hidden windows), a window of the app under test became the key window and took over the user's keyboard input (the stage's `stage.becameKey`); see `KeyFocus`.
    public static let keyFocus = Check(rawValue: "key-focus")
    /// In background mode, the app under test became frontmost during this step (`ForegroundWatch`): it took the front from the user, so what the user types lands in the app's window.
    public static let foreground = Check(rawValue: "foreground")
    /// A key press sent in this step was not handled by the app under test (the stage's `stage.beep`; in foreground mode, a beep that actually sounded, recorded in observe-only mode); see `StageBeep`.
    public static let beep = Check(rawValue: "beep")
    /// Sibling elements of the same role stacked vertically in one container are not aligned on their left edge (or right edge, or center). Listed for review (does not fail the step).
    public static let alignment = Check(rawValue: "alignment")
    /// An actionable element's frame is smaller than the macOS minimum control size of 20x20 points. Listed for review (does not fail the step).
    public static let hitTarget = Check(rawValue: "hit-target")
    /// Visible, with text or actionable, but without an accessibility identifier. Listed for review (does not fail the step).
    public static let missingIdentifier = Check(rawValue: "missing-id")

    /// Whether this check is judged in the given run mode. In foreground mode the app is supposed to become frontmost and its window to become key,
    /// so `foreground` and `keyFocus` are not judged there; the key and activation events the observe-only stage reports only go to the log.
    /// Beeps are judged in both modes (in foreground mode through the `stage.beep` reported in observe-only mode).
    func judged(in mode: RunMode) -> Bool {
        mode == .background || ![.foreground, .keyFocus].contains(self)
    }

    /// A failing check fails the step; checks listed for review (so false positives do not block scenarios while thresholds are not yet measured) go into summary.txt.
    /// Contrast is listed for review for now: the background color comes from the outer ring of the screenshot (rough, see Contrast), and it reports real problems in
    /// apps that otherwise pass. Failing the step would stop every scenario that shows such a view at its launch step and block the checks after it. Make it fail the step once the background sampling has been checked against measured colors.
    /// Partial occlusion is also listed for review: a popover or overlay covering part of the content beneath it is normal stacking (measured 2026-10-14: a small popover covering step text
    /// made up most of the partial-occlusion failures in a full run), and a generic rule cannot tell an overlay from an accidental cover; text overlapping text still fails the step through overlap.
    public var failsStep: Bool { ![.alignment, .hitTarget, .missingIdentifier, .contrast, .occlusion].contains(self) }

    /// All built-in checks, in the order declared above.
    public static let builtIn: [Check] = [
        .processAlive, .responsive, .placeholder, .plural, .overlap, .bounds, .truncation, .contrast, .occlusion,
        .keyFocus, .foreground, .beep, .alignment, .hitTarget, .missingIdentifier,
    ]
}

/// A run of UI text and its frame on screen (global coordinates, top-left origin, matching CGWindow bounds).
/// `clip` is the frame of its nearest enclosing scroll area: parts scrolled out of view take no part in the overlap and bounds checks.
public struct TextBox: Equatable, Sendable {
    public var text: String
    public var frame: CGRect
    public var clip: CGRect?

    public init(text: String, frame: CGRect, clip: CGRect? = nil) {
        self.text = text
        self.frame = frame
        self.clip = clip
    }

    /// Overlap and bounds compare the frame of the laid-out glyphs (`AXBoundsForRange` over the full text): an element's frame is often larger than its text (a time-range band spanning a whole timeline,
    /// with the text only in the middle), and comparing element frames would count panel text lying over the empty part as overlap. When the layout frame is zero-sized or outside the element frame, the element frame is used.
    static func laidOut(text: String, frame: CGRect, textBounds: CGRect?, clip: CGRect? = nil) -> TextBox {
        guard let b = textBounds, b.width > 0, b.height > 0, b.intersects(frame.insetBy(dx: -2, dy: -2)) else {
            return TextBox(text: text, frame: frame, clip: clip)
        }
        return TextBox(text: text, frame: b, clip: clip)
    }

    /// The part actually showing; nil when scrolled out of the scroll area or zero-sized.
    var visibleFrame: CGRect? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        guard let clip else { return frame }
        let v = frame.intersection(clip)
        return v.isNull || v.width <= 0 || v.height <= 0 ? nil : v
    }
}

/// The pure logic of the generic checks; reading text and frames lives in Driver.
public enum TextChecks {
    /// Two text runs overlap only when their intersection exceeds this many points in both width and height: frames reported by Accessibility carry rounding error, and adjacent lines often share 1 point.
    /// Value not yet measured.
    public static let overlapTolerance: CGFloat = 2
    /// Text counts as outside the window only when its frame extends past it by more than this many points, for the same reason. Value not yet measured.
    public static let boundsTolerance: CGFloat = 1

    private static let formatPattern = try! NSRegularExpression(pattern: #"%(\d+\$)?(l{0,2}|h|q|z)[@dDiuUxXoOfeEgGcCsSp]"#)
    private static let bracePattern = try! NSRegularExpression(pattern: #"\{[^{}\n]{1,40}\}"#)

    /// Substrings of a text that look like unreplaced placeholders or copy keys; `copyKeys` is every key in the strings tables, and text equal to a whole key is reported too
    /// (that is what localization shows when it cannot find a string). `extraPatterns` are regexes for the app's copy key naming scheme (`TextCheckConfig.extraPlaceholderPatterns`).
    public static func placeholders(in text: String, copyKeys: Set<String>, extraPatterns: [NSRegularExpression] = []) -> [String] {
        var hits: [String] = []
        for re in [formatPattern, bracePattern] + extraPatterns {
            hits += matches(re, in: text)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if copyKeys.contains(trimmed), !hits.contains(trimmed) { hits.append(trimmed) }
        return hits
    }

    private static let pluralPattern = try! NSRegularExpression(pattern: #"(?<![\d.,:])\b1\s+([A-Za-z]+s)\b"#)
    /// Common words that end in s but are not plural nouns.
    private static let notPlural: Set<String> = [
        "is", "has", "was", "does", "plus", "this", "its", "us", "yes", "as", "less", "across", "thus",
        "minus", "always", "perhaps", "versus", "vs", "gets", "goes", "remains", "needs", "means", "starts",
        "ends", "begins", "left", "focus", "status", "bonus", "process", "access", "progress", "success",
    ]

    /// English fragments such as "1 Minutes" or "1 cards" that pair a count of 1 with a plural.
    public static func pluralOne(in text: String) -> [String] {
        let ns = text as NSString
        return pluralPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let word = ns.substring(with: m.range(at: 1))
            return notPlural.contains(word.lowercased()) ? nil : ns.substring(with: m.range)
        }
    }

    /// Pairs of text runs in one window whose frames overlap. The same text in the same frame is one run reported twice by Accessibility and does not count.
    public static func overlaps(_ boxes: [TextBox]) -> [(TextBox, TextBox)] {
        overlapPairs(boxes, among: Array(boxes.indices)).map { (boxes[$0.a], boxes[$0.b]) }
    }

    /// Overlap and bounds results for one window, as indices into `boxes`.
    public struct LayoutFindings: Equatable {
        public struct Pair: Equatable { public var a: Int; public var b: Int }
        public var overlaps: [Pair] = []
        public var outOfBounds: [Int] = []
        /// Text that was involved but is occluded, so it was excluded.
        public var occluded: [Int] = []
    }

    /// Overlap and bounds checks with occlusion: first find the text involved by frame, hit-test only those (`hit` takes an index and a point),
    /// then exclude the occluded ones and check again. A pair where `separated(a, b)` is true is on different layers (one is covered by the layer the other belongs to, e.g. content text
    /// half under a details panel, overlapping the panel's text) and does not count as overlap.
    public static func layout(_ boxes: [TextBox], window: CGRect, hit: (Int, CGPoint) -> Occlusion.Hit?,
                              separated: (Int, Int) -> Bool = { _, _ in false }) -> LayoutFindings {
        let all = Array(boxes.indices)
        var involved = Set(overlapPairs(boxes, among: all).flatMap { [$0.a, $0.b] })
        involved.formUnion(outOfBoundsIndices(boxes, among: all, window: window))
        var occluded: [Int] = []
        for i in involved.sorted() {
            guard let v = boxes[i].visibleFrame else { continue }
            if Occlusion.isOccluded(v, hit: { hit(i, $0) }) { occluded.append(i) }
        }
        let shown = all.filter { !occluded.contains($0) }
        return LayoutFindings(overlaps: overlapPairs(boxes, among: shown).filter { !separated($0.a, $0.b) },
                              outOfBounds: outOfBoundsIndices(boxes, among: shown, window: window), occluded: occluded)
    }

    private static func overlapPairs(_ boxes: [TextBox], among idx: [Int]) -> [LayoutFindings.Pair] {
        let visible = idx.compactMap { i in boxes[i].visibleFrame.map { (i, $0) } }
        var hits: [LayoutFindings.Pair] = []
        for x in visible.indices {
            for y in visible.indices where y > x {
                let (i, fa) = visible[x], (j, fb) = visible[y]
                if boxes[i].text == boxes[j].text && fa.equalTo(fb) { continue }
                let r = fa.intersection(fb)
                if !r.isNull, r.width > overlapTolerance, r.height > overlapTolerance { hits.append(.init(a: i, b: j)) }
            }
        }
        return hits
    }

    private static func outOfBoundsIndices(_ boxes: [TextBox], among idx: [Int], window: CGRect) -> [Int] {
        let allowed = window.insetBy(dx: -boundsTolerance, dy: -boundsTolerance)
        return idx.filter { i in
            guard let v = boxes[i].visibleFrame else { return false }
            return !allowed.contains(v)
        }
    }

    /// Text whose frame extends outside the window.
    public static func outOfBounds(_ boxes: [TextBox], window: CGRect) -> [TextBox] {
        outOfBoundsIndices(boxes, among: Array(boxes.indices), window: window).map { boxes[$0] }
    }

    private static func matches(_ re: NSRegularExpression, in text: String) -> [String] {
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}

/// Reads every key in a `.strings` file (one `"key" = "value";` per line).
public enum CopyKeys {
    private static let linePattern = try! NSRegularExpression(pattern: #"^\s*"((?:[^"\\]|\\.)*)"\s*="#, options: [.anchorsMatchLines])

    public static func parse(_ source: String) -> Set<String> {
        let ns = source as NSString
        return Set(linePattern.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }

    /// The keys of several strings tables combined; files that cannot be read are skipped (only the "text equals a whole key" rule loses them).
    public static func load(files: [URL]) -> Set<String> {
        var keys: Set<String> = []
        for url in files {
            if let s = try? String(contentsOf: url, encoding: .utf8) { keys.formUnion(parse(s)) }
        }
        return keys
    }
}

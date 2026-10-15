import AppKit
import CoreGraphics
import Testing
@testable import WispstageKit

struct TruncationTests {
    private let long = "Write a note, or describe how to change the current row"
    private var body13: NSFont { FontSpec(name: ".SFNS-Regular", size: 13).nsFont }

    /// Frames are Accessibility frames measured 2026-10-14 in a small SwiftUI window (truncated on one line, truncated on two lines, fits) for a string
    /// 340.2 pt wide on one line in this font; this string is 337.8 pt, so the frames keep the same verdicts.
    @Test(arguments: [
        ("truncated on one line", CGSize(width: 143.5, height: 16), true),
        ("truncated on two lines", CGSize(width: 150, height: 32), true),
        ("fits on one line", CGSize(width: 340.5, height: 16), false),
        ("fits on three lines", CGSize(width: 150, height: 48), false),
    ] as [(String, CGSize, Bool)])
    func comparesFullTextMeasuredInTheFontWithTheFrame(_ name: String, frame: CGSize, truncated: Bool) {
        #expect(Truncation.isTruncated(long, font: body13, frame: frame) == truncated, "\(name)")
    }

    @Test func chineseSingleLineTruncationIsReportedOnlyWhenItDoesNotFit() {
        let s = "整理本周的会议记录整理本周的会议记录"
        #expect(Truncation.isTruncated(s, font: body13, frame: CGSize(width: 90.5, height: 16)))
        #expect(!Truncation.isTruncated("整理本周的会议记录", font: body13, frame: CGSize(width: 116.5, height: 16)))
    }

    @Test func frameLargerThanTheTextIsNotReported() {
        #expect(!Truncation.isTruncated("0:00–8:00", font: FontSpec(name: ".SFNS-Regular", size: 11).nsFont,
                                        frame: CGSize(width: 980, height: 28)))
        #expect(!Truncation.isTruncated("", font: body13, frame: CGSize(width: 1, height: 1)))
    }

    @Test func readsSizeAndWeightFromTheAccessibilityFontDictionary() {
        let s = FontSpec(axFont: ["AXFontName": ".SFNS-Semibold", "AXFontSize": 13.0, "AXFontFamily": ".AppleSystemUIFont"])
        #expect(s == FontSpec(name: ".SFNS-Semibold", size: 13))
        #expect(s?.isBold == false)   // semibold is not WCAG bold
        #expect(FontSpec(name: ".SFNS-Bold", size: 14).isBold)
        #expect(FontSpec(axFont: ["AXFontName": "x"]) == nil)
        let semibold = FontSpec(name: ".SFNS-Semibold", size: 13).nsFont
        let regular = FontSpec(name: ".SFNS-Regular", size: 13).nsFont
        #expect(("This Week" as NSString).size(withAttributes: [.font: semibold]).width
            > ("This Week" as NSString).size(withAttributes: [.font: regular]).width)
    }
}

struct AlignmentTests {
    private func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat = 20) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

    @Test func elementOffTheColumnLeftEdgeIsListed() {
        let frames = [r(10, 0, 100), r(10, 30, 80), r(16, 60, 90), r(10, 90, 120)]
        #expect(Alignment.outliers(frames) == [2])
    }

    @Test func rightAlignedColumnIsNotListed() {
        // Hour labels on a timeline: 10:00 is wider than 8:00, right edges aligned
        let frames = [r(245, 0, 23), r(245, 40, 23), r(239, 80, 30), r(239, 120, 30)]
        #expect(Alignment.outliers(frames).isEmpty)
    }

    @Test func horizontalRowsAndFewerThanThreeAreNotJudged() {
        #expect(Alignment.outliers([r(10, 0, 40), r(60, 2, 40), r(110, 0, 40)]).isEmpty)
        #expect(Alignment.outliers([r(10, 0, 40), r(30, 40, 40)]).isEmpty)
    }

    @Test func columnWithoutAnAlignedMajorityIsNotJudged() {
        #expect(Alignment.outliers([r(10, 0, 40), r(30, 40, 50), r(50, 80, 70)]).isEmpty)
    }
}

struct HitTargetTests {
    @Test(arguments: [
        ("AXCheckBox", nil, CGSize(width: 14, height: 14), true),
        ("AXButton", nil, CGSize(width: 64, height: 20), false),
        ("AXButton", nil, CGSize(width: 24, height: 18), true),
        ("AXButton", "AXCloseButton", CGSize(width: 14, height: 16), false),
        ("AXStaticText", nil, CGSize(width: 10, height: 10), false),
        ("AXScrollBar", nil, CGSize(width: 15, height: 500), false),
    ] as [(String, String?, CGSize, Bool)])
    func actionableElementsSmallerThan20PointsAreListed(role: String, subrole: String?, size: CGSize, small: Bool) {
        #expect(HitTarget.isTooSmall(role: role, subrole: subrole, size: size) == small)
    }

    @Test func elementsWithAPressActionCountAsActionable() {
        #expect(HitTarget.isActionable(role: "AXGroup", subrole: nil, actions: ["AXPress"]))
        #expect(!HitTarget.isActionable(role: "AXGroup", subrole: nil, actions: ["AXShowMenu"]))
        #expect(HitTarget.isActionable(role: "AXButton", subrole: nil, actions: []))
    }
}

struct MissingIdentifierTests {
    private func missing(role: String = "AXStaticText", subrole: String? = nil, id: String? = nil, text: String? = "Start",
                         actionable: Bool = false, labelled: Bool = false) -> Bool {
        MissingIdentifier.isMissing(role: role, subrole: subrole, id: id, text: text, actionable: actionable,
                                    labelledByAncestor: labelled)
    }

    @Test func textWithoutAnIdentifierIsListed() { #expect(missing()) }
    @Test func actionableElementWithoutTextOrIdentifierIsListed() { #expect(missing(role: "AXButton", text: nil, actionable: true)) }
    @Test func elementWithAnIdentifierIsNotListed() { #expect(!missing(id: "toolbar.start")) }
    @Test func elementWithoutTextThatIsNotActionableIsNotListed() { #expect(!missing(role: "AXGroup", text: nil)) }
    @Test func textInsideAnIdentifiedButtonIsNotListed() { #expect(!missing(labelled: true)) }
    @Test func systemScrollBarsAndTitleBarButtonsAreNotListed() {
        #expect(!missing(role: "AXScrollBar", text: "0", actionable: true))
        #expect(!missing(role: "AXButton", subrole: "AXCloseButton", text: nil, actionable: true))
    }
}

struct ContrastTests {
    private let white = RGB(r: 1, g: 1, b: 1), black = RGB(r: 0, g: 0, b: 0)

    private func gray(_ v: UInt8) -> RGB { RGB(r: Double(v) / 255, g: Double(v) / 255, b: Double(v) / 255) }

    @Test func luminanceAndContrastFollowTheWCAGFormula() {
        #expect(WCAG.relativeLuminance(white) == 1)
        #expect(WCAG.relativeLuminance(black) == 0)
        #expect(abs(WCAG.contrastRatio(black, white) - 21) < 1e-9)
        #expect(abs(WCAG.contrastRatio(white, black) - 21) < 1e-9)
        // #767676 is the gray that just passes 4.5:1 on white (commonly cited value 4.54)
        #expect(abs(WCAG.contrastRatio(gray(0x76), white) - 4.54) < 0.01)
    }

    @Test(arguments: [
        (13.0, false, 4.5), (17.0, false, 4.5), (18.0, false, 3.0), (14.0, true, 3.0), (13.0, true, 4.5),
    ] as [(Double, Bool, Double)])
    func largeTextThreshold(size: Double, bold: Bool, minimum: Double) {
        #expect(WCAG.minimumRatio(pointSize: CGFloat(size), bold: bold) == minimum)
    }

    @Test func unknownSizeIsJudgedAsBodyText() {
        #expect(WCAG.minimumRatio(pointSize: nil, bold: false) == 4.5)
    }

    @Test func translucentTextColorIsCompositedOverTheBackground() {
        let c = TextColor(rgb: black, alpha: 0.56).composite(over: white)
        #expect(abs(c.r - 0.44) < 1e-9 && c.r == c.g && c.g == c.b)
    }

    /// A 40×20 white image with a #595959 "glyph" in the middle and light gray anti-aliasing beside the strokes.
    private func glyphImage(core: UInt8) -> RGBAImage {
        var img = RGBAImage(width: 40, height: 20, fill: (255, 255, 255, 255))
        func set(_ x: Int, _ y: Int, _ v: UInt8) {
            let i = (y * img.width + x) * 4
            img.pixels[i] = v; img.pixels[i + 1] = v; img.pixels[i + 2] = v
        }
        for y in 5..<15 {
            for x in 10..<30 {
                if x % 4 == 0 { set(x, y, core) } else if x % 4 == 1 { set(x, y, 0xC0) }
            }
        }
        return img
    }

    @Test func backgroundIsTheEdgeModeAndForegroundIsTheHighestContrastCluster() throws {
        let m = try #require(Contrast.measure(glyphImage(core: 0x59), declared: nil))
        #expect(m.background == white)
        #expect(m.foreground == gray(0x59))
        #expect(!m.fromDeclared)
        #expect(abs(m.ratio - WCAG.contrastRatio(gray(0x59), white)) < 1e-9)
        let pale = try #require(Contrast.measure(glyphImage(core: 0x99), declared: nil))
        #expect(pale.ratio < 4.5)
    }

    @Test func declaredTextColorIsCompositedOverTheMeasuredBackground() throws {
        let m = try #require(Contrast.measure(glyphImage(core: 0x99), declared: TextColor(rgb: black, alpha: 0.56)))
        #expect(m.fromDeclared)
        #expect(abs(m.foreground.r - 0.44) < 1e-9)
        #expect(m.ratio > 4.5)
    }

    /// A label on a pill-shaped background: the text frame includes the pill, so the crop is the frame itself and its outer ring picks up the pill color, not the window background.
    @Test func textOnAPillUsesThePillColorAsBackground() throws {
        var img = RGBAImage(width: 60, height: 20, fill: (0xE5, 0x48, 0x4D, 255))
        for (x, y) in [(0, 0), (1, 0), (0, 1), (59, 0), (58, 0), (59, 1), (0, 19), (1, 19), (0, 18), (59, 19), (58, 19), (59, 18)] {
            let i = (y * 60 + x) * 4
            img.pixels[i] = 255; img.pixels[i + 1] = 255; img.pixels[i + 2] = 255
        }
        let m = try #require(Contrast.measure(img, declared: TextColor(rgb: white, alpha: 1)))
        #expect(m.background.distance(RGB((0xE5, 0x48, 0x4D))) < 0.01)
        #expect(m.ratio > 3.5 && m.ratio < 4.5)
    }

    /// A screenshot of a glass window has a translucent background: what shows through on screen is behind the window and not in the screenshot, so it is not judged.
    @Test func translucentBackgroundIsNotJudged() {
        var img = glyphImage(core: 0x59)
        for i in stride(from: 3, to: img.pixels.count, by: 4) {
            img.pixels[i] = 128
            for c in 1...3 { img.pixels[i - c] = img.pixels[i - c] / 2 }
        }
        #expect(Contrast.measure(img, declared: nil) == nil)
        #expect(Contrast.measure(img, declared: TextColor(rgb: black, alpha: 1)) == nil)
    }

    @Test func noDominantEdgeColorIsNotJudged() {
        var img = RGBAImage(width: 20, height: 20, fill: (255, 255, 255, 255))
        for i in stride(from: 0, to: img.pixels.count, by: 4) {
            let v = UInt8((i / 4) % 7 * 30)
            img.pixels[i] = v; img.pixels[i + 1] = 255 - v; img.pixels[i + 2] = v / 2
        }
        #expect(Contrast.measure(img, declared: nil) == nil)
    }
}

struct CoverTests {
    private let white = RGB(r: 1, g: 1, b: 1)
    private let ink = RGB(r: 0.2, g: 0.2, b: 0.2)

    private func patch(_ w: Int = 20, _ h: Int = 20, _ px: (Int, Int) -> (UInt8, UInt8, UInt8)) -> RGBAImage {
        var img = RGBAImage(width: w, height: h, fill: (0, 0, 0, 255))
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = px(x, y)
                let i = (y * w + x) * 4
                img.pixels[i] = r; img.pixels[i + 1] = g; img.pixels[i + 2] = b
            }
        }
        return img
    }

    /// A few 0x33 text strokes on white: the element's own text visible beneath a transparent layer.
    private var textPatch: RGBAImage { patch { x, y in (x % 5 == 0 && y > 4 && y < 15) ? (0x33, 0x33, 0x33) : (255, 255, 255) } }

    @Test func coverShowingTheOwnTextColorBeneathIsSeeThrough() {
        #expect(Occlusion.classify(patch: textPatch, textColor: ink, ownBackground: nil, coverHasContent: false) == .seeThrough)
    }

    @Test func coverWithItsOwnContentHereIsNotSeeThroughByTextColor() {
        #expect(Occlusion.classify(patch: textPatch, textColor: ink, ownBackground: nil, coverHasContent: true) == .opaque)
    }

    @Test func solidColorDifferentFromOwnBackgroundIsOpaqueAndTheSameIsSeeThrough() {
        let solid = patch { _, _ in (0x30, 0x60, 0x90) }
        #expect(Occlusion.classify(patch: solid, textColor: ink, ownBackground: white, coverHasContent: false) == .opaque)
        let blank = patch { _, _ in (255, 255, 255) }
        #expect(Occlusion.classify(patch: blank, textColor: ink, ownBackground: white, coverHasContent: false) == .seeThrough)
    }

    @Test func smoothGradientWithoutLegibleTextIsGlass() {
        let blurred = patch { x, _ in let v = UInt8(150 + x * 3); return (v, v, v) }
        #expect(Occlusion.classify(patch: blurred, textColor: ink, ownBackground: white, coverHasContent: false) == .glass)
    }

    @Test(arguments: [
        ([Occlusion.PointHit.own, .own], Occlusion.State.visible),
        ([.covered(.seeThrough), .covered(.seeThrough)], .visible),
        ([.covered(.opaque), .covered(.opaque)], .occluded),
        ([.covered(.glass), .covered(.opaque)], .underGlass),
        ([.own, .covered(.opaque)], .partial),
        ([.own, .covered(.glass)], .partialGlass),
        ([.covered(.seeThrough), .covered(.glass), .covered(.opaque)], .partial),
        // Another window of the same app (a panel floating over the main window) covers part of it: it floats as usual, is marked separately, and is not partial occlusion within this window
        ([.own, .covered(.otherWindow)], .partialOtherWindow),
        ([.own, .covered(.otherWindow), .covered(.glass)], .partialGlass),
        ([.covered(.otherWindow), .covered(.otherWindow)], .occluded),
    ] as [([Occlusion.PointHit], Occlusion.State)])
    func pointsCombineIntoOneOcclusionState(points: [Occlusion.PointHit], state: Occlusion.State) {
        #expect(Occlusion.state(points) == state)
    }

    @Test func unreadablePointsAreIgnored() {
        #expect(Occlusion.state([nil, nil]) == .visible)
        #expect(Occlusion.state([nil, .covered(.opaque)]) == .occluded)
    }

    @Test func fullyCoveredAndUnderGlassAreExcludedFromOverlapButPartialIsNot() {
        #expect(Occlusion.State.occluded.hidesText && Occlusion.State.underGlass.hidesText)
        #expect(!Occlusion.State.partial.hidesText && !Occlusion.State.partialGlass.hidesText && !Occlusion.State.visible.hidesText)
    }

    @Test(arguments: [
        ([Occlusion.Cover.seeThrough], Occlusion.Cover?.some(.seeThrough)),
        ([.seeThrough, .opaque], .seeThrough),
        ([.seeThrough, .opaque, .glass], .glass),
        ([.glass, .glass, .opaque], .glass),
        ([.glass, .opaque, .opaque], .opaque),
        ([.opaque], .opaque),
        ([], nil),
    ] as [([Occlusion.Cover], Occlusion.Cover?)])
    func layerKindIsVotedByThePointsOverTheText(votes: [Occlusion.Cover], kind: Occlusion.Cover?) {
        #expect(Occlusion.layerKind(votes: votes) == kind)
    }
}

struct LayeringTests {
    /// Elements in preorder: 0 main content, 1 text in the main content, 2 a dismiss layer (transparent, covering everything), 3 a details panel (right half), 4 the title in the panel.
    private let frames: [CGRect?] = [
        CGRect(x: 0, y: 0, width: 400, height: 300),
        CGRect(x: 150, y: 50, width: 100, height: 20),
        CGRect(x: 0, y: 0, width: 400, height: 300),
        CGRect(x: 200, y: 0, width: 200, height: 300),
        CGRect(x: 220, y: 20, width: 150, height: 20),
    ]
    /// End index (exclusive) of each element's subtree: the subtree of 0 is 1.
    private let subtreeEnd = [2, 2, 3, 5, 5]

    @Test func coverAtAPointIsTheLastInPreorder() {
        // The right half of the text lies under the panel: hit-testing hits only the dismiss layer, but the panel is later in the tree, so the panel counts as covering it
        #expect(Layering.cover(at: CGPoint(x: 230, y: 60), of: 1, frames: frames, subtreeEnd: subtreeEnd, hit: 2) == 3)
        #expect(Layering.cover(at: CGPoint(x: 160, y: 60), of: 1, frames: frames, subtreeEnd: subtreeEnd, hit: 2) == 2)
    }

    @Test func laterLayerInTheTreeCoveringThePointCountsWhenTheHitIsSelf() {
        #expect(Layering.cover(at: CGPoint(x: 230, y: 60), of: 1, frames: frames, subtreeEnd: subtreeEnd, hit: nil) == 3)
    }

    @Test func ownDescendantsAndAncestorsDoNotCount() {
        #expect(Layering.cover(at: CGPoint(x: 160, y: 60), of: 0, frames: [frames[0], frames[1]], subtreeEnd: [2, 2], hit: nil) == nil)
    }

    @Test func textHalfUnderAnOverlayIsOnlyMarkedAndALocalCoverFails() {
        // Layer 3 covers other elements entirely, so it is an overlay (a details panel); layer 7 covers only a corner of this text, so it is a layout collision
        #expect(Occlusion.refinePartial(.partial, opaqueCoverers: [3], overlays: [3]) == .partialUnderLayer)
        #expect(Occlusion.refinePartial(.partial, opaqueCoverers: [3, 7], overlays: [3]) == .partial)
        #expect(Occlusion.refinePartial(.partial, opaqueCoverers: [7], overlays: [3]) == .partial)
        #expect(Occlusion.refinePartial(.occluded, opaqueCoverers: [3], overlays: [3]) == .occluded)
        #expect(Occlusion.State.partialUnderLayer.mark == "partly under an overlay")
        #expect(!Occlusion.State.partialUnderLayer.hidesText)
    }

    @Test func overlappingTextOnDifferentLayersIsNotOverlap() {
        let below = TextBox(text: "Waiting for a quote", frame: CGRect(x: 180, y: 25, width: 90, height: 16))
        let title = TextBox(text: "Send the pricing update", frame: CGRect(x: 220, y: 20, width: 150, height: 20))
        let f = TextChecks.layout([below, title], window: CGRect(x: 0, y: 0, width: 400, height: 300), hit: { _, _ in .own },
                                  separated: { a, b in a == 0 && b == 1 })
        #expect(f.overlaps.isEmpty)
        let same = TextChecks.layout([below, title], window: CGRect(x: 0, y: 0, width: 400, height: 300), hit: { _, _ in .own })
        #expect(same.overlaps.count == 1)
    }
}

struct LayoutListingMarkTests {
    @Test(arguments: [
        (Occlusion.State.occluded, " occluded"), (.underGlass, " under glass"), (.partial, " partly covered"), (.partialGlass, " partly under glass"), (.visible, ""),
        (.partialOtherWindow, " partly under another window"),
    ] as [(Occlusion.State, String)])
    func listingLineEndsWithTheOcclusionMark(state: Occlusion.State, mark: String) {
        let e = AXListing.Entry(depth: 0, role: "AXStaticText", id: "a", text: nil, frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                visible: true, state: state)
        #expect(AXListing.render([e]) == "StaticText #a (0,0 10x10)\(mark)\n")
    }

    @Test func alignmentHitTargetAndMissingIdentifierAreListedForReview() {
        for c in [Check.truncation] { #expect(c.failsStep) }
        for c in [Check.alignment, .hitTarget, .missingIdentifier, .contrast, .occlusion] { #expect(!c.failsStep) }
    }
}

struct LaidOutBoxTests {
    /// A time-range band on a timeline: the element frame spans the whole timeline and the text is only a short stretch in the middle (AXBoundsForRange measured 2026-10-14).
    @Test func overlapUsesTheLaidOutGlyphFrame() {
        let frame = CGRect(x: 355, y: 186, width: 980, height: 28)
        let glyphs = CGRect(x: 817, y: 193, width: 55.7, height: 14)
        #expect(TextBox.laidOut(text: "0:00～8:00", frame: frame, textBounds: glyphs).frame == glyphs)
    }

    @Test func missingOrImplausibleLayoutFrameFallsBackToTheElementFrame() {
        let frame = CGRect(x: 10, y: 10, width: 100, height: 20)
        #expect(TextBox.laidOut(text: "a", frame: frame, textBounds: nil).frame == frame)
        #expect(TextBox.laidOut(text: "a", frame: frame, textBounds: CGRect(x: 10, y: 10, width: 0, height: 0)).frame == frame)
        #expect(TextBox.laidOut(text: "a", frame: frame, textBounds: CGRect(x: 500, y: 500, width: 10, height: 10)).frame == frame)
    }
}

struct NoteSummaryTests {
    @Test func notesListedForReviewAreGroupedByCheckInTheSummary() {
        let notes = [
            ScenarioResult.Note(check: "hit-target", step: "02-click-item", element: "CheckBox #list.row.0", detail: "14x14"),
            ScenarioResult.Note(check: "missing-id", step: "01-launch", element: "StaticText \"This Week\"", detail: "(10,20 30x16)"),
            ScenarioResult.Note(check: "missing-id", step: "03-press-key", element: "Button \"Collapse\"", detail: "(0,0 20x20)"),
        ]
        #expect(Runner.noteLines(notes) == [
            "      Missing identifier (2, listed for review):",
            "        @01-launch StaticText \"This Week\" (10,20 30x16)",
            "        @03-press-key Button \"Collapse\" (0,0 20x20)",
            "      Click target smaller than 20x20 pt (1, listed for review):",
            "        @02-click-item CheckBox #list.row.0 14x14",
        ])
    }

    @Test func insufficientContrastIsAlsoListedInTheSummary() {
        let notes = [ScenarioResult.Note(check: "contrast", step: "01-launch", element: "main#1 \"10:40\" (0,0 40x16) contrast 3.43:1 below 4.5:1", detail: "")]
        #expect(Runner.noteLines(notes) == [
            "      Low contrast (1, listed for review):",
            "        @01-launch main#1 \"10:40\" (0,0 40x16) contrast 3.43:1 below 4.5:1 ",
        ])
    }

    @Test func nothingIsWrittenWithoutNotes() {
        #expect(Runner.noteLines([]).isEmpty)
    }
}

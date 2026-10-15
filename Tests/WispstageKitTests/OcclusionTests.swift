import CoreGraphics
import Testing
@testable import WispstageKit

struct OcclusionTests {
    private func box(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> TextBox {
        TextBox(text: text, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    /// A detail panel covers the area x ≥ 200: points inside it hit the panel (another element), the rest hit the element itself.
    private func panelHit(_ panelMinX: CGFloat) -> (Int, CGPoint) -> Occlusion.Hit? {
        { _, p in p.x >= panelMinX ? .other : .own }
    }

    @Test func samplePointsIncludeCenterAndLieInsideFrame() {
        let r = CGRect(x: 10, y: 20, width: 100, height: 20)
        let pts = Occlusion.samplePoints(in: r)
        #expect(pts.first == CGPoint(x: r.midX, y: r.midY))
        #expect(pts.count > 1)
        #expect(pts.allSatisfy { r.contains($0) })
    }

    @Test(arguments: [
        ([Occlusion.Hit.other, .other, .other], true),
        ([.other, .own, .other], false),
        ([.own], false),
        ([nil, nil], false),
        ([nil, .other], true),
    ] as [([Occlusion.Hit?], Bool)])
    func occludedOnlyWhenAllSamplePointsHitOtherElements(hits: [Occlusion.Hit?], occluded: Bool) {
        #expect(Occlusion.isOccluded(hits) == occluded)
    }

    @Test func textCoveredByPanelIsLeftOutOfOverlap() {
        let content = box("Waiting for client reply", 220, 100, 120, 20)   // entirely under the panel
        let panel = box("Email customers about the price change", 230, 105, 150, 20)
        // The panel's own text hits the panel itself
        let hit: (Int, CGPoint) -> Occlusion.Hit? = { i, p in i == 1 ? .own : (p.x >= 200 ? .other : .own) }
        let f = TextChecks.layout([content, panel], window: CGRect(x: 0, y: 0, width: 600, height: 400), hit: hit)
        #expect(f.overlaps.isEmpty)
        #expect(f.occluded == [0])
    }

    @Test func partlyVisibleTextIsComparedAsUsual() {
        let half = box("Half under the panel", 150, 100, 120, 20)  // 150 to 270; the panel starts at 200
        let other = box("Text over it", 160, 105, 30, 20)
        let f = TextChecks.layout([half, other], window: CGRect(x: 0, y: 0, width: 600, height: 400), hit: panelHit(200))
        #expect(f.overlaps.count == 1)
        #expect(f.occluded.isEmpty)
    }

    @Test func occludedTextOutsideTheWindowIsNotReported() {
        let win = CGRect(x: 0, y: 0, width: 300, height: 200)
        let hidden = box("Hidden", 280, 50, 60, 20)
        let shown = box("Shown", 280, 100, 60, 20)
        let f = TextChecks.layout([hidden, shown], window: win, hit: { i, _ in i == 0 ? .other : .own })
        #expect(f.outOfBounds == [1])
        #expect(f.occluded == [0])
    }

    @Test func onlyInvolvedTextIsHitTested() {
        let a = box("A", 10, 10, 50, 20), b = box("B", 40, 15, 50, 20), c = box("C", 10, 200, 50, 20)
        var tested: Set<Int> = []
        _ = TextChecks.layout([a, b, c], window: CGRect(x: 0, y: 0, width: 600, height: 400), hit: { i, _ in tested.insert(i); return .own })
        #expect(tested == [0, 1])
    }

    /// Shortcut recorder field: accessibility reports the frame of "⌥ Space" as the whole 150x24 field; the × clear button at its right end lies inside that frame but not over the text.
    /// Text is sampled by the frame of its laid-out glyphs, so the × button covers no sample point and is not occlusion.
    @Test func textIsSampledByGlyphFrameSoOtherButtonsInTheFieldDoNotOcclude() {
        let element = CGRect(x: 100, y: 200, width: 150, height: 24)
        let glyphs = CGRect(x: 108, y: 204, width: 52, height: 16)
        let clear = CGRect(x: 220, y: 204, width: 20, height: 16)
        let pts = Occlusion.samplePoints(in: Occlusion.sampleRect(visible: element, textBounds: glyphs))
        let hits: [Occlusion.PointHit?] = pts.map { clear.contains($0) ? .covered(.opaque) : .own }
        #expect(Occlusion.state(hits) == .visible)
    }

    @Test func fallsBackToElementFrameWhenGlyphFrameIsUnreadable() {
        let element = CGRect(x: 100, y: 200, width: 150, height: 24)
        #expect(Occlusion.sampleRect(visible: element, textBounds: nil) == element)
        #expect(Occlusion.sampleRect(visible: element, textBounds: CGRect(x: 600, y: 600, width: 10, height: 10)) == element)
        // When the glyph frame extends past the visible part, only the visible part is used
        #expect(Occlusion.sampleRect(visible: element, textBounds: CGRect(x: 90, y: 204, width: 40, height: 16))
                == CGRect(x: 100, y: 204, width: 30, height: 16))
    }
}

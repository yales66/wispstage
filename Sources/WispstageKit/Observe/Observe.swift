import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// One element seen while walking a window's accessibility tree, with its occlusion result and (for static text) font and text color.
struct ObservedElement {
    let node: AXNode
    let ancestors: [AXNode]
    /// Indices of the ancestors in this window's element table (root first).
    let ancestorIndices: [Int]
    let role: String?
    let subrole: String?
    let id: String?
    /// What VoiceOver reads out (the text listed in the listing).
    let text: String?
    /// The full text static text displays (AXValue), used for measuring truncation and reading the font.
    let value: String?
    /// Global coordinates.
    let frame: CGRect?
    let clip: CGRect?
    /// The part visible within scroll areas and the window; nil when not visible.
    let visibleFrame: CGRect?
    let actionable: Bool
    var font: FontSpec?
    var color: TextColor?
    /// The frame of the laid-out static text (`AXBoundsForRange` over the full text); nil when unreadable.
    var textBounds: CGRect?
    var state: Occlusion.State = .visible
    /// Indices in this window's element table of the layers covering it (opaque or glass).
    var coverers: Set<Int> = []

    var isText: Bool { role == kAXStaticTextRole }
    /// Listed in the text listing: visible, with an identifier or text.
    var listed: Bool { visibleFrame != nil && (id != nil || text != nil) }
    var box: TextBox { TextBox.laidOut(text: text ?? "", frame: frame ?? .zero, textBounds: textBounds, clip: clip) }
}

/// What one walk of a window's accessibility tree produces.
struct WindowObservation {
    var listingHeader: String
    var elements: [ObservedElement] = []
    var strings: [String] = []

    var entries: [AXListing.Entry] {
        elements.map { e in
            AXListing.Entry(depth: e.ancestors.count, role: e.role, id: e.id, text: e.text,
                            frame: e.frame.map { $0.offsetBy(dx: -window.minX, dy: -window.minY) },
                            visible: e.visibleFrame != nil, state: e.state)
        }
    }

    var window: CGRect = .zero
}

/// Who answers the hit test at a point.
enum HitSource {
    /// External Accessibility (`AXUIElementCopyElementAtPosition`, following the window server's stacking order). Used by the preview entry point, which has no command channel.
    case accessibility
    /// The app under test hit-tests in process (the E2E bundle's `hit` command): takes the window number and all sample points and returns a result per point, nil when it cannot answer.
    /// In hidden mode the windows are beneath the wallpaper and external hit tests cannot reach them, so this is the only way.
    case app((_ window: Int, _ points: [CGPoint]) -> [AppHit?]?)
}

/// Walks the tree, hit-tests, and decides occlusion by layer. The screenshot is taken on demand (only when some point is covered by another element in the same window).
enum Observer {
    /// When the covering layer is not in this window's tree (no index can be found), at most this many elements of its subtree are examined.
    static let coverWalkLimit = 400

    /// `above` holds the frames of the same app's windows stacked above this one (`CGWindowListCopyWindowInfo` order); sample points inside them count as covered by another window.
    static func observe(_ w: AppWindow, app ax: AXNode, hits: HitSource = .accessibility, above: [CGRect] = [],
                        image: () -> RGBAImage?) -> WindowObservation {
        var o = WindowObservation(listingHeader: "== \(w.kind.rawValue) #\(w.id) \(w.title.debugDescription) \(Int(w.frame.width))x\(Int(w.frame.height))\n")
        o.window = w.frame
        guard let wax = w.ax else { return o }
        var stack: [Int] = []
        wax.walkPath { n, ancestors, clip in
            o.strings += n.allStrings
            let role = n.role
            let id = n.identifier.flatMap { $0.isEmpty ? nil : $0 }
            let text = n.spoken.flatMap { $0.isEmpty ? nil : $0 }
            let frame = n.frame
            let visible = frame.flatMap { TextBox(text: "", frame: $0, clip: clip).visibleFrame }.flatMap { v -> CGRect? in
                let r = v.intersection(w.frame)
                return r.isNull || r.width <= 0 || r.height <= 0 ? nil : v
            }
            let subrole = n.subrole
            let actionable = visible != nil && HitTarget.isActionable(role: role, subrole: subrole, actions: id != nil || text != nil || role == kAXButtonRole ? n.actions : [])
            while stack.count > ancestors.count { stack.removeLast() }
            var e = ObservedElement(node: n, ancestors: ancestors, ancestorIndices: stack, role: role, subrole: subrole, id: id, text: text,
                                    value: role == kAXStaticTextRole ? n.value : nil, frame: frame, clip: clip,
                                    visibleFrame: visible, actionable: actionable)
            if e.isText, e.visibleFrame != nil, let style = n.textStyle() {
                e.font = style.font
                e.color = style.color
                if let v = e.value { e.textBounds = n.bounds(for: NSRange(location: 0, length: (v as NSString).length)) }
            }
            stack.append(o.elements.count)
            o.elements.append(e)
            return true
        }
        resolveOcclusion(&o, app: ax, window: w, windowRef: wax.ref, hits: hits, above: above, image: image)
        return o
    }

    /// What covers the element at a sample point: an element in this window's tree (index), or an element outside the tree (usually another window's).
    private enum Coverer {
        case element(Int)
        case external(AXUIElement)
        /// Another window of the same app.
        case otherWindow
    }

    /// What a sample point hits: unreadable, the element itself (or an ancestor or descendant), another element in this window's table, another window, or an element in this window outside the tree.
    private enum Probe {
        case unknown, own, element(Int), otherWindow
        case foreign(AXUIElement)
    }

    /// Hit testing plus tree order (`Layering`) decides the covering layer at each sample point, then the screenshot decides whether each layer is transparent, glass or opaque (`Occlusion`),
    /// combining them into each element's occlusion state and recording the indices of the layers covering it (opaque or glass).
    private static func resolveOcclusion(_ o: inout WindowObservation, app ax: AXNode, window aw: AppWindow, windowRef: AXUIElement,
                                         hits: HitSource, above: [CGRect], image: () -> RGBAImage?) {
        let window = aw.frame
        let els = o.elements
        let n = els.count
        let frames = els.map(\.frame)
        var subtreeEnd = Array(repeating: n, count: n)
        for i in 0..<n {
            var j = i + 1
            while j < n, els[j].ancestors.count > els[i].ancestors.count { j += 1 }
            subtreeEnd[i] = j
        }
        var index: [AXRef: Int] = [:]
        for i in 0..<n { index[AXRef(ref: els[i].node.ref)] = index[AXRef(ref: els[i].node.ref)] ?? i }
        var otherWindow: [AXRef: Bool] = [:]
        func inOtherWindow(_ cover: AXUIElement) -> Bool {
            let key = AXRef(ref: cover)
            if let v = otherWindow[key] { return v }
            var v: AnyObject?
            var other = false
            if AXUIElementCopyAttributeValue(cover, kAXWindowAttribute as CFString, &v) == .success, let wv = v,
               CFGetTypeID(wv) == AXUIElementGetTypeID() {
                other = !CFEqual(wv, windowRef)
            }
            otherWindow[key] = other
            return other
        }

        // A covering element belongs to its layer: its first ancestor that is not an ancestor of the covered element (any child of a detail panel belongs to the panel)
        func layerRoot(_ c: Int, over i: Int) -> Int {
            let mine = Set(els[i].ancestorIndices)
            return (els[c].ancestorIndices + [c]).first { !mine.contains($0) && $0 != i } ?? c
        }

        // Sampling: text tests every sample point (to know whether it is partly covered); other elements stop once they hit themselves
        let sampled = (0..<n).filter { els[$0].visibleFrame != nil && (els[$0].listed || els[$0].actionable) }
        // Text is sampled by the frame of its laid-out glyphs (see Occlusion.sampleRect)
        let points = sampled.map { i in
            let v = els[i].visibleFrame!
            return Occlusion.samplePoints(in: els[i].isText ? Occlusion.sampleRect(visible: v, textBounds: els[i].textBounds) : v)
        }
        var appResults: [AppHit?]?
        if case .app(let ask) = hits {
            let all = points.flatMap { $0 }
            if !all.isEmpty { appResults = ask(aw.id, all) }
        }
        let roles = els.map(\.role), ids = els.map(\.id), ancestorIdx = els.map(\.ancestorIndices)
        func probe(_ i: Int, _ p: CGPoint, flat q: Int) -> Probe {
            if AppHitResolver.coveredByWindowAbove(p, above: above) { return .otherWindow }
            switch hits {
            case .app:
                guard let r = appResults, q < r.count else { return .unknown }
                switch AppHitResolver.resolve(r[q], for: i, roles: roles, ids: ids, frames: frames, ancestors: ancestorIdx) {
                case .unknown: return .unknown
                case .own: return .own
                case .element(let j): return .element(j)
                }
            case .accessibility:
                let set = Set(els[i].ancestors.map { AXRef(ref: $0.ref) })
                switch HitTest.hit(app: ax.ref, at: p, element: els[i].node.ref, ancestors: set) {
                case nil: return .unknown
                case .own?: return .own
                case .other(let b)?:
                    if let bi = index[AXRef(ref: b)] { return .element(bi) }
                    return inOtherWindow(b) ? .otherWindow : .foreign(b)
                }
            }
        }

        struct Sample { var point: CGPoint; var coverer: Coverer?; var own: Bool; var known: Bool }
        var samples: [[Sample]] = Array(repeating: [], count: n)
        var flat = 0
        for (si, i) in sampled.enumerated() {
            let e = els[i]
            defer { flat += points[si].count }
            for (k, p) in points[si].enumerated() {
                var smp = Sample(point: p, coverer: nil, own: false, known: true)
                // Tree order is added only for text: text has a color, so pixels can tell that the added layer is actually beneath it (the text is visible); containers cannot, so only the hit test is trusted
                let layered = e.isText
                switch probe(i, p, flat: flat + k) {
                case .unknown:
                    smp.known = false
                case .own:
                    if layered, let c = Layering.cover(at: p, of: i, frames: frames, subtreeEnd: subtreeEnd, hit: nil) { smp.coverer = .element(c) } else { smp.own = true }
                case .otherWindow:
                    smp.coverer = .otherWindow
                case .element(let bi):
                    smp.coverer = layered ? Layering.cover(at: p, of: i, frames: frames, subtreeEnd: subtreeEnd, hit: bi).map(Coverer.element) : .element(bi)
                case .foreign(let b):
                    if layered, let c = Layering.cover(at: p, of: i, frames: frames, subtreeEnd: subtreeEnd, hit: nil) {
                        smp.coverer = .element(c)
                    } else {
                        smp.coverer = .external(b)
                    }
                }
                if case .element(let c)? = smp.coverer { smp.coverer = .element(layerRoot(c, over: i)) }
                samples[i].append(smp)
                if !e.isText, smp.own { break }
            }
        }

        func key(_ c: Coverer) -> AXRef {
            switch c {
            case .element(let i): AXRef(ref: els[i].node.ref)
            case .external(let b): AXRef(ref: b)
            case .otherWindow: AXRef(ref: windowRef)
            }
        }
        func isOtherWindow(_ c: Coverer) -> Bool { if case .otherWindow = c { true } else { false } }

        // Whether the covering layer has its own content (text, images, controls) in a patch
        var content: [AXRef: [CGRect]] = [:]
        func contentFrames(_ c: Coverer) -> [CGRect] {
            let k = key(c)
            if let v = content[k] { return v }
            var out: [CGRect] = []
            func isContent(_ role: String?, _ text: String?) -> Bool {
                text != nil || role == kAXImageRole || HitTarget.actionableRoles.contains(role ?? "")
            }
            switch c {
            case .element(let ci):
                for j in (ci + 1)..<max(ci + 1, subtreeEnd[ci]) where isContent(els[j].role, els[j].text) { if let f = els[j].frame { out.append(f) } }
            case .otherWindow:
                break
            case .external(let b):
                AXNode(b).walk(limit: coverWalkLimit) { nd, depth, _ in
                    if depth > 0, isContent(nd.role, nd.spoken), let f = nd.frame { out.append(f) }
                    return true
                }
            }
            content[k] = out
            return out
        }

        let needImage = samples.contains { $0.contains { s in s.coverer.map { !isOtherWindow($0) } ?? false } }
        let img = needImage ? image() : nil
        func patch(_ e: ObservedElement, at p: CGPoint) -> (RGBAImage, CGRect)? {
            guard let img, let v = e.visibleFrame else { return nil }
            let side = min(max(v.height, 8), 24)
            let r = CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side).intersection(v)
            guard !r.isNull, let px = Crop.pixelRect(element: r, window: window, imageSize: CGSize(width: img.width, height: img.height), margin: 0),
                  let sub = img.sub(px) else { return nil }
            return (sub, r)
        }

        // Each covered point is first judged by pixels on its own; points on text where the patch has none of that layer's own content vote for that layer
        var perPoint: [[Occlusion.Cover?]] = samples.map { $0.map { _ in nil } }
        var votes: [AXRef: [Occlusion.Cover]] = [:]
        if img != nil {
            for i in 0..<n where !samples[i].isEmpty {
                let e = els[i]
                let textual = e.isText && e.color != nil
                var ownBackground: RGB?
                for s in samples[i] where s.own {
                    if let (pp, _) = patch(e, at: s.point), let bg = Contrast.background(pp) { ownBackground = bg.color; break }
                }
                for (k, s) in samples[i].enumerated() {
                    guard let c = s.coverer, !isOtherWindow(c), let (pp, r) = patch(e, at: s.point) else { continue }
                    let hasContent = contentFrames(c).contains { $0.intersects(r) }
                    let base = ownBackground ?? Contrast.background(pp)?.color ?? RGB(r: 1, g: 1, b: 1)
                    let textColor = textual ? e.color?.composite(over: base) : nil
                    let v = Occlusion.classify(patch: pp, textColor: textColor, ownBackground: ownBackground, coverHasContent: hasContent)
                    perPoint[i][k] = v
                    if textual, !hasContent { votes[key(c), default: []].append(v) }
                }
            }
        }
        let layers = votes.compactMapValues(Occlusion.layerKind(votes:))

        var opaqueCoverers: [Set<Int>] = Array(repeating: [], count: n)
        for i in 0..<n {
            var points: [Occlusion.PointHit?] = []
            var coverers: Set<Int> = []
            for (k, s) in samples[i].enumerated() {
                guard s.known else { points.append(nil); continue }
                guard let c = s.coverer else { points.append(.own); continue }
                let kind: Occlusion.Cover = isOtherWindow(c) ? .otherWindow : layers[key(c)] ?? perPoint[i][k] ?? .opaque
                points.append(.covered(kind))
                if kind != .seeThrough, case .element(let ci) = c {
                    coverers.insert(ci)
                    if kind == .opaque { opaqueCoverers[i].insert(ci) }
                }
            }
            o.elements[i].state = Occlusion.state(points)
            o.elements[i].coverers = coverers
        }
        // A layer that fully covers some other element is an overlay; text only half showing at an overlay's edge does not fail (see Occlusion.refinePartial)
        let overlays = Set((0..<n).filter { o.elements[$0].state.hidesText }.flatMap { o.elements[$0].coverers })
        for i in 0..<n {
            o.elements[i].state = Occlusion.refinePartial(o.elements[i].state, opaqueCoverers: opaqueCoverers[i], overlays: overlays)
        }
    }
}

extension AXNode {
    /// The frame of a run of text (UTF-16 range) after layout (`AXBoundsForRange`); nil when unreadable.
    func bounds(for r: NSRange) -> CGRect? {
        var range = CFRange(location: r.location, length: r.length)
        guard let rv = AXValueCreate(.cfRange, &range) else { return nil }
        var out: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(ref, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &out) == .success,
              let v = out, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(v as! AXValue, .cgRect, &rect) ? rect : nil
    }

    /// Font and text color of the first run of static text (AXFont and AXForegroundColor from `AXAttributedStringForRange`); nil when unreadable.
    func textStyle() -> (font: FontSpec?, color: TextColor?)? {
        guard let v = value, !v.isEmpty else { return nil }
        var range = CFRange(location: 0, length: (v as NSString).length)
        guard let rv = AXValueCreate(.cfRange, &range) else { return nil }
        var out: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(ref, kAXAttributedStringForRangeParameterizedAttribute as CFString, rv, &out) == .success,
              let a = out as? NSAttributedString, a.length > 0 else { return nil }
        let font = (a.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any]).flatMap(FontSpec.init(axFont:))
        var color: TextColor?
        if let c = a.attribute(NSAttributedString.Key("AXForegroundColor"), at: 0, effectiveRange: nil) as CFTypeRef?,
           CFGetTypeID(c) == CGColor.typeID {
            color = TextColor(c as! CGColor)
        }
        return (font, color)
    }
}

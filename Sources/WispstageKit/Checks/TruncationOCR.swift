import ApplicationServices
import CoreGraphics
import Foundation
import os
import Vision

/// Truncation verdict: compares the text recognized in the screenshot with the full text from Accessibility (measured 2026-10-14).
/// Basis: all 48 cases across two layouts (11 pt and 13 pt) were correct; the highest character ratio among truncated cases was 0.81, and every control case was 1.00 (measured 2026-10-14).
/// Known blind spots: truncation without an ellipsis that cuts less than a tenth of the text is missed (derived from the threshold); dark mode and non-white backgrounds are untested (flattening onto white swallows light text, inferred).
public enum TruncationOCR {
    /// Judged truncated when the recognized text is below this share of the full text (measured 2026-10-14).
    public static let ratio = 0.9
    /// Margin in points added on each side of the frame for per-element crops (measured 2026-10-14).
    public static let cropMargin: CGFloat = 6
    /// Recognition languages when none are configured (the default of `TextCheckConfig.ocrLanguages`). When the UI contains Chinese they must include zh-Hans:
    /// with English only, all 4 Chinese control cases were false positives; the zh-Hans model also recognizes English (measured 2026-10-14).
    static let defaultLanguages = ["en-US"]

    public enum Verdict: Equatable {
        case fits(ratio: Double)
        case truncated(ratio: Double, ellipsis: Bool)
        /// Nothing recognized at all: most likely this area cannot be recognized (light text, icons), not truncation; not judged.
        case unreadable

        public var isTruncated: Bool { if case .truncated = self { true } else { false } }
    }

    /// Lowercases and removes whitespace and punctuation (an ellipsis is punctuation too).
    public static func normalized(_ s: String) -> String {
        String(s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && $0 != "…" })
    }

    static func hasEllipsis(_ s: String) -> Bool { s.contains("…") || s.contains("..") }

    /// Judged truncated when the recognized text contains an ellipsis (and the full text does not); otherwise normalized character counts are compared, truncated when below 90% of the full text and the last character was not recognized. Nothing recognized is not judged.
    /// `ellipsisOnly`: the full text comes from a button's description (what VoiceOver reads, which can be longer than the displayed text), so only an ellipsis counts, not the character count.
    public static func verdict(full: String, ocr: String, ellipsisOnly: Bool = false) -> Verdict {
        let f = normalized(full).count, o = normalized(ocr).count
        guard f > 0, o > 0 || hasEllipsis(ocr) else { return .unreadable }
        let r = Double(o) / Double(f)
        if hasEllipsis(ocr), !hasEllipsis(full) { return .truncated(ratio: r, ellipsis: true) }
        // Truncation without an ellipsis cuts off a piece, so the last character is never visible; when the last character is still there, recognition missed characters in the middle (measured: Vision
        // dropped one middle character of a 9-character Chinese title, ratio 0.89)
        let clipped = normalized(ocr).last != normalized(full).last
        return r < ratio && clipped && !ellipsisOnly ? .truncated(ratio: r, ellipsis: false) : .fits(ratio: r)
    }

    /// Neighbor frames to paint white in the crop: those covering more than half of this element's frame are not painted (measured 2026-10-14: it is usually this element's own container, and painting it would erase the element itself).
    public static func masks(me: CGRect, others: [CGRect]) -> [CGRect] {
        let area = me.width * me.height
        return others.filter { g in
            let i = g.intersection(me)
            return i.isNull || i.width * i.height < 0.5 * area
        }
    }

    /// Splits recognized text into tokens that are then assigned to elements by position: Chinese, Japanese and similar scripts per character, everything else split on whitespace.
    public static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var word = ""
        func flush() { if !word.isEmpty { out.append(word); word = "" } }
        for ch in s {
            if ch.isWhitespace { flush(); continue }
            if ch.unicodeScalars.contains(where: isIdeograph) { flush(); out.append(String(ch)); continue }
            word.append(ch)
        }
        flush()
        return out
    }

    private static func isIdeograph(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF, 0x20000...0x2FA1F: true
        default: false
        }
    }

    /// Assigns each token, by its center, to the smallest frame that contains it (frames widened by `slack` points on each side); tokens in the same frame are joined in the order given.
    public static func assign(_ tokens: [(String, CGRect)], to frames: [CGRect], slack: CGFloat = 3) -> [Int: String] {
        var out: [Int: String] = [:]
        for (t, r) in tokens {
            let c = CGPoint(x: r.midX, y: r.midY)
            guard let i = frames.indices.filter({ frames[$0].insetBy(dx: -slack, dy: -slack).contains(c) })
                .min(by: { frames[$0].width * frames[$0].height < frames[$1].width * frames[$1].height }) else { continue }
            out[i] = out[i].map { $0 + " " + t } ?? t
        }
        return out
    }

    /// The text an element displays: static text takes its value; a button takes its title, or its description when it has none; a text field with an empty value takes its placeholder. Other roles take nothing.
    public static func displayedText(role: String?, value: String?, title: String?, description: String?, placeholder: String?) -> String? {
        func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
        switch role {
        case "AXStaticText": return nonEmpty(value)
        case "AXButton": return nonEmpty(title) ?? nonEmpty(description)
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
            return nonEmpty(value) == nil ? nonEmpty(placeholder) : nil
        default: return nil
        }
    }

    /// Frames that differ by no more than this many points count as unmoved and fully showing (Accessibility frames are rounded to 0.5 points).
    static let frameSlack: CGFloat = 0.5

    /// Only text that is not covered (`.visible`) and shows entirely inside its scroll area and window goes to text recognition: text partly covered by an overlay or details panel, or half past the edge
    /// of a scroll area, shows only partly in the screenshot anyway, so too few recognized characters is not truncation (measured false positives).
    public static func eligible(state: Occlusion.State, frame: CGRect, visibleFrame: CGRect?) -> Bool {
        guard state == .visible, let v = visibleFrame else { return false }
        return v.minX <= frame.minX + frameSlack && v.minY <= frame.minY + frameSlack
            && v.maxX >= frame.maxX - frameSlack && v.maxY >= frame.maxY - frameSlack
    }

    /// Judged only when the frame read before the screenshot matches the one read again after it: for an element animating during the screenshot the frame is stale, and the crop is not of it (a measured false positive).
    public static func stable(_ before: CGRect, _ after: CGRect?) -> Bool {
        guard let after else { return false }
        return abs(before.minX - after.minX) <= frameSlack && abs(before.minY - after.minY) <= frameSlack
            && abs(before.width - after.width) <= frameSlack && abs(before.height - after.height) <= frameSlack
    }

    // MARK: - Recognition

    /// The error thrown by the most recent text recognition (written to steps.log for troubleshooting).
    static let lastError = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Recognizes the text in an image and splits it into tokens; frames are in image pixels (top-left origin).
    static func recognize(_ image: CGImage, languages: [String] = defaultLanguages) -> [(String, CGRect)] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.recognitionLanguages = languages
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([req]) } catch {
            lastError.withLock { $0 = "\(error)" }
        }
        let W = CGFloat(image.width), H = CGFloat(image.height)
        var out: [(String, CGRect)] = []
        let obs = (req.results ?? []).sorted { a, b in
            abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
        }
        for o in obs {
            guard let cand = o.topCandidates(1).first else { continue }
            let s = cand.string
            var cursor = s.startIndex
            for tok in tokens(s) {
                guard let r = s.range(of: tok, range: cursor..<s.endIndex) else { continue }
                cursor = r.upperBound
                let nb = (try? cand.boundingBox(for: r))?.boundingBox ?? o.boundingBox
                out.append((tok, CGRect(x: nb.minX * W, y: (1 - nb.maxY) * H, width: nb.width * W, height: nb.height * H)))
            }
        }
        return out
    }

    /// Flattens onto an opaque white background (the screenshot has an alpha channel, and Vision treats transparency as black), then paints `masks` (pixels, top-left origin) white.
    static func flattened(_ img: CGImage, masks: [CGRect] = []) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let H = CGFloat(img.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        for r in masks { ctx.fill(CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)) }
        return ctx.makeImage()
    }

    /// Recognizes the whole window once and assigns the text to elements by frame (global points).
    static func readWindow(_ image: CGImage, window: CGRect, frames: [CGRect], languages: [String] = defaultLanguages) -> [Int: String] {
        guard let flat = flattened(image), window.width > 0 else { return [:] }
        let s = CGFloat(image.width) / window.width
        let toks = recognize(flat, languages: languages).map { ($0.0, CGRect(x: $0.1.minX / s + window.minX, y: $0.1.minY / s + window.minY,
                                                       width: $0.1.width / s, height: $0.1.height / s)) }
        return assign(toks, to: frames)
    }

    /// Recognizes a per-element crop (the approach of the 2026-10-14 measurement probe): crop with 6 points around the frame, flatten onto white, and paint the frames of other text elements white.
    static func readCrop(_ image: CGImage, window: CGRect, frame: CGRect, others: [CGRect], languages: [String] = defaultLanguages) -> String? {
        let size = CGSize(width: image.width, height: image.height)
        guard let px = Crop.pixelRect(element: frame, window: window, imageSize: size, margin: cropMargin),
              let cut = image.cropping(to: px) else { return nil }
        let s = size.width / window.width
        let local = masks(me: frame, others: others).map {
            CGRect(x: ($0.minX - window.minX) * s - px.minX, y: ($0.minY - window.minY) * s - px.minY, width: $0.width * s, height: $0.height * s)
        }
        guard let flat = flattened(cut, masks: local) else { return nil }
        return recognize(flat, languages: languages).map(\.0).joined(separator: " ")
    }
}

// MARK: - For the per-step generic checks

/// Truncation check results for one window.
struct TruncationFinding {
    let index: Int
    let text: String
    let frame: CGRect
    let detail: String
}

struct TruncationScan {
    var findings: [TruncationFinding] = []
    /// Number of elements sent to text recognition, and number that could not be read.
    var checked = 0
    var unreadable = 0
    /// Elements whose frames differed before and after the screenshot, not judged (animating).
    var moving: [String] = []
    /// Error thrown by text recognition (nil when there was none).
    var error: String?
    /// Judged truncated by whole-window recognition, then overturned to fits by the per-element crop recheck.
    var overturned: [String] = []
    /// Per-element comparison (only with WISPSTAGE_OCR_COMPARE=1): elements where whole-window assignment and per-element crops gave different verdicts.
    var compared = 0
    var disagreements: [String] = []
}

extension TruncationOCR {
    /// Recognizes the whole window once and judges each element by the text assigned to its frame; elements judged truncated are rechecked with a per-element crop, and the recheck wins.
    /// With the environment variable WISPSTAGE_OCR_COMPARE=1, every element is also recognized from a crop, and elements where the two approaches disagree are recorded (to measure assignment accuracy).
    static func scan(_ o: WindowObservation, window: CGRect, image: CGImage?, languages: [String] = defaultLanguages) -> TruncationScan {
        var scan = TruncationScan()
        let els = o.elements
        // When a button has a static text child, the text belongs to the child and the button itself is skipped
        func hasTextChild(_ i: Int) -> Bool {
            var j = i + 1
            while j < els.count, els[j].ancestors.count > els[i].ancestors.count {
                if els[j].isText { return true }
                j += 1
            }
            return false
        }
        let cands: [(Int, String, CGRect, Bool)] = els.indices.compactMap { i in
            let e = els[i]
            guard let f = e.frame, f.width > 0, f.height > 0, eligible(state: e.state, frame: f, visibleFrame: e.visibleFrame) else { return nil }
            let isButton = e.role == kAXButtonRole
            guard let t = displayedText(role: e.role, value: e.isText ? e.value : e.node.value,
                                        title: isButton ? e.node.title : nil, description: isButton ? e.node.label : nil,
                                        placeholder: e.role == kAXTextFieldRole || e.role == kAXTextAreaRole ? e.node.placeholder : nil),
                  !normalized(t).isEmpty, !(isButton && hasTextChild(i)) else { return nil }
            let fromDescription = isButton && (e.node.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (i, t, f, fromDescription)
        }
        guard !cands.isEmpty, let image else { return scan }
        // The screenshot is taken: read the frames again, and skip those that differ from before the screenshot (animating)
        let moving = Set(cands.indices.filter { !stable(cands[$0].2, els[cands[$0].0].node.frame) })
        scan.moving = moving.map { cands[$0].1 }
        lastError.withLock { $0 = nil }
        let frames = cands.map(\.2)
        let whole = readWindow(image, window: window, frames: frames, languages: languages)
        let compare = ProcessInfo.processInfo.environment["WISPSTAGE_OCR_COMPARE"] == "1"
        for (k, c) in cands.enumerated() where !moving.contains(k) {
            scan.checked += 1
            let others = frames.indices.filter { $0 != k }.map { frames[$0] }
            var v = verdict(full: c.1, ocr: whole[k] ?? "", ellipsisOnly: c.3)
            var read = whole[k] ?? ""
            if compare {
                let crop = readCrop(image, window: window, frame: c.2, others: others, languages: languages) ?? ""
                let cv = verdict(full: c.1, ocr: crop, ellipsisOnly: c.3)
                scan.compared += 1
                if cv.isTruncated != v.isTruncated {
                    scan.disagreements.append("\"\(c.1)\": whole window read \"\(read)\" (\(v.isTruncated ? "truncated" : "fits")), crop read \"\(crop)\" (\(cv.isTruncated ? "truncated" : "fits"))")
                }
            }
            if v.isTruncated {
                let crop = readCrop(image, window: window, frame: c.2, others: others, languages: languages) ?? ""
                let cv = verdict(full: c.1, ocr: crop, ellipsisOnly: c.3)
                if !cv.isTruncated { scan.overturned.append("\"\(c.1)\": whole window read \"\(read)\", crop read \"\(crop)\"") }
                v = cv
                read = crop
            }
            switch v {
            case .unreadable:
                scan.unreadable += 1
            case .fits:
                break
            case .truncated(let r, let ellipsis):
                var detail = "recognized \"\(read)\" in the screenshot, " + (ellipsis ? "with an ellipsis" : String(format: "only %.0f%% of the full text's characters", r * 100))
                if let font = els[c.0].font, els[c.0].isText {
                    let need = Truncation.singleLineWidth(c.1, font: font.nsFont)
                    let quick = Truncation.isTruncated(c.1, font: font.nsFont, frame: c.2.size)
                    detail += String(format: "; quick filter: one line in %@ %.0f pt needs %.1f pt of width, %@", font.name, Double(font.size), Double(need),
                                     quick ? "it also says it does not fit" : "it says it fits (clipped)")
                }
                scan.findings.append(TruncationFinding(index: c.0, text: c.1, frame: c.2, detail: detail))
            }
        }
        scan.error = lastError.withLock { $0 }
        return scan
    }
}

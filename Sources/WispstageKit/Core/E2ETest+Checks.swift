import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WispstageClient

extension E2ETest {
    // MARK: - Generic checks

    func runChecks(skipping: Set<Check>) throws {
        guard let p = app else { return }
        if !skipping.contains(.processAlive), !p.isRunning {
            let report = p.crashReport()
            crashReportPath = report?.path
            throw E2EFailure("App process is gone (exit code \(p.process.terminationStatus))" + (report.map { ", crash report \($0.path)" } ?? ", no crash report found for this run"), check: .processAlive)
        }
        guard p.isRunning, let ax = axApp else { return }
        if !skipping.contains(.responsive) {
            let t0 = Date()
            let (err, _) = ax.raw(kAXWindowsAttribute)
            let dt = Date().timeIntervalSince(t0)
            if err == .cannotComplete || dt > 5 {
                throw E2EFailure(String(format: "Accessibility request got no response for %.1fs (AXError %d)", dt, err.rawValue), check: .responsive)
            }
        }
        var problems: [(Check, String)] = []
        for (c, m) in externalInputProblems(p) {
            if skipping.contains(c) { log("  Waived [\(c.rawValue)] \(m)") } else { problems.append((c, m)) }
        }
        if !Check.keyFocus.judged(in: runMode) {
            for m in KeyFocus.observed(p.stageEvents, since: keyFocusSeen) { log("  Stage recorded: \(m)") }
        }
        let keyFocus = KeyFocus.check(p.stageEvents, since: keyFocusSeen, hidden: hiddenRun && Check.keyFocus.judged(in: runMode))
        keyFocusSeen = keyFocus.seen
        for m in keyFocus.found {
            if skipping.contains(.keyFocus) { log("  Waived [\(Check.keyFocus.rawValue)] \(m)") } else { problems.append((.keyFocus, m)) }
        }
        var listing = ""
        let resolved = WindowList.resolve(pid: p.pid, app: ax, known: knownWindows(), classifier: configuration.classifier)
        for (wi, w) in resolved.enumerated() {
            guard w.ax != nil else { continue }
            let shot = WindowShot { self.windowImage(w).flatMap(RGBAImage.init) }
            let o = Observer.observe(w, app: ax, hits: hitSource, above: resolved[..<wi].map(\.frame), image: shot.get)
            listing += o.listingHeader + AXListing.render(o.entries)
            let wname = "\(w.kind.rawValue)#\(w.id)"
            // A translucent window's (glass panel's) screenshot lacks what shows through from behind it on screen, so its background cannot be measured and contrast is not measured
            let translucent = configuration.classifier.translucentWindows(events: app?.events ?? []).contains(w.id)
            if !skipping.contains(.placeholder) {
                for s in Set(o.strings) { for h in TextChecks.placeholders(in: s, copyKeys: configuration.textChecks.copyKeys, extraPatterns: placeholderPatterns) { problems.append((.placeholder, "\(wname) \"\(s)\" contains \(h)")) } }
            }
            if !skipping.contains(.plural), language.hasPrefix("en") {
                for s in Set(o.strings) { for h in TextChecks.pluralOne(in: s) { problems.append((.plural, "\(wname) \"\(s)\": \(h)")) } }
            }
            // Static text takes part in the overlap, outside-the-window, truncation, occlusion and contrast checks; text that is fully covered (opaque or glass) does not (see Occlusion).
            // Waived checks are still computed, only to crop the involved elements and record them as waived.
            let texts = o.elements.indices.filter { o.elements[$0].isText && o.elements[$0].text != nil && o.elements[$0].frame != nil }
            let boxes = texts.map { o.elements[$0].box }
            var involved: [(Check, Int)] = []   // (check, index into o.elements)
            func report(_ c: Check, _ m: String, _ i: Int) {
                if skipping.contains(c) {
                    log("  Waived [\(c.rawValue)] \(m)")
                } else if c.failsStep {
                    problems.append((c, m))
                } else if let label = currentStep, noteKeys.insert(c.rawValue + "|" + m).inserted {
                    notes.append(.init(check: c.rawValue, step: label, element: m, detail: ""))
                }
                involved.append((c, i))
            }
            // When one text is covered by the layer of another (that text itself or an ancestor), the two are on different layers and intersecting does not count as overlap
            func layered(_ a: Int, under b: Int) -> Bool {
                let cov = o.elements[a].coverers
                return cov.contains(b) || o.elements[b].ancestorIndices.contains(where: cov.contains)
            }
            let found = TextChecks.layout(boxes, window: w.frame, hit: { i, _ in o.elements[texts[i]].state.hidesText ? .other : .own },
                                          separated: { a, b in layered(texts[a], under: texts[b]) || layered(texts[b], under: texts[a]) })
            let hidden = texts.filter { o.elements[$0].state.hidesText }
            if !hidden.isEmpty {
                log("  \(wname) occluded, excluded from text checks: " + hidden.map { "\"\(o.elements[$0].text ?? "")\"\(o.elements[$0].state.mark ?? "")" }.joined(separator: ", "))
            }
            for pair in found.overlaps {
                let a = boxes[pair.a], b = boxes[pair.b]
                report(.overlap, "\(wname) \"\(a.text)\"\(rect(a.frame)) overlaps \"\(b.text)\"\(rect(b.frame))", texts[pair.a])
                involved.append((.overlap, texts[pair.b]))
            }
            for i in found.outOfBounds {
                report(.bounds, "\(wname)\(rect(w.frame)): \"\(boxes[i].text)\"\(rect(boxes[i].frame)) is outside the window", texts[i])
            }
            // Truncation: static text, button titles and placeholder text of empty fields; text recognition runs once on the whole window, results are assigned to elements by frame and compared with the accessibility full text (TruncationOCR)
            let trunc = TruncationOCR.scan(o, window: w.frame, image: shot.get()?.cgImage, languages: configuration.textChecks.ocrLanguages)
            for f in trunc.findings { report(.truncation, "\(wname) \"\(f.text)\"\(rect(f.frame)) is truncated: \(f.detail)", f.index) }
            if trunc.checked > 0 {
                log("  \(wname) truncation text recognition: \(trunc.checked) checked, \(trunc.unreadable) unreadable and not judged" + (trunc.error.map { " (recognition error: \($0))" } ?? "")
                    + (trunc.moving.isEmpty ? "" : "; \(trunc.moving.count) not judged because their frame changed around the screenshot")
                    + (trunc.overturned.isEmpty ? "" : "; \(trunc.overturned.count) judged truncated on the whole window, overturned to fitting by crop review: " + trunc.overturned.joined(separator: ", "))
                    + (trunc.compared > 0 ? "; \(trunc.compared) compared per element, \(trunc.disagreements.count) disagreed" : ""))
                for d in trunc.disagreements { log("    Disagreement \(d)") }
            }
            var measured = 0
            var lowest: (ratio: Double, text: String)?
            for i in texts {
                let e = o.elements[i]
                guard !e.state.hidesText, e.visibleFrame != nil, let f = e.frame else { continue }
                if e.state == .partial {
                    report(.occlusion, "\(wname) \"\(e.text ?? "")\"\(rect(f)) is partly covered by something opaque in the same app", i)
                }
                if e.state == .visible, !translucent, let m = contrast(e, window: w, shot: shot) {
                    measured += 1
                    if m.ratio < lowest?.ratio ?? .infinity { lowest = (m.ratio, e.text ?? "") }
                    let need = WCAG.minimumRatio(pointSize: e.font?.size, bold: e.font?.isBold ?? false)
                    if m.ratio < need, !e.ancestors.contains(where: { !$0.isEnabled }) {
                        report(.contrast, "\(wname) \"\(e.text ?? "")\"\(rect(f)) contrast \(String(format: "%.2f", m.ratio)):1 is below \(fmt(CGFloat(need))):1"
                               + " (text \(hex(m.foreground))\(m.fromDeclared ? " declared color" : " from screenshot"), background \(hex(m.background)))", i)
                    }
                }
            }
            if translucent {
                log("  \(wname) is a translucent window (glass panel); its screenshot lacks what shows through from behind, contrast not measured")
            } else if let lowest {
                log("  \(wname) contrast measured on \(measured) texts, lowest \(String(format: "%.2f", lowest.ratio)):1 \"\(lowest.text.prefix(20))\"")
            }
            if !involved.isEmpty {
                cropInvolved(involved.map { (check: $0.0, box: o.elements[$0.1].box, id: o.elements[$0.1].id) }, window: w, waived: skipping)
            }
            listOnly(o, window: w, skipping: skipping)
        }
        writeListing(listing)
        if let first = problems.first {
            for (c, m) in problems { log("  Check failed [\(c.rawValue)] \(m)") }
            let more = problems.count > 1 ? " (\(problems.count - 1) more in steps.log)" : ""
            throw E2EFailure(first.1 + more, check: first.0)
        }
    }

    /// A window's screenshot, captured the first time it is needed.
    final class WindowShot {
        let load: () -> RGBAImage?
        var done = false
        var image: RGBAImage?

        init(_ load: @escaping () -> RGBAImage?) { self.load = load }

        func get() -> RGBAImage? {
            if !done { image = load(); done = true }
            return image
        }
    }

    /// Measures contrast on a crop of the laid-out text's own frame (the element's frame when that cannot be read); the background comes from the outer ring, see `Contrast`. It does not expand outward: for a label on a capsule
    /// background the frame touches the capsule, and expanding picks up the window background (measured 1:1 on a capsule label, 2026-10-14); nor does it use the whole element's frame: a card title's
    /// frame can be the entire card, and the outer ring then picks up the blue selection outline (same day).
    func contrast(_ e: ObservedElement, window w: AppWindow, shot: WindowShot) -> Contrast.Measurement? {
        guard let v = e.box.visibleFrame, v.width >= 4, v.height >= 4, let img = shot.get(),
              let px = Crop.pixelRect(element: v, window: w.frame, imageSize: CGSize(width: img.width, height: img.height), margin: 0),
              let crop = img.sub(px) else { return nil }
        return Contrast.measure(crop, declared: e.color)
    }

    func fmt(_ v: CGFloat) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", Double(v)) }

    func hex(_ c: RGB) -> String {
        String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    /// Listed for review (does not fail the step): missing identifiers, click targets, alignment. Each element is recorded only the first time in a scenario (`notes`).
    func listOnly(_ o: WindowObservation, window w: AppWindow, skipping: Set<Check>) {
        guard let label = currentStep else { return }
        let index = Dictionary(o.elements.indices.map { (AXRef(ref: o.elements[$0].node.ref), $0) }) { a, _ in a }
        let shown = o.elements.indices.filter { o.elements[$0].visibleFrame != nil && !o.elements[$0].state.hidesText }
        func local(_ f: CGRect?) -> String { f.map { rect($0.offsetBy(dx: -w.frame.minX, dy: -w.frame.minY)) } ?? "" }
        func describe(_ e: ObservedElement) -> String {
            var s = String((e.role ?? "?").dropPrefix("AX") ?? (e.role ?? "?"))
            if let id = e.id { s += " #" + id }
            if let t = e.text { s += "\"\(t.count > 30 ? String(t.prefix(30)) + "…" : t)\"".replacingOccurrences(of: "\n", with: "⏎") }
            return s
        }
        func note(_ c: Check, _ e: ObservedElement, _ detail: String) {
            guard !skipping.contains(c) else { log("  Waived [\(c.rawValue)] \(describe(e))"); return }
            let key = c.rawValue + "|" + describe(e)
            guard noteKeys.insert(key).inserted else { return }
            notes.append(.init(check: c.rawValue, step: label, element: describe(e), detail: detail))
        }
        for i in shown {
            let e = o.elements[i]
            if MissingIdentifier.isMissing(role: e.role, subrole: e.subrole, id: e.id, text: e.text, actionable: e.actionable, labelledByAncestor: false) {
                let labelled = e.ancestors.contains { a in
                    index[AXRef(ref: a.ref)].map { o.elements[$0].id != nil && o.elements[$0].actionable } ?? false
                }
                if !labelled { note(.missingIdentifier, e, local(e.frame)) }
            }
            if e.actionable, let f = e.frame, HitTarget.isTooSmall(role: e.role, subrole: e.subrole, size: f.size) {
                note(.hitTarget, e, "\(fmt(f.width))x\(fmt(f.height))")
            }
        }
        var groups: [String: [Int]] = [:]
        for i in shown where o.elements[i].listed {
            let e = o.elements[i]
            guard let parent = e.ancestors.last, e.frame != nil else { continue }
            groups["\(CFHash(parent.ref))|\(e.role ?? "")|\(e.ancestors.count)", default: []].append(i)
        }
        for members in groups.values where members.count >= Alignment.minimumCount {
            let frames = members.map { o.elements[$0].frame! }
            for k in Alignment.outliers(frames) {
                let e = o.elements[members[k]]
                note(.alignment, e, "\(local(e.frame)) is not edge-aligned with the other \(members.count - 1) vertically stacked \((e.role ?? "").dropPrefix("AX") ?? "") in the same container")
            }
        }
    }

    /// Writes this step's text listing NN-<step name>.ax.txt.
    func writeListing(_ text: String) {
        guard let label = currentStep else { return }
        try? text.write(to: dir.appendingPathComponent(label + ".ax.txt"), atomically: true, encoding: .utf8)
    }

    /// Writes this step's text listing when the action failed before reaching the generic checks.
    func writeListingNow() {
        guard let (p, ax) = try? requireApp() else { return }
        var s = ""
        let resolved = WindowList.resolve(pid: p.pid, app: ax, known: knownWindows(), classifier: configuration.classifier)
        for (wi, w) in resolved.enumerated() where w.ax != nil {
            let o = Observer.observe(w, app: ax, hits: hitSource, above: resolved[..<wi].map(\.frame)) { self.windowImage(w).flatMap(RGBAImage.init) }
            s += o.listingHeader + AXListing.render(o.entries)
        }
        writeListing(s)
    }

    /// Crops each element involved in a generic check (each element once per step), recorded in results.json and summary.txt.
    func cropInvolved(_ items: [(check: Check, box: TextBox, id: String?)], window w: AppWindow, waived: Set<Check>) {
        guard let label = currentStep else { return }
        guard let img = windowImage(w) else { log("  Cannot crop: cannot capture window #\(w.id)"); return }
        var seen: Set<String> = []
        for item in items {
            let key = "\(item.box.text)|\(item.box.frame)"
            guard seen.insert(key).inserted else { continue }
            let frame = item.box.visibleFrame ?? item.box.frame
            guard let r = Crop.pixelRect(element: frame, window: w.frame, imageSize: CGSize(width: img.width, height: img.height), margin: 8),
                  let cut = Crop.crop(img, to: r) else { log("  Cannot crop: \(rect(frame)) is not inside the screenshot of window \(rect(w.frame))"); continue }
            let url = uniqueURL(Crop.fileName(step: label, id: item.id, text: item.box.text))
            guard PNG.write(cut, to: url) else { log("  Cannot crop: cannot write \(url.path)"); continue }
            let isWaived = waived.contains(item.check)
            crops.append(.init(step: label, check: item.check.rawValue, element: item.id ?? item.box.text, path: url.path, waived: isWaived))
            log("  Crop [\(item.check.rawValue)]\(isWaived ? " waived" : "") \(url.lastPathComponent)")
        }
    }

    /// Captures a window into memory (the temporary file is deleted right after).
    func windowImage(_ w: AppWindow) -> CGImage? {
        let tmp = dir.appendingPathComponent("tmp-window-\(w.id)-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let why = Screenshot.captureError(windowID: w.id, to: tmp) { log("  Cannot capture \(w): \(why)"); return nil }
        return PNG.load(tmp)
    }

    /// `<name>.png`, with -2, -3 added when the name is taken.
    func uniqueURL(_ base: String) -> URL {
        var url = dir.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(n).png")
            n += 1
        }
        return url
    }

    func rect(_ r: CGRect) -> String { "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))" }
}

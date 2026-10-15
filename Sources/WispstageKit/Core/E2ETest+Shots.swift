import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WispstageClient

extension E2ETest {
    // MARK: - Screenshots

    /// A screenshot step: captures every window of the app under test on screen (or only one kind), saved as NN-<name>.png (with multiple windows, the others get -<kind>).
    public func shot(_ name: String, window kind: WindowKind? = nil) throws {
        try step(name, shot: false) {
            let n = capture(currentStep ?? name, kind: kind)
            if n == 0 { throw E2EFailure("Cannot capture any window of the app under test") }
        }
    }

    /// A crop step by identifier: captures the element's window as NN-<name>.png, then crops the element's frame plus `margin` points into NN-<name>-<identifier>.png.
    public func shot(id: String, margin: CGFloat = 8, name: String = "crop") throws {
        try shot(.id(id), margin: margin, name: name)
    }

    /// Same as above; the target can be found by text or be an element already found.
    public func shot(_ target: Target, margin: CGFloat, name: String = "crop") throws {
        try step(name, shot: false) {
            let n = try resolve(target)
            guard let frame = n.frame else { throw E2EFailure("Cannot read the frame of \(target)") }
            let w = try windowOf(n, frame: frame)
            guard let label = currentStep else { return }
            let full = dir.appendingPathComponent(label + ".png")
            if let why = Screenshot.captureError(windowID: w.id, to: full) { throw E2EFailure("Cannot capture the window containing \(target) (\(why))") }
            guard let img = PNG.load(full) else { throw E2EFailure("Cannot read the screenshot of the window containing \(target) (\(full.lastPathComponent))") }
            capturedSteps.insert(label)
            shotRecords.append(ShotRecord(file: full.lastPathComponent, variant: variant))
            guard let r = Crop.pixelRect(element: frame, window: w.frame, imageSize: CGSize(width: img.width, height: img.height), margin: margin),
                  let cut = Crop.crop(img, to: r) else { throw E2EFailure("Frame \(rect(frame)) of \(target) is not inside window \(rect(w.frame))") }
            let ident: String? = if case .id(let s) = target { s } else { n.identifier }
            let url = uniqueURL(Crop.fileName(step: label, id: ident, text: n.spoken ?? target.description))
            guard PNG.write(cut, to: url) else { throw E2EFailure("Cannot write \(url.path)") }
            crops.append(.init(step: label, check: nil, element: ident ?? target.description, path: url.path, waived: false))
            shotRecords.append(ShotRecord(file: url.lastPathComponent, variant: variant))
            log("  Crop \(url.lastPathComponent) (in window \(rect(frame.offsetBy(dx: -w.frame.minX, dy: -w.frame.minY))))")
        }
    }

    /// The pixels currently inside the target's frame (plus `margin` points), for scenarios comparing before and after (changes VoiceOver cannot read, such as hover highlights). Not a step; saves no file.
    public func pixels(of target: Target, margin: CGFloat = 0) throws -> RGBAImage {
        let n = try resolve(target)
        guard let frame = n.frame else { throw E2EFailure("Cannot read the frame of \(target)") }
        let w = try windowOf(n, frame: frame)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wispstage-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let why = Screenshot.captureError(windowID: w.id, to: tmp) { throw E2EFailure("Cannot capture the window containing \(target) (\(why))") }
            guard let img = PNG.load(tmp) else { throw E2EFailure("Cannot read the screenshot of the window containing \(target) (\(tmp.lastPathComponent))") }
        guard let r = Crop.pixelRect(element: frame, window: w.frame, imageSize: CGSize(width: img.width, height: img.height), margin: margin),
              let cut = Crop.crop(img, to: r), let rgba = RGBAImage(cut) else { throw E2EFailure("Frame \(rect(frame)) of \(target) is not inside window \(rect(w.frame))") }
        return rgba
    }

    /// The element's window: matched by its AXWindow frame; if none matches, the frontmost one containing its center point.
    func windowOf(_ n: AXNode, frame: CGRect) throws -> AppWindow {
        let ws = try windows()
        if let axw = n.attr(kAXWindowAttribute), CFGetTypeID(axw) == AXUIElementGetTypeID(),
           let wf = AXNode(axw as! AXUIElement).frame,
           let hit = ws.first(where: { abs($0.frame.minX - wf.minX) < 2 && abs($0.frame.minY - wf.minY) < 2 && abs($0.frame.width - wf.width) < 2 }) {
            return hit
        }
        guard let hit = ws.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else {
            throw E2EFailure("\(rect(frame)) is not inside any window of the app under test")
        }
        return hit
    }

    @discardableResult
    func capture(_ label: String, kind: WindowKind? = nil) -> Int {
        guard let ws = try? windows() else { return 0 }
        let targets = ws.filter { kind == nil || $0.kind == kind }
            .sorted { ($0.kind == .main ? 0 : 1, $0.id) < ($1.kind == .main ? 0 : 1, $1.id) }
        var count = 0
        var used: Set<String> = []
        for (i, w) in targets.enumerated() {
            var file = i == 0 ? label : "\(label)-\(w.kind.rawValue)"
            // When there are several windows of the same kind, number them in order (not by window number: it changes every run, so baselines with the same name would not match)
            if used.contains(file) {
                var k = 2
                while used.contains("\(file)-\(k)") { k += 1 }
                file += "-\(k)"
            }
            used.insert(file)
            if Screenshot.capture(windowID: w.id, to: dir.appendingPathComponent(file + ".png")) {
                count += 1
                // Failure screenshots are diagnostic only and do not go into baselines
                if !label.hasSuffix("-failed") { shotRecords.append(ShotRecord(file: file + ".png", variant: variant)) }
            }
        }
        if count > 0 { capturedSteps.insert(label) }
        return count
    }
}

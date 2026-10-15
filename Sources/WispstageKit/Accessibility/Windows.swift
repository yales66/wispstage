import CoreGraphics
import Foundation

/// The kind of a window of the app under test.
/// Built in: `main`, `settings`, `other`; add your own in an `extension WindowKind` (`static let inspector: WindowKind = "inspector"`).
public struct WindowKind: RawRepresentable, Hashable, ExpressibleByStringLiteral, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    public static let main: WindowKind = "main"
    public static let settings: WindowKind = "settings"
    public static let other: WindowKind = "other"
}

/// One on-screen window of the app under test: its CGWindow number (for screenshots) and the matching accessibility window.
public struct AppWindow: CustomStringConvertible {
    public let id: Int
    public var kind: WindowKind
    public let title: String
    /// Global coordinates, top-left origin.
    public let frame: CGRect
    public let layer: Int
    public let ax: AXNode?

    public var description: String {
        "\(kind.rawValue) #\(id) \(title.debugDescription) (\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))) layer=\(layer)"
    }
}

public enum WindowList {
    /// A process's on-screen windows (CGWindowListCopyWindowInfo filtered by pid; the order is the stacking order).
    /// No excludeDesktopElements: in hidden mode the windows sit at the lowest layer beneath the wallpaper, and that option would leave them out (measured 2026-10-14).
    public static func onScreen(pid: pid_t) -> [(id: Int, title: String, frame: CGRect, layer: Int)] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: b as CFDictionary)
            else { return nil }
            let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1
            guard alpha > 0, frame.width > 1, frame.height > 1 else { return nil }
            return (id, (w[kCGWindowName as String] as? String) ?? "", frame, (w[kCGWindowLayer as String] as? Int) ?? 0)
        }
    }

    /// Pairs CGWindows with accessibility windows by frame, then assigns kinds. `known` holds window numbers reported by the app through events or registered by your project; the rest are guessed with `classifier`.
    static func resolve(pid: pid_t, app: AXNode, known: [Int: WindowKind], classifier: any WindowClassifier) -> [AppWindow] {
        let axWindows = app.windows.map { ($0, $0.frame) }
        var out: [AppWindow] = []
        for w in onScreen(pid: pid) {
            let ax = axWindows.first { pair in
                guard let f = pair.1 else { return false }
                return abs(f.minX - w.frame.minX) < 2 && abs(f.minY - w.frame.minY) < 2
                    && abs(f.width - w.frame.width) < 2 && abs(f.height - w.frame.height) < 2
            }?.0
            // Windows with no accessibility window that are not among the known ones (such as menu bar items) are not app windows.
            if ax == nil && known[w.id] == nil { continue }
            let title = w.title.isEmpty ? (ax?.title ?? "") : w.title
            let kind = known[w.id] ?? classifier.guess(identifier: ax?.identifier, title: title)
            out.append(AppWindow(id: w.id, kind: kind, title: title, frame: w.frame, layer: w.layer, ax: ax))
        }
        // The largest unrecognized standard window becomes the main window.
        if !out.contains(where: { $0.kind == .main }),
           let i = out.indices.filter({ out[$0].kind == .other && out[$0].ax?.subrole == "AXStandardWindow" })
               .max(by: { out[$0].frame.width * out[$0].frame.height < out[$1].frame.width * out[$1].frame.height }) {
            out[i].kind = .main
        }
        return out
    }
}

/// Screenshot: `screencapture -l <window number> -o -x` captures only that window (no shadow, no sound), panels included.
/// When the window under test is not frontmost and is fully covered by another app's window, the capture still shows the window's own content (measured 2026-10-14:
/// in inprocess mode with Finder frontmost and a Finder window placed over the main window's frame, the screenshot showed the app's main window content).
public enum Screenshot {
    @discardableResult
    public static func capture(windowID: Int, to url: URL) -> Bool {
        captureError(windowID: windowID, to: url) == nil
    }

    /// Why the capture failed (screencapture's exit status and standard error verbatim, or no file was written); nil on success.
    public static func captureError(windowID: Int, to url: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-l", String(windowID), "-o", "-x", url.path]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return "screencapture could not start: \(error)" }
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        p.waitUntilExit()
        if p.terminationStatus != 0 { return "screencapture window \(windowID) exit status \(p.terminationStatus): \(stderr)" }
        if !FileManager.default.fileExists(atPath: url.path) { return "screencapture window \(windowID) exit status 0 but no file was written: \(stderr)" }
        return nil
    }
}

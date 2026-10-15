import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Visibility self-check before a hidden-mode run. Whether the run continues is decided by `coverReason` from window metadata; the compositing comparison below is only logged for reference.
/// What the compositing comparison is for (the risk built into pushing windows beneath the wallpaper: if the wallpaper window is not opaque or its layer changes, it no longer hides them, so a self-check is needed):
/// ScreenCaptureKit composites only "the desktop stack" (the window server backdrop, wallpaper, Stage Manager and other windows below layer -2147483600, excluding Finder desktop icons)
/// within the frame of the window under test, once with that window and once without, and compares the pixels.
/// Both images are compared in memory only, never saved or sent; the user's app windows are not captured either (they can only add another covering layer, never make the result worse).
/// The two images are captured one after the other; with concurrent instances at launch or the user working on the Mac, they have differed by hundreds to thousands of pixels and wrongly stopped a whole run (cause not confirmed), so they do not decide anything. Transient states such as Mission Control or the Spaces switching animation are not covered (verifying those needs the user present; not verified as of 2026-10-14).
public enum Visibility {
    struct StackWindow {
        var id: Int
        var layer: Int
        var owner: String?
        var frame: CGRect
        var alpha: Double = 1
        var name: String? = nil
        /// Owner process id (kCGWindowOwnerPID); nil when unknown.
        var pid: Int32? = nil
        /// kCGWindowIsOnscreen; windows listed with `.optionOnScreenOnly` are all on screen.
        var onScreen: Bool = true

        /// Wallpaper window: owner `Wallpaper` (seen on macOS 27, 2026-10-14), or owner `WindowManager` with window name `Wallpaper`
        /// (seen on macOS 27.2 after a restart, 2026-10-15, at layer -2147483624).
        var isWallpaper: Bool { owner == "Wallpaper" || (owner == "WindowManager" && name == "Wallpaper") }
    }

    /// Decides from window metadata whether the window under test is hidden: its on-screen part must be fully covered by opaque wallpaper windows (`StackWindow.isWallpaper`) at a higher layer.
    /// Returns nil when hidden, otherwise the reason. Reads only layers, frames and alpha, so whatever changes on the user's screen does not affect the result.
    /// Rough part: it assumes "an opaque wallpaper hides it", and the wallpaper owner name and layer are window server implementation details (behavior observed on macOS 27, 2026-10-14; a system update may change it).
    /// If the system changes them, the result becomes "not hidden" (the conservative side); the pixel compositing comparison still runs once and is logged for reference.
    static func wallpaperCovers(target: CGRect, layer: Int, windows: [StackWindow], displays: [CGRect]) -> String? {
        let need = displays.reduce(0) { $0 + area(target.intersection($1)) }
        guard need > 0 else { return nil }
        let walls = windows.filter { $0.isWallpaper && $0.alpha >= 1 && $0.layer > layer }
        let covered = walls.reduce(0) { $0 + area(target.intersection($1.frame)) }
        if covered + 0.5 >= need { return nil }
        if walls.isEmpty {
            let any = windows.contains { $0.isWallpaper }
            return any ? "layer \(layer) is not beneath an opaque wallpaper" : "no wallpaper window found"
        }
        return "the wallpaper covers only \(Int(covered))/\(Int(need)) square points of the window under test on screen"
    }

    /// Decides from window metadata whether the window under test (owned by `pid`) is hidden: covered by opaque wallpaper (`wallpaperCovers`), or, on each display it is on,
    /// contained in one opaque, on-screen, normal-layer (layer 0) window of another process. The second case is another app's full-screen Space, which has no wallpaper window:
    /// that app's window then hides the window under test. Returns nil when hidden, otherwise the wallpaper reason.
    /// Rough part: any window meeting the rule counts, full-screen or not; it is consulted only when the wallpaper does not cover, which in a normal Space it does.
    static func coverReason(target: CGRect, layer: Int, pid: Int32, windows: [StackWindow], displays: [CGRect]) -> String? {
        guard let why = wallpaperCovers(target: target, layer: layer, windows: windows, displays: displays) else { return nil }
        let covers = windows.filter { $0.pid != nil && $0.pid != pid && $0.layer == 0 && $0.alpha >= 1 && $0.onScreen }
        let parts = displays.map { target.intersection($0) }.filter { area($0) > 0 }
        let hidden = !parts.isEmpty && parts.allSatisfy { part in covers.contains { $0.frame.contains(part) } }
        return hidden ? nil : why
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    /// Metadata of the windows on screen right now (CGWindowListCopyWindowInfo; wallpapers of other Spaces are not included), global top-left origin.
    static func currentWindows() -> [StackWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { w in
            guard let id = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return StackWindow(id: id, layer: (w[kCGWindowLayer as String] as? Int) ?? 0, owner: w[kCGWindowOwnerName as String] as? String,
                               frame: frame, alpha: (w[kCGWindowAlpha as String] as? Double) ?? 1, name: w[kCGWindowName as String] as? String,
                               pid: w[kCGWindowOwnerPID as String] as? Int32, onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? true)
        }
    }

    static func displayFrames() -> [CGRect] {
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &n) == .success, n > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        guard CGGetActiveDisplayList(n, &ids, &n) == .success else { return [] }
        return ids.prefix(Int(n)).map { CGDisplayBounds($0) }
    }

    /// Upper bound of the layers around the wallpaper: wallpaper -2147483625, backdrop -2147483626, Stage Manager -2147483624 (measured); ordinary windows are near 0.
    static let desktopLayerCeiling = -2147483600

    /// A pixel counts as different only when the sum of its three color channel differences exceeds `threshold` (24 measured 0 differing pixels at the lowest layer).
    static func countDiffering(_ a: [UInt8], _ b: [UInt8], threshold: Int = 24) -> Int {
        var n = 0
        for i in stride(from: 0, to: min(a.count, b.count) - 3, by: 4) {
            let d = abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
            if d > threshold { n += 1 }
        }
        return n
    }

    /// Window numbers in the desktop stack that intersect the window under test.
    static func desktopStack(_ ws: [StackWindow], targetID: Int, target: CGRect) -> [Int] {
        ws.filter { $0.id != targetID && $0.layer < desktopLayerCeiling && $0.owner != "Finder" && $0.frame.intersects(target) }.map(\.id)
    }

    /// Composites the desktop stack with and without the window under test and returns how many pixels differ.
    public static func differingPixels(windowID: Int, timeout: TimeInterval = 15) throws -> Int {
        final class Box: @unchecked Sendable { var result: Result<Int, Error>? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await compare(windowID: CGWindowID(windowID))) } catch { box.result = .failure(error) }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + timeout) == .success, let r = box.result else {
            throw E2EFailure("visibility self-check did not finish within \(Int(timeout)) s")
        }
        return try r.get()
    }

    private static func compare(windowID: CGWindowID) async throws -> Int {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let target = content.windows.first(where: { $0.windowID == windowID }) else {
            throw E2EFailure("visibility self-check could not find the window under test #\(windowID)")
        }
        let all = content.windows.map {
            StackWindow(id: Int($0.windowID), layer: $0.windowLayer, owner: $0.owningApplication?.applicationName, frame: $0.frame)
        }
        let ids = Set(desktopStack(all, targetID: Int(windowID), target: target.frame))
        let stack = content.windows.filter { ids.contains(Int($0.windowID)) }
        guard let display = content.displays.first(where: { $0.frame.intersects(target.frame) }) else {
            throw E2EFailure("visibility self-check: window under test #\(windowID) is not on any display")
        }
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = CGRect(x: target.frame.minX - display.frame.minX, y: target.frame.minY - display.frame.minY,
                                width: target.frame.width, height: target.frame.height)
        cfg.width = Int(target.frame.width) * 2
        cfg.height = Int(target.frame.height) * 2
        cfg.showsCursor = false
        let with = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: stack + [target]), configuration: cfg)
        let without = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: stack), configuration: cfg)
        return countDiffering(rgba(with), rgba(without))
    }

    private static func rgba(_ img: CGImage) -> [UInt8] {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }
}

/// Self-checks once per run, only in background mode (hidden windows), the first time the E2E bundle launches; if windows cannot be hidden the whole run stops (`Runner.run` checks `failed`).
public enum VisibilityGate {
    nonisolated(unsafe) static var checked = false
    nonisolated(unsafe) public static var failed = false

    static func verify(pid: pid_t, log: (String) -> Void) throws {
        guard !checked else { return }
        checked = true
        var target: (id: Int, frame: CGRect, layer: Int)?
        _ = Wait.until {
            target = WindowList.onScreen(pid: pid).first { $0.layer < Visibility.desktopLayerCeiling }.map { ($0.id, $0.frame, $0.layer) }
            return target != nil
        }
        do {
            guard let target else { throw E2EFailure("no window of the app under test found beneath the wallpaper") }
            // Only window metadata decides: the two compositing images are captured one after the other, and changes on the user's screen or from concurrent instances in between can differ by hundreds to thousands of pixels,
            // which once wrongly stopped a whole run; the comparison result stays in the log for reference and does not decide.
            let why = Visibility.coverReason(target: target.frame, layer: target.layer, pid: pid,
                                             windows: Visibility.currentWindows(), displays: Visibility.displayFrames())
            let diff = (try? Visibility.differingPixels(windowID: target.id)).map(String.init) ?? "unavailable"
            log("  visibility self-check: window under test #\(target.id) layer \(target.layer), \(why ?? "fully beneath an opaque wallpaper or another app's opaque window"); compositing pixel difference \(diff) (reference only)")
            if let why { throw E2EFailure(why) }
        } catch {
            failed = true
            throw E2EFailure("windows cannot be hidden (\(error)): stopping the whole run; to watch the windows or investigate, run with --mode foreground")
        }
    }
}

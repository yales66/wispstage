import Accelerate
import ApplicationServices
import CoreGraphics
import CoreMedia
import Foundation
import QuartzCore
import ScreenCaptureKit

/// Captures the area of the window under test during a motion recording: a display filter composites only this window, and `sourceRect` crops to the window frame.
/// A single-window stream `SCContentFilter(desktopIndependentWindow:)` isn't used: with the window under test hidden beneath the wallpaper,
/// a single-window stream delivers only 1 to 5 frames during an 8 to 16 second animation; a display filter delivers every frame, dropping 2% to 3.3%
/// at a `minimumFrameInterval` of 1/120 (measured 2026-10-14).
/// The window frame is the one the caller got from `CGWindowListCopyWindowInfo`: `SCWindow.frame` can be off by 1 to 2 pt, shifting the whole image (same measurement).
/// Each frame keeps only the luminance plane in the callback, losslessly: one full-window image at one pixel per point (averaging k×k native pixels),
/// plus a crop near the targets at native pixel density (`MotionHiRes`: keeps wherever changed), which doubles the resolution of capture readings.
/// A full-window Retina color frame is about 13 MB, too much to keep.
final class MotionDisplayStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Keeps at most this many frames (a frame is about one byte per point of window area, about 1 MB for a 1200x800 window): enough for 15 seconds on a 60 Hz display.
    static let maxFrames = 900

    private let size: (width: Int, height: Int)
    /// Native pixels per point (the display's pointPixelScale rounded; no crop is kept when 1).
    let pixelsPerPoint: Int
    /// Which area the native-pixel crop currently keeps (points in the window) and how many bytes crops use so far; the previous full-window frame (for finding changes). Read and written only on the callback queue.
    private var region: CGRect
    private var cropBytes = 0
    private var previous: MotionGrayFrame?
    private let queue = DispatchQueue(label: "wispstage.motion.display")
    private let lock = NSLock()
    private var frames: [MotionGrayFrame] = []
    private var stream: SCStream?
    private(set) var stopError: String?
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    private init(width: Int, height: Int, pixelsPerPoint: Int, seed: CGRect) {
        size = (width, height)
        self.pixelsPerPoint = pixelsPerPoint
        region = seed
    }

    /// Starts capturing `windowID`; `frame` is its frame in global coordinates (top-left origin, points, from CGWindowListCopyWindowInfo).
    /// `seed` is the first native-pixel crop (points in the window, usually the targets' frames when recording starts). Returns the reason when
    /// capture can't start (for example the terminal lacks Screen Recording permission).
    static func start(windowID: Int, frame: CGRect, seed: CGRect) -> Result<MotionDisplayStream, E2EFailure> {
        let sem = DispatchSemaphore(value: 0)
        var content: SCShareableContent?
        var failure: String?
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { c, e in
            content = c
            failure = e.map { "\($0.localizedDescription)" }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 5) == .success else { return .failure(E2EFailure("timed out waiting for SCShareableContent")) }
        guard let window = content?.windows.first(where: { Int($0.windowID) == windowID }) else {
            return .failure(E2EFailure(failure ?? "window \(windowID) not found in ScreenCaptureKit"))
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let display = content?.displays.first(where: { $0.frame.contains(center) }) ?? content?.displays.first else {
            return .failure(E2EFailure("no display in ScreenCaptureKit"))
        }
        let w = max(1, Int(frame.width.rounded())), h = max(1, Int(frame.height.rounded()))
        let filter = SCContentFilter(display: display, including: [window])
        let k = max(1, Int(Double(filter.pointPixelScale).rounded()))
        let config = SCStreamConfiguration()
        config.sourceRect = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = w * k
        config.height = h * k
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 8
        let s = MotionDisplayStream(width: w, height: h, pixelsPerPoint: k, seed: seed.insetBy(dx: -MotionHiRes.margin, dy: -MotionHiRes.margin))
        let stream = SCStream(filter: filter, configuration: config, delegate: s)
        do { try stream.addStreamOutput(s, type: .screen, sampleHandlerQueue: s.queue) } catch {
            return .failure(E2EFailure("addStreamOutput: \(error.localizedDescription)"))
        }
        var startError: Error?
        stream.startCapture { e in
            startError = e
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 5) == .success else { return .failure(E2EFailure("timed out waiting for startCapture")) }
        if let startError { return .failure(E2EFailure("startCapture: \(startError.localizedDescription)")) }
        s.stream = stream
        return .success(s)
    }

    /// Display time of the last frame (nil before any frame).
    var lastFrameTime: Double? {
        lock.lock(); defer { lock.unlock() }
        return frames.last?.t
    }

    /// Frames so far (unsorted, in arrival order).
    var snapshot: [MotionGrayFrame] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    /// Stops and returns the frames so far (sorted by display time).
    func stop() -> [MotionGrayFrame] {
        if let stream {
            let sem = DispatchSemaphore(value: 0)
            stream.stopCapture { _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 3)
        }
        stream = nil
        queue.sync {}
        lock.lock(); defer { lock.unlock() }
        return frames.sorted { $0.t < $1.t }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let infos = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = infos.first, let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer else { return }
        let t: Double
        if let display = info[.displayTime] as? UInt64 { t = Double(display) * Self.timebase } else {
            t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pb) >= 1, let raw0 = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let base = raw0.assumingMemoryBound(to: UInt8.self)
        let k = pixelsPerPoint
        let W = CVPixelBufferGetWidthOfPlane(pb, 0), H = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let w = min(size.width, W / k), h = min(size.height, H / k)
        // Full window at one pixel per point: native pixels scaled to 1/k with vImage (a per-pixel loop takes over 100 ms a frame in a debug build of the driver, and every frame gets dropped)
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBufferPointer { dst in
            if k == 1 {
                for y in 0..<h { memcpy(dst.baseAddress! + y * w, base + y * stride, w) }
            } else {
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(h * k),
                                        width: vImagePixelCount(w * k), rowBytes: stride)
                var out = vImage_Buffer(data: dst.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                _ = vImageScale_Planar8(&src, &out, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        let small = MotionGrayFrame(t: t, width: w, height: h, pixels: px)
        // Native-pixel crop: follows whatever changed from the previous frame to this one
        var crop: MotionCrop?
        if k > 1 {
            region = MotionHiRes.nextRegion(previous: region, changed: previous.flatMap { MotionQuiet.changedBounds($0, small, step: 3) })
            let r = region.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            if !r.isNull, r.width > 0, r.height > 0 {
                let x0 = Int((r.minX * CGFloat(k)).rounded(.down)), x1 = min(W, Int((r.maxX * CGFloat(k)).rounded(.up)))
                let y0 = Int((r.minY * CGFloat(k)).rounded(.down)), y1 = min(H, Int((r.maxY * CGFloat(k)).rounded(.up)))
                let cw = x1 - x0, ch = y1 - y0
                if cw > 0, ch > 0, cropBytes + cw * ch <= MotionHiRes.byteBudget {
                    var cp = [UInt8](repeating: 0, count: cw * ch)
                    cp.withUnsafeMutableBytes { dst in
                        for y in 0..<ch { memcpy(dst.baseAddress! + y * cw, base + (y0 + y) * stride + x0, cw) }
                    }
                    cropBytes += cw * ch
                    crop = MotionCrop(origin: CGPoint(x: CGFloat(x0) / CGFloat(k), y: CGFloat(y0) / CGFloat(k)),
                                      pixelsPerPoint: Double(k), width: cw, height: ch, pixels: cp)
                }
            }
        }
        previous = small
        lock.lock()
        if frames.count < Self.maxFrames { frames.append(MotionGrayFrame(t: t, width: w, height: h, pixels: px, crop: crop)) }
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        stopError = error.localizedDescription
        lock.unlock()
    }
}

/// Reads the accessibility frames (`AXPosition`, `AXSize`) of a few elements in a loop on a background thread, recording `CACurrentMediaTime` each time and keeping only readings that changed.
/// Interval 2 ms: per the 2026-10-14 measurement it must be no longer than 4 ms (the upper bound derived from 60 Hz, guaranteeing at least one reading per frame); one read measured 0.14 ms.
final class MotionAXPoller: @unchecked Sendable {
    struct Reading: Equatable {
        let t: Double
        /// Global coordinates, top-left origin.
        let rect: CGRect
    }

    static let interval: TimeInterval = 0.002
    /// When a read fails, finds the element again by identifier at this interval. A search walks the window's whole tree, and every node read
    /// needs a reply from the app's main thread; at 0.05 s, a whole drag in a lift-and-drag recording once had no effect, suspected to be
    /// from starving the main thread, so it is about 0.25 s (value not yet measured).
    static let refindInterval: TimeInterval = 0.25

    private var elements: [AXUIElement]
    private let refind: [() -> AXUIElement?]
    private var latestRects: [CGRect?]
    private let lock = NSLock()
    private var stopped = false
    private var readings: [[Reading]]
    private var lastChangeTime: Double
    private let done = DispatchSemaphore(value: 0)

    init(elements: [AXUIElement], refind: [() -> AXUIElement?] = []) {
        self.elements = elements
        self.refind = refind
        latestRects = Array(repeating: nil, count: elements.count)
        readings = Array(repeating: [], count: elements.count)
        lastChangeTime = CACurrentMediaTime()
    }

    /// The last time any element frame changed.
    var lastChange: Double {
        lock.lock(); defer { lock.unlock() }
        return lastChangeTime
    }

    /// Each element's most recently read frame (global coordinates).
    var latest: [CGRect?] {
        lock.lock(); defer { lock.unlock() }
        return latestRects
    }

    func start() {
        let t = Thread { [self] in
            var local = Array(repeating: [Reading](), count: elements.count)
            var lastRefind = Array(repeating: 0.0, count: elements.count)
            while true {
                lock.lock()
                let stop = stopped
                lock.unlock()
                if stop { break }
                var changed = false
                for i in elements.indices {
                    guard let r = Self.frame(elements[i]) else {
                        let now = CACurrentMediaTime()
                        if i < refind.count, now - lastRefind[i] >= Self.refindInterval {
                            lastRefind[i] = now
                            if let e = refind[i]() { elements[i] = e }
                        }
                        continue
                    }
                    let now = CACurrentMediaTime()
                    if local[i].last?.rect != r {
                        local[i].append(Reading(t: now, rect: r))
                        changed = true
                        lock.lock()
                        latestRects[i] = r
                        lock.unlock()
                    }
                }
                if changed {
                    lock.lock()
                    lastChangeTime = CACurrentMediaTime()
                    lock.unlock()
                }
                Thread.sleep(forTimeInterval: Self.interval)
            }
            lock.lock()
            readings = local
            lock.unlock()
            done.signal()
        }
        t.qualityOfService = .userInteractive
        t.start()
    }

    func stop() -> [[Reading]] {
        lock.lock()
        stopped = true
        lock.unlock()
        _ = done.wait(timeout: .now() + 2)
        lock.lock(); defer { lock.unlock() }
        return readings
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        var pv: AnyObject?, sv: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}

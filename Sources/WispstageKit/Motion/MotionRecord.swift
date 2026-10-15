import CoreGraphics
import Foundation
import QuartzCore

extension E2ETest {
    /// Records the frame-by-frame motion of elements during an interaction: do the interaction in `body` (for example `t.drag(...)`), then wait
    /// for the screen to settle (no accessibility frame change and no new captured frame for `quiet` seconds in a row, at most `timeout` seconds)
    /// before stopping. Everything is measured from outside the app (see the Motion.swift file header), without asking the app under test for layer data.
    /// Writes three files to the scenario directory:
    /// - `motion-<name>.jsonl`: one line per reading (ms, id, src, x, y, w, h, scale, opacity, shadow); time zero is the lift;
    /// - `motion-<name>.txt`: "spec / measured / diff" for each item in `specs`, with diffs over tolerance marked, then each track's per-channel start, end and 95% time;
    /// - `motion-<name>.png`: stills (captured luminance images) at `stills` milliseconds after each spec's time zero, one row per spec.
    /// Each identifier gets two tracks: the accessibility frame (the identifier itself) and capture template matching ("identifier~capture",
    /// which can follow a lifted element that isn't in the accessibility tree).
    /// Deviations from spec don't fail the step; they only go into the report.
    @discardableResult
    public func recordMotion(_ name: String, ids: [String], specs: [MotionSpec] = [], stills: [Int] = MotionStills.defaultOffsets,
                             quiet: TimeInterval = 0.3, timeout: TimeInterval = 5, _ body: () throws -> Void) throws -> MotionRecording {
        let (proc, _) = try requireApp()
        var targets: [MotionTarget] = []
        var nodes: [AXNode] = []
        var window: AppWindow?
        for id in ids {
            let n = try element(id: id)
            guard let f = n.frame else { throw E2EFailure("can't read the frame of \(id)") }
            let w = try window ?? windowOf(n, frame: f)
            window = w
            nodes.append(n)
            targets.append(MotionTarget(id: id, rect: f.offsetBy(dx: -w.frame.minX, dy: -w.frame.minY)))
        }
        guard let window else { throw E2EFailure("recordMotion needs at least one identifier") }

        var notes: [String] = []
        let stream: MotionDisplayStream?
        let seed = targets.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        switch MotionDisplayStream.start(windowID: window.id, frame: window.frame, seed: seed) {
        case .success(let s):
            stream = s
            if s.pixelsPerPoint > 1 {
                notes.append("Capture: full window at 1 px per pt; near the targets (wherever two adjacent frames changed, padded \(Int(MotionHiRes.margin)) pt, otherwise the previous area) "
                             + "an extra crop at the native \(s.pixelsPerPoint) px per pt, and frames where it covers the element are read from it (pixelsPerPoint of px readings: see each row's smallest resolvable amount)")
            }
        case .failure(let why):
            stream = nil
            notes.append("No capture (no px tracks, opacity or stills sheet): the display filter stream didn't start (\(why.reason))")
        }
        // When a frame can't be read (the element was rebuilt, or removed from a list during a drag), find it again in the window by identifier
        // WISPSTAGE_MOTION_AX=0 skips accessibility polling (to check whether polling starves the app's main thread)
        let pollAX = ProcessInfo.processInfo.environment["WISPSTAGE_MOTION_AX"] != "0"
        if !pollAX { notes.append("Accessibility polling was off this time (WISPSTAGE_MOTION_AX=0), so there are no ax tracks") }
        let windowNode = window.ax
        let poller = MotionAXPoller(elements: pollAX ? nodes.map(\.ref) : [], refind: pollAX ? ids.map { id in
            { windowNode?.first { $0.identifier == id }?.ref }
        } : [])
        poller.start()
        // Wait for the first frame first (how things look when recording starts is the template)
        _ = Wait.until(timeout: 1, interval: 0.02) { stream?.lastFrameTime != nil || stream == nil }
        log("  Recording motion \(name): \(ids.joined(separator: ", "))")

        let inputStart = CACurrentMediaTime()
        let mark = proc.lineCount
        var bodyError: Error?
        do { try body() } catch { bodyError = error }
        let (wallEnd, inputEnd) = (Date(), CACurrentMediaTime())
        let release = MotionInputs.releaseTime(lines: proc.lines, since: mark, wallNow: wallEnd, mediaNow: inputEnd) ?? inputEnd

        // Wait for the screen to settle: quiet seconds have passed since both the last accessibility frame change and the last captured change near the targets (start and end frames padded 32 pt).
        // Only near the targets: the display filter stream also delivers frames when something changes elsewhere (a clock, another panel), so the whole frame would never settle
        // Record at least MotionRecordSpan.afterRelease seconds after release: the drop spring takes 0.6 s to settle, and the app may handle the release later than the input reply
        var quietAt: Double?
        _ = Wait.until(timeout: timeout, interval: 0.05) {
            guard CACurrentMediaTime() >= release + MotionRecordSpan.afterRelease else { return false }
            let region = (targets.map(\.rect) + poller.latest.compactMap { $0?.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY) })
                .reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -32, dy: -32)
            let pixels = stream.flatMap { MotionQuiet.lastChange(frames: $0.snapshot, region: region) } ?? 0
            let last = max(poller.lastChange, pixels)
            guard CACurrentMediaTime() - last >= quiet else { return false }
            quietAt = last
            return true
        }
        if quietAt == nil { notes.append(String(format: "Area near the targets didn't settle within %.1f s; recorded until the timeout", timeout)) }
        let readings = poller.stop()
        // Frames after settling aren't tracked (template matching takes tens of milliseconds a frame, and the seconds an action step spends on checks are all still frames)
        let keep = MotionRecordSpan.keepUntil(quietAt: quietAt, quiet: quiet, release: release)
        let frames = (stream?.stop() ?? []).filter { $0.t <= keep }
        if let why = stream?.stopError { notes.append("Capture stopped early: \(why)") }

        let tracks = Self.motionTracks(targets: targets, readings: readings, frames: frames, window: window.frame)
        let rec = MotionRecording(name: name, targets: targets, tracks: tracks,
                                  inputs: MotionInputs(start: inputStart, release: release), capturedFrames: frames.count)

        try step("motion \(name)", shot: false) {
            let base = "motion-" + FileName.safe(name)
            let jsonl = dir.appendingPathComponent(base + ".jsonl")
            try rec.jsonl().write(to: jsonl, atomically: true, encoding: .utf8)
            if !frames.isEmpty {
                if let sheet = Self.stillsSheet(rec, specs: specs, offsets: stills, frames: frames) {
                    PNG.write(sheet.image, to: dir.appendingPathComponent(base + ".png"))
                    notes.append("Stills sheet: \(base).png, \(sheet.caption)")
                } else {
                    notes.append("No stills sheet: \(frames.count) captured frames, but no still frames could be picked or no area could be cropped")
                }
            }
            // WISPSTAGE_MOTION_FRAMES=1: exports every frame from 0.3 s before release (full-window luminance image and native-pixel crop) as PNG,
            // named by milliseconds from release, for checking lost tracking and position differences against the images
            if ProcessInfo.processInfo.environment["WISPSTAGE_MOTION_FRAMES"] == "1" {
                let out = dir.appendingPathComponent(base + "-frames")
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                var n = 0
                for f in frames where f.t >= release - 0.3 {
                    let ms = Int(((f.t - release) * 1000).rounded())
                    if let img = f.cgImage { PNG.write(img, to: out.appendingPathComponent("f\(ms).png")) }
                    if let c = f.crop, let img = c.cgImage {
                        PNG.write(img, to: out.appendingPathComponent(String(format: "f%d-crop@%.0f,%.0f.png", ms, c.origin.x, c.origin.y)))
                    }
                    n += 1
                }
                notes.append("Frame images: \(base)-frames/, \(n) frames from 0.3 s before release, named by milliseconds from release")
            }
            let report = rec.report(specs: specs, notes: notes)
            try report.write(to: dir.appendingPathComponent(base + ".txt"), atomically: true, encoding: .utf8)
            log("  Motion tracks \(base).jsonl (\(frames.count) captured frames, \(rec.tracks.count) tracks), comparison \(base).txt")
            for spec in specs {
                for r in rec.compare(spec) { log("    \(spec.name) \(r.item): \(r.spec) / \(r.measured) / \(r.diff)") }
            }
        }
        if let bodyError { throw bodyError }
        return rec
    }

    /// Accessibility readings lead the screen by about one frame (measured 2026-10-14: 17 ms early after alignment); times are shifted later by this amount to line up with capture display times.
    static let axLead = 0.017

    /// Two tracks per target: the accessibility frame (scale = width / starting width; opacity is the regression slope of the frame on screen at that moment against the starting look) and capture template matching.
    static func motionTracks(targets: [MotionTarget], readings: [[MotionAXPoller.Reading]], frames: [MotionGrayFrame],
                             window: CGRect) -> [MotionTrack] {
        var out: [MotionTrack] = []
        let times = frames.map(\.t)
        for (i, target) in targets.enumerated() {
            let rs = i < readings.count ? readings[i] : []
            let ax = rs.map { r -> MotionSample in
                let t = r.t + axLead
                let local = r.rect.offsetBy(dx: -window.minX, dy: -window.minY)
                let scale = target.rect.width > 0 ? Double(local.width / target.rect.width) : 1
                let opacity = frames.isEmpty ? nil : MotionPixelTracker.opacity(
                    in: frames[MotionStills.pick(frameTimes: times, at: [t])[0]], rect: local, scale: 1, base: frames[0], baseRect: target.rect)
                return MotionSample(t: t, rect: local, scale: scale, opacity: opacity, shadow: nil)
            }
            out.append(MotionTrack(name: target.id, target: i, source: .accessibility, samples: ax))
            if !frames.isEmpty {
                // After capture loses track, or when accessibility reports a new frame that disagrees with the captured position, retake the template at the accessibility frame.
                // The first reading is the frame when recording started (where the template was taken) and doesn't count as a new frame: during a drag it stays at the original position
                let axr = ax.dropFirst().map { MotionReacquire.Reading(t: $0.t, rect: $0.rect) }
                out.append(MotionTrack(name: target.id + "~capture", target: i, source: .pixels,
                                       samples: MotionPixelTracker.track(frames: frames, rect: target.rect) { f, lostAfter in
                                           MotionReacquire.axRect(axr, at: f.t, lostAfter: lostAfter)
                                       }))
            }
        }
        return out
    }

    /// One row of stills per spec (or for the track's time zero when there are no specs); each row is cropped to the area the elements covered in that row's time span, plus a 16 pt margin.
    private static func stillsSheet(_ rec: MotionRecording, specs: [MotionSpec], offsets: [Int],
                                    frames: [MotionGrayFrame]) -> (image: CGImage, caption: String)? {
        guard !frames.isEmpty, !offsets.isEmpty else { return nil }
        var rows: [(label: String, zero: Double, pick: MotionTrackPick?, anchor: MotionAnchor)] = []
        var seen: Set<String> = []
        for s in specs {
            guard let z = rec.time(of: s.anchor), seen.insert(String(z)).inserted else { continue }
            rows.append((s.name, z, s.track, s.anchor))
        }
        if rows.isEmpty { rows = [("", rec.zero, nil, .start)] }
        let times = frames.map(\.t)
        var cells: [(String, CGImage)] = []
        var decoded: [Int: CGImage] = [:]
        for row in rows {
            let span = (row.zero + Double(offsets.min()!) / 1000)...(row.zero + Double(offsets.max()!) / 1000)
            // Crop to the area covered in this span by the element this spec compares; use all elements when none can be picked
            let focus = row.pick.flatMap { p in rec.window(row.anchor).flatMap { rec.pick(p, in: $0) } }
            guard let extent = focus.flatMap({ rec.extent(of: [$0], in: span) }) ?? rec.extent(of: rec.tracks, in: span) else { continue }
            let picks = MotionStills.pick(frameTimes: times, at: offsets.map { row.zero + Double($0) / 1000 })
            for (o, idx) in zip(offsets, picks) {
                if decoded[idx] == nil { decoded[idx] = frames[idx].cgImage }
                guard let img = decoded[idx] else { continue }
                let px = extent.insetBy(dx: -16, dy: -16).integral.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
                guard !px.isNull, let cut = img.cropping(to: px) else { continue }
                let shown = Int(((frames[idx].t - row.zero) * 1000).rounded())
                cells.append(("\(row.label) +\(o) ms (frame on screen \(shown >= 0 ? "+" : "")\(shown) ms)", cut))
            }
        }
        guard let image = MotionStills.sheet(cells: cells, columns: offsets.count) else { return nil }
        return (image, "\(counted(rows.count, "row")) × \(counted(offsets.count, "cell")), at \(offsets.map(String.init).joined(separator: "/")) ms; " +
                "parentheses in each cell give the display time of the frame actually used (\(frames.count) captured frames, luminance images, one pixel per point)")
    }
}

/// How long a recording is kept.
public enum MotionRecordSpan {
    /// Keep at least this long after release (seconds): the slowest drop spring in the spec, .snappy(duration: 0.35), theoretically settles in 635 ms, plus a margin.
    public static let afterRelease = 1.0

    /// Time captured frames are kept until: `quiet` after the screen settles, and no earlier than `afterRelease` after release; not trimmed if it never settles.
    public static func keepUntil(quietAt: Double?, quiet: Double, release: Double?) -> Double {
        guard let quietAt else { return .infinity }
        return max(quietAt + quiet, release.map { $0 + afterRelease } ?? -.infinity)
    }
}

extension MotionRecording {
    /// The area these elements covered during the time span (points in the window).
    func extent(of tracks: [MotionTrack], in span: ClosedRange<Double>) -> CGRect? {
        tracks.flatMap(\.samples).filter { span.contains($0.t) }.map(\.rect).reduce(nil) { acc, r in acc.map { $0.union(r) } ?? r }
    }
}

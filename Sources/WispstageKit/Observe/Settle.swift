import CoreGraphics
import Foundation

/// After each step, waits for the UI to settle: animations and refreshes count as finished once two consecutive snapshots are equal.
enum Settle {
    /// One snapshot: each window's frame in the window server (what the generic check for text outside the window measures), plus each accessibility element's
    /// role, text and frame. Comparing text alone settles too early during a window move animation, when the text already reports its new position while the window frame is still moving, and reports [bounds].
    struct Snapshot: Equatable {
        var windows: [String]
        var elements: [String]

        init(windows: [(id: Int, frame: CGRect)], elements: [String]) {
            self.windows = windows.map { "\($0.id):" + Settle.rect($0.frame) }
            self.elements = elements
        }
    }

    /// The frame rounded to "x,y,width,height".
    static func rect(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))" }

    /// Takes a snapshot every `interval` and returns true once it equals the previous one; returns false if it is still changing at `timeout`.
    @discardableResult
    static func wait(timeout: TimeInterval, interval: TimeInterval, take: () -> Snapshot) -> Bool {
        var last: Snapshot?
        return Wait.until(timeout: timeout, interval: interval) {
            let snap = take()
            defer { last = snap }
            return snap == last
        }
    }
}

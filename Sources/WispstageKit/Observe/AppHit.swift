import CoreGraphics
import Foundation

/// The hit result at one point: the deepest element the driver computes from accessibility tree frames (`GeometricHit`, see `E2ETest.hitSource`).
/// With windows beneath the wallpaper, an external `AXUIElementCopyElementAtPosition` cannot hit them, so occlusion is decided this way instead.
public struct AppHit: Equatable, Sendable {
    public var role: String?
    public var id: String?
    /// Global coordinates, top-left origin.
    public var frame: CGRect?
    public var window: Int

    public init(role: String?, id: String?, frame: CGRect?, window: Int) {
        self.role = role
        self.id = id
        self.frame = frame
        self.window = window
    }
}

/// Maps a hit element back to the element table the driver read (same window, preorder): elements with the same role and identifier whose frames differ by less than 1 point are candidates.
enum AppHitResolver {
    enum Point: Equatable { case unknown, own, element(Int) }

    /// Frame edges within this many points count as the same element (rounding differences between the app and the driver).
    static let frameTolerance: CGFloat = 1

    /// A candidate that is the element itself, an ancestor or a descendant means a hit on itself; otherwise the last (deepest) candidate; unknown when nothing matches.
    static func resolve(_ h: AppHit?, for i: Int, roles: [String?], ids: [String?], frames: [CGRect?], ancestors: [[Int]]) -> Point {
        guard let h, let hf = h.frame else { return .unknown }
        let candidates = frames.indices.filter { j in
            guard roles[j] == h.role, ids[j] == h.id, let f = frames[j] else { return false }
            return abs(f.minX - hf.minX) <= frameTolerance && abs(f.minY - hf.minY) <= frameTolerance
                && abs(f.width - hf.width) <= frameTolerance && abs(f.height - hf.height) <= frameTolerance
        }
        guard let last = candidates.last else { return .unknown }
        if candidates.contains(where: { $0 == i || ancestors[i].contains($0) || ancestors[$0].contains(i) }) { return .own }
        return .element(last)
    }

    /// Whether the frame of a window of the same app stacked above (`CGWindowListCopyWindowInfo` order; in hidden mode all windows share a layer and the order only reflects when they appeared on screen)
    /// covers this point. Decided by frame, not by whether that window is opaque at this point.
    static func coveredByWindowAbove(_ p: CGPoint, above: [CGRect]) -> Bool {
        above.contains { $0.contains(p) }
    }
}

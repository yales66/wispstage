import CoreGraphics
import Foundation

/// The text listing of each step's UI, NN-<step>.ax.txt: one line per visible element, indented by hierarchy,
/// with role, identifier, text (truncated to 60 characters), frame (point coordinates within the window) and occlusion state. Plain containers with neither identifier nor text are left out.
public enum AXListing {
    public struct Entry: Equatable {
        public var depth: Int
        public var role: String?
        public var id: String?
        public var text: String?
        /// Point coordinates within the window.
        public var frame: CGRect?
        public var visible: Bool
        public var occluded: Bool
        public var state: Occlusion.State

        public init(depth: Int, role: String?, id: String?, text: String?, frame: CGRect?, visible: Bool, occluded: Bool) {
            self.init(depth: depth, role: role, id: id, text: text, frame: frame, visible: visible, state: occluded ? .occluded : .visible)
        }

        public init(depth: Int, role: String?, id: String?, text: String?, frame: CGRect?, visible: Bool, state: Occlusion.State) {
            self.depth = depth
            self.role = role
            self.id = id
            self.text = text
            self.frame = frame
            self.visible = visible
            self.occluded = state == .occluded
            self.state = state
        }
    }

    public static let textLimit = 60

    /// Elements in tree preorder (`depth` is the depth in the original tree); indentation counts the ancestors that were kept.
    public static func render(_ entries: [Entry]) -> String {
        var out = ""
        var kept: [Int] = []   // depths of the kept ancestors
        for e in entries {
            while let last = kept.last, last >= e.depth { kept.removeLast() }
            let id = e.id.flatMap { $0.isEmpty ? nil : $0 }
            let text = e.text.flatMap { $0.isEmpty ? nil : $0 }
            guard e.visible, id != nil || text != nil else { continue }
            var parts = [String((e.role ?? "?").dropPrefix("AX") ?? (e.role ?? "?"))]
            if let id { parts.append("#" + id) }
            if let text { parts.append("\"" + clip(text) + "\"") }
            if let f = e.frame {
                parts.append("(\(Int(f.minX.rounded())),\(Int(f.minY.rounded())) \(Int(f.width.rounded()))x\(Int(f.height.rounded())))")
            }
            if let m = e.state.mark { parts.append(m) }
            out += String(repeating: "  ", count: kept.count) + parts.joined(separator: " ") + "\n"
            kept.append(e.depth)
        }
        return out
    }

    private static func clip(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\r\n", with: "⏎").replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\"", with: "'")
        return one.count > textLimit ? String(one.prefix(textLimit)) + "…" : one
    }
}

/// Which steps keep a full-window screenshot: `--shots=key|all|none`.
public enum ShotsMode: String, Sendable {
    case key, all, none

    /// Whether step `index` (from 1) keeps a full-window screenshot. `explicit` comes from `step(_:shot:)`: true always captures (as `t.shot` does),
    /// false never does; nil follows the mode: key captures only the first step (the last step is added when the scenario ends, failing steps get a failure screenshot), all captures every step, none captures nothing.
    public func capturesStep(_ index: Int, explicit: Bool?) -> Bool {
        if let explicit { return explicit }
        switch self {
        case .key: return index == 1
        case .all: return true
        case .none: return false
        }
    }
}

/// Arguments of the `run` subcommand: filters and `--shots=`.
public struct RunOptions: Equatable {
    public var filters: [String] = []
    public var shots: ShotsMode = .key

    public static func parse(_ args: [String]) throws -> RunOptions {
        var o = RunOptions()
        for a in args {
            if let v = a.dropPrefix("--shots=") {
                guard let m = ShotsMode(rawValue: v) else { throw E2EFailure("--shots must be key, all or none: \(v)") }
                o.shots = m
            } else {
                o.filters.append(a)
            }
        }
        return o
    }
}

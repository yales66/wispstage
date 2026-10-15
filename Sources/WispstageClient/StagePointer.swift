import CoreGraphics
import Foundation

/// The stage `pointer` command: synthesizes one mouse gesture in the process under test. Coordinates are in points, measured from the target window's content area top-left corner.
/// One JSON line: `{"cmd":"pointer","action":"click","window":12,"x":100,"y":200,"right":false,"count":1,"mods":["cmd"]}`;
/// `drag` also takes `toX`, `toY`, `steps`; `move` takes `steps`; `scroll` takes `dy`, `dx` (pixels, positive dy scrolls up).
/// Replies `{"ok":true}` when done and `{"ok":false,"error":"…"}` on error.
public enum StagePointer: Equatable, Sendable {
    case click(window: Int, at: CGPoint, right: Bool = false, count: Int = 1, modifiers: [Modifier] = [])
    case drag(window: Int, from: CGPoint, to: CGPoint, steps: Int)
    /// A held drag in three commands: press the left button, move to a point while held (in `steps` steps), release. Use it to take a screenshot or press Esc mid-drag.
    case down(window: Int, at: CGPoint)
    case move(window: Int, to: CGPoint, steps: Int)
    case up(window: Int, at: CGPoint)
    case hover(window: Int, at: CGPoint)
    case scroll(window: Int, at: CGPoint, dy: Int, dx: Int = 0)

    public enum Modifier: String, Sendable, CaseIterable { case cmd, shift, opt, ctrl }

    public var window: Int {
        switch self {
        case let .click(w, _, _, _, _), let .drag(w, _, _, _), let .down(w, _), let .move(w, _, _), let .up(w, _),
             let .hover(w, _), let .scroll(w, _, _, _): w
        }
    }

    /// The command's fields (including `cmd`).
    public var fields: [String: Any] {
        var f: [String: Any] = ["cmd": "pointer", "window": window]
        func at(_ p: CGPoint) { f["x"] = Double(p.x); f["y"] = Double(p.y) }
        switch self {
        case let .click(_, p, right, count, mods):
            f["action"] = "click"; at(p); f["right"] = right; f["count"] = count; f["mods"] = mods.map(\.rawValue)
        case let .drag(_, a, b, steps):
            f["action"] = "drag"; at(a); f["toX"] = Double(b.x); f["toY"] = Double(b.y); f["steps"] = steps
        case let .down(_, p): f["action"] = "down"; at(p)
        case let .move(_, p, steps): f["action"] = "move"; at(p); f["steps"] = steps
        case let .up(_, p): f["action"] = "up"; at(p)
        case let .hover(_, p): f["action"] = "hover"; at(p)
        case let .scroll(_, p, dy, dx): f["action"] = "scroll"; at(p); f["dy"] = dy; f["dx"] = dx
        }
        return f
    }

    /// Decodes from the command's fields; throws `StageClientError` for a missing or malformed field, and the message goes back to the driver as is.
    public init(fields f: [String: Any]) throws {
        func bad(_ why: String) -> StageClientError { StageClientError("pointer \(f["action"] ?? "?"): \(why)") }
        func num(_ k: String) throws -> Double {
            guard let v = (f[k] as? NSNumber)?.doubleValue, v.isFinite else { throw bad("missing number \(k)") }
            return v
        }
        func count(_ k: String, default d: Int? = nil) throws -> Int {
            guard let n = (f[k] as? NSNumber)?.intValue ?? d else { throw bad("missing \(k)") }
            guard n >= 1 else { throw bad("\(k) must be ≥ 1") }
            return n
        }
        guard let w = (f["window"] as? NSNumber)?.intValue, w > 0 else { throw bad("missing window number") }
        guard let action = f["action"] as? String else { throw bad("missing action") }
        let p = CGPoint(x: try num("x"), y: try num("y"))
        switch action {
        case "click":
            var mods: [Modifier] = []
            for name in f["mods"] as? [String] ?? [] {
                guard let m = Modifier(rawValue: name) else { throw bad("unknown modifier \(name)") }
                mods.append(m)
            }
            self = .click(window: w, at: p, right: f["right"] as? Bool ?? false, count: try count("count", default: 1), modifiers: mods)
        case "drag":
            self = .drag(window: w, from: p, to: CGPoint(x: try num("toX"), y: try num("toY")), steps: try count("steps"))
        case "down": self = .down(window: w, at: p)
        case "move": self = .move(window: w, to: p, steps: try count("steps", default: 1))
        case "up": self = .up(window: w, at: p)
        case "hover": self = .hover(window: w, at: p)
        case "scroll":
            self = .scroll(window: w, at: p, dy: Int(try num("dy")), dx: (f["dx"] as? NSNumber)?.intValue ?? 0)
        default:
            throw bad("unknown action")
        }
    }

    /// Points along a drag: `steps` equal segments, excluding the start and including the end.
    public static func path(from a: CGPoint, to b: CGPoint, steps: Int) -> [CGPoint] {
        let n = max(steps, 1)
        return (1...n).map { i in
            let t = CGFloat(i) / CGFloat(n)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    /// A point measured from the content area's top-left corner → window coordinates (bottom-left origin). `contentFrame` is the contentView's frame in the window.
    public static func windowPoint(_ p: CGPoint, contentFrame: CGRect) -> CGPoint {
        CGPoint(x: contentFrame.minX + p.x, y: contentFrame.maxY - p.y)
    }
}

/// Reply to the stage `status` command: the keyboard target, the actual key window, whether the app is active, and the keyboard target's first responder.
public struct StageStatus: Equatable, Sendable {
    /// The first responder (a field editor is replaced by the control it edits): accessibility identifier, role, and frame in global coordinates with a top-left origin.
    public struct Responder: Equatable, Sendable {
        public var id: String?
        public var role: String?
        public var frame: CGRect?
        public init(id: String?, role: String?, frame: CGRect?) {
            self.id = id
            self.role = role
            self.frame = frame
        }
    }

    public var keyTarget: Int
    public var keyWindow: Int
    public var active: Bool
    public var firstResponder: Responder?

    public init(keyTarget: Int, keyWindow: Int, active: Bool, firstResponder: Responder?) {
        self.keyTarget = keyTarget
        self.keyWindow = keyWindow
        self.active = active
        self.firstResponder = firstResponder
    }

    public init(reply r: [String: Any]) {
        keyTarget = (r["keyTarget"] as? NSNumber)?.intValue ?? 0
        keyWindow = (r["keyWindow"] as? NSNumber)?.intValue ?? 0
        active = r["active"] as? Bool ?? false
        if let fr = r["firstResponder"] as? [String: Any] {
            let a = (fr["frame"] as? [NSNumber])?.map(\.doubleValue)
            firstResponder = Responder(id: fr["id"] as? String, role: fr["role"] as? String,
                                       frame: a.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil })
        } else {
            firstResponder = nil
        }
    }

    /// The fields of `firstResponder` in the reply.
    public static func responderFields(_ r: Responder) -> [String: Any] {
        var f: [String: Any] = [:]
        if let id = r.id { f["id"] = id }
        if let role = r.role { f["role"] = role }
        if let fr = r.frame { f["frame"] = [fr.minX, fr.minY, fr.width, fr.height].map(Double.init) }
        return f
    }
}

extension StageClient {
    /// Asks the stage to synthesize one mouse gesture in the process under test and waits for it to finish (allow enough time for a drag's steps). Throws `StageClientError` when the stage replies with an error.
    public func pointer(_ p: StagePointer, timeout: TimeInterval = 5) throws {
        let r = try request(p.fields, timeout: timeout)
        guard r["ok"] as? Bool == true else { throw StageClientError("pointer failed: \(r["error"] ?? r)") }
    }

    /// The stage's current keyboard target and its first responder.
    public func status(timeout: TimeInterval = 5) throws -> StageStatus {
        let r = try request(["cmd": "status"], timeout: timeout)
        guard r["ok"] as? Bool == true else { throw StageClientError("status failed: \(r["error"] ?? r)") }
        return StageStatus(reply: r)
    }
}

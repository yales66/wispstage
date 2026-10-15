import ApplicationServices
import CoreGraphics
import Foundation

/// An accessibility role. `press(label: "Start", role: .button)`.
public struct AXRole: ExpressibleByStringLiteral, Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { raw = value.hasPrefix("AX") ? value : "AX" + value }
    public var description: String { raw }

    public static let button = AXRole("AXButton")
    public static let staticText = AXRole("AXStaticText")
    public static let textField = AXRole("AXTextField")
    public static let textArea = AXRole("AXTextArea")
    public static let checkBox = AXRole("AXCheckBox")
    public static let radioButton = AXRole("AXRadioButton")
    public static let menuItem = AXRole("AXMenuItem")
    public static let menuButton = AXRole("AXMenuButton")
    public static let popUpButton = AXRole("AXPopUpButton")
    public static let group = AXRole("AXGroup")
    public static let image = AXRole("AXImage")
    public static let link = AXRole("AXLink")
    public static let slider = AXRole("AXSlider")
    public static let window = AXRole("AXWindow")
    public static let scrollArea = AXRole("AXScrollArea")
}

/// An Accessibility API error: `cannotComplete` usually means the app is hung or has quit.
public struct AXFailure: Error, CustomStringConvertible {
    public let what: String
    public let code: AXError
    public var description: String { "\(what): AXError \(code.rawValue)\(code == .cannotComplete ? " (not responding)" : "")" }
}

/// An accessibility element. Attributes that cannot be read are nil; nothing throws.
public struct AXNode: CustomStringConvertible {
    public let ref: AXUIElement

    public init(_ ref: AXUIElement) { self.ref = ref }

    public static func application(pid: pid_t) -> AXNode {
        let app = AXUIElementCreateApplication(pid)
        // Convention: an accessibility request must get a response within 5 seconds, otherwise the app counts as hung.
        AXUIElementSetMessagingTimeout(app, 5)
        return AXNode(app)
    }

    public func raw(_ name: String) -> (AXError, AnyObject?) {
        var v: AnyObject?
        let err = AXUIElementCopyAttributeValue(ref, name as CFString, &v)
        return (err, v)
    }

    public func attr(_ name: String) -> AnyObject? {
        let (err, v) = raw(name)
        return err == .success ? v : nil
    }

    public func string(_ name: String) -> String? {
        guard let v = attr(name) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    public var role: String? { string(kAXRoleAttribute) }
    public var subrole: String? { string(kAXSubroleAttribute) }
    public var identifier: String? { string(kAXIdentifierAttribute) }
    public var title: String? { string(kAXTitleAttribute) }
    /// AXValue when it is a string (text, text field contents); numbers are converted to strings.
    public var value: String? { string(kAXValueAttribute) }
    public var label: String? { string(kAXDescriptionAttribute) }
    public var help: String? { string(kAXHelpAttribute) }
    public var placeholder: String? { string(kAXPlaceholderValueAttribute) }
    public var isEnabled: Bool { (attr(kAXEnabledAttribute) as? Bool) ?? true }

    public var children: [AXNode] {
        (attr(kAXChildrenAttribute) as? [AXUIElement])?.map(AXNode.init) ?? []
    }

    public var windows: [AXNode] {
        (attr(kAXWindowsAttribute) as? [AXUIElement])?.map(AXNode.init) ?? []
    }

    public var position: CGPoint? {
        guard let v = attr(kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    public var size: CGSize? {
        guard let v = attr(kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    /// Global coordinates with a top-left origin, matching CGWindow bounds and CGEvent coordinates.
    public var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    public var center: CGPoint? { frame.map { CGPoint(x: $0.midX, y: $0.midY) } }

    public var actions: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(ref, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    public func perform(_ action: String) throws {
        let err = AXUIElementPerformAction(ref, action as CFString)
        if err != .success { throw AXFailure(what: "perform \(action)", code: err) }
    }

    public func setValue(_ text: String) throws {
        let err = AXUIElementSetAttributeValue(ref, kAXValueAttribute as CFString, text as CFString)
        if err != .success { throw AXFailure(what: "set AXValue", code: err) }
    }

    public func setFocused() throws {
        let err = AXUIElementSetAttributeValue(ref, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if err != .success { throw AXFailure(what: "set AXFocused", code: err) }
    }

    /// What VoiceOver reads out: the first non-empty of title, description and value.
    public var spoken: String? {
        for s in [title, label, value] { if let s, !s.isEmpty { return s } }
        return nil
    }

    /// Every string that is displayed or read out (used by the placeholder check).
    public var allStrings: [String] {
        [title, value, label, help, placeholder].compactMap { $0 }.filter { !$0.isEmpty }
    }

    public var description: String {
        var parts = [role ?? "?"]
        if let s = subrole { parts.append("[\(s)]") }
        if let i = identifier, !i.isEmpty { parts.append("#\(i)") }
        if let t = title, !t.isEmpty { parts.append("title=\(t.debugDescription)") }
        if let l = label, !l.isEmpty { parts.append("desc=\(l.debugDescription)") }
        if let v = value, !v.isEmpty { parts.append("value=\(String(v.prefix(80)).debugDescription)") }
        if let f = frame { parts.append("frame=(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))") }
        let acts = actions.filter { $0 != "AXShowMenu" && $0 != "AXScrollToVisible" }
        if !acts.isEmpty { parts.append("actions=\(acts.joined(separator: ","))") }
        return parts.joined(separator: " ")
    }

    /// Walks the subtree depth first. `visit` receives the element, its depth and the frame of the nearest enclosing scroll area; returning false skips its children.
    /// Visits at most `limit` elements so a malformed tree cannot make the walk run forever.
    public func walk(limit: Int = 8000, _ visit: (AXNode, Int, CGRect?) -> Bool) {
        var count = 0
        func go(_ n: AXNode, _ depth: Int, _ clip: CGRect?) {
            count += 1
            guard count <= limit, depth < 80 else { return }
            guard visit(n, depth, clip) else { return }
            var childClip = clip
            if n.role == kAXScrollAreaRole, let f = n.frame { childClip = clip.map { $0.intersection(f) } ?? f }
            for c in n.children { go(c, depth + 1, childClip) }
        }
        go(self, 0, nil)
    }

    /// Same as `walk`, but `visit` receives the ancestor chain (root first, excluding the element itself) instead of the depth.
    public func walkPath(limit: Int = 8000, _ visit: (AXNode, [AXNode], CGRect?) -> Bool) {
        var count = 0
        var path: [AXNode] = []
        func go(_ n: AXNode, _ clip: CGRect?) {
            count += 1
            guard count <= limit, path.count < 80 else { return }
            guard visit(n, path, clip) else { return }
            var childClip = clip
            if n.role == kAXScrollAreaRole, let f = n.frame { childClip = clip.map { $0.intersection(f) } ?? f }
            path.append(n)
            for c in n.children { go(c, childClip) }
            path.removeLast()
        }
        go(self, nil)
    }

    public func first(where match: (AXNode) -> Bool) -> AXNode? {
        var found: AXNode?
        walk { n, _, _ in
            if found != nil { return false }
            if match(n) { found = n; return false }
            return true
        }
        return found
    }

    /// An indented text tree, written to ax-<step>.txt on failure.
    public func dump() -> String {
        var out = ""
        walk { n, depth, _ in
            out += String(repeating: "  ", count: depth) + n.description + "\n"
            return true
        }
        return out
    }
}

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WispstageClient

extension E2ETest {
    // MARK: - Windows

    func knownWindows() -> [Int: WindowKind] {
        registeredWindows.merging(configuration.classifier.knownWindows(events: app?.events ?? [])) { _, b in b }
    }

    /// Every window of the app under test on screen (main window, settings, panels, popovers…), in stacking order.
    public func windows() throws -> [AppWindow] {
        let (p, ax) = try requireApp()
        return WindowList.resolve(pid: p.pid, app: ax, known: knownWindows(), classifier: configuration.classifier)
    }

    /// Waits for a window of some kind to appear. On timeout, notes when the app's windows exist but none is on the current Space.
    @discardableResult
    public func window(_ kind: WindowKind, timeout: TimeInterval = Wait.defaultTimeout) throws -> AppWindow {
        do {
            return try Wait.value("a \(kind.rawValue) window", timeout: timeout) { try self.windows().first { $0.kind == kind } }
        } catch var f as E2EFailure {
            if let p = app, let note = WindowList.offSpaceNote(WindowList.all(pid: p.pid)) { f.reason += note }
            throw f
        }
    }

    /// Waits for a window of some kind to disappear.
    public func waitGone(_ kind: WindowKind, timeout: TimeInterval = Wait.defaultTimeout) throws {
        guard Wait.until(timeout: timeout, { ((try? self.windows()) ?? []).allSatisfy { $0.kind != kind } }) else {
            throw E2EFailure("\(kind.rawValue) window still present after \(timeout)s")
        }
    }

    // MARK: - Finding elements

    func searchRoots(_ kind: WindowKind?) throws -> [AXNode] {
        let (_, ax) = try requireApp()
        if let kind { return try windows().filter { $0.kind == kind }.compactMap(\.ax) }
        return ax.windows
    }

    /// Finds an element by accessibility identifier, waiting until it appears. `in:` limits the window kind.
    @discardableResult
    public func element(id: String, in kind: WindowKind? = nil, timeout: TimeInterval = Wait.defaultTimeout) throws -> AXNode {
        try Wait.value("identifier \(id)", timeout: timeout) {
            try self.searchRoots(kind).lazy.compactMap { $0.first { $0.identifier == id } }.first
        }
    }

    /// Finds an element by visible or spoken text (title, description, value; exact match), optionally limited to a role.
    @discardableResult
    public func find(label: String, role: AXRole? = nil, in kind: WindowKind? = nil, timeout: TimeInterval = Wait.defaultTimeout) throws -> AXNode {
        try Wait.value("\"\(label)\"\(role.map { " (\($0.raw))" } ?? "")", timeout: timeout) {
            try self.searchRoots(kind).lazy.compactMap { root in
                root.first { n in
                    (role == nil || n.role == role!.raw) && [n.title, n.label, n.value].contains { $0 == label }
                }
            }.first
        }
    }

    /// Every element of a role (no waiting).
    public func all(role: AXRole, in kind: WindowKind? = nil) throws -> [AXNode] {
        var out: [AXNode] = []
        for root in try searchRoots(kind) { root.walk { n, _, _ in if n.role == role.raw { out.append(n) }; return true } }
        return out
    }

    /// Whether the identifier exists (no waiting).
    public func exists(id: String, in kind: WindowKind? = nil) -> Bool {
        ((try? searchRoots(kind)) ?? []).contains { $0.first { $0.identifier == id } != nil }
    }

    /// Waits for an identifier to disappear.
    public func waitGone(id: String, timeout: TimeInterval = Wait.defaultTimeout) throws {
        guard Wait.until(timeout: timeout, { !self.exists(id: id) }) else { throw E2EFailure("\(id) still present after \(timeout)s") }
    }

    public func resolve(_ target: Target) throws -> AXNode {
        switch target {
        case .id(let id): return try element(id: id)
        case .label(let l, let role): return try find(label: l, role: role)
        case .element(let n): return n
        default: throw E2EFailure("\(target) is not an element")
        }
    }

    /// The target's point on screen (the frame's center for an element).
    public func point(of target: Target) throws -> CGPoint {
        switch target {
        case .point(let p): return p
        case .inWindow(let kind, let p):
            let w = try window(kind)
            return CGPoint(x: w.frame.minX + p.x, y: w.frame.minY + p.y)
        case .offset: throw E2EFailure("offset can only be the end of a drag")
        default:
            let n = try resolve(target)
            guard let c = n.center else { throw E2EFailure("Cannot read the frame of \(target)") }
            return c
        }
    }

    /// An element's text: its own value, title or description; if none, the text in its subtree joined in order.
    public func text(of target: Target) throws -> String {
        let n = try resolve(target)
        if let s = n.value ?? n.title, !s.isEmpty { return s }
        var parts: [String] = []
        n.walk { c, depth, _ in
            if depth > 0, c.role == kAXStaticTextRole, let s = c.spoken, !s.isEmpty { parts.append(s) }
            return true
        }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return n.label ?? ""
    }

    /// All text in a window (values of static text), in tree order.
    public func texts(in kind: WindowKind? = nil) throws -> [String] {
        try all(role: .staticText, in: kind).compactMap(\.spoken).filter { !$0.isEmpty }
    }
}

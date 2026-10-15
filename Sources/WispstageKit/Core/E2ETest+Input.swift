import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WispstageClient

extension E2ETest {
    // MARK: - Input that is not a step (use inside a step, or where an action step is deliberately skipped, as tabRaw does)
    //
    // Follows the input mode like the actions above (inprocess: the stage synthesizes inside the process under test, without moving the system cursor or changing the frontmost app; hid: CGEvent),
    // but records no step, does not wait to settle, takes no screenshot and runs no generic checks. Scenarios do not call `Input.*` directly.

    /// Clicks once at a screen point.
    public func rawClick(at p: CGPoint, count: Int = 1, right: Bool = false, modifiers: Mods = []) throws {
        if inputMode == .inprocess {
            let (w, local) = try windowAt(p)
            try pointer(.click(window: w, at: local, right: right, count: count, modifiers: PointerTarget.modifiers(modifiers)))
        } else {
            activate()
            Input.click(at: p, count: count, right: right, mods: modifiers)
        }
    }

    /// Types character by character into the current focus. Under inprocess it types into the focused text field of the app under test (if none, focus is moved through Accessibility to the only
    /// text field in the front window, with the cursor at the end), sending each character through postToPid.
    public func rawType(_ text: String) throws {
        if inputMode == .inprocess {
            let (p, _) = try requireApp()
            let field = try focusedTextInput()
            let before = field.value ?? ""
            valueOnlyField = nil
            // A text field in a panel still reports AXFocused false after focus is set through Accessibility, so key presses from postToPid do not reach it:
            // the stage routes key presses to the first responder of the keyboard target (the panel), which is not this field, and every character reports stage.beep
            // (measured 2026-10-14 on a quick-entry panel in an app under test; the value stayed empty). In that case the whole value is written, the field is remembered, and the next Return becomes AXConfirm on it (`KeyRoute`).
            if (field.attr(kAXFocusedAttribute) as? Bool) != true {
                log("  \(field.identifier ?? field.role ?? "text field") cannot take focus, writing the whole value (AXSetValue, no key presses)")
                try field.setValue(before + text)
                valueOnlyField = field
                return
            }
            PidInput.type(pid: p.pid, text)
            // Non-ASCII characters such as Chinese are sent with the event as committed text; if they do not arrive, fall back to AXSetValue and say so in the log (not a real typing path)
            if text.unicodeScalars.contains(where: { !$0.isASCII }),
               !Wait.until(timeout: 1, { (field.value ?? "").contains(text.filter { $0 != "\n" && $0 != "\r" }) }) {
                log("  postToPid could not type \"\(text.prefix(24))\", falling back to AXSetValue (whole value, no key presses)")
                try field.setValue(before + text)
            }
        } else {
            activate()
            Input.type(text)
        }
    }

    /// Presses a key, delivered to the key window of the app under test (the window clicked last when there is no key window).
    public func rawKey(_ key: Key, modifiers: Mods = []) throws {
        guard let code = key.keyCode else { throw E2EFailure("Unknown key \(key)") }
        if inputMode == .inprocess {
            try externalKey(key, modifiers: modifiers)
        } else {
            activate()
            Input.key(code: code, mods: modifiers)
        }
    }

    /// Presses a key by key code (saved shortcuts store only the key code).
    public func rawKey(code: CGKeyCode, modifiers: Mods = []) throws {
        guard let key = Key(code: code) else { throw E2EFailure("Unknown key code \(code)") }
        try rawKey(key, modifiers: modifiers)
    }

    /// Global shortcut: only possible in foreground mode (in background mode `requireForeground` skips the scenario). Does not bring the app to the front first:
    /// a global shortcut should respond whichever app is frontmost.
    public func rawGlobalKey(_ key: Key, modifiers: Mods = []) throws {
        try requireForeground("global shortcut \(key)")
        guard let code = key.keyCode else { throw E2EFailure("Unknown key \(key)") }
        Input.key(code: code, mods: modifiers)
    }

    public func rawGlobalKey(code: CGKeyCode, modifiers: Mods = []) throws {
        guard let key = Key(code: code) else { throw E2EFailure("Unknown key code \(code)") }
        try rawGlobalKey(key, modifiers: modifiers)
    }

    /// Moves the mouse to a point and stays there (hover).
    public func rawHover(at p: CGPoint) throws {
        if inputMode == .inprocess {
            let (w, local) = try windowAt(p)
            try pointer(.hover(window: w, at: local))
        } else {
            activate()
            Input.hover(at: p)
        }
    }

    /// A press-and-hold drag (to take screenshots or press Esc mid-drag): `mouseDown(at:)` presses, `mouseMove(to:)` moves while held (any number of times),
    /// `mouseUp(at:)` releases. Coordinates are global, origin at top left; under inprocess all three go to the window pressed in. Not a step.
    public func mouseDown(at p: CGPoint) throws {
        guard heldMouse == nil else { throw E2EFailure("Left button already held, call mouseUp first") }
        if inputMode == .inprocess {
            let (w, local) = try windowAt(p)
            try pointer(.down(window: w, at: local))
            heldMouse = (w, CGPoint(x: p.x - local.x, y: p.y - local.y), p)
        } else {
            activate()
            Input.press(at: p)
            heldMouse = (0, .zero, p)
        }
    }

    /// Moves from the current position to `p` with the left button held, in `steps` steps of about 16 milliseconds each.
    public func mouseMove(to p: CGPoint, steps: Int = 24) throws {
        guard let h = heldMouse else { throw E2EFailure("Call mouseDown before mouseMove") }
        if inputMode == .inprocess {
            let local = CGPoint(x: p.x - h.origin.x, y: p.y - h.origin.y)
            try pointer(.move(window: h.window, to: local, steps: steps), timeout: 5 + Double(steps) * 0.05)
        } else {
            Input.dragMove(from: h.at, to: p, steps: steps)
        }
        heldMouse = (h.window, h.origin, p)
    }

    /// Releases the left button at `p`.
    public func mouseUp(at p: CGPoint) throws {
        guard let h = heldMouse else { throw E2EFailure("Call mouseDown before mouseUp") }
        heldMouse = nil
        if inputMode == .inprocess {
            try pointer(.up(window: h.window, at: CGPoint(x: p.x - h.origin.x, y: p.y - h.origin.y)))
        } else {
            Input.release(at: p)
        }
    }

    // MARK: - inprocess input

    /// Which window of the app under test a global point falls in (frontmost first), and the point measured from that window's top-left corner.
    func windowAt(_ p: CGPoint) throws -> (Int, CGPoint) {
        let ws = try windows()
        guard let hit = PointerTarget.window(containing: p, in: ws.map { ($0.id, $0.frame) }) else {
            throw E2EFailure("Point (\(Int(p.x)),\(Int(p.y))) is not inside any window of the app under test")
        }
        return (hit.id, hit.local)
    }

    /// Hit testing for occlusion is computed outside by the driver from geometry (`GeometricHit`): it reads this window's accessibility tree and takes the deepest element containing the point,
    /// with later siblings on top. This holds even with the window beneath the wallpaper (reading the tree does not rely on window server hit testing), and needs no `hit` command in the app under test.
    /// Windows of the same app stacked above are ruled out first by `Observer` from the CG on-screen window order.
    var hitSource: HitSource {
        .app { [weak self] window, points in self?.geometricHits(window: window, points: points) }
    }

    func geometricHits(window: Int, points: [CGPoint]) -> [AppHit?]? {
        guard let w = try? windows().first(where: { $0.id == window }), let wax = w.ax else {
            log("  Hit testing cannot read the accessibility tree of window #\(window)")
            return nil
        }
        var roles: [String?] = [], ids: [String?] = [], frames: [CGRect?] = [], depths: [Int] = []
        wax.walkPath { n, ancestors, _ in
            roles.append(n.role)
            ids.append(n.identifier.flatMap { $0.isEmpty ? nil : $0 })
            frames.append(n.frame)
            depths.append(ancestors.count)
            return true
        }
        let tree = GeometricHit(frames: frames, depths: depths)
        return points.map { p in tree.hit(p).map { AppHit(role: roles[$0], id: ids[$0], frame: frames[$0], window: window) } }
    }

    // MARK: - External keyboard (inprocess)

    static let textInputRoles = KeyRoute.textInputRoles


    /// The app-level AXFocusedUIElement of the app under test (the system-wide attribute cannot be read in hidden mode, measured 2026-10-14, macOS 27.2).
    /// The app-level attribute only answers for elements in the window it considers focused, so a text field in a panel focused through Accessibility cannot be read;
    /// in that case, look for a text field with AXFocused true in each window.
    func focusedElement() -> AXNode? {
        guard let ax = axApp else { return nil }
        var app: AXNode?
        if let v = ax.attr(kAXFocusedUIElementAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() {
            app = AXNode(v as! AXUIElement)
            if let r = app?.role, Self.textInputRoles.contains(r) { return app }
        }
        var field: AXNode?
        for w in ax.windows where field == nil {
            w.walk { n, _, _ in
                if field == nil, let r = n.role, Self.textInputRoles.contains(r), (n.attr(kAXFocusedAttribute) as? Bool) == true { field = n }
                return field == nil
            }
        }
        return field ?? app
    }

    /// The typing target: the focused text field; if none, the only text field in the frontmost window that has text fields, focused through Accessibility.
    /// Setting focus through AX selects all existing text (measured 2026-10-14, macOS 27.2), so afterwards the cursor moves to the end, keeping the "keep typing" behavior.
    func focusedTextInput() throws -> AXNode {
        if let f = focusedElement(), let r = f.role, Self.textInputRoles.contains(r) { return f }
        for w in try windows() {
            guard let wax = w.ax else { continue }
            let fields = textInputs(in: wax)
            if fields.isEmpty { continue }
            guard fields.count == 1 else {
                if let f = stageFocusedField(fields) { return f }
                throw E2EFailure("No focused text field before typing, and the \(w.kind.rawValue) window has \(fields.count) text fields ("
                                 + fields.map { $0.identifier ?? $0.role ?? "?" }.joined(separator: ", ") + "), cannot tell which to type into")
            }
            let f = fields[0]
            try f.setFocused()
            let len = ((f.value ?? "") as NSString).length
            var range = CFRange(location: len, length: 0)
            if let v = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(f.ref, kAXSelectedTextRangeAttribute as CFString, v)
            }
            log("  Focus moved through Accessibility to \(f.identifier ?? f.role ?? "text field"), cursor at the end")
            return f
        }
        throw E2EFailure("No focused text field before typing, and no text field found in the windows of the app under test")
    }

    /// When Accessibility cannot read the focus (a text field clicked in a panel), identifies it among these text fields by the keyboard target's first responder reported by the stage (`ResponderMatch`).
    /// It is already the first responder in the process under test, so focus is not set again through Accessibility (setting focus selects all existing text).
    func stageFocusedField(_ fields: [AXNode]) -> AXNode? {
        guard runMode.usesStage, let stage = app?.stage else { return nil }
        let status: StageStatus
        do { status = try stage.status() } catch { log("  Could not get the first responder from the stage: \(error)"); return nil }
        guard let r = status.firstResponder else { return nil }
        guard let i = ResponderMatch.pick(fields.map { ($0.identifier, $0.frame) }, responder: r) else {
            log("  The first responder reported by the stage (\(r.id ?? r.role ?? "?")) is not one of these text fields")
            return nil
        }
            log("  Identified text field \(fields[i].identifier ?? fields[i].role ?? "text field") from the first responder reported by the stage")
        return fields[i]
    }

    /// Usable text fields in the subtree (including the root).
    func textInputs(in root: AXNode) -> [AXNode] {
        var fields: [AXNode] = []
        root.walk { n, _, _ in
            if let r = n.role, Self.textInputRoles.contains(r), n.isEnabled { fields.append(n) }
            return true
        }
        return fields
    }

    /// Whether the windows of the app under test have a default button and a cancel button (AXDefaultButton, AXCancelButton).
    func windowButtons() -> (default: Bool, cancel: Bool) {
        var d = false, c = false
        for w in axApp?.windows ?? [] {
            if w.attr(kAXDefaultButtonAttribute) != nil { d = true }
            if w.attr(kAXCancelButtonAttribute) != nil { c = true }
        }
        return (d, c)
    }

    /// Presses a key under inprocess: with modifiers, when the main menu has the same shortcut, presses the menu item through AXMenuBar;
    /// for a text field whose value alone was written by the last typing, Return becomes AXConfirm on it (`KeyRoute`); otherwise first checks whether anything will receive it (`KeyGuard`; if nothing will, nothing is sent and the step fails), then sends it to the process under test through postToPid.
    /// `receiver` is the text field the driver just focused through Accessibility (the app-level AXFocusedUIElement may not report it in a panel).
    func externalKey(_ key: Key, modifiers: Mods, receiver: AXNode? = nil) throws {
        let (p, ax) = try requireApp()
        guard let stroke = PidKeys.stroke(key, modifiers: modifiers) else { throw E2EFailure("Unknown key \(key)") }
        if !modifiers.isEmpty, let item = MenuShortcut.find(in: ax, key: key, modifiers: modifiers) {
            log("  Pressing \"\(item.title ?? "?")\" through the main menu")
            try item.perform(kAXPressAction)
            return
        }
        let focused = receiver ?? focusedElement()
        let valueOnly = receiver == nil ? valueOnlyField.flatMap { $0.role == nil ? nil : $0 } : nil
        switch KeyRoute.decide(key: key, modifiers: modifiers, focusedRole: focused?.role, valueOnlyField: valueOnly != nil) {
        case .axConfirm(let note):
            log("  \(note)")
            try valueOnly!.perform(kAXConfirmAction)
            return
        case .external: break
        }
        let buttons = windowButtons()
        if case .unverified(let note) = KeyGuard.decide(key: key, modifiers: modifiers, focusedRole: focused?.role,
                                                        defaultButton: buttons.default, cancelButton: buttons.cancel) {
            log("  \(note)")
        }
        PidInput.key(pid: p.pid, stroke, modifiers: modifiers)
    }

    /// This step's frontmost changes and beeps: the frontmost app changed to the app under test (judged only in background mode, see `Check.judged(in:)`), or the stage reported `stage.beep`.
    func externalInputProblems(_ p: AppProcess) -> [(Check, String)] {
        var out: [(Check, String)] = []
        if Check.foreground.judged(in: runMode) {
            let now = Date()
            for m in ForegroundWatch.violations(ForegroundWatch.shared.activations, appPID: p.pid, from: stepStartedAt, to: now) {
                out.append((.foreground, m))
            }
            if out.isEmpty, NSWorkspace.shared.frontmostApplication?.processIdentifier == p.pid {
                out.append((.foreground, "The app under test is frontmost now (pid \(p.pid)), so the user's keyboard input will go into its windows"))
            }
        }
        let beeps = StageBeep.check(p.stageEvents, since: beepSeen)
        beepSeen = beeps.seen
        out += beeps.found.map { (.beep, $0) }
        return out
    }

    /// Synthesizes one mouse gesture inside the process under test through the stage's `pointer` command and waits for it to finish; fails if the stage returns an error or times out.
    /// When done, records an input acknowledgment in the app's output lines (`AppProcess.notePointerDone`), which motion recording uses for the release time.
    func pointer(_ c: StagePointer, timeout: TimeInterval = 5) throws {
        let (p, _) = try requireApp()
        guard let stage = p.stage else {
            throw E2EFailure("No stage under inprocess, cannot send the mouse gesture (events are not posted to the system)")
        }
        do {
            try stage.pointer(c, timeout: timeout)
        } catch {
            guard p.isRunning else { throw E2EFailure("App has exited", check: .processAlive) }
            throw E2EFailure("The stage did not complete mouse gesture \(c): \(error)")
        }
        p.notePointerDone()
    }
}

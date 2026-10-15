import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WispstageClient

extension E2ETest {
    // MARK: - Actions

    /// Presses by accessibility identifier (AXPress). An element without AXPress is a VoiceOver problem worth recording; use click for clicking.
    public func press(id: String) throws {
        try step("press \(id)") { try pressNode(element(id: id), what: id) }
    }

    /// Finds by text (and role), then presses.
    public func press(label: String, role: AXRole? = .button) throws {
        try step("press \(label)") { try pressNode(find(label: label, role: role), what: label) }
    }

    func pressNode(_ n: AXNode, what: String) throws {
        guard n.actions.contains(kAXPressAction) else {
            throw E2EFailure("\(what) has no AXPress action (VoiceOver users cannot press it); actions are \(n.actions)")
        }
        try n.perform(kAXPressAction)
    }

    /// Clicks once at a screen point (inprocess: the stage synthesizes it inside the process under test; hid: posts a CGEvent).
    public func click(at p: CGPoint, count: Int = 1, right: Bool = false, modifiers: Mods = []) throws {
        try click(.point(p), count: count, right: right, modifiers: modifiers)
    }

    /// Clicks once at the center of the target's frame (for custom gestures).
    public func click(_ target: Target, count: Int = 1, right: Bool = false, modifiers: Mods = []) throws {
        try step("click \(target)") { try rawClick(at: try point(of: target), count: count, right: right, modifiers: modifiers) }
    }

    /// Clicks outside the app under test (screen point): tests behavior driven by global event monitors, such as "clicking elsewhere closes it". With hidden windows the stage
    /// does not deliver real global events to the app, so this sends a synthesized click through the stage's `globalEvent` command to the app's registered global monitors, posting no system event;
    /// it fails when no handler received it. Under hid without hidden windows it posts a real click (which lands in whatever other app is at that point).
    public func clickOutside(at p: CGPoint, right: Bool = false) throws {
        try step("click outside \(Int(p.x)),\(Int(p.y))") {
            let (app, _) = try requireApp()
            if runMode.usesStage, let stage = app.stage {
                let n = try stage.globalEvent(right ? "rightMouseDown" : "leftMouseDown", x: Double(p.x), y: Double(p.y))
                guard n > 0 else { throw E2EFailure("App under test has no global event monitor for clicks, so nothing received the synthesized click elsewhere") }
                _ = try stage.globalEvent(right ? "rightMouseUp" : "leftMouseUp", x: Double(p.x), y: Double(p.y))
            } else if inputMode == .hid {
                Input.click(at: p, right: right)
            } else {
                throw E2EFailure("No stage under inprocess, cannot send the global click elsewhere (events are not posted to the system)")
            }
        }
    }

    /// Sends Unicode keyboard events character by character to the current focus.
    public func type(_ text: String) throws {
        try step("type \(text.prefix(24))") { try rawType(text) }
    }

    /// Sets a text field's AXValue, then presses Return once more when `submit`. Under inprocess it first moves focus to the field through Accessibility
    /// (@FocusState follows, the window does not become key), and Return reaches its field editor through postToPid, triggering onSubmit.
    public func setValue(_ target: Target, _ text: String, submit: Bool = true) throws {
        try step("set \(target)") {
            var n = try resolve(target)
            guard inputMode == .inprocess else {
                try? n.setFocused()
                try n.setValue(text)
                if submit { try rawKey(.return) }
                return
            }
            // The identifier may sit on a container wrapping the text field (a custom input view), so focus has to go to the text field inside it
            if !(n.role.map(Self.textInputRoles.contains) ?? false) {
                let inner = textInputs(in: n)
                if inner.count == 1 { n = inner[0] }
            }
            do { try n.setFocused() } catch { log("  Cannot focus \(target): \(error)") }
            try n.setValue(text)
            guard submit else { return }
            if (n.attr(kAXFocusedAttribute) as? Bool) == true {
                try externalKey(.return, modifiers: [], receiver: n)
            } else if n.actions.contains(kAXConfirmAction) {
                // A text field in a panel still reports AXFocused false after focus is set through Accessibility (measured 2026-10-14 on a panel in an app under test),
                // so Return sent through postToPid does not reach it; AXConfirm is used instead and triggers onSubmit the same way (measured 2026-10-14, macOS 27.2)
                log("  \(target) cannot take focus, using AXConfirm instead of Return (no key press)")
                try n.perform(kAXConfirmAction)
            } else {
                try externalKey(.return, modifiers: [], receiver: n)
            }
        }
    }

    /// Presses a key (optionally with modifiers), delivered to the key window of the app under test. For global shortcuts use `globalKey` (only possible in foreground mode).
    public func key(_ key: Key, modifiers: Mods = []) throws {
        let modText = [(Mods.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { modifiers.contains($0.0) }.map(\.1).joined()
        try step("key \(modText)\(key)") { try rawKey(key, modifiers: modifiers) }
    }

    /// Global shortcut: hot keys registered with Carbon only respond to system keyboard events, so only hid mode can do it; under inprocess the rest of the scenario is skipped.
    public func globalKey(_ key: Key, modifiers: Mods = []) throws {
        try step("global key \(key)") { try rawGlobalKey(key, modifiers: modifiers) }
    }

    /// The next action needs foreground mode (for example, a global shortcut): in background mode this records "step needs foreground mode" and throws `E2ESkip` to end the scenario;
    /// the result is recorded as skipped, not failed, and listed under "Skipped in background mode" in summary.txt, left for a `--mode foreground` run.
    public func requireForeground(_ why: String) throws {
        guard runMode == .background else { return }
        var skip = E2ESkip("Step needs foreground mode: \(why)", step: currentStep)
        skip.foregroundOnly = true
        skipped = skipped ?? skip
        log("  ⤼ Skipped: \(skip.reason)")
        throw skip
    }

    /// Press-and-hold drag: element to element, element to point, or `.offset(dx:dy:)`. Moves in `steps` steps of about 16 milliseconds each.
    public func drag(from: Target, to: Target, steps: Int = 20) throws {
        try step("drag \(from) → \(to)") {
            let a = try point(of: from)
            let b: CGPoint
            if case .offset(let dx, let dy) = to { b = CGPoint(x: a.x + dx, y: a.y + dy) } else { b = try point(of: to) }
            if inputMode == .inprocess {
                let (w, local) = try windowAt(a)
                let origin = CGPoint(x: a.x - local.x, y: a.y - local.y)
                let end = CGPoint(x: b.x - origin.x, y: b.y - origin.y)
                // Each drag step takes about 16 milliseconds; wait for it to finish, plus some margin
                try pointer(.drag(window: w, from: local, to: end, steps: steps), timeout: 5 + Double(steps) * 0.05)
            } else {
                activate()
                Input.drag(from: a, to: b, steps: steps)
            }
        }
    }

    /// Moves the mouse onto the target and stays there.
    public func hover(_ target: Target) throws {
        try step("hover \(target)") { try rawHover(at: try point(of: target)) }
    }

    /// Scrolls over the target; positive dy scrolls up, in pixels.
    public func scroll(_ target: Target, dy: Int, dx: Int = 0) throws {
        try step("scroll \(target) \(dy)") {
            let p = try point(of: target)
            if inputMode == .inprocess {
                let (w, local) = try windowAt(p)
                try pointer(.scroll(window: w, at: local, dy: dy, dx: dx))
            } else {
                activate()
                Input.scroll(at: p, dx: Int32(dx), dy: Int32(dy))
            }
        }
    }
}

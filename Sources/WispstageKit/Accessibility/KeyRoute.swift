import ApplicationServices

/// Which path the next key press takes in inprocess mode: an external `postToPid`, or AXConfirm on the text field that last received only a written value.
///
/// Keys without modifiers are always sent externally too: when there is no key window, the stage of the app under test (the stage library Wispstage) dispatches them as if "the keyboard target is the key window",
/// rewriting the event's window number so local event monitors recognize it; Esc is interpreted as `cancelOperation:` and Return presses the default button.
/// Keys with modifiers are also sent externally (main menu items additionally go through AXMenuBar; shortcut recorder fields receive them, as measured).
enum KeyRoute: Equatable {
    case external
    case axConfirm(String)

    static let textInputRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]

    static let confirmNote = "Return uses AXConfirm instead of a key press: the text field typed into last could not be focused, so its text was written as a whole value"

    /// `focusedRole` is the role of the app's currently focused element (nil if unreadable). `valueOnlyField` means the text field typed into last could not be
    /// focused and its text was written with AXSetValue (see `E2ETest.rawType`): Return sent with postToPid would not reach it then,
    /// so AXConfirm is performed on it instead, which also triggers onSubmit (measured on macOS 27.2, 2026-10-14).
    static func decide(key: Key, modifiers: Mods, focusedRole: String?, valueOnlyField: Bool = false) -> KeyRoute {
        guard modifiers.isEmpty else { return .external }
        if let r = focusedRole, textInputRoles.contains(r) { return .external }
        if valueOnlyField, ["return", "enter"].contains(key.name.lowercased()) { return .axConfirm(confirmNote) }
        return .external
    }
}

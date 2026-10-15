import CoreGraphics
import XCTest

/// The stage tests create windows and synthesize AppKit events, which needs a logged-in graphical session.
/// The check goes through CoreGraphics only, so a machine without a window server skips these tests instead of crashing the test process on the first AppKit call.
enum GUISession {
    static var available: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return d["kCGSSessionOnConsoleKey"] as? Bool ?? false
    }

    static func require() throws {
        try XCTSkipUnless(available, "needs a logged-in graphical session")
    }
}

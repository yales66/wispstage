import AppKit
import ObjectiveC
import SwiftUI

/// What a SwiftUI `.onHover` reported, readable from the test.
@MainActor final class HoverRecord {
    var values: [Bool] = []
}

/// A hosting view whose whole area is one SwiftUI view with `.onHover`: unlike `MouseCountingView`, NSHostingView checks
/// whether the system cursor is hidden before it handles enter and move events.
@MainActor func hoverRecordingHostingView(frame: NSRect, record: HoverRecord) -> NSView {
    let host = NSHostingView(rootView: Color.blue.onHover { record.values.append($0) })
    host.frame = frame
    return host
}

/// Makes `+[NSCursor _isHidden]` (private) answer `hidden` until `restore()`, standing in for the system cursor hidden after typing
/// until the mouse moves. Nil when the method can't be found.
final class CursorHiddenDouble {
    private let method: Method
    private let original: IMP

    init?(hidden: Bool) {
        guard let m = class_getClassMethod(NSCursor.self, NSSelectorFromString("_isHidden")) else { return nil }
        method = m
        let block: @convention(block) (AnyObject) -> Bool = { _ in hidden }
        original = method_setImplementation(m, imp_implementationWithBlock(block))
    }

    func restore() { method_setImplementation(method, original) }

    /// What `+[NSCursor _isHidden]` answers right now.
    var answer: Bool {
        typealias Fn = @convention(c) (AnyClass, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Fn.self)(NSCursor.self, NSSelectorFromString("_isHidden"))
    }
}

import Foundation
import SwiftUI

/// Six bugs planted on purpose, switched on by launching the app with `WISPBOARD_PLANT_BUGS=1` in its environment
/// (`WISPBOARD_PLANT_BUGS=1 wispstage run` passes it through the driver to the app).
///
/// No scenario asserts on any of them. Each one is caught by a check Wispstage runs after every step, or shows up in a motion report.
/// Each bug shows up only after one particular action, so each one fails a different scenario:
///
/// | Bug | Shows up | Scenario | Caught by |
/// |---|---|---|---|
/// | 1. "Remind me when a card is due" gets a fixed narrow width and one line | German settings window | settings.de | truncation |
/// | 2. Once the due count changes, the summary line shows its raw template, "{count} cards due today" | after a drag | board.dragToDone | placeholder |
/// | 3. Selecting "Book a dentist appointment" pins its "Due" badge onto its title | after selecting it | board.dark | overlap |
/// | 4. ⌫ with a card selected is not handled | after the key press | board.deleteKey | beep |
/// | 5. Sync runs its work on the main thread and freezes the app | after pressing Sync | board.sync | responsive |
/// | 6. The inspector springs in with `.bouncy(duration: 0.6)` instead of `.snappy(duration: 0.3)` | inspector opening | inspector.motion | motion report |
enum PlantedBugs {
    static let enabled = ProcessInfo.processInfo.environment["WISPBOARD_PLANT_BUGS"] == "1"

    // 1. truncation
    static var narrowRemindLabel: Bool { enabled }
    /// Wide enough for the English label (184 pt), too narrow for the German one (206 pt); widths read from the settings window listing.
    static let remindLabelWidth: CGFloat = 188

    // 2. placeholder
    static var rawSummaryTemplate: Bool { enabled }
    static let summaryTemplate = "{count} cards due today"

    // 3. overlap
    static func badgeOnTitle(cardID: String, selected: Bool) -> Bool { enabled && selected && cardID == "book-a-dentist-appointment" }

    // 4. beep
    static var deleteKeyUnhandled: Bool { enabled }

    // 5. responsive: the driver gives every accessibility request 5 s to answer. It waits up to 5 s for the UI to settle after the
    // press, then asks once more and counts the app as hung when that request also gets no answer within 5 s; 12 s covers both.
    static var syncBlocksMainThread: Bool { enabled }
    static let syncBlockSeconds: TimeInterval = 12
    static func blockingSync() { Thread.sleep(forTimeInterval: syncBlockSeconds) }

    // 6. motion
    static var inspectorAnimation: Animation { enabled ? .bouncy(duration: 0.6) : .snappy(duration: 0.3) }
}

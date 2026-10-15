import CoreGraphics
import Testing
@testable import WispstageKit

/// When a window wait times out, the app's windows are looked up on every Space: a window that exists but is off screen means it is not on the current Space.
@Suite struct OffSpaceNoteTests {
    private static let frame = CGRect(x: 100, y: 100, width: 1040, height: 660)

    @Test(arguments: [
        ("window off screen", [WindowList.ListedWindow(frame: frame, onScreen: false)], true),
        ("no window", [], false),
        ("window on screen", [WindowList.ListedWindow(frame: frame, onScreen: true)], false),
        ("one on screen, one off screen", [.init(frame: frame, onScreen: true), .init(frame: frame, onScreen: false)], false),
        ("only a 1x1 helper window off screen", [.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1), onScreen: false)], false),
        ("only a transparent window off screen", [.init(frame: frame, onScreen: false, alpha: 0)], false),
    ] as [(String, [WindowList.ListedWindow], Bool)])
    func notesWindowsThatAreNotOnTheCurrentSpace(_ name: String, _ windows: [WindowList.ListedWindow], _ noted: Bool) {
        let note = WindowList.offSpaceNote(windows)
        #expect((note != nil) == noted, "\(name)")
        if noted { #expect(note?.contains("not on the current Space") == true) }
    }
}

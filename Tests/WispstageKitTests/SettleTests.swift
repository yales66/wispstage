import CoreGraphics
import Foundation
import Testing
@testable import WispstageKit

struct SettleTests {
    /// Hands out the given snapshots in order, then keeps handing out the last one; counts how many were taken.
    private final class Feed {
        let snaps: [Settle.Snapshot]
        var taken = 0
        init(_ snaps: [Settle.Snapshot]) { self.snaps = snaps }
        func next() -> Settle.Snapshot {
            defer { taken += 1 }
            return snaps[min(taken, snaps.count - 1)]
        }
    }

    private let text = ["AXStaticText|Waiting for client reply|1114,170,90,16"]

    private func snap(windowY: CGFloat) -> Settle.Snapshot {
        Settle.Snapshot(windows: [(id: 7, frame: CGRect(x: 1098, y: windowY, width: 360, height: 100))], elements: text)
    }

    /// A window moving: the text is already at its new position while the window frame is still moving there; it settles only once the move finishes.
    @Test func movingWindowIsNotSettledEvenIfTextsAreStill() {
        let feed = Feed([snap(windowY: 40), snap(windowY: 90), snap(windowY: 151), snap(windowY: 151)])
        #expect(Settle.wait(timeout: 5, interval: 0, take: feed.next))
        #expect(feed.taken == 4)
    }

    @Test func stillWindowAndTextsSettleOnSecondLook() {
        let feed = Feed([snap(windowY: 151)])
        #expect(Settle.wait(timeout: 5, interval: 0, take: feed.next))
        #expect(feed.taken == 2)
    }
}

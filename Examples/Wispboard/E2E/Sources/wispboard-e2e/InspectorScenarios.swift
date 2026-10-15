import CoreGraphics
import Foundation
import WispstageKit

/// The inspector panel on the right of the board.
let inspectorScenarios: [Scenario] = [
    // The inspector slides in with .snappy(duration: 0.3) and pushes the columns to the left. The last card in Done is on screen
    // before and after, so its movement is what the recording measures: it should reach its new place on the curve of that spring.
    scenario("inspector.motion") { t in
        try t.launchBoard()
        // Learn where that card ends up with the inspector open, then close the inspector again.
        try t.press(id: "board.toggleInspector")
        _ = try t.element(id: "inspector.panel")
        let openX = try t.x(of: "card.send-the-birthday-card")
        try t.press(id: "inspector.close")
        try t.waitGone(id: "inspector.panel")

        let slide = MotionSpec(
            name: "Inspector slides in", anchor: .firstMove, track: .named("card.send-the-birthday-card"),
            source: "Wispboard: the inspector animates with .snappy(duration: 0.3)",
            expectations: [MotionExpectation(.x, to: Double(openX), spring: MotionSpring(.snappy, duration: 0.3))])
        try t.recordMotion("inspector-open", ids: ["card.send-the-birthday-card"], specs: [slide]) {
            try t.press(id: "board.toggleInspector")
        }
        try t.shot("inspector-open")
    },
]

extension E2ETest {
    /// An element's left edge in points from the board window's left edge.
    func x(of id: String) throws -> CGFloat {
        let node = try element(id: id)
        guard let frame = node.frame, let window = try windows().first(where: { $0.kind == .main }) else {
            throw E2EFailure("Can't read the frame of \(id) or of the board window")
        }
        return frame.minX - window.frame.minX
    }
}

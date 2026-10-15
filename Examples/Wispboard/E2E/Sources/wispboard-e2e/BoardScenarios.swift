import Foundation
import WispstageKit

/// The board: cards, columns, the toolbar.
let boardScenarios: [Scenario] = [
    scenario("board.launch") { t in
        try t.launchBoard()
        for column in ["today", "next", "done"] { _ = try t.element(id: "column.\(column)") }
        try t.expect(try t.text(of: "board.dueSummary") == "3 cards due today", "Three cards are due today")
        try t.expect(try t.text(of: "column.today.count") == "3", "Today holds three cards")
        try t.shot("board")
    },

    scenario("board.newCard") { t in
        try t.launchBoard()
        try t.press(id: "board.newCard")
        _ = try t.element(id: "card.untitled")
        _ = try t.element(id: "inspector.title")
        // New Card opens the inspector with an empty title field ("Untitled" is its placeholder) and focuses it.
        try t.type("Buy oat milk")
        try t.key(.return)
        try t.waitText(of: "card.untitled.title", "Buy oat milk")
        try t.shot(id: "card.untitled", name: "renamed")
    },

    scenario("board.dragToDone") { t in
        try t.launchBoard()
        try t.drag(from: "card.water-the-ferns", to: "column.done")
        try t.waitText(of: "column.done.count", "3")
        try t.expect(try t.text(of: "column.today.count") == "2", "Today holds two cards after the drag")
        try t.expect(try t.text(of: "board.dueSummary") == "2 cards due today", "A done card is no longer due")
        try t.shot(id: "column.done", name: "done-column")
    },

    scenario("board.hoverDelete") { t in
        try t.launchBoard()
        try t.hover("card.renew-library-books")
        try t.shot(id: "card.renew-library-books", name: "hovered")
        try t.press(id: "card.renew-library-books.delete")
        try t.waitGone(id: "card.renew-library-books")
        try t.expect(try t.text(of: "column.next.count") == "2", "Next holds two cards after deleting one")
    },

    scenario("board.deleteKey") { t in
        try t.launchBoard()
        try t.click("card.reply-to-the-landlord")
        _ = try t.element(id: "inspector.panel")
        try t.key(.delete)
        try t.waitGone(id: "card.reply-to-the-landlord")
        try t.expect(try t.text(of: "board.dueSummary") == "2 cards due today", "Two cards are due after deleting one")
    },

    scenario("board.sync") { t in
        try t.launchBoard()
        try t.expect(try t.text(of: "board.syncStatus") == "Not synced yet", "Nothing synced at launch")
        try t.press(id: "board.sync")
        try t.waitText(of: "board.syncStatus", "Synced just now")
        try t.shot(id: "board.syncStatus", name: "synced")
    },

    scenario("board.dark") { t in
        try t.launchBoard(appearance: .dark)
        try t.click("card.book-a-dentist-appointment")
        _ = try t.element(id: "inspector.title")
        try t.shot("board-dark")
    },
]

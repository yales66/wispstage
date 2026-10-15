import Foundation
import WispstageKit

/// The settings window, in English and in German. Scenarios find elements by identifier, so the same steps work in both languages.
let settingsScenarios: [Scenario] = [
    scenario("settings.en") { t in
        try t.launchBoard()
        try t.openSettings()
        try t.shot("settings", window: .settings)
        try t.press(id: "settings.showCompleted")
        try t.waitGone(id: "column.done")
        try t.expect(t.exists(id: "column.today") && t.exists(id: "column.next"), "Today and Next stay when completed cards are hidden")
    },

    scenario("settings.de") { t in
        try t.launchBoard(language: "de", region: "de_DE")
        try t.expect(try t.text(of: "board.dueSummary") == "3 Karten heute fällig", "The summary line is in German")
        try t.shot("board-de")
        try t.openSettings()
        try t.shot("settings-de", window: .settings)
    },
]

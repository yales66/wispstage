import Foundation
import WispstageKit

extension E2ETest {
    /// Launches Wispboard's test host in a given language and appearance, and waits for the board window.
    func launchBoard(language: String = "en", region: String = "en_US", appearance: Appearance = .light,
                     step: String = "launch") throws {
        var arguments = LaunchSpec.localeArguments(language: language, region: region, hour24: language != "en")
        // Open with a fresh board window instead of restoring the windows of the previous launch.
        arguments += ["-ApplePersistenceIgnoreState", "YES"]
        // Pin the appearance so screenshots don't depend on the Mac's own setting (the test host reads this argument).
        arguments += ["-WispboardAppearance", appearance.rawValue]
        try launch(LaunchSpec(executable: configuration.defaultExecutable,
                              arguments: arguments,
                              ready: .anyWindow,
                              variant: Baselines.variant(language: language, appearance: appearance, hour24: language != "en"),
                              language: language,
                              missingHint: "Build it with: swift build --product WispboardTestHost (from Examples/Wispboard)"),
                   step: step)
        _ = try window(.main)
    }

    /// Opens the settings window with ⌘, and waits for it.
    func openSettings() throws {
        try key(",", modifiers: .command)
        _ = try window(.settings)
    }

    /// Waits until an element's text reads `expected` (the app updates some text a moment after the action that changes it).
    func waitText(of id: String, _ expected: String, timeout: TimeInterval = 5) throws {
        var last = ""
        let ok = Wait.until(timeout: timeout, interval: 0.1) {
            last = (try? text(of: .id(id))) ?? ""
            return last == expected
        }
        try expect(ok, "\(id) reads \"\(expected)\" (last read \"\(last)\")")
    }
}

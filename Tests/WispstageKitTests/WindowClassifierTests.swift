import Testing
@testable import WispstageKit

struct ConventionWindowClassifierTests {
    private let c = ConventionWindowClassifier()
    private func ev(_ json: String) -> E2EEvent { E2EEvent(json: json)! }

    @Test func readyFieldNamesIdentifyMainAndSettingsWindows() {
        let events = [
            ev(#"{"type":"ready","at":"x","windows":{"main":11,"settings":12,"other":13}}"#),
            ev(#"{"type":"ready","at":"x","settingsWindow":41,"mainWindow":42}"#),
            ev(#"{"type":"panel.show","at":"x","window":21}"#),
        ]
        #expect(c.knownWindows(events: events) == [11: .main, 12: .settings, 41: .settings, 42: .main])
    }

    @Test(arguments: [
        ("identifier is kind plus .window", "settings.window", "General", WindowKind.settings),
        ("custom kind", "inspector.window", "", WindowKind(rawValue: "inspector")),
        ("main window identifier", "main.window", "Untitled", .main),
        ("no identifier, settings recognized by title", nil, "Settings", .settings),
        ("Chinese title", nil, "设置", .settings),
        ("not recognized", nil, "General", .other),
        ("identifier not ending in .window", "sidebar.panel", "x", .other),
        ("only .window", ".window", "x", .other),
    ] as [(String, String?, String, WindowKind)])
    func guessesFromIdentifierAndTitle(_ name: String, _ identifier: String?, _ title: String, _ kind: WindowKind) {
        #expect(c.guess(identifier: identifier, title: title) == kind)
    }

    @Test func translucentWindowsUseTheLastReport() {
        let events = [
            ev(#"{"type":"windows.translucent","at":"x","windows":[21]}"#),
            ev(#"{"type":"windows.translucent","at":"x","windows":[21,31]}"#),
        ]
        #expect(c.translucentWindows(events: events) == [21, 31])
        #expect(c.translucentWindows(events: []).isEmpty)
    }

    @Test func windowKindCanBeExtendedWithStringLiterals() {
        let k: WindowKind = "inspector"
        #expect(k.rawValue == "inspector")
        #expect(k != .other)
        #expect(WindowKind.main.description == "main")
    }
}

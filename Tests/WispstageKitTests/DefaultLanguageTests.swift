import Testing
@testable import WispstageKit

struct DefaultLanguageTests {
    // When a scenario gives no LaunchSpec.language, the app under test displays in the system's preferred language, and checks (such as English plurals) use it too.
    @Test(arguments: [(["en-AU", "zh-Hans-AU"], "en-AU"), (["zh-Hans-CN"], "zh-Hans-CN"), ([String](), "en")])
    func usesSystemPreferredLanguageWhenNoneIsSpecified(_ preferred: [String], _ expected: String) {
        #expect(E2ETest.defaultLanguage(preferred: preferred) == expected)
    }
}

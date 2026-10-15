import CoreGraphics
import Testing
@testable import WispstageKit

struct PlaceholderTests {
    /// A sample app's copy key naming scheme (string function names such as k3_14, and keys with letter subkeys such as 4.1.library), passed in through `TextCheckConfig.extraPlaceholderPatterns`.
    static let appKeyPatterns = TextCheckConfig(extraPlaceholderPatterns: [
        #"(?<![\w.])k\d+([._]\d+)+(_[A-Za-z]\w*)?(?![\w])"#,
        #"(?<![\w.])\d+\.\d+(\.\d+)*\.[A-Za-z]\w*(?![\w.])"#,
    ]).compiledPatterns

    @Test(arguments: [
        ("还剩 %@ 分钟", "%@"),
        ("%d items", "%d"),
        ("%lld min", "%lld"),
        ("%1$@ 与 %2$@", "%1$@"),
        ("开始 {任务名}", "{任务名}"),
        ("Start {taskTitle}", "{taskTitle}"),
        ("k3.14", "k3.14"),
        ("查看 k1_4_today", "k1_4_today"),
        ("4.1.library", "4.1.library"),
    ])
    func recognizesPlaceholders(text: String, hit: String) {
        #expect(TextChecks.placeholders(in: text, copyKeys: [], extraPatterns: Self.appKeyPatterns).contains(hit))
    }

    @Test(arguments: [
        "还剩 80 分钟", "100% 完成", "10:40–11:20", "版本 1.2", "SampleApp", "50%", "¥30 / 月", "3.14",
    ])
    func ordinaryTextIsNotReported(text: String) {
        #expect(TextChecks.placeholders(in: text, copyKeys: [], extraPatterns: Self.appKeyPatterns).isEmpty)
    }

    @Test func copyKeyNamesAreNotRecognizedWithoutTheAppNamingScheme() {
        #expect(TextChecks.placeholders(in: "查看 k1_4_today", copyKeys: []).isEmpty)
        #expect(Self.appKeyPatterns.count == 2)
    }

    @Test func textEqualToAWholeCopyKeyIsReported() {
        #expect(TextChecks.placeholders(in: "7.21", copyKeys: ["7.21", "1.1"]) == ["7.21"])
        #expect(TextChecks.placeholders(in: "今天 7.21", copyKeys: ["7.21"]).isEmpty)
    }

    @Test func parsesKeysFromAStringsTable() {
        let src = """
        /* Comment */
        "1.1" = "SampleApp";

        /* Another one */
        "4.1.library" = "Library \\"Items\\"";
        """
        #expect(CopyKeys.parse(src) == ["1.1", "4.1.library"])
    }
}

struct CheckNameTests {
    @Test func fifteenBuiltInChecksHaveDistinctNames() {
        #expect(Check.builtIn.count == 15)
        #expect(Set(Check.builtIn.map(\.rawValue)).count == 15)
        #expect(Check.builtIn.first == .processAlive)
        #expect(Check.builtIn.contains(.missingIdentifier))
    }

    @Test func customChecksFailTheStepByDefaultAndAreJudgedInBothModes() {
        let mine = Check(rawValue: "my-check")
        #expect(!Check.builtIn.contains(mine))
        #expect(mine.failsStep)
        #expect(mine.judged(in: .foreground) && mine.judged(in: .background))
        #expect(!Check.keyFocus.judged(in: .foreground))
        #expect(!Check.contrast.failsStep)
    }
}

struct PluralTests {
    @Test(arguments: [
        ("1 Minutes left", "1 Minutes"),
        ("Done 1 cards", "1 cards"),
        ("in 1 hours", "1 hours"),
    ])
    func countOfOneWithAPluralIsReported(text: String, hit: String) {
        #expect(TextChecks.pluralOne(in: text) == [hit])
    }

    @Test(arguments: [
        "1 Minute left", "11 Minutes", "21 cards", "2.1 hours", "Step 1 is done", "1 has started",
        "10:1 minutes", "1 of 3", "Plan 1 was good", "1 plus 1",
    ])
    func isNotReported(text: String) {
        #expect(TextChecks.pluralOne(in: text).isEmpty)
    }
}

struct LayoutCheckTests {
    private func box(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, clip: CGRect? = nil) -> TextBox {
        TextBox(text: text, frame: CGRect(x: x, y: y, width: w, height: h), clip: clip)
    }

    @Test func overlappingTextIsReported() {
        let a = box("Today", 10, 10, 50, 20), b = box("Inbox", 40, 15, 50, 20)
        let hits = TextChecks.overlaps([a, b])
        #expect(hits.count == 1)
        #expect(hits.first?.0.text == "Today")
    }

    @Test func adjacentTextOrAOnePointOverlapIsNotReported() {
        let a = box("Today", 10, 10, 50, 20), b = box("Inbox", 60, 10, 50, 20), c = box("Archive", 10, 29, 50, 20)
        #expect(TextChecks.overlaps([a, b, c]).isEmpty)
    }

    @Test func duplicateNodeWithTheSameTextAndFrameIsNotReported() {
        let a = box("Today", 10, 10, 50, 20)
        #expect(TextChecks.overlaps([a, a]).isEmpty)
    }

    @Test func textScrolledOutOfViewIsIgnored() {
        let clip = CGRect(x: 0, y: 0, width: 100, height: 100)
        let a = box("Top", 10, 150, 50, 20, clip: clip), b = box("Bottom", 20, 155, 50, 20, clip: clip)
        #expect(TextChecks.overlaps([a, b]).isEmpty)
        #expect(TextChecks.outOfBounds([a, b], window: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
    }

    @Test func textOutsideTheWindowIsReported() {
        let win = CGRect(x: 100, y: 100, width: 400, height: 300)
        let inside = box("Inside", 110, 110, 50, 20)
        let right = box("Past right", 480, 110, 50, 20)
        let above = box("Past top", 110, 90, 50, 20)
        let hits = TextChecks.outOfBounds([inside, right, above], window: win)
        #expect(hits.map(\.text) == ["Past right", "Past top"])
    }

    @Test func textSlightlyPastTheEdgeIsNotReported() {
        let win = CGRect(x: 100, y: 100, width: 400, height: 300)
        #expect(TextChecks.outOfBounds([box("Edge", 450.5, 100, 50, 20)], window: win).isEmpty)
    }

    @Test func zeroSizedTextIsIgnored() {
        let win = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(TextChecks.outOfBounds([box("", 500, 500, 0, 0)], window: win).isEmpty)
    }
}

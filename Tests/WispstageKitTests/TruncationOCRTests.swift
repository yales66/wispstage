import CoreGraphics
import Testing
@testable import WispstageKit

struct TruncationOCRTests {
    @Test func normalizationLowercasesAndStripsWhitespaceAndPunctuation() {
        #expect(TruncationOCR.normalized("Hello, World 你好！") == "helloworld你好")
    }

    @Test(arguments: [
        ("ellipsis", "整理本周的会议记录", "整理本周的…", true),
        ("two dots count as an ellipsis", "Write the weekly report", "Write the..", true),
        ("under 90% of the characters", "abcdefghij", "abcdefgh", true),
        ("exactly 90% does not count", "abcdefghij", "abcdefghi", false),
        ("full text recognized", "Long title here", "Long title here", false),
        ("extra recognized characters are not truncation", "设置", "设置 >", false),
        ("full text has its own ellipsis", "加载中…", "加载中…", false),
        // Measured: the title was shown in full and Vision dropped one middle character, ratio 0.89; text whose last character was not cut off does not count as clipped
        ("one middle character missed", "整理上周的会议记录", "整理上周会议记录", false),
        ("end clipped and last character misread", "被外层裁掉一截的长句子", "被外层裁掉一=", true),
    ] as [(String, String, String, Bool)])
    func judgesTruncation(_ name: String, full: String, ocr: String, truncated: Bool) {
        #expect(TruncationOCR.verdict(full: full, ocr: ocr).isTruncated == truncated, "\(name)")
    }

    /// A button's description is what VoiceOver reads and can be longer than the displayed text (e.g. a hint appended after the title): only an ellipsis counts.
    @Test func textFromADescriptionCountsOnlyAnEllipsis() {
        let full = "整理本周的会议记录，按下打开详情"
        #expect(!TruncationOCR.verdict(full: full, ocr: "整理本周会议记录 共 3 项", ellipsisOnly: true).isTruncated)
        #expect(TruncationOCR.verdict(full: full, ocr: "整理本周的…", ellipsisOnly: true).isTruncated)
    }

    @Test func nothingRecognizedIsNotJudged() {
        #expect(TruncationOCR.verdict(full: "整理本周的会议记录", ocr: "") == .unreadable)
    }

    @Test func masksOtherElementsExceptNeighborsCoveringMoreThanHalf() {
        let me = CGRect(x: 0, y: 0, width: 100, height: 20)
        let right = CGRect(x: 104, y: 0, width: 80, height: 20)
        let wrapper = CGRect(x: -2, y: -2, width: 104, height: 24)
        let half = CGRect(x: 40, y: 0, width: 100, height: 20)
        #expect(TruncationOCR.masks(me: me, others: [right, wrapper, half]) == [right])
    }

    @Test func tokensSplitChinesePerCharacter() {
        #expect(TruncationOCR.tokens("Hello world 你好…") == ["Hello", "world", "你", "好", "…"])
        #expect(TruncationOCR.tokens("Hel… ok") == ["Hel…", "ok"])
    }

    @Test func tokensGoToTheSmallestFrameContainingTheirCenter() {
        let row = CGRect(x: 0, y: 0, width: 300, height: 20)
        let a = CGRect(x: 0, y: 0, width: 100, height: 20)
        let b = CGRect(x: 120, y: 0, width: 100, height: 20)
        let tokens: [(String, CGRect)] = [("A", CGRect(x: 10, y: 2, width: 12, height: 16)),
                                          ("B", CGRect(x: 130, y: 2, width: 12, height: 16)),
                                          ("C", CGRect(x: 250, y: 2, width: 12, height: 16)),
                                          ("D", CGRect(x: 500, y: 2, width: 12, height: 16))]
        #expect(TruncationOCR.assign(tokens, to: [row, a, b]) == [1: "A", 2: "B", 0: "C"])
    }

    @Test(arguments: [
        ("static text takes its value", "AXStaticText", "Settings", nil, nil, nil, "Settings"),
        ("button takes its title", "AXButton", nil, "Save", "Store", nil, "Save"),
        ("button without a title takes its description", "AXButton", nil, "", "Store", nil, "Store"),
        ("empty text field takes its placeholder", "AXTextField", "", nil, nil, "Write an idea", "Write an idea"),
        ("text field with text does not take its placeholder", "AXTextField", "Typed", nil, nil, "Write an idea", nil),
        ("other roles take nothing", "AXGroup", "x", "y", "z", nil, nil),
    ] as [(String, String, String?, String?, String?, String?, String?)])
    func takesTheDisplayedText(_ name: String, role: String, value: String?, title: String?, desc: String?, ph: String?, want: String?) {
        #expect(TruncationOCR.displayedText(role: role, value: value, title: title, description: desc, placeholder: ph) == want, "\(name)")
    }

    /// Regression of the 48 cases from the 2026-10-14 truncation recognition measurement (two layouts, 11 pt and 13 pt, named by the case prefixes tr11 and tr13;
    /// values come from the text recognized from per-element crops in that run's scan.json; the first characters of the long Chinese sentence were later swapped
    /// for different ones in both the full and the recognized text, keeping the length and the repeated characters): all 48 must stay correct after any change to the verdict rules.
    @Test(arguments: [
        ("tr11 btn.en.N", "Archive", "Archive", true, false),
        ("tr11 btn.en.T", "Archive all completed reminders now", "Archive all complet...", true, true),
        ("tr11 btn.zh.T", "归档全部已完成的提醒事项", "归档全部已完成…", true, true),
        ("tr11 clip.en.N", "Fits", "Fits", false, false),
        ("tr11 clip.en.T", "Clipped label too wide", "Clipped label tc", false, true),
        ("tr11 clip.zh.N", "放得下", "放得下", false, false),
        ("tr11 clip.zh.T", "被外层裁掉一半的标签", "被外层裁掉一=", false, true),
        ("tr11 mid.en.T", "The quick brown fox jumps over the lazy dog near the riverbank", "The quick brow...r the riverbank", false, true),
        ("tr11 mid.zh.T", "定下的日程临近：十月十四日下午三点开会讨论季度计划", "定下的日程临近…会讨论季度计划", false, true),
        ("tr11 multi.en.N", "Two short lines\nfit fine", "Two short lines fit fine", false, false),
        ("tr11 multi.en.T", "Reminders you snooze come back at the time you picked, and the list keeps them in order until you finish each one", "Reminders you snooze come back at the time you picked, and the list kee...", false, true),
        ("tr11 multi.zh.T", "推迟的提醒会在你选的时间回来，列表按顺序留着它们，直到你逐条做完为止，不会自动删除任何一条", "推迟的提醒会在你选的时间回来，列表按 顺序留着它们，直到你逐条做完为止，…", false, true),
        ("tr11 ns.en.N", "Short label", "Short label", false, false),
        ("tr11 ns.en.T", "The quick brown fox jumps over the lazy dog near the riverbank", "The quiCK brown fox Jumps o...", false, true),
        ("tr11 ns.zh.N", "短标签", "短标签", false, false),
        ("tr11 ns.zh.T", "定下的日程临近：十月十四日下午三点开会讨论季度计划", "定下的日程临近：十月十四日…", false, true),
        ("tr11 ph.en.N", "Search", "Search", false, false),
        ("tr11 ph.en.T", "Search all your notes and reminders here", "Search all your notes and r", false, true),
        ("tr11 ph.zh.N", "搜索", "搜索", false, false),
        ("tr11 ph.zh.T", "在这里搜索你的全部笔记与提醒事项", "在这里搜索你的全部笔记与提", false, true),
        ("tr11 tail.en.N", "Short label", "Short label", false, false),
        ("tr11 tail.en.T", "The quick brown fox jumps over the lazy dog near the riverbank", "The quick brown fox jumps ov...", false, true),
        ("tr11 tail.zh.N", "短标签", "短标签", false, false),
        ("tr11 tail.zh.T", "定下的日程临近：十月十四日下午三点开会讨论季度计划", "定下的日程临近：十月十四日下…", false, true),
        ("tr13 btn.en.N", "Archive", "Archive", true, false),
        ("tr13 btn.en.T", "Archive all completed reminders now", "Archive all complet...", true, true),
        ("tr13 btn.zh.T", "归档全部已完成的提醒事项", "归档全部已完成…", true, true),
        ("tr13 clip.en.N", "Fits", "Fits", false, false),
        ("tr13 clip.en.T", "Clipped label too wide", "Clipped label", false, true),
        ("tr13 clip.zh.N", "放得下", "放得下", false, false),
        ("tr13 clip.zh.T", "被外层裁掉一半的标签", "外层裁掉-", false, true),
        ("tr13 mid.en.T", "The quick brown fox jumps over the lazy dog near the riverbank", "The quick br...the riverbank", false, true),
        ("tr13 mid.zh.T", "定下的日程临近：十月十四日下午三点开会讨论季度计划", "定下的日程临…讨论季度计划", false, true),
        ("tr13 multi.en.N", "Two short lines\nfit fine", "Two short lines fit fine", false, false),
        ("tr13 multi.en.T", "Reminders you snooze come back at the time you picked, and the list keeps them in order until you finish each one", "Reminders you snooze come back at the time you picked, an...", false, true),
        ("tr13 multi.zh.T", "推迟的提醒会在你选的时间回来，列表按顺序留着它们，直到你逐条做完为止，不会自动删除任何一条", "推迟的提醒会在你选的时间回来， 列表按顺序留着它们，直到你逐.", false, true),
        ("tr13 ns.en.N", "Short label", "Short label", false, false),
        ("tr13 ns.en.T", "The quick brown fox jumps over the lazy dog near the riverbank", "The quick brown fox jum...", false, true),
        ("tr13 ns.zh.N", "短标签", "短标签", false, false),
        ("tr13 ns.zh.T", "定下的日程临近：十月十四日下午三点开会讨论季度计划", "定下的日程临近：十月十…", false, true),
        ("tr13 ph.en.N", "Search", "Search", false, false),
        ("tr13 ph.en.T", "Search all your notes and reminders here", "Search all your notes al", false, true),
        ("tr13 ph.zh.N", "搜索", "搜索", false, false),
        ("tr13 ph.zh.T", "在这里搜索你的全部笔记与提醒事项", "在这里搜索你全部笔记", false, true),
        ("tr13 tail.en.N", "Short label", "Short label", false, false),
        ("tr13 tail.en.T", "The quick brown fox jumps over the lazy dog near the riverbank", "The quick brown fox jump...", false, true),
        ("tr13 tail.zh.N", "短标签", "短标签", false, false),
        ("tr13 tail.zh.T", "定下的日程临近：十月十四日下午三点开会讨论季度计划", "定下的日程临近：十月十四…", false, true),
    ] as [(String, String, String, Bool, Bool)])
    func regressionOfThe48MeasuredCases(_ name: String, full: String, ocr: String, ellipsisOnly: Bool, truncated: Bool) {
        #expect(TruncationOCR.verdict(full: full, ocr: ocr, ellipsisOnly: ellipsisOnly).isTruncated == truncated, "\(name)")
    }

    @Test(arguments: [
        ("visible and fully showing", Occlusion.State.visible, CGRect(x: 0, y: 0, width: 100, height: 20), CGRect(x: 0, y: 0, width: 100, height: 20), true),
        ("partly under an overlay", .partialUnderLayer, CGRect(x: 0, y: 0, width: 100, height: 20), CGRect(x: 0, y: 0, width: 100, height: 20), false),
        ("partly covered", .partial, CGRect(x: 0, y: 0, width: 100, height: 20), CGRect(x: 0, y: 0, width: 100, height: 20), false),
        ("half outside the scroll area", .visible, CGRect(x: 0, y: 0, width: 100, height: 20), CGRect(x: 0, y: 0, width: 100, height: 9), false),
        ("shown part within half a point counts as fully showing", .visible, CGRect(x: 0, y: 0, width: 100, height: 20), CGRect(x: 0, y: 0.3, width: 100, height: 19.7), true),
    ] as [(String, Occlusion.State, CGRect, CGRect, Bool)])
    func onlyUncoveredFullyShowingTextGoesToRecognition(_ name: String, state: Occlusion.State, frame: CGRect, visible: CGRect, want: Bool) {
        #expect(TruncationOCR.eligible(state: state, frame: frame, visibleFrame: visible) == want, "\(name)")
    }

    @Test func frameMovingMoreThanHalfAPointAcrossTheScreenshotIsNotJudged() {
        let a = CGRect(x: 10, y: 10, width: 100, height: 20)
        #expect(TruncationOCR.stable(a, a.offsetBy(dx: 0.4, dy: 0)))
        #expect(!TruncationOCR.stable(a, a.offsetBy(dx: 0, dy: 3)))
        #expect(!TruncationOCR.stable(a, nil))
    }
}

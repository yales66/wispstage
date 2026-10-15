import CoreGraphics
import Testing
@testable import WispstageKit

struct AXListingTests {
    private func e(_ depth: Int, _ role: String, id: String? = nil, text: String? = nil,
                   frame: CGRect? = CGRect(x: 10, y: 20, width: 30, height: 40), visible: Bool = true, occluded: Bool = false) -> AXListing.Entry {
        AXListing.Entry(depth: depth, role: role, id: id, text: text, frame: frame, visible: visible, occluded: occluded)
    }

    @Test func oneLinePerElementIndentedByKeptAncestors() {
        let out = AXListing.render([
            e(0, "AXWindow", text: "SampleApp"),
            e(1, "AXGroup"),                                   // plain container, dropped
            e(2, "AXGroup", id: "main.timeline"),
            e(3, "AXStaticText", id: "main.clock", text: "10:40", frame: CGRect(x: 100.4, y: 200.6, width: 44, height: 18)),
            e(2, "AXButton", text: "Next Day", occluded: true),
        ])
        #expect(out == """
        Window "SampleApp" (10,20 30x40)
          Group #main.timeline (10,20 30x40)
            StaticText #main.clock "10:40" (100,201 44x18)
          Button "Next Day" (10,20 30x40) occluded

        """)
    }

    @Test func invisibleElementsAreNotListed() {
        let out = AXListing.render([e(0, "AXStaticText", text: "Scrolled away", visible: false), e(0, "AXStaticText", text: "Here")])
        #expect(out == "StaticText \"Here\" (10,20 30x40)\n")
    }

    @Test func textIsTruncatedToSixtyCharactersOnOneLine() {
        let long = String(repeating: "字", count: 70)
        let out = AXListing.render([e(0, "AXStaticText", text: "第一行\n" + long)])
        let quoted = out.split(separator: "\"")[1]
        #expect(quoted.count == 61)
        #expect(quoted.hasPrefix("第一行⏎字"))
        #expect(quoted.hasSuffix("…"))
    }
}

struct ShotsModeTests {
    @Test(arguments: [
        (["smoke"], ShotsMode.key, ["smoke"]),
        (["--shots=all", "smoke.keys", "settings."], .all, ["smoke.keys", "settings."]),
        (["settings.", "--shots=none"], .none, ["settings."]),
        (["--shots=key"], .key, []),
    ] as [([String], ShotsMode, [String])])
    func shotsModeIsTakenFromRunArguments(args: [String], mode: ShotsMode, filters: [String]) throws {
        let o = try RunOptions.parse(args)
        #expect(o.shots == mode)
        #expect(o.filters == filters)
    }

    @Test func invalidShotsModeThrows() {
        #expect(throws: E2EFailure.self) { try RunOptions.parse(["--shots=some"]) }
    }

    @Test(arguments: [
        (ShotsMode.key, 1, nil, true), (.key, 2, nil, false), (.key, 5, true, true), (.key, 3, false, false),
        (.all, 4, nil, true), (.all, 4, false, false),
        (.none, 1, nil, false), (.none, 2, true, true),
    ] as [(ShotsMode, Int, Bool?, Bool)])
    func whichStepsKeepAFullWindowScreenshot(mode: ShotsMode, step: Int, explicit: Bool?, capture: Bool) {
        #expect(mode.capturesStep(step, explicit: explicit) == capture)
    }
}

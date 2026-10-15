import Testing
@testable import WispstageKit

struct OutputLineTests {
    private let e2e = PrefixedLineProtocol(prefix: "E2E_")

    @Test func eventLineYieldsTypeAndFields() throws {
        let line = e2e.parse(#"E2E_EVENT {"type":"timer.start","at":"2026-10-14T10:40:00","item":"x"}"#)
        guard case .event(let e) = line else { Issue.record("Not an event: \(line)"); return }
        #expect(e.type == "timer.start")
        #expect(e.at == "2026-10-14T10:40:00")
        #expect(e["item"] as? String == "x")
    }

    @Test func stateLineKeepsRawJSON() {
        #expect(e2e.parse(#"E2E_STATE {"items":[]}"#) == .reply(kind: "STATE", payload: #"{"items":[]}"#))
    }

    @Test func otherLines() {
        #expect(e2e.parse("E2E_SAVED") == .reply(kind: "SAVED", payload: ""))
        #expect(e2e.parse("E2E_ERROR unknown command foo") == .error("unknown command foo"))
        #expect(e2e.parse("E2E_ERROR") == .error(""))
        #expect(e2e.parse("PREVIEW_WINDOWS main=123") == .other("PREVIEW_WINDOWS main=123"))
        #expect(e2e.parse(#"E2E_EVENT not json"#) == .other(#"E2E_EVENT not json"#))
    }

    @Test(arguments: [
        ("a different prefix is not recognized", "WISPSTAGE_STATE {}"),
        ("no uppercase name after the prefix", "E2E_state {}"),
        ("prefix only", "E2E_"),
        ("prefix not at line start", "x E2E_STATE {}"),
    ])
    func repliesWithoutThisPrefixAreKeptAsIs(_ name: String, _ line: String) {
        #expect(e2e.parse(line) == .other(line))
    }

    @Test func defaultPrefix() {
        let p = PrefixedLineProtocol(prefix: PrefixedLineProtocol.defaultPrefix)
        #expect(p.parse("WISPSTAGE_DONE 3") == .reply(kind: "DONE", payload: "3"))
        guard case .event(let e) = p.parse(#"WISPSTAGE_EVENT {"type":"ready"}"#) else { Issue.record("Not an event"); return }
        #expect(e.type == "ready")
    }
}

struct JSONPathTests {
    @Test func readsFieldsByPath() throws {
        let json = try JSONValue.parse(#"{"session":{"id":"A","minutes":80},"items":[{"title":"A"},{"title":"B"}]}"#)
        #expect(json["session.minutes"] as? Int == 80)
        #expect(json["items.1.title"] as? String == "B")
        #expect(json["items.5.title"] == nil)
        #expect(json["nope"] == nil)
    }
}

struct FilterTests {
    @Test func filtersByNameOrPrefix() {
        let names = ["smoke.preview", "settings.general.save", "editor.text.drag", "sidebar.search"]
        #expect(ScenarioFilter.select(names, filters: []) == names)
        #expect(ScenarioFilter.select(names, filters: ["settings."]) == ["settings.general.save"])
        #expect(ScenarioFilter.select(names, filters: ["sidebar.search", "smoke"]) == ["smoke.preview", "sidebar.search"])
        #expect(ScenarioFilter.select(names, filters: ["editor*"]) == ["editor.text.drag"])
    }

    @Test func fileNameDropsUnusableCharacters() {
        #expect(FileName.safe("after launch / step 2:look") == "after-launch-step-2-look")
    }
}

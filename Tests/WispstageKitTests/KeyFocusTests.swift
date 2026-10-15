import Testing
import WispstageClient
@testable import WispstageKit

/// stage.* events on the stage library's socket (see the stage library Wispstage).
struct KeyFocusTests {
    private func ev(_ json: String) -> StageEvent { StageEvent(line: json)! }

    private var events: [StageEvent] {
        [
            ev(#"{"event":"stage.windowPinned","class":"SampleFloatingPanel","level":3,"window":31}"#),
            ev(#"{"event":"stage.becameKey","class":"SampleFloatingPanel","window":31}"#),
            ev(#"{"event":"stage.keyRequested","class":"SampleFloatingPanel","window":31}"#),
            ev(#"{"event":"stage.becameKey","class":"EscClosingWindow","window":41}"#),
        ]
    }

    @Test func windowBecomingKeyFailsWhenWindowsAreHidden() {
        let r = KeyFocus.check(events, since: 0, hidden: true)
        #expect(r.found == ["SampleFloatingPanel #31 became the key window", "EscClosingWindow #41 became the key window"])
        #expect(r.seen == 4)
    }

    @Test func onlyEventsAfterThePreviousStepCount() {
        #expect(KeyFocus.check(events, since: 2, hidden: true).found == ["EscClosingWindow #41 became the key window"])
        #expect(KeyFocus.check(events, since: 4, hidden: true).found.isEmpty)
    }

    @Test func notJudgedWhenWindowsAreNotHidden() {
        let r = KeyFocus.check(events, since: 0, hidden: false)
        #expect(r.found.isEmpty)
        #expect(r.seen == 4)
    }

    @Test func failsTheStep() {
        #expect(Check.keyFocus.failsStep)
    }

    @Test func foregroundModeOnlyLogsKeyAndActivationSeenByObserveOnlyStage() {
        let events = [
            ev(#"{"event":"stage.becameKey","class":"SampleFloatingPanel","observed":true,"window":31}"#),
            ev(#"{"event":"stage.beep","keyCode":0,"observed":true}"#),
            ev(#"{"event":"stage.activateRequested","observed":true,"via":"NSApp.activate"}"#),
            ev(#"{"event":"stage.becameActive","observed":true}"#),
        ]
        #expect(KeyFocus.observed(events, since: 0) == [
            "SampleFloatingPanel #31 became the key window", "App requested activation (NSApp.activate)", "App became the active app",
        ])
        #expect(KeyFocus.observed(events, since: 3) == ["App became the active app"])
        #expect(KeyFocus.observed(events, since: 4).isEmpty)
    }
}

struct StageBeepTests {
    private func ev(_ json: String) -> StageEvent { StageEvent(line: json)! }

    @Test func eachUnhandledKeyPressSinceThePreviousStepBecomesOneSentence() {
        let events = [
            ev(#"{"event":"stage.beep","keyCode":53,"window":31}"#),
            ev(#"{"event":"stage.keyRequested","window":31}"#),
            ev(#"{"event":"stage.beep"}"#),
        ]
        let r = StageBeep.check(events, since: 0)
        #expect(r.found == ["Key press not handled (key code 53), the app would have played a beep", "Key press not handled (key code ?), the app would have played a beep"])
        #expect(r.seen == 3)
        #expect(StageBeep.check(events, since: 1).found == ["Key press not handled (key code ?), the app would have played a beep"])
        #expect(StageBeep.check(events, since: 3).found.isEmpty)
    }

    @Test func beepRecordedInForegroundModeActuallySounded() {
        let events = [ev(#"{"event":"stage.beep","keyCode":0,"observed":true,"window":31}"#)]
        #expect(StageBeep.check(events, since: 0).found == ["Key press not handled (key code 0), the app played a beep"])
    }
}

import Foundation
import WispstageClient

/// In hidden-window mode, no window of the app under test may become the key window (`Check.keyFocus`).
///
/// The key window receives system keyboard input: while the app is not frontmost, a nonactivating panel can still become key,
/// and what the user types in another app goes into the window under test. The stage keeps windows from becoming key; if one does, it sends `stage.becameKey`
/// over the socket (with class and window). After each step the driver checks for this event since the previous step.
///
/// In foreground mode the stage runs in observe-only mode: windows are meant to become key and the app is meant to activate, so nothing fails; `observed` only writes these events to the log.
enum KeyFocus {
    /// Turns each "window became key" event in `events` from `since` on into a sentence; `seen` is where the next step resumes. Not judged when windows are not hidden.
    static func check(_ events: [StageEvent], since: Int, hidden: Bool) -> (found: [String], seen: Int) {
        guard hidden, since < events.count else { return ([], max(since, events.count)) }
        let found = events[since...].filter { $0.name == StageEvent.becameKey }.map(keyLine)
        return (found, events.count)
    }

    /// Turns each become-key, activation request and actual activation in `events` from `since` on into a sentence (logged only, not judged).
    static func observed(_ events: [StageEvent], since: Int) -> [String] {
        guard since < events.count else { return [] }
        return events[since...].compactMap { e in
            switch e.name {
            case StageEvent.becameKey: keyLine(e)
            case StageEvent.activateRequested: "App requested activation (\(e["via"] as? String ?? "?"))"
            case StageEvent.becameActive: "App became the active app"
            default: nil
            }
        }
    }

    private static func keyLine(_ e: StageEvent) -> String {
        let cls = e["class"] as? String ?? "?"
        let window = e.int("window").map { "#\($0)" } ?? "#?"
        return "\(cls) \(window) became the key window"
    }
}

/// A key press nobody handled (`Check.beep`): a real app plays the system beep. In background mode the stage keeps it silent and sends `stage.beep` (with keyCode) over the socket;
/// the observe-only stage in foreground mode lets it sound and also sends `stage.beep`, with `observed: true`. An app making a sound the user did not expect fails the step in both modes.
enum StageBeep {
    static func check(_ events: [StageEvent], since: Int) -> (found: [String], seen: Int) {
        guard since < events.count else { return ([], max(since, events.count)) }
        let found = events[since...].filter { $0.name == StageEvent.beep }.map { e in
            "Key press not handled (\(e.int("keyCode").map { "key code \($0)" } ?? "key code ?")), the app \(e.observed ? "played" : "would have played") a beep"
        }
        return (found, events.count)
    }
}

extension RunMode {
    /// Value of the `WISPSTAGE_STAGE` environment variable when launching the app under test (the stage library's `Wispstage.Mode`): background mode uses `1`,
    /// foreground mode uses observe-only mode `observe`, where the app comes to the front and windows become key as usual and the stage only reports events.
    var stageEnvironmentValue: String { usesStage ? "1" : "observe" }

    /// Whether failing to connect to the stage is an error: background mode relies on it to hide windows and block key status, so it cannot run without it; foreground mode only uses its events to judge beeps,
    /// so apps that do not link the stage library (adoption level 0) still run, and the beep check has no source and is not judged.
    var requiresStage: Bool { usesStage }
}

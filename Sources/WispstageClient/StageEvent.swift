import Foundation

/// One event on the stage library's socket: one JSON line, with `event` as the name (such as `stage.beep`) and the rest as fields.
public struct StageEvent: @unchecked Sendable, Equatable, CustomStringConvertible {
    public static let beep = "stage.beep"
    public static let keyRequested = "stage.keyRequested"
    public static let activateRequested = "stage.activateRequested"
    /// A window actually became key (the stage is meant to keep it from becoming key; once key, it has taken over the user's keyboard input).
    public static let becameKey = "stage.becameKey"
    /// The app actually became the active app (`NSApplication.didBecomeActiveNotification`). Emitted only in observe-only mode.
    public static let becameActive = "stage.becameActive"
    /// Every observe-only mode event carries this field set to true: the thing happened as usual (the window really became key, the activation request
    /// went to AppKit, the beep sounded), as opposed to the same-named background-mode event, which means "intercepted, not carried out".
    public static let observedField = "observed"
    /// A window was pinned to the minimum level for the first time; carries the level the app asked for.
    public static let windowPinned = "stage.windowPinned"
    /// A real event received by a global event monitor was dropped; carries `type` (the event type name, such as leftMouseDown).
    public static let globalEventDropped = "stage.globalEventDropped"

    public let name: String
    public let fields: [String: Any]
    /// The raw line as received (without the newline).
    public let raw: String

    public init?(line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["event"] as? String
        else { return nil }
        self.name = name
        fields = obj
        raw = line
    }

    public subscript(_ key: String) -> Any? { fields[key] }

    /// An integer field (JSON number).
    public func int(_ key: String) -> Int? { (fields[key] as? NSNumber)?.intValue }

    /// Emitted by observe-only mode (it happened as usual rather than being intercepted by the stage).
    public var observed: Bool { fields[Self.observedField] as? Bool == true }

    public var description: String { raw }

    public static func == (a: StageEvent, b: StageEvent) -> Bool { a.raw == b.raw }

    /// Encodes a command reply as one JSON line (sorted keys, no `event` key, which is how the driver tells it apart from events).
    public static func encodeReply(_ fields: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Encodes as one JSON line (sorted keys, no newline). Field values must be representable in JSON: strings, numbers, booleans, arrays, dictionaries.
    public static func encode(_ name: String, _ fields: [String: Any] = [:]) -> String {
        var obj = fields
        obj["event"] = name
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return #"{"event":"\#(name)"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}

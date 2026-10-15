import Foundation

/// How window kinds are recognized: window numbers the app reported through events, guesses from accessibility identifier and title, and which windows are translucent.
public protocol WindowClassifier: Sendable {
    /// Window numbers and kinds the app reported through events (later events can remove closed ones).
    func knownWindows(events: [E2EEvent]) -> [Int: WindowKind]
    /// For windows not among the known ones, guesses from the accessibility identifier and title.
    func guess(identifier: String?, title: String) -> WindowKind
    /// Translucent windows the app reported: a screenshot of a glass panel lacks what shows through it on screen, so its background color cannot be measured.
    func translucentWindows(events: [E2EEvent]) -> Set<Int>
}

/// The default convention (if your app reports windows this way you need no classifier of your own):
/// - integer fields in the `ready` event (possibly nested in objects): a field name containing `settings` is the settings window, one containing `main` is the main window;
/// - an accessibility identifier of the form `<kind>.window` uses the prefix as the kind; a title containing "settings" (English or Chinese) is the settings window;
/// - the `windows` array of the `windows.translucent` event (the last one) lists translucent windows.
public struct ConventionWindowClassifier: WindowClassifier {
    public init() {}

    public func knownWindows(events: [E2EEvent]) -> [Int: WindowKind] {
        var out: [Int: WindowKind] = [:]
        for e in events where e.type == "ready" { Self.collect(e.fields, into: &out) }
        return out
    }

    private static func collect(_ dict: [String: Any], into out: inout [Int: WindowKind]) {
        for (k, v) in dict {
            if let sub = v as? [String: Any] { collect(sub, into: &out); continue }
            guard let n = v as? Int, k != "at" else { continue }
            let key = k.lowercased()
            if key.contains("settings") { out[n] = .settings } else if key.contains("main") { out[n] = .main }
        }
    }

    public func guess(identifier: String?, title: String) -> WindowKind {
        if let id = identifier, id.hasSuffix(".window"), id.count > ".window".count {
            return WindowKind(rawValue: String(id.dropLast(".window".count)))
        }
        let t = title.lowercased()
        if t.contains("设置") || t.contains("settings") { return .settings }
        return .other
    }

    public func translucentWindows(events: [E2EEvent]) -> Set<Int> {
        Self.translucent(events)
    }

    /// The `windows` array of the `windows.translucent` event (the last one).
    public static func translucent(_ events: [E2EEvent]) -> Set<Int> {
        guard let last = events.last(where: { $0.type == "windows.translucent" }) else { return [] }
        return Set((last["windows"] as? [Any])?.compactMap { $0 as? Int } ?? [])
    }
}

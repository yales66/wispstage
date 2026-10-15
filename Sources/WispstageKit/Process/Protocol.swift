import Foundation

/// An event in the app's standard output: `type`, `at` (the current time on the app's clock) and the remaining fields.
public struct E2EEvent: Equatable, @unchecked Sendable, CustomStringConvertible {
    /// The JSON after the prefix in the event line, written to events.jsonl as is.
    public let raw: String
    public let fields: [String: Any]
    /// When the driver received this line.
    public let receivedAt: Date

    public init?(json: String, receivedAt: Date = Date()) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] is String
        else { return nil }
        raw = json
        fields = obj
        self.receivedAt = receivedAt
    }

    public var type: String { fields["type"] as? String ?? "" }
    public var at: String? { fields["at"] as? String }
    /// A field; nested ones can be read with a dot path: `e["windows.main"]`.
    public subscript(_ path: String) -> Any? { JSONValue(fields)[path] }

    public var description: String { raw }

    public static func == (a: E2EEvent, b: E2EEvent) -> Bool { a.raw == b.raw }
}

/// One line of standard output, parsed by `OutputProtocol`.
public enum OutputLine: Equatable {
    case event(E2EEvent)
    /// An error reported by the app (such as a malformed command); the content may be empty.
    case error(String)
    /// The app's reply to a command: the name and the content after it (may be empty).
    case reply(kind: String, payload: String)
    case other(String)
}

/// A value decoded by JSONSerialization, with fields read by dot path: `"session.minutes"`, `"items.0.title"`.
public struct JSONValue: @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public static func parse(_ text: String) throws -> JSONValue {
        JSONValue(try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]))
    }

    public subscript(_ path: String) -> Any? {
        var cur: Any? = value
        for seg in path.split(separator: ".") {
            if let d = cur as? [String: Any] {
                cur = d[String(seg)]
            } else if let a = cur as? [Any], let i = Int(seg) {
                cur = a.indices.contains(i) ? a[i] : nil
            } else {
                return nil
            }
            if cur is NSNull { return nil }
        }
        return cur
    }
}

/// `run <filter…>`: each filter is a full name or a prefix (a trailing `*` is optional); with no filters everything is selected. Registration order is kept.
public enum ScenarioFilter {
    public static func select(_ names: [String], filters: [String]) -> [String] {
        guard !filters.isEmpty else { return names }
        let prefixes = filters.map { $0.hasSuffix("*") ? String($0.dropLast()) : $0 }
        return names.filter { n in prefixes.contains { n == $0 || n.hasPrefix($0) } }
    }
}

public enum FileName {
    /// Screenshot and log file names: path separators, colons and whitespace become `-`, and runs of them collapse into one.
    public static func safe(_ s: String) -> String {
        var out = ""
        for ch in s {
            let bad = ch == "/" || ch == ":" || ch == "\\" || ch.isWhitespace || ch == "\"" || ch == "*" || ch == "?"
            if bad {
                if !out.hasSuffix("-") { out.append("-") }
            } else {
                out.append(ch)
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

extension String {
    func dropPrefix(_ p: String) -> String? { hasPrefix(p) ? String(dropFirst(p.count)) : nil }
}

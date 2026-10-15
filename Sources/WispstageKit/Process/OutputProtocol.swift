import Foundation

/// How to parse one line of the app's standard output.
public protocol OutputProtocol: Sendable {
    func parse(_ line: String) -> OutputLine
}

/// Prefixed line protocol: `<prefix>EVENT <json>` is an event, `<prefix>ERROR[ reason]` is an error,
/// any other `<prefix><name>[ payload]` (name made of uppercase letters, digits and underscores) is the reply `.reply(name, payload)`, and other lines are kept as is.
public struct PrefixedLineProtocol: OutputProtocol {
    /// Prefix used when none is given.
    public static let defaultPrefix = "WISPSTAGE_"
    public let prefix: String

    public init(prefix: String) { self.prefix = prefix }

    public func parse(_ line: String) -> OutputLine {
        guard let rest = line.dropPrefix(prefix) else { return .other(line) }
        let name = rest.prefix { $0 != " " }
        let payload = rest.count > name.count ? String(rest.dropFirst(name.count + 1)) : ""
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }) else { return .other(line) }
        switch name {
        case "EVENT": return E2EEvent(json: payload).map(OutputLine.event) ?? .other(line)
        case "ERROR": return .error(payload)
        default: return .reply(kind: String(name), payload: payload)
        }
    }
}

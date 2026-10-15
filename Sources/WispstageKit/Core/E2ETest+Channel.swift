import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WispstageClient

extension E2ETest {
    // MARK: - Command channel

    /// Sends one line over the command channel (the app's standard input), such as `advance 600` or `screen 2`. The step fails when the app replies with an error line.
    public func send(_ command: String) throws {
        try step(command) {
            let (p, _) = try requireApp()
            let mark = p.lineCount
            try p.send(command)
            settle()
            if let err = p.lines.dropFirst(mark).compactMap({ if case .error(let m) = $0.1 { return m } else { return nil } }).first {
                throw E2EFailure("App replied with error \(err)")
            }
        }
    }

    /// Sends a command line, waits for the reply the protocol recognizes as `reply`, and returns its content. Not a step.
    /// Fails if the app replies with an error line while waiting.
    public func request(_ command: String, reply: String, timeout: TimeInterval = Wait.defaultTimeout) throws -> String {
        let (p, _) = try requireApp()
        let mark = p.lineCount
        try p.send(command)
        var error: String?
        let payload: String? = try? Wait.value("reply \(reply)", timeout: timeout) { () -> String? in
            for (_, line) in p.lines.dropFirst(mark) {
                if case .reply(let kind, let payload) = line, kind == reply { return payload }
                if case .error(let m) = line, error == nil { error = m }
            }
            return error.map { _ in "" }
        }
        if let error { throw E2EFailure("\(command) replied with error \(error)") }
        guard let payload else { throw E2EFailure("No reply \(reply) to \(command) after \(timeout)s") }
        return payload
    }

    // MARK: - Events

    /// Events received so far (optionally filtered by type).
    public func events(_ type: String? = nil) -> [E2EEvent] {
        (app?.events ?? []).filter { type == nil || $0.type == type }
    }

    /// Waits for an event of the given type that matches and has not been taken by an earlier waitEvent; takes it and every event before it.
    @discardableResult
    public func waitEvent(_ type: String, where match: @escaping (E2EEvent) -> Bool = { _ in true },
                          timeout: TimeInterval = Wait.defaultTimeout) throws -> E2EEvent {
        do {
            let (idx, e): (Int, E2EEvent) = try Wait.value("event \(type)", timeout: timeout) {
                let evs = self.events()
                guard self.eventCursor < evs.count else { return nil }
                return evs.indices.dropFirst(self.eventCursor).lazy.map { ($0, evs[$0]) }.first { $0.1.type == type && match($0.1) }
            }
            eventCursor = idx + 1
            log("  event \(e.raw.prefix(200))")
            return e
        } catch var f as E2EFailure {
            let seen = events().dropFirst(eventCursor).map(\.type)
            f.reason += "; events received after it: \(seen.isEmpty ? "none" : seen.joined(separator: ", "))"
            f.step = f.step ?? "waitEvent \(type)"
            throw f
        }
    }

    @discardableResult
    public func waitEvent(type: String, where match: @escaping (E2EEvent) -> Bool = { _ in true },
                          timeout: TimeInterval = Wait.defaultTimeout) throws -> E2EEvent {
        try waitEvent(type, where: match, timeout: timeout)
    }

    /// Stops waiting for earlier events (only waits for later ones).
    public func skipPastEvents() { eventCursor = events().count }
}

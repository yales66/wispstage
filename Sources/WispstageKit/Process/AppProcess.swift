import Foundation
import WispstageClient
import Security

/// One process of the app under test: launches it, writes to standard input, collects standard output line by line.
/// Standard output is collected on a background thread and events are appended to events.jsonl right away; queries take the lock.
public final class AppProcess {
    public let process = Process()
    public let launchedAt = Date()
    public let executable: URL
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var _lines: [(Date, OutputLine)] = []
    private let eventsFile: FileHandle?
    private let stderrFile: FileHandle?
    private let outputProtocol: any OutputProtocol

    public init(executable: URL, arguments: [String], environment: [String: String], eventsLog: URL, stderrLog: URL,
                outputProtocol: any OutputProtocol = PrefixedLineProtocol(prefix: PrefixedLineProtocol.defaultPrefix)) throws {
        self.executable = executable
        self.outputProtocol = outputProtocol
        FileManager.default.createFile(atPath: eventsLog.path, contents: nil)
        FileManager.default.createFile(atPath: stderrLog.path, contents: nil)
        eventsFile = try? FileHandle(forWritingTo: eventsLog)
        eventsFile?.seekToEndOfFile()
        stderrFile = try? FileHandle(forWritingTo: stderrLog)
        stderrFile?.seekToEndOfFile()

        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.ingest(d)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.lock.lock(); self?.stderrFile?.write(d); self?.lock.unlock()
        }
        try process.run()
    }

    /// The stage's event channel (connected by `connectStage` in hidden-window mode).
    public private(set) var stage: StageClient?

    /// Connects to the stage socket inside the process under test; the stage.* events it receives are also appended line by line to events.jsonl.
    public func connectStage(path: String, timeout: TimeInterval = 10) throws {
        stage = try StageClient(path: path, timeout: timeout) { [weak self] e in
            guard let self else { return }
            self.lock.lock(); self.eventsFile?.write(Data((e.raw + "\n").utf8)); self.lock.unlock()
        }
    }

    /// Stage events received so far; empty when the stage is not enabled.
    public var stageEvents: [StageEvent] { stage?.events ?? [] }

    public var pid: pid_t { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    private func ingest(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let parsed = outputProtocol.parse(line)
            _lines.append((Date(), parsed))
            if case .event(let e) = parsed { eventsFile?.write(Data((e.raw + "\n").utf8)) }
        }
    }

    /// Every line received so far.
    public var lines: [(Date, OutputLine)] {
        lock.lock(); defer { lock.unlock() }
        return _lines
    }

    public var lineCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _lines.count
    }

    public var events: [E2EEvent] {
        lines.compactMap { if case .event(let e) = $0.1 { return e } else { return nil } }
    }

    /// The stage finished a mouse gesture: appends an `E2E_INPUT_DONE` output line recording when it finished. Motion recording takes the last one after an interaction as the release time
    /// (`MotionInputs.releaseTime`); the test host used to synthesize gestures and print this line itself when done, and now the stage synthesizes them and the driver records it.
    public func notePointerDone() {
        lock.lock(); defer { lock.unlock() }
        _lines.append((Date(), .other("E2E_INPUT_DONE")))
    }

    /// Writes one command line to standard input.
    public func send(_ command: String) throws {
        guard isRunning else { throw E2EFailure("App has exited, cannot send command \(command)") }
        try stdinPipe.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    }

    /// Ends the process: with `gracefully` and a command quit strategy, sends the command first for a normal quit, then SIGTERM if it does not exit in time, then SIGKILL.
    public func stop(gracefully: Bool, quit: QuitStrategy = .terminate) {
        if gracefully, isRunning, case .command(let command) = quit {
            try? send(command)
            _ = Wait.until(timeout: 5) { !self.isRunning }
        }
        if isRunning {
            process.terminate()
            _ = Wait.until(timeout: 3) { !self.isRunning }
        }
        if isRunning {
            kill(pid, SIGKILL)
            _ = Wait.until(timeout: 2) { !self.isRunning }
        }
        stage?.disconnect()
        lock.lock()
        try? eventsFile?.synchronize()
        lock.unlock()
    }

    /// Crash reports that appeared since this launch (those in ~/Library/Logs/DiagnosticReports starting with the executable's name).
    public func crashReport(wait: TimeInterval = 5) -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let name = executable.lastPathComponent
        var found: URL?
        _ = Wait.until(timeout: wait) {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            found = items.filter { $0.lastPathComponent.hasPrefix(name) }.first { url in
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return m >= self.launchedAt.addingTimeInterval(-1)
            }
            return found != nil
        }
        return found
    }
}

/// Where the stage socket goes: when the bundle under test enables App Sandbox, the app can only create files in its own container, so it goes in the container's tmp
/// (`~/Library/Containers/<Bundle ID>/Data/tmp`); without the sandbox it goes in the driver's temporary directory.
/// Unix domain socket paths are limited to 104 bytes, so the name is kept short.
public enum StageSocketPath {
    public static func make(executable: URL, tag: String) -> String {
        if let id = sandboxedBundleID(executable: executable) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return "\(home)/Library/Containers/\(id)/Data/tmp/stage-\(tag).sock"
        }
        return NSTemporaryDirectory() + "wispstage-\(tag).sock"
    }

    /// Bundle ID of the app bundle containing the executable, returned only when the bundle's signature has `com.apple.security.app-sandbox`.
    static func sandboxedBundleID(executable: URL) -> String? {
        let bundleURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundleURL.pathExtension == "app", let id = Bundle(url: bundleURL)?.bundleIdentifier else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let ent = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              ent["com.apple.security.app-sandbox"] as? Bool == true
        else { return nil }
        return id
    }
}

/// A failure in a scenario. The driver fills in `step`.
public struct E2EFailure: Error, CustomStringConvertible {
    public var reason: String
    public var step: String?
    public var check: Check?

    public init(_ reason: String, step: String? = nil, check: Check? = nil) {
        self.reason = reason
        self.step = step
        self.check = check
    }

    public var description: String {
        (check.map { "[\($0.rawValue)] " } ?? "") + reason
    }
}

/// Every wait means "until the condition holds, error on timeout"; the polling interval is 50 milliseconds.
public enum Wait {
    public static let defaultTimeout: TimeInterval = 5

    /// Returns true when the condition holds before the timeout.
    @discardableResult
    public static func until(timeout: TimeInterval = defaultTimeout, interval: TimeInterval = 0.05, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if cond() { return true }
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }
    }

    /// Polls until it gets a non-nil value; throws `E2EFailure(what)` on timeout.
    public static func value<T>(_ what: @autoclosure () -> String, timeout: TimeInterval = defaultTimeout, _ get: () throws -> T?) throws -> T {
        var result: T?
        var lastError: Error?
        let ok = until(timeout: timeout) {
            do { result = try get() } catch { lastError = error }
            return result != nil
        }
        if ok, let result { return result }
        throw E2EFailure("Timed out after \(timeout)s waiting for \(what())" + (lastError.map { " (\($0))" } ?? ""))
    }
}

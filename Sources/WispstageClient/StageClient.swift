import Foundation

/// A Unix domain socket address. `sun_path` holds only 104 bytes; returns nil when the path is too long.
public enum UnixSocketAddress {
    public static func make(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        return addr
    }
}

/// Splits on newlines: feed in bytes, get back complete lines (with any trailing `\r` removed).
public struct LineSplitter {
    public init() {}
    private var buffer = Data()

    public mutating func feed(_ d: Data) -> [String] {
        buffer.append(d)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            lines.append(line.hasSuffix("\r") ? String(line.dropLast()) : line)
        }
        return lines
    }
}

/// Driver side: connects to the stage library's socket and receives events line by line on a background thread. The stage library opens the socket
/// when the app under test starts and buffers events until a driver connects, then sends them all, so connecting late loses no events.
public final class StageClient: @unchecked Sendable {
    public let path: String
    private let fd: Int32
    private let lock = NSLock()
    private var _events: [StageEvent] = []
    private var _replies: [String] = []
    private let onEvent: (@Sendable (StageEvent) -> Void)?

    /// Waits up to `timeout` seconds for the socket file to appear and connect; throws if it can't connect. `onEvent` is called for each event on a background thread.
    public init(path: String, timeout: TimeInterval = 10, onEvent: (@Sendable (StageEvent) -> Void)? = nil) throws {
        self.path = path
        self.onEvent = onEvent
        guard var addr = UnixSocketAddress.make(path) else { throw StageClientError("socket path too long: \(path)") }
        let deadline = Date().addingTimeInterval(timeout)
        var connected: Int32 = -1
        while true {
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { throw StageClientError("cannot create socket (errno \(errno))") }
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if r == 0 { connected = s; break }
            close(s)
            if Date() >= deadline { throw StageClientError("could not connect to stage socket \(path) within \(timeout) s (errno \(errno))") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        fd = connected
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "WispstageClient"
        thread.start()
    }

    deinit { close(fd) }

    /// Disconnects: the stage library accepts one driver at a time and accepts the next only after a disconnect. The read thread holds this object while it runs, so it stays connected until you disconnect.
    public func disconnect() { shutdown(fd, SHUT_RDWR) }

    /// Events received so far.
    public var events: [StageEvent] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    /// Sends one command (one line of JSON). Replies arrive line by line in `replies`; use `request` to wait for a reply.
    public func send(_ json: String) throws {
        let data = Array((json + "\n").utf8)
        let n = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard n == data.count else { throw StageClientError("cannot write to stage socket (errno \(errno))") }
    }

    /// Command replies received so far (lines that aren't events).
    public var replies: [String] {
        lock.lock(); defer { lock.unlock() }
        return _replies
    }

    private let requestLock = NSLock()

    /// Sends a command and waits up to `timeout` seconds for its reply (one JSON line decoded into a dictionary). Don't call it on the thread where the stage answers commands (the main thread of the process under test).
    public func request(_ fields: [String: Any], timeout: TimeInterval = 5) throws -> [String: Any] {
        requestLock.lock(); defer { requestLock.unlock() }
        let before = replies.count
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        try send(String(decoding: data, as: UTF8.self))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let all = replies
            if all.count > before {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(all[before].utf8)) as? [String: Any] else {
                    throw StageClientError("stage reply is not JSON: \(all[before])")
                }
                return obj
            }
            if Date() >= deadline { throw StageClientError("no stage reply to \(fields["cmd"] ?? "?") within \(timeout) s") }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Hands a synthesized global event (`type` is the event type name, such as leftMouseDown) to the global event monitors the app under test has
    /// registered, and returns how many handlers received it. `x` and `y` are screen coordinates with a top-left origin. While the stage is on, real user
    /// events don't reach these handlers, so behavior such as "click elsewhere" can only be tested this way.
    public func globalEvent(_ type: String, x: Double, y: Double, timeout: TimeInterval = 5) throws -> Int {
        let r = try request(["cmd": "globalEvent", "type": type, "x": x, "y": y], timeout: timeout)
        guard r["ok"] as? Bool == true, let n = (r["delivered"] as? NSNumber)?.intValue else {
            throw StageClientError("globalEvent \(type) failed: \(r["error"] ?? r)")
        }
        return n
    }

    private func readLoop() {
        var splitter = LineSplitter()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            for line in splitter.feed(Data(buf[0..<n])) where !line.isEmpty {
                if let e = StageEvent(line: line) {
                    lock.lock(); _events.append(e); lock.unlock()
                    onEvent?(e)
                } else {
                    lock.lock(); _replies.append(line); lock.unlock()
                }
            }
        }
    }
}

public struct StageClientError: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}
